local json = require("leanjson")
local io_source = require("leanjson.source_io")
local proxy = require("leanjson.proxy")
local ffi = require("ffi")
ffi.cdef[[int fcntl(int, int, ...);]]

describe("memory-backed file and incremental input", function()
    local filename, held, inputs, original, fds
    local raw = '{"prompt":"hello\\nworld","nested":{"x":1},"items":[false,null,3],"big":9007199254740993}'
    local function hold(value) held[#held + 1] = value; return value end
    local function write(bytes)
        local file = assert(io.open(filename, "wb")); assert(file:write(bytes)); assert(file:close())
    end
    before_each(function()
        filename, held, inputs, fds, original = os.tmpname(), {}, {}, {}, {}
        write(raw)
        for _, name in ipairs({"open", "spool", "read", "write", "close"}) do original[name] = io_source[name] end
        io_source.open = function(...)
            local fd, err = original.open(...)
            if fd then fds[#fds + 1] = fd end
            return fd, err
        end
    end)
    after_each(function()
        collectgarbage("restart")
        for i = #inputs, 1, -1 do inputs[i]:close() end
        for i = #held, 1, -1 do json.close(held[i]) end
        for name, fn in pairs(original) do io_source[name] = fn end
        os.remove(filename)
        collectgarbage("collect"); collectgarbage("collect")
    end)
    local function decode(mode, opts, codec)
        codec = codec or json
        if mode == "file" then return hold(codec.decode_file(filename, opts)) end
        local input = codec.new_decoder(opts); inputs[#inputs + 1] = input
        -- Split escape sequences, keys and native read windows across feed chunks.
        local step = math.max(5, opts and opts.chunk_size or 5)
        for first = 1, #raw, step do assert(input:feed(raw:sub(first, first + step - 1))) end
        local value, err = input:finish(); assert.is_nil(err)
        return hold(value), input
    end
    local function no_io()
        for _, name in ipairs({"open", "spool", "read", "write"}) do
            io_source[name] = function() error("unexpected source I/O: " .. name) end
        end
    end
    local function drain(value)
        local reader = json.reader(value, {chunk_size = 3, normalize_duplicates = true})
        local parts, length = {}, assert(reader:length())
        while true do
            local bytes, err = reader:next(); assert.is_nil(err)
            if not bytes then break end
            assert.is_true(#bytes <= 3); parts[#parts + 1] = bytes
        end
        local out = table.concat(parts); assert.are.equal(length, #out)
        return out
    end
    for _, mode in ipairs({"file", "feed"}) do
        for _, policy in ipairs({"lazy", "eager", "preload"}) do
            for _, carrier in ipairs({"table", "userdata"}) do
                it("defaults to independent memory storage in " .. mode .. "/" .. policy .. "/" .. carrier, function()
                    local opts = {chunk_size = 2, proxy_mode = carrier, index_budget_bytes = 0}
                    if policy == "eager" then opts.lazyload = false end
                    if policy == "preload" then opts.preload_paths = {"$.nested", "$.items[0]"} end
                    io_source.spool = function() error("memory input created a spool") end
                    local body, input = decode(mode, opts)
                    if mode == "file" then
                        assert.are.equal(-1, ffi.C.fcntl(fds[1], 1), "input fd must close before decode returns")
                        write('truncated')
                    end
                    no_io()
                    local branch = hold(json.fork(body))
                    branch.model = "mapped"
                    json.close(body); if input then input:close() end
                    assert.are.equal("hello\nworld", branch.prompt)
                    local child = hold(branch.nested); child.x = 7
                    assert.are.equal(7, branch.nested.x)
                    if policy == "eager" then assert.are.equal(9007199254740992, branch.big) end
                    local out = drain(branch)
                    if policy ~= "eager" then assert.matches('"big":9007199254740993', out, 1, true)
                    end
                    assert.matches('"items":[false,null,3]', out, 1, true)
                end)
            end
        end
    end
    it("keeps fd/window behavior when explicitly disabled", function()
        local body = hold(json.decode_file(filename, {file_in_memory = false, chunk_size = 2}))
        assert.is_false(proxy.node(body).backend.memory == true)
        assert.is_true(ffi.C.fcntl(fds[1], 1) >= 0)
        write('')
        assert.has_error(function() return body.prompt end)
        local creates = 0
        io_source.spool = function(...) creates = creates + 1; return original.spool(...) end
        local input = json.new_decoder({file_in_memory = false}); inputs[#inputs + 1] = input
        assert.are.equal(1, creates)
        assert(input:feed('{}')); local root = hold(assert(input:finish()))
        assert.are.equal('object', json.type(root))
    end)
    it("rejects nonboolean file_in_memory before opening a source", function()
        io_source.open = function() error("opened before option validation") end
        for _, invalid in ipairs({0, 1, "true", {}}) do
            local ok, err = pcall(json.decode_file, filename, {file_in_memory = invalid})
            assert.is_false(ok); assert.matches("file_in_memory", err, 1, true)
            assert.has_error(function() json.new_decoder({file_in_memory = invalid}) end)
        end
    end)
    it("releases stored chunks on the last explicit owner and cancels a suspended feed", function()
        local input = json.new_decoder({chunk_size = 2, on_chunk = function() coroutine.yield("feeding") end})
        inputs[#inputs + 1] = input
        local worker = coroutine.create(function() return input:feed(raw) end)
        assert.are.same({true, "feeding"}, {coroutine.resume(worker)})
        collectgarbage("stop"); input:close()
        assert.are.equal(0, input.backend.state.buffer.length)
        local ok, value, err = coroutine.resume(worker)
        assert.is_true(ok); assert.is_nil(value); assert.is_string(err)
    end)
    it("retains readers independently after the decoder, root and fork close", function()
        local body, input = decode("feed", {chunk_size = 1})
        local branch = hold(json.fork(body)); branch.model = "mapped"
        local backend = proxy.node(body).backend
        local reader = json.reader(branch, {chunk_size = 7})
        input:close(); json.close(body); json.close(branch)
        no_io()
        assert.is_number(reader:length())
        local bytes = assert(reader:next()); assert.is_true(#bytes <= 7)
        reader:close()
        assert.are.equal(0, backend.state.buffer.length)
        assert.are.equal(0, #backend.state.buffer.chunks)
        assert.has_error(function() backend:check_open() end)
    end)
    it("streams long tokens across memory chunks without scalar materialization or concatenating the source", function()
        raw = '{"prompt":"' .. string.rep('a\\n\\u0062', 65536) .. '","model":"public"}'
        write(raw)
        for _, mode in ipairs({"file", "feed"}) do
            local body, input = decode(mode, {chunk_size = 257, index_budget_bytes = 0})
            local backend = proxy.node(body).backend
            backend.scalar = function() error("full scalar materialization") end
            local original_concat = table.concat
            rawset(table, "concat", function(...)
                local result = original_concat(...)
                assert.is_true(#result <= 1024, "whole source concatenation")
                return result
            end)
            local reader
            local ok, err = pcall(function()
                assert.are.equal(3 * 65536, json.len(body, "$.prompt"))
                body.model = "mapped"
                reader = json.reader(body, {chunk_size = 257})
                local expected = assert(reader:length())
                json.close(body); if input then input:close() end
                local total = 0
                while true do
                    local bytes, failure = reader:next(); assert.is_nil(failure)
                    if not bytes then break end
                    assert.is_true(#bytes <= 257); total = total + #bytes
                end
                assert.are.equal(expected, total)
            end)
            rawset(table, "concat", original_concat)
            if reader then reader:close() end
            assert(ok, err)
        end
    end)

    it("preserves safe/independent codecs, scalar roots and repeated finish", function()
        for _, codec in ipairs({json.new(), require("leanjson.safe"), require("leanjson.safe").new()}) do
            io_source.spool = function() error("memory input created a spool") end
            local input = codec.new_decoder(); inputs[#inputs + 1] = input
            assert(input:feed('false'))
            local value, err = input:finish(); assert.is_nil(err); assert.is_false(value)
            value, err = input:finish(); assert.is_nil(err); assert.is_false(value)
            value, err = input:get(""); assert.is_false(value); assert.are.equal("READY", err)
        end
    end)
end)
