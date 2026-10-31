local qjson = require("qjson")

local function drain(reader, chunk_size)
    local parts = {}
    while true do
        local chunk, err = reader:next()
        assert.is_nil(err)
        if chunk == nil then break end
        assert.is_true(#chunk > 0 and #chunk <= chunk_size)
        parts[#parts + 1] = chunk
    end
    return table.concat(parts)
end

local function allocation_guard(limit, fn)
    local original_sub, original_concat = string.sub, table.concat
    rawset(string, "sub", function(s, first, last)
        local result = original_sub(s, first, last)
        assert.is_true(#result <= limit, "unbounded string slice")
        return result
    end)
    rawset(table, "concat", function(...)
        local result = original_concat(...)
        assert.is_true(#result <= limit, "unbounded output concatenation")
        return result
    end)
    local ok, err = pcall(fn)
    rawset(string, "sub", original_sub)
    rawset(table, "concat", original_concat)
    if not ok then error(err, 0) end
end

describe("bounded snapshot reader", function()
    it("streams unmodified spans within the bound without full output allocations", function()
        local body = qjson.decode('{"blob":"' .. string.rep("x", 1024 * 1024) .. '"}')
        allocation_guard(257, function()
            local reader = qjson.reader(body, { chunk_size = 257 })
            assert.are.equal(1024 * 1024 + 11, reader:length())
            local bytes = 0
            while true do
                local chunk, err = reader:next()
                assert.is_nil(err)
                if not chunk then break end
                bytes = bytes + #chunk
            end
            assert.are.equal(1024 * 1024 + 11, bytes)
        end)
    end)

    it("streams added large escaped strings without a full scalar encode", function()
        local body = qjson.decode('{"n":1}')
        body.text = string.rep('a\n"\\\0', 65536)
        allocation_guard(127, function()
            local reader = qjson.reader(body, { chunk_size = 127 })
            local expected = 17 + 65536 * 13
            assert.are.equal(expected, reader:length())
            local bytes = 0
            while true do
                local chunk, err = reader:next()
                assert.is_nil(err)
                if not chunk then break end
                bytes = bytes + #chunk
            end
            assert.are.equal(expected, bytes)
        end)
    end)

    it("handles escaping and nested edits at every chunk boundary", function()
        for size = 1, 23 do
            local body = qjson.decode('{"keep":"\\u0061","a":[{"x":1}]}')
            body.a[1].x = '"\b\f\n\r\t\\\0é'
            local reader = qjson.reader(body, { chunk_size = size })
            local expected = '{"keep":"\\u0061","a":[{"x":"\\\"\\b\\f\\n\\r\\t\\\\\\u0000é"}]}'
            assert.are.equal(#expected, reader:length())
            assert.are.equal(#expected, reader:length())
            assert.are.equal(expected, drain(reader, size))
        end
    end)

    it("normalizes duplicates recursively while preserving untouched scalar spans", function()
        local body = qjson.decode('{ "a":1,"a":2,"nested":{"b":0,"b":3},"s":"\\u0061" }')
        assert.are.equal('{ "a":1,"a":2,"nested":{"b":0,"b":3},"s":"\\u0061" }',
            drain(qjson.reader(body, { chunk_size = 7 }), 7))
        local reader = qjson.reader(body, { chunk_size = 7, normalize_duplicates = true })
        local expected = '{"a":2,"nested":{"b":3},"s":"\\u0061"}'
        assert.are.equal(#expected, reader:length())
        assert.are.equal(expected, drain(reader, 7))
    end)

    it("freezes proxies and plain tables including shared mixed subtrees", function()
        local body = qjson.decode('{"a":{"x":1}}')
        local value = { body = body, added = { text = "old" } }
        local reader = qjson.reader(value, { chunk_size = 3 })
        local length = reader:length()
        body.a.x, value.added.text = 9, "new"
        value.extra = true
        local out = drain(reader, 3)
        assert.are.equal(#out, length)
        local decoded = qjson.decode(out)
        assert.are.equal(1, decoded.body.a.x)
        assert.are.equal("old", decoded.added.text)
        assert.is_nil(decoded.extra)
    end)

    it("reports encoding errors and makes EOF, error and close terminal", function()
        local cycle = {}; cycle.self = cycle
        for _, value in ipairs({ math.huge, cycle, function() end, require("ffi").cast("void *", 0) }) do
            local reader = qjson.reader(value)
            local length, err = reader:length()
            assert.is_nil(length)
            assert.is_string(err)
            local chunk, next_err = reader:next()
            assert.is_nil(chunk)
            assert.is_string(next_err)
            local again, closed = reader:next()
            assert.is_nil(again)
            assert.is_truthy(closed:find("closed", 1, true))
            reader:close(); reader:close()
        end
        local reader = qjson.reader(false, { chunk_size = 1 })
        assert.are.equal("false", drain(reader, 1))
        local _, err = reader:next()
        assert.is_truthy(err:find("closed", 1, true))
        reader = qjson.reader({})
        reader:close(); reader:close()
        local _, closed = reader:next()
        assert.is_truthy(closed:find("closed", 1, true))
    end)

    it("does not retain a complete encoded replacement string", function()
        local body = qjson.decode('{}')
        body.blob = string.rep("x", 2 * 1024 * 1024)
        collectgarbage("collect")
        local before = collectgarbage("count")
        local reader = qjson.reader(body, { chunk_size = 1024 })
        reader:length()
        reader:next()
        collectgarbage("collect")
        assert.is_true(collectgarbage("count") - before < 256, "reader retained a full output buffer")
        reader:close()
    end)

    it("accepts opaque source handles and propagates bounded read failures", function()
        local proxy = require("qjson.proxy")
        local raw = '{"x":"long raw value"}'
        local handles = { root = {}, scalar = {} }
        local reads, fail = 0, false
        local backend = {}
        function backend:type(handle) return handle == handles.root and "object" or "string" end
        function backend:scalar() error("raw output must not decode scalars") end
        function backend:children(handle)
            assert.are.equal(handles.root, handle)
            local done = false
            return function()
                if done then return nil end
                done = true
                return "x", handles.scalar
            end
        end
        function backend:span(handle)
            if handle == handles.root then return 0, #raw end
            return 5, #raw - 1
        end
        function backend:read(offset, length)
            assert.is_true(length <= 3)
            reads = reads + 1
            if fail then return nil, "source read failed" end
            return raw:sub(offset + 1, offset + math.min(length, 2))
        end
        local body = proxy.from_backend(backend, handles.root)
        local reader = qjson.reader(body, { chunk_size = 3, normalize_duplicates = true })
        assert.are.equal(#raw, reader:length())
        assert.are.equal(0, reads)
        assert.are.equal(raw, drain(reader, 3))
        reader = qjson.reader(body, { chunk_size = 3 })
        assert.is_string(reader:next())
        fail = true
        local chunk, err = reader:next()
        assert.is_nil(chunk)
        assert.is_truthy(err:find("source read failed", 1, true))
        assert.are.equal("object", qjson.type(body))
        local _, closed = reader:next()
        assert.is_truthy(closed:find("closed", 1, true))
    end)

    it("releases only its source references on close", function()
        local function make_reader()
            local backend = {}
            function backend:type() return "object" end
            function backend:span() return 0, 2 end
            function backend:children() return function() end end
            function backend:read(offset, length) return ("{}"):sub(offset + 1, offset + length) end
            function backend:close() error("reader cannot close a shared source") end
            local weak = setmetatable({ backend }, { __mode = "v" })
            local body = require("qjson.proxy").from_backend(backend, {})
            return qjson.reader(body), weak, qjson.fork(body)
        end
        local reader, weak, branch = make_reader()
        collectgarbage("collect")
        assert.is_not_nil(weak[1])
        reader:close()
        collectgarbage("collect")
        assert.is_not_nil(weak[1])
        assert.are.equal("{}", qjson.encode(branch))
        branch = nil
        assert.is_nil(branch)
        collectgarbage("collect"); collectgarbage("collect")
        assert.is_nil(weak[1])
    end)

    it("releases snapshot references immediately on length failure", function()
        local function failed_reader()
            local backend = {}
            function backend:type() return "object" end
            function backend:span() error("span unavailable", 0) end
            local weak = setmetatable({ backend }, { __mode = "v" })
            local value = require("qjson.proxy").from_backend(backend, {})
            return qjson.reader(value), weak
        end
        local reader, weak = failed_reader()
        local length, err = reader:length()
        collectgarbage("collect"); collectgarbage("collect")
        assert.is_nil(weak[1])
        assert.is_nil(length)
        assert.is_truthy(err:find("span unavailable", 1, true))
        local _, first = reader:next()
        assert.are.equal(err, first)
        local _, closed = reader:next()
        assert.is_truthy(closed:find("closed", 1, true))
    end)

    it("rejects premature source EOF and oversized source chunks", function()
        for _, output in ipairs({ "", "xxx" }) do
            local backend = {}
            function backend:type() return "object" end
            function backend:span() return 0, 2 end
            function backend:read() return output end
            local value = require("qjson.proxy").from_backend(backend, {})
            local reader = qjson.reader(value, { chunk_size = 2 })
            local chunk, err = reader:next()
            assert.is_nil(chunk)
            assert.is_string(err)
            local _, closed = reader:next()
            assert.is_truthy(closed:find("closed", 1, true))
        end
    end)

    it("freezes number precision and reports cached length after close", function()
        local before = qjson.encode_number_precision()
        qjson.encode_number_precision(4)
        local reader = qjson.reader({ 1.234567 }, { chunk_size = 2 })
        qjson.encode_number_precision(2)
        local out = drain(reader, 2)
        qjson.encode_number_precision(before)
        assert.are.equal("[1.235]", out)
        assert.are.equal(7, reader:length())
        reader:close()
        assert.are.equal(7, reader:length())
    end)

    it("round-trips deterministic generated mutations and frozen forks", function()
        local prop = require("tests.lua.property_json")
        local cjson = require("cjson")
        local rng = prop.rng(20261031)
        for i = 1, 100 do
            local nested = prop.encode_json(prop.gen_container(rng))
            local body = qjson.decode('{"value":' .. nested .. ',"sequence":[1,2,3],"tag":"old"}')
            local fork = qjson.fork(body)
            body.tag = "new"
            qjson.array_insert(body.sequence, 2, false)
            qjson.array_remove(body.sequence, 4)
            local size = rng:int(97)
            local reader = qjson.reader(body, { chunk_size = size, normalize_duplicates = i % 2 == 0 })
            local expected = cjson.decode('{"value":' .. nested .. ',"sequence":[1,false,2],"tag":"new"}')
            body.tag = "after snapshot"
            local length = reader:length()
            local output = drain(reader, size)
            assert.are.equal(#output, length)
            assert.are.same(expected, cjson.decode(output))
            assert.are.equal("old", fork.tag)
            assert.are.equal('[1,2,3]', qjson.encode(fork.sequence))
        end
    end)

    it("cancels pending source output after close including buffered prefixes", function()
        for _, normalize in ipairs({ false, true }) do
            for _, outcome in ipairs({ "bytes", "error" }) do
                local backend, root = require("qjson.source_memory").open('{"a":"source"}')
                local original, reads = backend.read, 0
                function backend:read(offset, length)
                    reads = reads + 1
                    coroutine.yield("source read pending")
                    if outcome == "error" then error("late read error", 0) end
                    return original(self, offset, length)
                end
                local value = require("qjson.proxy").from_backend(backend, root)
                local reader = qjson.reader(value, { chunk_size = 64, normalize_duplicates = normalize })
                local co = coroutine.create(function() return reader:next() end)
                local ok, pending = coroutine.resume(co)
                assert.is_true(ok)
                assert.are.equal("source read pending", pending)
                reader:close()
                local resumed, chunk, err = coroutine.resume(co)
                assert.is_true(resumed)
                assert.is_nil(chunk)
                assert.are.equal("qjson.reader: closed", err)
                assert.are.equal(1, reads)
                assert.are.equal(14, reader:length())
                local after, closed = reader:next()
                assert.is_nil(after)
                assert.are.equal("qjson.reader: closed", closed)
            end
        end
    end)

    it("does not start a source read after close during yielding span metadata", function()
        local backend, spans, reads = {}, 0, 0
        function backend:type() return "object" end
        function backend:span()
            spans = spans + 1
            if spans == 2 then coroutine.yield("span pending") end
            return 0, 2
        end
        function backend:read(offset, length)
            reads = reads + 1
            return ("{}"):sub(offset + 1, offset + length)
        end
        local value = require("qjson.proxy").from_backend(backend, {})
        local reader = qjson.reader(value, { chunk_size = 2 })
        local co = coroutine.create(function() return reader:next() end)
        local ok, pending = coroutine.resume(co)
        assert.is_true(ok)
        assert.are.equal("span pending", pending)
        reader:close()
        local resumed, chunk, err = coroutine.resume(co)
        assert.is_true(resumed)
        assert.is_nil(chunk)
        assert.are.equal("qjson.reader: closed", err)
        assert.are.equal(0, reads)
    end)

    it("validates reader options", function()
        for _, size in ipairs({ 0, -1, 0.5, math.huge }) do
            assert.has_error(function() qjson.reader({}, { chunk_size = size }) end)
        end
        assert.has_error(function() qjson.reader({}, false) end)
        assert.has_error(function() qjson.reader({}, { chunk_size = false }) end)
        assert.has_error(function() qjson.reader({}, { normalize_duplicates = 1 }) end)
    end)
end)
