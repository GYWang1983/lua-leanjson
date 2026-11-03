local leanjson = require("leanjson")
local proxy = require("leanjson.proxy")

local function fresh()
    assert.is_function(leanjson.new)
    return leanjson.new()
end

local function drain(reader)
    local chunks = {}
    while true do
        local chunk, err = reader:next()
        assert.is_nil(err)
        if not chunk then return table.concat(chunks) end
        chunks[#chunks + 1] = chunk
    end
end

local function load(codec, source, raw, opts)
    if source == "memory" then return codec.decode(raw, opts) end
    if source == "file" then
        local name = os.tmpname()
        local f = assert(io.open(name, "wb"))
        assert(f:write(raw)); assert(f:close())
        local ok, value = pcall(codec.decode_file, name, opts)
        os.remove(name)
        assert.is_true(ok, tostring(value))
        return value
    end
    local decoder = codec.new_decoder(opts)
    for i = 1, #raw, 3 do assert(decoder:feed(raw:sub(i, i + 2))) end
    local value, err = decoder:finish()
    assert.is_nil(err)
    decoder:close()
    return value
end

describe("independent codec instances", function()
    local old_precision, old_sparse
    before_each(function()
        old_precision = leanjson.encode_number_precision()
        old_sparse = { leanjson.encode_sparse_array() }
    end)
    after_each(function()
        leanjson.encode_number_precision(old_precision)
        leanjson.encode_sparse_array(unpack(old_sparse))
    end)

    it("creates fresh defaults instead of cloning parent configuration", function()
        local a, b = fresh(), fresh()
        leanjson.encode_number_precision(2)
        leanjson.encode_sparse_array(true, 1, 1)
        a.encode_number_precision(3)
        a.encode_sparse_array(true, 4, 5)
        local child = a.new()
        assert.is_not.equal(a, b)
        assert.is_not.equal(a.encode, b.encode)
        assert.equal(2, leanjson.encode_number_precision())
        assert.equal(3, a.encode_number_precision())
        assert.equal(14, b.encode_number_precision())
        assert.equal(14, child.encode_number_precision())
        assert.same({ false, 2, 10 }, { child.encode_sparse_array() })
        assert.same({ false, 2, 10 }, { b.encode_sparse_array() })
        assert.same({ true, 4, 5 }, { a.encode_sparse_array() })
    end)

    it("isolates plain encoding, sparse classification and failed setters", function()
        local a, b = fresh(), fresh()
        a.encode_number_precision(3)
        assert.equal("0.333", a.encode(1 / 3))
        assert.equal("0.33333333333333", b.encode(1 / 3))
        assert.has_error(function() a.encode_number_precision(15) end)
        assert.equal(3, a.encode_number_precision())
        a.encode_sparse_array(true)
        local sparse = { [100] = 1 / 3 }
        assert.equal('{"100":0.333}', a.encode(sparse))
        assert.equal("object", a.type(sparse))
        assert.has_error(function() b.encode(sparse) end)
        assert.has_error(function() b.type(sparse) end)
        assert.has_error(function() a.encode_sparse_array(false, -1) end)
        assert.same({ true, 2, 10 }, { a.encode_sparse_array() })
        assert.equal('{"100":0.333}', drain(a.reader(sparse)))
        local _, err = b.reader(sparse):next()
        assert.matches("excessively sparse", err)
    end)

    it("shares markers and stateless helpers while retaining plain-table support", function()
        local a, b = fresh(), fresh()
        assert.is_true(rawequal(leanjson.null, a.null))
        assert.is_true(rawequal(a.empty_array_mt, b.empty_array_mt))
        assert.equal("null", b.encode(a.null))
        assert.equal("[]", b.encode(setmetatable({}, a.empty_array_mt)))
        local value = a.decode('{"arr":[],"nil":null}', { lazyload = false })
        assert.is_false(proxy.is_proxy(value))
        assert.equal("[]", b.encode(value.arr))
        assert.equal("null", b.encode(value["nil"]))
        assert.is_function(a.parse)
        assert.is_function(a.get)
    end)

    it("keeps reader formatting snapshots independent across instances", function()
        local a, b = fresh(), fresh()
        a.encode_number_precision(3)
        b.encode_number_precision(5)
        local value = a.decode('{"n":0}')
        value.n = 1 / 3
        local ra, rb = a.reader(value, { chunk_size = 1 }), b.reader(value, { chunk_size = 1 })
        a.encode_number_precision(2)
        b.encode_number_precision(4)
        assert.equal('{"n":0.333}', drain(ra))
        assert.equal('{"n":0.33333}', drain(rb))
        assert.equal('{"n":0.33}', tostring(value))
        assert.equal('{"n":0.3333}', b.encode(value))
    end)

    it("retains creator configuration for detached children and adopts the fork codec", function()
        local a, b = fresh(), fresh()
        a.encode_number_precision(3)
        b.encode_number_precision(5)
        a.encode_sparse_array(true)
        local root = a.decode('{"child":{},"arr":[]}')
        local child = a.get(root, "child")
        root.child = {}
        child.n = 1 / 3
        child.sparse = { [100] = 1 }
        assert.equal("0.333", tostring(child):match('"n":([^,}]+)'))
        a.array_insert(root.arr, 1, { [100] = 2 })
        assert.equal('[{"100":2}]', a.encode(root.arr))
        local fork = b.fork(child)
        assert.has_error(function() fork.sparse = { [100] = 2 } end)
        fork.n = 1 / 3
        assert.equal("0.33333", tostring(fork):match('"n":([^,}]+)'))
        assert.equal("0.333", tostring(child):match('"n":([^,}]+)'))
    end)

    it("binds incremental get and repeated finish views to their codec", function()
        local a, b = fresh(), fresh()
        local decoder = a.new_decoder()
        assert(decoder:feed('{"child":{}}'))
        a.encode_number_precision(3)
        a.encode_sparse_array(true)
        local root = assert(decoder:finish())
        local child, status = decoder:get("child")
        assert.equal("READY", status)
        child.n = 1 / 3
        child.sparse = { [100] = 1 }
        b.encode_number_precision(2)
        assert.equal("0.333", tostring(child):match('"n":([^,}]+)'))
        local again = assert(decoder:finish())
        again.child.n = 1 / 3
        assert.equal('{"child":{"n":0.333}}', tostring(again))
        decoder:close()
        a.close(root); a.close(child); a.close(again)
    end)

    it("isolates codecs during reentrant source callbacks and yielding readers", function()
        local a, b = fresh(), fresh()
        a.encode_number_precision(3)
        b.encode_number_precision(5)
        local active, calls = false, 0
        local decoder = a.new_decoder({ chunk_size = 8, on_chunk = function()
            if active then
                calls = calls + 1
                assert.equal("0.33333", b.encode(1 / 3))
                coroutine.yield("source-read")
            end
        end })
        assert(decoder:feed('{"text":"original text to read","n":0}'))
        local value = assert(decoder:finish())
        value.n = 1 / 3
        local reader = a.reader(value, { chunk_size = 4 })
        active = true
        local co = coroutine.create(function() return drain(reader) end)
        local encoded
        repeat
            local ok, result = coroutine.resume(co)
            assert.is_true(ok, tostring(result))
            if coroutine.status(co) == "dead" then encoded = result
            else
                assert.equal("source-read", result)
                assert.equal("0.33333", b.encode(1 / 3))
            end
        until coroutine.status(co) == "dead"
        assert.is_true(calls > 0)
        assert.equal('{"text":"original text to read","n":0.333}', encoded)
        active = false
        decoder:close(); a.close(value)
    end)

    it("keeps array removals and materialized origins usable across codecs", function()
        local a, b = fresh(), fresh()
        a.encode_number_precision(3)
        a.encode_sparse_array(true)
        local root = a.decode('[{"n":0},{"n":1}]')
        local removed = a.array_remove(root, 1)
        removed.n = 1 / 3
        removed.sparse = { [100] = 1 }
        assert.equal("0.333", tostring(removed):match('"n":([^,}]+)'))
        local plain = a.materialize(removed, { keep_origin = true })
        b.encode_number_precision(5)
        assert.equal("0.33333", b.encode(plain):match('"n":([^,}]+)'))
        -- Plain Lua keys stay numeric: classification must use a's sparse
        -- policy, but lookup must not silently rewrite the input table.
        assert.is_nil(a.get({ [100] = 1 }, "100"))
        assert.has_error(function() b.get({ [100] = 1 }, "100") end)
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
        for _, mode in ipairs({ "lazy", "eager", "preload" }) do
            it("preserves " .. source .. "/" .. mode .. " loading and isolated mutations", function()
                local a, b = fresh(), fresh()
                a.encode_number_precision(3)
                a.encode_sparse_array(true)
                b.encode_number_precision(5)
                local opts = { lazyload = mode ~= "eager" }
                if mode == "preload" then
                    opts.preload_paths = { "$.child" }
                    opts.index_depth, opts.index_array_limit, opts.index_budget_bytes = 0, 0, 0
                end
                local raw = '{"child":{"n":3.141592653589793},"other":"retained"}'
                local value = load(a, source, raw, opts)
                assert.equal(mode ~= "eager", proxy.is_proxy(value))
                assert.equal("retained", value.other)
                if mode ~= "eager" then assert.equal(raw, a.encode(value)) end
                value.child.n = 1 / 3
                assert.equal("0.333", a.encode(value):match('"n":([^,}]+)'))
                assert.equal("0.33333", b.encode(value):match('"n":([^,}]+)'))
                value.child.sparse = { [100] = 1 }
                assert.matches('"100":1', a.encode(value), 1, true)
                if mode ~= "eager" then
                    assert.equal("0.333", tostring(value.child):match('"n":([^,}]+)'))
                    a.close(value.child); a.close(value)
                end
            end)
        end
    end
end)
