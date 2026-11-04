local json = require("leanjson")
local safe = require("leanjson.safe")
local proxy = require("leanjson.proxy")
local io_source = require("leanjson.source_io")
local ffi = require("ffi")
local lfs = require("lfs")
ffi.cdef[[int fcntl(int, int, ...);]]

local function external(length, values, raw)
    return setmetatable(raw or {}, { __len = function() return length end, __index = values })
end

local function drain(reader, size)
    local length, err = reader:length()
    assert.is_nil(err)
    assert.equal(length, reader:length())
    local chunks = {}
    while true do
        local chunk, failure = reader:next()
        assert.is_nil(failure)
        if chunk == nil then break end
        assert.is_true(#chunk > 0 and #chunk <= size)
        chunks[#chunks + 1] = chunk
    end
    local result = table.concat(chunks)
    assert.equal(#result, length)
    assert.equal(length, reader:length())
    return result
end

local function check(c, value, want)
    assert.equal(want, c.encode(value))
    for _, size in ipairs({ 1, 7 }) do
        assert.equal(want, drain(c.reader(value, { chunk_size = size }), size))
    end
end

describe("cjson external arrays", function()
    it("encodes the original TEST 23 virtual values", function()
        local value = setmetatable({}, {
            __len = function() return 3 end,
            __index = function(_, index) return ({ "foo", "bar", "baz" })[index] end,
        })
        assert.equal('["foo","bar","baz"]', json.encode(value))
    end)

    it("reads the original TEST 23 with exact lengths and bounded chunks", function()
        for _, size in ipairs({ 1, 7 }) do
            local value = external(3, { "foo", "bar", "baz" })
            assert.equal('["foo","bar","baz"]', drain(json.reader(value, { chunk_size = size }), size))
        end
    end)

    for _, case in ipairs({
        { "normal", function() return json end }, { "safe", function() return safe end },
        { "new", json.new }, { "safe new", safe.new },
    }) do
        it("supports root and nested arrays through " .. case[1], function()
            local c = case[2]()
            check(c, external(3, { "first", false, c.null }), '["first",false,null]')
            check(c, { nested = external(2, { external(0), "last" }) }, '{"nested":[[],"last"]}')
        end)
    end

    for _, case in ipairs({
        { "zero", 0, '[]' }, { "negative", -3, '[]' }, { "negative fraction", -1.9, '[]' },
        { "fraction", 1.9, '["a"]' }, { "number string", "2.8", '["a","b"]' },
        { "whitespace", " 2 ", '["a","b"]' }, { "exponent", "2e0", '["a","b"]' },
        { "hexadecimal", "0x2", '["a","b"]' }, { "hex fraction", "0x1p1", '["a","b"]' },
        { "binary", "0b10", '["a","b"]' }, { "plus", "+2", '["a","b"]' },
        -- lua_tointeger in native cjson follows this VM's numeric scanner:
        -- older LuaJIT accepts the prefix before NUL, newer builds reject it.
        { "trailing text", "2x", '[]' },
        { "embedded NUL", "2\0bad", tonumber("2\0bad") == 2 and '["a","b"]' or '[]' },
        { "empty string", "", '[]' }, { "nonnumeric", "invalid", '[]' },
        { "false", false, '[]' }, { "true", true, '[]' }, { "table", {}, '[]' },
        { "integer cdata", ffi.new("int", 2), '[]' }, { "nil", nil, '[]' },
        { "minimum fractional", -2147483648.9, '[]' },
    }) do
        it("coerces a " .. case[1] .. " length using native number conversion", function()
            check(json.new(), external(case[2], { "a", "b", "c" }), case[3])
        end)
    end

    it("honors real protected metatables and callable length values", function()
        local value
        local method = setmetatable({}, { __metatable = "locked callable", __call = function(_, received)
            assert.is_true(rawequal(value, received)); return 2
        end })
        value = setmetatable({}, { __metatable = "locked", __len = method, __index = { "a", "b" } })
        check(json.new(), value, '["a","b"]')
    end)

    it("ignores inherited and fabricated length metadata", function()
        local mt = setmetatable({}, { __index = { __len = function() error("inherited length was called") end } })
        check(json.new(), setmetatable({}, mt), '{}')
        mt = { __metatable = { __len = function() error("public length was called") end } }
        check(json.new(), setmetatable({}, mt), '{}')
    end)

    for _, case in ipairs({ { false, "boolean" }, { 2, "number" }, { "two", "string" }, { {}, "table" } }) do
        it("preserves the native non-callable " .. case[2] .. " method error", function()
            local value = setmetatable({}, { __len = case[1] })
            local want = "attempt to call a " .. case[2] .. " value"
            local ok, err = pcall(json.encode, value)
            assert.is_false(ok); assert.equal(want, err)
            local result, failure = safe.encode(value)
            assert.is_nil(result); assert.equal(want, failure)
            local reader = json.reader(value)
            local length, reader_error = reader:length()
            assert.is_nil(length); assert.equal(want, reader_error)
            local chunk, read_error = reader:next()
            assert.is_nil(chunk); assert.equal(want, read_error)
        end)
    end

    it("ignores hash and sparse raw keys when a length method selects an array", function()
        local c = json.new()
        check(c, external(3, { "a", nil, c.null }, { hash = function() end, [10000] = "ignored" }),
            '["a",null,null]')
        c.encode_sparse_array(true, 1, 0)
        c.encode_empty_table_as_object(false)
        check(c, external(2, { "a", "b" }, { [10000] = "ignored" }), '["a","b"]')
        assert.equal('{"10000":"ordinary"}', c.encode({ [10000] = "ordinary" }))
    end)

    it("gives raw array markers precedence and external methods precedence over empty markers", function()
        local c = json.new()
        local array_len, array_index = rawget(c.array_mt, "__len"), rawget(c.array_mt, "__index")
        local empty_len, empty_index = rawget(c.empty_array_mt, "__len"), rawget(c.empty_array_mt, "__index")
        local ok, err = pcall(function()
            rawset(c.array_mt, "__len", function() error("marked length was called") end)
            rawset(c.array_mt, "__index", function() error("marked index was called") end)
            check(c, setmetatable({ 1, 2, 3, hash = "ignored" }, c.array_mt), '[1,2,3]')
            rawset(c.empty_array_mt, "__len", function() return 2 end)
            rawset(c.empty_array_mt, "__index", { "a", "b" })
            check(c, setmetatable({ [10000] = "ignored" }, c.empty_array_mt), '["a","b"]')
        end)
        rawset(c.array_mt, "__len", array_len); rawset(c.array_mt, "__index", array_index)
        rawset(c.empty_array_mt, "__len", empty_len); rawset(c.empty_array_mt, "__index", empty_index)
        assert.is_true(ok, err)
    end)

    for _, length in ipairs({ 0 / 0, math.huge, -math.huge, 2147483648, -2147483649, "inf", "1e100" }) do
        it("rejects unsafe external length " .. tostring(length) .. " before indexing", function()
            local indexed = false
            local value = external(length, function() indexed = true; error("must not index", 0) end)
            local ok, err = pcall(json.encode, value)
            assert.is_false(ok)
            assert.matches("external array length", err, 1, true)
            local result, failure = safe.encode(value)
            assert.is_nil(result); assert.equal(err, failure)
            local reader = json.reader(value)
            local bytes, reader_error = reader:length()
            assert.is_nil(bytes); assert.equal(err, reader_error)
            local chunk, read_error = reader:next()
            assert.is_nil(chunk); assert.equal(err, read_error)
            assert.is_false(indexed)
        end)
    end

    it("accepts the signed 32 bit positive boundary without imposing a smaller cap", function()
        for _, length in ipairs({ 2147483647, 2147483647.9, "2147483647" }) do
            local value = external(length, function() error("first boundary element", 0) end)
            local ok, err = pcall(json.encode, value)
            assert.is_false(ok); assert.equal("first boundary element", err)
            local reader = json.reader(value)
            local bytes, failure = reader:length()
            assert.is_nil(bytes); assert.equal("first boundary element", failure)
        end
    end)

    for _, phase in ipairs({ "length", "index" }) do
        it("preserves non-string " .. phase .. " callback errors and reader failures", function()
            local problem = {}
            local mt = { __len = function() return 2 end, __index = function() error(problem, 0) end }
            if phase == "length" then mt.__len = function() error(problem, 0) end end
            local value = setmetatable({}, mt)
            local ok, err = pcall(json.encode, value)
            assert.is_false(ok); assert.is_true(rawequal(problem, err))
            local result, failure = safe.encode(value)
            assert.is_nil(result); assert.is_true(rawequal(problem, failure))
            local reader = json.reader(value)
            local bytes, reader_error = reader:length()
            assert.is_nil(bytes); assert.equal(tostring(problem), reader_error)
            local chunk, read_error = reader:next()
            assert.is_nil(chunk); assert.equal(reader_error, read_error)
        end)
    end

    it("preserves unprintable callback errors through normal and safe encoding", function()
        for _, kind in ipairs({ "throwing", "non-string" }) do
            local formatted = false
            local problem = setmetatable({}, { __tostring = function()
                formatted = true
                if kind == "throwing" then error("formatting failed", 0) end
                return {}
            end })
            local value = setmetatable({}, { __len = function() error(problem, 0) end })
            local ok, err = pcall(json.encode, value)
            assert.is_false(ok); assert.is_true(rawequal(problem, err))
            local result, failure = safe.encode(value)
            assert.is_nil(result); assert.is_true(rawequal(problem, failure))
            assert.is_false(formatted)
        end
    end)

    it("captures each external container once when constructing a reader", function()
        local lengths, indexes = 0, 0
        local values = { "first", "second" }
        local value = setmetatable({}, { __len = function() lengths = lengths + 1; return 2 end,
            __index = function(_, index) indexes = indexes + 1; return values[index] end })
        local reader = json.reader({ value, value }, { chunk_size = 1 })
        assert.equal(2, lengths); assert.equal(4, indexes)
        values[1], values[2] = "changed", "changed"
        getmetatable(value).__len = function() error("length was called after construction") end
        getmetatable(value).__index = function() error("index was called after construction") end
        assert.equal('[["first","second"],["first","second"]]', drain(reader, 1))
        assert.equal(2, lengths); assert.equal(4, indexes)
    end)

    it("bypasses own proxy length methods while retaining source lexical values", function()
        local c = json.new()
        c.decode_array_with_array_mt(true)
        local value = c.decode('[9007199254740993,{"x":1,"x":2}]')
        local mt = debug.getmetatable(value)
        local previous = rawget(mt, "__len")
        rawset(mt, "__len", function() error("own proxy classified as external") end)
        local ok, err = pcall(function()
            check(c, value, '[9007199254740993,{"x":1,"x":2}]')
            check(c, external(1, { value }), '[[9007199254740993,{"x":1,"x":2}]]')
        end)
        rawset(mt, "__len", previous); c.close(value)
        assert.is_true(ok, err)
    end)

    it("uses the calling codec for external values containing another codec's proxy", function()
        local producer, consumer = json.new(), safe.new()
        local child = producer.decode('[9007199254740993]')
        consumer.encode_number_precision(3)
        check(consumer, external(2, { child, 1.23456 }), '[[9007199254740993],1.23]')
        assert.equal(14, producer.encode_number_precision())
        producer.close(child)
    end)

    it("supports yielding length and element callbacks without repeating them", function()
        local lengths, indexes = 0, 0
        local value = setmetatable({}, {
            __len = function() lengths = lengths + 1; coroutine.yield("length"); return 1 end,
            __index = function() indexes = indexes + 1; coroutine.yield("index"); return "done" end,
        })
        for _, operation in ipairs({ "encode", "reader" }) do
            lengths, indexes = 0, 0
            local worker = coroutine.create(function()
                if operation == "encode" then return json.encode(value) end
                return drain(json.reader(value, { chunk_size = 1 }), 1)
            end)
            assert.same({ true, "length" }, { coroutine.resume(worker) })
            assert.same({ true, "index" }, { coroutine.resume(worker) })
            assert.same({ true, '["done"]' }, { coroutine.resume(worker) })
            assert.equal(1, lengths); assert.equal(1, indexes)
        end
    end)

    it("does not repeat origin length callbacks or reuse old external array spans", function()
        local c = json.new()
        local source = c.decode('[ "' .. string.rep("\\u0061", 10) .. '" ]')
        local value = c.materialize(source, { keep_origin = true })
        local count = 0
        setmetatable(value, { __len = function() count = count + 1; return count == 1 and 1 or 0 end })
        assert.equal('["aaaaaaaaaa"]', c.encode(value))
        assert.equal(1, count)
        c.close(source)
    end)

    it("invalidates whole-parent origin reuse without executing nested callbacks twice", function()
        local c = json.new()
        local source = c.decode('{"outer":{"inner":["' .. string.rep("x", 90) .. '"]}}')
        local value = c.materialize(source, { keep_origin = true })
        local count = 0
        setmetatable(value.outer.inner, { __len = function() count = count + 1; return 0 end })
        assert.equal('{"outer":{"inner":[]}}', c.encode(value))
        assert.equal(1, count)
        c.close(source)
    end)

    it("retains virtual arrays across fork assignment and materialization", function()
        local c, values, count = json.new(), { "a", "b" }, 0
        local value = setmetatable({}, { __len = function() count = count + 1; return 2 end, __index = values })
        local branch, target = c.fork(value), c.decode('{}')
        target.value = value
        local array = c.fork(c.empty_array)
        c.array_insert(array, 1, value)
        assert.equal(3, count)
        values[1] = "changed"
        assert.equal('["a","b"]', c.encode(branch))
        assert.equal('{"value":["a","b"]}', c.encode(target))
        assert.equal('[["a","b"]]', c.encode(array))
        assert.equal('["a","b"]', c.encode(c.materialize(branch, { keep_origin = true })))
        c.close(branch); c.close(target); c.close(array)
    end)

    it("enforces cycles and depth through external elements", function()
        local c, value = json.new()
        value = external(1, function() return value end)
        c.encode_max_depth(3)
        assert.has_error(function() c.encode(value) end, "Cannot serialise, excessive nesting (4)")
        local reader = c.reader(value)
        local length, err = reader:length()
        assert.is_nil(length); assert.equal("Cannot serialise, excessive nesting (4)", err)
        c.encode_max_depth(1)
        value = external(1, { external(0) })
        assert.has_error(function() c.encode(value) end, "Cannot serialise, excessive nesting (2)")
        local result, failure = c.reader(value):next()
        assert.is_nil(result); assert.equal("Cannot serialise, excessive nesting (2)", failure)
    end)

    it("preserves indentation holes and unsupported-value skipping", function()
        local c = json.new()
        c.encode_indent("  ")
        c.encode_skip_unsupported_value_types(true)
        check(c, external(4, { function() end, "a", nil, false }), '[\n  "a",\n  null,\n  false\n]')
        check(c, external(1, { function() end }), '[\n]')
        check(c, external(0), '[]')
        c.encode_skip_unsupported_value_types(false)
        assert.has_error(function() c.encode(external(1, { function() end })) end,
            "Cannot serialise function: type not supported")
    end)
end)

describe("external array source ownership", function()
    local directory, held, descriptors, spools, restore_open, restore_spool
    local function hold(value) held[#held + 1] = value; return value end
    local function load(c, source, raw, mode, checkpoint)
        local opts = { lazyload = mode ~= "eager", chunk_size = 7, index_depth = 0,
            index_array_limit = 0, index_budget_bytes = 0,
            preload_paths = mode == "preload" and { "$.selected" } or nil, on_chunk = checkpoint }
        if source == "memory" then return c.decode(raw, opts) end
        if source == "file" then
            local path = directory .. "/input-" .. tostring(#descriptors + 1)
            local file = assert(io.open(path, "wb")); assert(file:write(raw)); file:close()
            return c.decode_file(path, opts)
        end
        opts.temp_dir = directory
        local decoder = c.new_decoder(opts)
        for first = 1, #raw, 7 do assert(decoder:feed(raw:sub(first, first + 6))) end
        local value, err = decoder:finish()
        decoder:close(); assert.is_nil(err)
        return value
    end
    local function closed()
        for _, fd in ipairs(descriptors) do
            assert.equal(-1, ffi.C.fcntl(fd, 1), "source descriptor remained open")
            assert.equal(9, ffi.errno())
        end
        for _, path in ipairs(spools) do assert.is_nil(lfs.attributes(path)) end
    end
    before_each(function()
        directory = os.tmpname(); os.remove(directory); assert(lfs.mkdir(directory))
        held, descriptors, spools = {}, {}, {}
        restore_open, restore_spool = io_source.open, io_source.spool
        io_source.open = function(path)
            local fd, err = restore_open(path)
            if fd then descriptors[#descriptors + 1] = fd end
            return fd, err
        end
        io_source.spool = function(path)
            local fd, name = restore_spool(path)
            if fd then descriptors[#descriptors + 1] = fd; spools[#spools + 1] = name end
            return fd, name
        end
    end)
    after_each(function()
        collectgarbage("restart")
        for _, value in ipairs(held) do json.close(value) end
        io_source.open, io_source.spool = restore_open, restore_spool
        collectgarbage("collect"); collectgarbage("collect")
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then os.remove(directory .. "/" .. name) end
        end
        lfs.rmdir(directory)
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
        for _, mode in ipairs({ "lazy", "eager", "preload" }) do
            it("snapshots mixed external arrays across " .. source .. "/" .. mode, function()
                local c = json.new()
                local root = hold(load(c, source, '{"selected":{"v":1}}', mode))
                local child = hold(root.selected)
                local values = { child, c.null }
                local value = external(2, values)
                check(c, value, '[{"v":1},null]')
                local reader = c.reader(value, { chunk_size = 1 })
                local branch, target = hold(c.fork(value)), hold(c.decode('{}'))
                target.value = value
                values[1] = "changed"
                c.close(child); c.close(root)
                assert.equal('[{"v":1},null]', drain(reader, 1))
                assert.equal('[{"v":1},null]', c.encode(branch))
                assert.equal('{"value":[{"v":1},null]}', c.encode(target))
                c.close(branch); c.close(target)
                closed()
            end)
        end
    end

    for _, source in ipairs({ "file", "feed" }) do
        for _, phase in ipairs({ "construction", "length", "next" }) do
            for _, kind in ipairs({ "throwing", "non-string" }) do
                it("cleans " .. source .. " reader " .. phase .. " leases before " .. kind .. " error formatting", function()
                    local c, child, backend = json.new()
                    local formatted, leases_at_format, descriptor_at_format = false
                    local problem = setmetatable({}, { __tostring = function()
                        formatted = true
                        leases_at_format = backend.state.leases
                        descriptor_at_format = ffi.C.fcntl(descriptors[1], 1)
                        if kind == "throwing" then error("formatting failed", 0) end
                        return {}
                    end })
                    local reader, ok, bytes, err
                    collectgarbage("stop")
                    if phase == "construction" then
                        local value = external(2, function(_, index)
                            if index == 1 then
                                child = hold(load(c, source, '{"v":1}', "lazy"))
                                backend = proxy.node(child).backend
                                return child
                            end
                            c.close(child)
                            error(problem, 0)
                        end)
                        ok, reader = pcall(c.reader, value)
                    else
                        c.encode_max_depth(2)
                        child = hold(load(c, source, '{"v":1}', "lazy"))
                        backend = proxy.node(child).backend
                        reader = c.reader(external(1, { child }), { chunk_size = 7 })
                        c.close(child)
                        if phase == "next" then assert.equal(9, reader:length()) end
                        function backend:read() error(problem, 0) end
                        ok, bytes, err = pcall(reader[phase], reader)
                    end
                    assert.equal(0, backend.state.leases, "reader leaked its lease after an unprintable error")
                    closed()
                    assert.is_true(ok, "error formatting escaped the reader operation")
                    assert.is_true(formatted)
                    assert.equal(0, leases_at_format, "error formatting ran before lease cleanup")
                    assert.equal(-1, descriptor_at_format, "error formatting observed an open descriptor")
                    if phase == "construction" then
                        bytes, err = reader:length()
                        local chunk, read_error = reader:next()
                        assert.is_nil(chunk); assert.equal(err, read_error)
                    end
                    assert.is_nil(bytes)
                    assert.equal("leanjson.reader: error message unavailable", err)
                    local length, failure = reader:length()
                    assert.is_nil(length); assert.equal(err, failure)
                    reader:close()
                    closed()
                end)
            end
        end

        for _, operation in ipairs({ "reader", "fork", "assignment", "insert" }) do
            it("pins ephemeral " .. source .. " children before later GC during " .. operation, function()
                local c, backend, returned = json.new()
                local value = external(2, function(_, index)
                    if index == 1 then
                        returned = hold(load(c, source, '{"selected":{"v":1}}', "lazy"))
                        backend = proxy.node(returned).backend
                        return returned
                    end
                    c.close(returned); returned = nil
                    collectgarbage("collect"); collectgarbage("collect")
                    return false
                end)
                local result
                if operation == "reader" then result = c.reader(value, { chunk_size = 7 })
                elseif operation == "fork" then result = hold(c.fork(value))
                elseif operation == "assignment" then result = hold(c.decode('{}')); result.value = value
                else result = hold(c.fork(c.empty_array)); c.array_insert(result, 1, value) end
                assert.is_not_nil(backend, "external index callback was not used")
                assert.is_not_nil(backend.state.fd, "ephemeral child closed before ownership transfer")
                local want = '[{"selected":{"v":1}},false]'
                if operation == "reader" then assert.equal(want, drain(result, 7))
                elseif operation == "assignment" then assert.equal('{"value":' .. want .. '}', c.encode(result))
                elseif operation == "insert" then assert.equal('[' .. want .. ']', c.encode(result))
                else assert.equal(want, c.encode(result)) end
                collectgarbage("stop")
                if operation == "reader" then result:close() else c.close(result) end
                closed()
            end)

            it("pins an unreachable " .. source .. " child across a third callback GC during " .. operation, function()
                local c, backend = json.new()
                local value = external(3, function(_, index)
                    if index == 1 then
                        local child = load(c, source, '{"selected":{"v":1}}', "lazy")
                        backend = proxy.node(child).backend
                        return child
                    end
                    if index == 3 then collectgarbage("collect"); collectgarbage("collect") end
                    return false
                end)
                local result
                if operation == "reader" then result = c.reader(value, { chunk_size = 7 })
                elseif operation == "fork" then result = hold(c.fork(value))
                elseif operation == "assignment" then result = hold(c.decode('{}')); result.value = value
                else result = hold(c.fork(c.empty_array)); c.array_insert(result, 1, value) end
                assert.is_not_nil(backend.state.fd, "unreachable source closed during snapshot construction")
                local want = '[{"selected":{"v":1}},false,false]'
                if operation == "reader" then assert.equal(want, drain(result, 7))
                elseif operation == "assignment" then assert.equal('{"value":' .. want .. '}', c.encode(result))
                elseif operation == "insert" then assert.equal('[' .. want .. ']', c.encode(result))
                else assert.equal(want, c.encode(result)) end
                collectgarbage("stop")
                if operation == "reader" then result:close() else c.close(result) end
                closed()
            end)
        end

        for _, operation in ipairs({ "reader", "fork", "assignment", "insert" }) do
            it("releases pinned " .. source .. " children on callback failure during " .. operation, function()
                local c, child = json.new()
                local problem = {}
                local value = external(2, function(_, index)
                    if index == 1 then child = hold(load(c, source, '{"selected":{"v":1}}', "lazy")); return child end
                    c.close(child)
                    error(problem, 0)
                end)
                collectgarbage("stop")
                if operation == "reader" then
                    local reader = c.reader(value)
                    local chunk, err = reader:next()
                    assert.is_nil(chunk); assert.equal(tostring(problem), err)
                else
                    local target = operation ~= "fork" and hold(c.decode(operation == "insert" and '[]' or '{}'))
                    local ok, err = pcall(function()
                        if operation == "fork" then c.fork(value)
                        elseif operation == "assignment" then target.value = value
                        else c.array_insert(target, 1, value) end
                    end)
                    assert.is_false(ok); assert.is_true(rawequal(problem, err))
                    if target then assert.equal(operation == "insert" and '[]' or '{}', c.encode(target)); c.close(target) end
                end
                closed()
            end)
        end

        it("cancels a yielding assignment and releases captured " .. source .. " leases without GC", function()
            local c, child = json.new()
            local target = hold(c.decode('{}'))
            local value = external(2, function(_, index)
                if index == 1 then child = hold(load(c, source, '{"selected":{"v":1}}', "lazy")); return child end
                c.close(child)
                coroutine.yield("external callback paused")
                return false
            end)
            collectgarbage("stop")
            local worker = coroutine.create(function() return pcall(function() target.value = value end) end)
            assert.same({ true, "external callback paused" }, { coroutine.resume(worker) })
            assert.is_true(ffi.C.fcntl(descriptors[1], 1) ~= -1)
            c.close(target)
            closed()
            local resumed, ok, err = coroutine.resume(worker)
            assert.is_true(resumed); assert.is_false(ok); assert.matches("closed", err, 1, true)
            closed()
        end)

        it("releases captured " .. source .. " leases after a yielding reader-construction error", function()
            local c, child = json.new()
            local value = external(2, function(_, index)
                if index == 1 then child = hold(load(c, source, '{"selected":{"v":1}}', "lazy")); return child end
                c.close(child)
                coroutine.yield("construction paused")
                error("construction failed", 0)
            end)
            collectgarbage("stop")
            local worker = coroutine.create(function() return c.reader(value) end)
            assert.same({ true, "construction paused" }, { coroutine.resume(worker) })
            assert.is_true(ffi.C.fcntl(descriptors[1], 1) ~= -1)
            local ok, reader = coroutine.resume(worker)
            assert.is_true(ok)
            local bytes, err = reader:next()
            assert.is_nil(bytes); assert.equal("construction failed", err)
            closed()
        end)

        it("cancels yielded external-array " .. source .. " traversal without publishing bytes", function()
            local c, pause = json.new(), false
            local child = hold(load(c, source, '{"selected":{"v":1}}', "lazy", function()
                if pause then pause = false; coroutine.yield("traversal paused") end
            end))
            local reader = c.reader(external(1, { child }), { chunk_size = 1 })
            c.close(child)
            pause = true
            collectgarbage("stop")
            local worker = coroutine.create(function() return reader:next() end)
            assert.same({ true, "traversal paused" }, { coroutine.resume(worker) })
            reader:close()
            closed()
            local ok, bytes, err = coroutine.resume(worker)
            assert.is_true(ok); assert.is_nil(bytes); assert.matches("closed", err, 1, true)
            closed()
        end)
    end

    it("keeps file-backed strings bounded through external array readers", function()
        local c = json.new()
        local text = string.rep("x", 65537)
        local child = hold(load(c, "file", '{"selected":"' .. text .. '"}', "lazy"))
        local backend = proxy.node(child).backend
        local read, largest = backend.read, 0
        function backend:read(first, count, scope)
            largest = math.max(largest, count)
            assert.is_true(count <= 7, "source read exceeded its configured window")
            return read(self, first, count, scope)
        end
        local reader = c.reader(external(1, { child }), { chunk_size = 7 })
        c.close(child)
        assert.equal('[{"selected":"' .. text .. '"}]', drain(reader, 7))
        assert.is_true(largest > 0)
        closed()
    end)
end)
