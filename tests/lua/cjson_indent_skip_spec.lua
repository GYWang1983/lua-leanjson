local json = require("leanjson")
local safe = require("leanjson.safe")
local ffi = require("ffi")
local proxy = require("leanjson.proxy")

local function collect(c, value, size, normalize)
    local reader = c.reader(value, { chunk_size = size, normalize_duplicates = normalize })
    local length, err = reader:length(); assert.is_nil(err)
    assert.equal(length, reader:length())
    local parts = {}
    while true do
        local chunk, failure = reader:next(); assert.is_nil(failure)
        if chunk == nil then break end
        assert.is_true(#chunk > 0 and #chunk <= size)
        parts[#parts + 1] = chunk
    end
    local output = table.concat(parts)
    assert.equal(#output, length)
    assert.equal(length, reader:length())
    return output
end

describe("cjson indentation and unsupported value settings", function()
    local files, held
    before_each(function() files, held = {}, {} end)
    after_each(function()
        collectgarbage("restart")
        for _, value in ipairs(held) do json.close(value) end
        for _, path in ipairs(files) do os.remove(path) end
    end)
    local function hold(value) held[#held + 1] = value; return value end
    local function load(c, source, raw, mode, window)
        local opts = { lazyload = mode ~= "eager", chunk_size = window or 7,
            index_depth = 0, index_array_limit = 0, index_budget_bytes = 0,
            preload_paths = mode == "preload" and { "$.selected" } or nil }
        if source == "memory" then return hold(c.decode(raw, opts)) end
        if source == "file" then
            local path = os.tmpname(); files[#files + 1] = path
            local file = assert(io.open(path, "wb")); assert(file:write(raw)); file:close()
            return hold(c.decode_file(path, opts))
        end
        local decoder = c.new_decoder(opts)
        local ok, result = pcall(function()
            for i = 1, #raw, window or 7 do assert(decoder:feed(raw:sub(i, i + (window or 7) - 1))) end
            return assert(decoder:finish())
        end)
        decoder:close(); if not ok then error(result, 0) end
        return hold(result)
    end

    it("isolates normal safe and new defaults and uses the calling codec", function()
        for _, c in ipairs({ json, safe, json.new(), safe.new() }) do
            assert.is_function(c.encode_indent)
            assert.is_function(c.encode_skip_unsupported_value_types)
            assert.equal("", c.encode_indent())
            assert.is_false(c.encode_skip_unsupported_value_types())
        end
        local a, b, s = json.new(), json.new(), safe.new()
        a.encode_indent("  "); a.encode_skip_unsupported_value_types(true)
        s.encode_indent("x"); s.encode_skip_unsupported_value_types("on")
        assert.equal("", b.encode_indent()); assert.is_false(b.encode_skip_unsupported_value_types())
        assert.equal("", a.new().encode_indent()); assert.is_false(s.new().encode_skip_unsupported_value_types())
        local body = hold(b.decode('{ "n" : [1] }'))
        assert.equal('{\n  "n": [\n    1\n  ]\n}', a.encode(body))
        assert.equal('{\nx"n": [\nxx1\nx]\n}', s.encode(body))
        assert.equal('{ "n" : [1] }', b.encode(body))
    end)

    it("coerces numeric indentation and truncates embedded NUL bytes", function()
        local c = json.new()
        for _, case in ipairs({ { 2, "2" }, { 1.25, "1.25" }, { 0/0, "nan" }, { math.huge, "inf" },
            { "abc", "abc" }, { "x\0tail", "x" }, { "\0tail", "" }, { "", "" } }) do
            assert.equal(case[2], c.encode_indent(case[1]))
            assert.equal(case[2], c.encode_indent(nil))
            local want = case[2] == "" and "[1]" or "[\n" .. case[2] .. "1\n]"
            assert.equal(want, c.encode({ 1 }))
            for _, size in ipairs({ 1, 7 }) do assert.equal(want, collect(c, { 1 }, size)) end
        end
    end)

    it("rejects indentation argument errors atomically on normal and safe codecs", function()
        for _, c in ipairs({ json.new(), safe.new() }) do
            c.encode_indent("x")
            for _, value in ipairs({ false, true, {}, function() end, coroutine.create(function() end), newproxy(true), ffi.new("int", 2) }) do
                local ok, err = pcall(c.encode_indent, value)
                assert.is_false(ok)
                assert.equal("bad argument #1 to '?' (string expected, got " .. type(value) .. ")", err)
                assert.equal("x", c.encode_indent())
            end
            local ok, err = pcall(c.encode_indent, "changed", nil)
            assert.is_false(ok); assert.equal("bad argument #2 to '?' (found too many arguments)", err)
            assert.equal("x", c.encode_indent())
        end
    end)

    it("validates boolean skip options including native NUL termination atomically", function()
        for _, c in ipairs({ json.new(), safe.new() }) do
            for _, case in ipairs({ { true, true }, { "off", false }, { "on\0tail", true }, { "off\0tail", false }, { "on", true } }) do
                assert.equal(case[2], c.encode_skip_unsupported_value_types(case[1]))
                assert.equal(case[2], c.encode_skip_unsupported_value_types(nil))
            end
            for _, value in ipairs({ 0, 1, "ON", "true", {} }) do
                assert.has_error(function() c.encode_skip_unsupported_value_types(value) end)
                assert.is_true(c.encode_skip_unsupported_value_types())
            end
            local ok, err = pcall(c.encode_skip_unsupported_value_types, false, nil)
            assert.is_false(ok); assert.equal("bad argument #2 to '?' (found too many arguments)", err)
            assert.is_true(c.encode_skip_unsupported_value_types())
        end
    end)

    it("preserves unsupported errors with skip disabled and empty skipped roots", function()
        local bad = { function() end, coroutine.create(function() end), newproxy(true), ffi.cast("void *", 0), ffi.new("double", 1.5) }
        for _, value in ipairs(bad) do
            local c, s = json.new(), safe.new()
            local want = "Cannot serialise " .. type(value) .. ": type not supported"
            assert.has_error(function() c.encode(value) end, want)
            local out, err = s.encode(value); assert.is_nil(out); assert.equal(want, err)
            for _, codec in ipairs({ c, s }) do
                codec.encode_skip_unsupported_value_types(true)
                assert.equal("", codec.encode(value))
                assert.equal("", collect(codec, value, 1))
                local array = { value, 1, value, json.null, value, 2, value }
                assert.equal("[1,null,2]", codec.encode(array))
                assert.equal("[1,null,2]", collect(codec, array, 7))
                assert.equal(7, #array); assert.equal(value, array[1]); assert.equal(value, array[7])
                assert.equal("{}", codec.encode({ omitted = value }))
                assert.equal('[{"n":3}]', collect(codec, { { omitted = value, n = 3 } }, 1))
            end
        end
    end)

    it("distinguishes empty and all-skipped containers with native closing indentation", function()
        local c = json.new(); c.encode_indent("  "); c.encode_skip_unsupported_value_types(true)
        local f = function() end
        for _, case in ipairs({ { {}, "{}" }, { json.empty_array, "[]" }, { { f, f }, "[\n]" },
            { { f = f }, "{\n}" }, { { { f = f } }, "[\n  {\n  }\n]" },
            { { f, 1, f, 2, f }, "[\n  1,\n  2\n]" } }) do
            assert.equal(case[2], c.encode(case[1]))
            for _, size in ipairs({ 1, 7 }) do assert.equal(case[2], collect(c, case[1], size)) end
        end
        assert.equal("null", c.encode(nil)); assert.equal("null", c.encode(json.null))
        assert.equal("42", c.encode(ffi.new("int64_t", 42)))
        assert.equal("[\n  42\n]", collect(c, { ffi.new("uint64_t", 42) }, 1))
        assert.equal("[\n  null,\n  3\n]", c.encode({ [2] = 3 }))
    end)

    it("retains invalid-key number sparse depth and cycle errors while skipping", function()
        local c = json.new(); c.encode_indent("  "); c.encode_skip_unsupported_value_types(true)
        local cycle = {}; cycle.self = cycle
        for _, case in ipairs({ { { [true] = function() end }, "Cannot serialise boolean: table key must be a number or string" },
            { { [json.null] = function() end }, "Cannot serialise userdata: table key must be a number or string" },
            { { [math.huge] = function() end, tag = 1 }, "Cannot serialise number: must not be NaN or Infinity" },
            { { math.huge, function() end }, "Cannot serialise number: must not be NaN or Infinity" },
            { { [100] = function() end }, "Cannot serialise table: excessively sparse array" },
            { cycle, "Cannot serialise, excessive nesting (1001)" } }) do
            assert.has_error(function() c.encode(case[1]) end, case[2])
            local reader = c.reader(case[1]); local length, err = reader:length()
            assert.is_nil(length); assert.equal(case[2], err); reader:close()
        end
        c.encode_max_depth(1)
        assert.has_error(function() c.encode({ {} }) end, "Cannot serialise, excessive nesting (2)")
        local r = c.reader({ {} }); local n, err = r:length()
        assert.is_nil(n); assert.equal("Cannot serialise, excessive nesting (2)", err); r:close()
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
        for _, mode in ipairs({ "lazy", "eager", "preload" }) do
            it("formats clean dirty and forked values in " .. source .. "/" .. mode, function()
                for _, factory in ipairs({ json.new, safe.new }) do
                    local c = factory(); c.decode_array_with_array_mt(true)
                    c.encode_indent("  "); c.encode_skip_unsupported_value_types(true)
                    local body = load(c, source, '{ "selected" : [ 1, { "v" : 2 }, {}, [] ] }', mode)
                    local want = '{\n  "selected": [\n    1,\n    {\n      "v": 2\n    },\n    {},\n    []\n  ]\n}'
                    assert.equal(want, c.encode(body))
                    for _, size in ipairs({ 1, 7 }) do assert.equal(want, collect(c, body, size)) end
                    local fork = hold(c.fork(body))
                    body.selected[2].v = function() end
                    local dirty = '{\n  "selected": [\n    1,\n    {\n    },\n    {},\n    []\n  ]\n}'
                    assert.equal(dirty, c.encode(body)); assert.equal(dirty, collect(c, body, 1))
                    assert.equal(want, collect(c, fork, 7))
                end
            end)
        end
    end

    it("reformats keep_origin and mixed table/proxy containers without losing scalar spelling", function()
        local c = json.new(); c.encode_indent("  ")
        local long = string.rep("a", 90)
        local body = hold(c.decode('{ "nested" : { "long" : "' .. long .. '" } }'))
        local value = c.materialize(body, { keep_origin = true })
        local want = '{\n  "nested": {\n    "long": "' .. long .. '"\n  }\n}'
        assert.equal(want, c.encode(value)); assert.equal(want, collect(c, value, 7))
        local scalar = hold(c.decode('{"n":1.00,"s":"\\u0061"}'))
        assert.equal('[\n  {\n    "n": 1.00,\n    "s": "\\u0061"\n  }\n]', collect(c, { scalar }, 1))
        body.extra = { scalar }
        local emitted = c.encode(body)
        assert.is_truthy(emitted:find('"extra": [\n    {\n      "n": 1.00', 1, true))
        assert.equal(emitted, collect(c, body, 7))
    end)

    it("removes comments and honors duplicate normalization while indenting", function()
        local c = json.new(); c.decode_allow_comment(true); c.encode_indent("x")
        local body = hold(c.decode('{/*lead*/"a":1,"a":2,"b":{/*empty*/}}'))
        assert.equal('{\nx"a": 1,\nx"a": 2,\nx"b": {}\n}', collect(c, body, 1))
        assert.equal('{\nx"a": 2,\nx"b": {}\n}', collect(c, body, 7, true))
        c.encode_indent("")
        assert.equal('{"a":2,"b":{}}', collect(c, body, 1))
    end)

    it("freezes indent skip values and mixed sources before later codec changes", function()
        local creator, caller = json.new(), json.new()
        caller.encode_indent("  "); caller.encode_skip_unsupported_value_types(true)
        local body = hold(creator.decode('{"a":[1]}'))
        local value = { body, { function() end, 2 } }
        local reader = caller.reader(value, { chunk_size = 1 })
        caller.encode_indent(""); caller.encode_skip_unsupported_value_types(false)
        value[2][2] = 9; body.a[1] = 8
        local want = '[\n  {\n    "a": [\n      1\n    ]\n  },\n  [\n    2\n  ]\n]'
        assert.equal(#want, reader:length())
        local parts = {}
        while true do local chunk, err = reader:next(); assert.is_nil(err); if not chunk then break end; parts[#parts + 1] = chunk end
        assert.equal(want, table.concat(parts))
    end)

    it("keeps deep indentation iterative and reader temporaries within its chunk size", function()
        local c = json.new(); c.encode_max_depth(5000); c.decode_max_depth(5000); c.encode_indent("x")
        local depth, value = 1200, 1
        for _ = 1, depth do value = { value } end
        local original_rep, original_concat = string.rep, table.concat
        local reader = c.reader(value, { chunk_size = 7 })
        local ok, err = pcall(function()
            rawset(string, "rep", function(s, n) assert.is_true(#s * n <= 7, "unbounded indentation repeat"); return original_rep(s, n) end)
            rawset(table, "concat", function(...) local out = original_concat(...); assert.is_true(#out <= 7, "unbounded output concat"); return out end)
            local want = 1 + depth * depth + 4 * depth
            assert.equal(want, reader:length())
            local bytes = 0
            while true do local chunk, failure = reader:next(); assert.is_nil(failure); if not chunk then break end; bytes = bytes + #chunk end
            assert.equal(want, bytes)
        end)
        rawset(string, "rep", original_rep); rawset(table, "concat", original_concat)
        reader:close(); if not ok then error(err, 0) end
        local encoded = c.encode(value); assert.equal(1 + depth * depth + 4 * depth, #encoded)
        local body = hold(c.decode(string.rep("[", depth) .. "1" .. string.rep("]", depth)))
        local r = c.reader(body, { chunk_size = 7 }); assert.equal(#encoded, r:length()); r:close()
    end)

    for _, source in ipairs({ "file", "feed" }) do
        it("streams large " .. source .. " strings with bounded reads and no materialization", function()
            local c = json.new(); c.encode_indent("  ")
            local body = load(c, source, '{"blob":"' .. string.rep("x/y", 65536) .. '","empty":{}}', "lazy", 127)
            local backend = proxy.node(body).backend
            local original_read, reads = backend.read, 0
            function backend:read(offset, length, scope)
                assert.is_true(length <= 127, "unbounded source read"); reads = reads + 1
                return original_read(self, offset, length, scope)
            end
            function backend:scalar() error("full scalar materialization", 0) end
            local reader = c.reader(body, { chunk_size = 7 })
            local want = #'{\n  "blob": "' + 4 * 65536 + #'",\n  "empty": {}\n}'
            assert.equal(want, reader:length())
            c.close(body); collectgarbage("stop")
            local bytes = 0
            while true do
                local chunk, err = reader:next(); assert.is_nil(err); if not chunk then break end
                assert.is_true(#chunk > 0 and #chunk <= 7); bytes = bytes + #chunk
            end
            assert.equal(want, bytes); assert.is_true(reads > 0)
            assert.is_nil(backend.state.fd); assert.equal(0, backend.state.leases)
        end)

        it("releases " .. source .. " leases without GC on failure and suspended cancellation", function()
            for _, phase in ipairs({ "failure", "length", "next" }) do
                local c = json.new(); c.encode_indent("  ")
                local body = load(c, source, '{"blob":"long text","nested":{"n":1}}', "lazy", 7)
                local backend = proxy.node(body).backend
                local reader = c.reader(body, { chunk_size = 1 })
                if phase == "next" then assert.is_number(reader:length()) end
                c.close(body); collectgarbage("stop")
                local original_read = backend.read
                function backend:read(offset, length, scope)
                    if phase == "failure" then error("injected read error", 0) end
                    coroutine.yield("read pending")
                    return original_read(self, offset, length, scope)
                end
                if phase == "failure" then
                    local n, err = reader:length(); assert.is_nil(n); assert.matches("injected read error", err)
                else
                    local co = coroutine.create(function()
                        if phase == "length" then return reader:length() end
                        while true do local chunk, err = reader:next(); if not chunk then return chunk, err end end
                    end)
                    local ok, pending = coroutine.resume(co); assert.is_true(ok); assert.equal("read pending", pending)
                    reader:close()
                    local resumed, chunk, err = coroutine.resume(co)
                    assert.is_true(resumed); assert.is_nil(chunk); assert.equal("leanjson.reader: closed", err)
                end
                assert.is_nil(backend.state.fd); assert.equal(0, backend.state.leases)
                reader:close(); collectgarbage("restart")
            end
        end)
    end
end)
