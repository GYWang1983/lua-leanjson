local json = require("leanjson")
local proxy = require("leanjson.proxy")

local function codec(safe)
    local c = safe and require("leanjson.safe").new() or json.new()
    assert.is_function(c.encode_empty_table_as_object)
    assert.is_function(c.decode_array_with_array_mt)
    assert.is_table(c.array_mt)
    assert.is_not_nil(c.empty_array)
    return c
end
local function output(c, value)
    local reader, chunks = c.reader(value, { chunk_size = 2 }), {}
    while true do
        local chunk, err = reader:next()
        assert.is_nil(err)
        if not chunk then return table.concat(chunks) end
        chunks[#chunks + 1] = chunk
    end
end

describe("cjson array markers and empty table settings", function()
    local paths
    local function load(c, source, raw, opts)
        if source == "memory" then return c.decode(raw, opts) end
        if source == "file" then
            local path = os.tmpname(); paths[#paths + 1] = path
            local f = assert(io.open(path, "wb")); assert(f:write(raw)); f:close()
            return c.decode_file(path, opts)
        end
        local d = c.new_decoder(opts)
        for i = 1, #raw, 2 do assert(d:feed(raw:sub(i, i + 1))) end
        local root, err = d:finish(); assert.is_nil(err); d:close()
        return root
    end
    before_each(function() paths = {} end)
    after_each(function() for _, path in ipairs(paths) do os.remove(path) end end)

    it("shares distinct markers across normal and safe instances", function()
        local a, b, s = codec(), codec(), require("leanjson.safe").new()
        assert.is_not.equal(a.array_mt, a.empty_array_mt)
        assert.is_true(rawequal(a.empty_array, b.empty_array))
        assert.equal(a.array_mt, s.array_mt)
        assert.equal("[]", s.encode(a.empty_array))
        assert.equal("[]", output(a, b.empty_array))
        local root = a.decode('{}'); root.array = b.empty_array
        assert.equal('{"array":[]}', a.encode(root))
        a.close(root)
    end)

    it("validates isolated boolean/on/off settings and fresh defaults", function()
        local a, b = codec(), codec()
        assert.is_true(a.encode_empty_table_as_object())
        assert.is_false(a.decode_array_with_array_mt())
        for _, fn in ipairs({ a.encode_empty_table_as_object, a.decode_array_with_array_mt }) do
            assert.is_true(fn("on")); assert.is_false(fn("off"))
            for _, invalid in ipairs({ "true", "ON", "yes", 1, {} }) do
                assert.has_error(function() fn(invalid) end)
                assert.is_false(fn())
            end
            assert.has_error(function() fn(true, nil) end)
            assert.is_false(fn())
        end
        assert.is_true(b.encode_empty_table_as_object())
        assert.is_false(b.decode_array_with_array_mt())
        assert.is_true(a.new().encode_empty_table_as_object())
    end)

    it("encodes empty tables and explicit array markers with native precedence", function()
        local c = codec()
        assert.equal("{}", c.encode({}))
        c.encode_empty_table_as_object(false)
        assert.equal("[]", c.encode({}))
        assert.equal("[[]]", output(c, { {} }))
        c.encode_empty_table_as_object(true)
        for _, marker in ipairs({ c.array_mt, c.empty_array_mt }) do
            assert.equal("[]", c.encode(setmetatable({ hash = 1 }, marker)))
            assert.equal("[1]", c.encode(setmetatable({ 1, hash = 2 }, marker)))
        end
        local sparse = { [100] = 1 }
        setmetatable(sparse, c.empty_array_mt)
        assert.has_error(function() c.encode(sparse) end)
        setmetatable(sparse, c.array_mt)
        assert.equal("[]", c.encode(sparse))
        assert.equal("[]", output(c, sparse))
    end)

    it("honors explicit markers over materialized origin/type hints", function()
        local c = codec()
        local root = c.decode('{"object":{"long":"' .. string.rep("x", 90) .. '"},"array":[]}')
        local plain = c.materialize(root, { keep_origin = true })
        setmetatable(plain.object, c.array_mt)
        assert.equal("[]", c.encode(plain.object))
        assert.equal("[]", c.encode(plain.array)) -- materialize is a shape-preserving helper
        c.close(root)
    end)

    it("invalidates whole-parent origin reuse when a nested child changes marker", function()
        local c = codec()
        local source = c.decode('{"outer":{"inner":{"long":"' .. string.rep("x",90) .. '"}}}')
        local plain = c.materialize(source, { keep_origin = true })
        setmetatable(plain.outer.inner, c.array_mt)
        assert.equal('{"outer":{"inner":[]}}', output(c, plain))
        assert.equal('{"outer":{"inner":[]}}', c.encode(plain))
        c.close(source)
    end)

    it("retains source array marking after all source-backed slots are replaced or removed", function()
        local c = codec()
        c.decode_array_with_array_mt(true)
        local root = c.decode('{"array":[1]}')
        local array = root.array
        array[1] = 2
        local fork = c.fork(array)
        assert.equal(c.array_mt, getmetatable(fork))
        assert.equal(c.array_mt, getmetatable(c.materialize(array)))
        c.close(array)
        array = root.array
        assert.equal(c.array_mt, getmetatable(array))
        c.array_remove(array, 1)
        c.close(array)
        array = root.array
        assert.equal(c.array_mt, getmetatable(array))
        assert.equal("[]", c.encode(array))
        local sentinel = c.fork(c.empty_array)
        c.array_insert(sentinel, 1, false)
        assert.equal(c.array_mt, getmetatable(c.materialize(sentinel)))
        c.close(fork); c.close(sentinel); c.close(array); c.close(root)
    end)

    for _, case in ipairs({ "raw", "equality", "empty" }) do
      it("uses native marker rules with " .. case .. " metamethods", function()
        -- Registry-shared markers must not be modified in the suite's VM.
        local interpreter = os.getenv("LUAJIT_BIN") or os.getenv("LUAJIT")
            or (arg and type(arg[-1]) == "string" and not arg[-1]:match("^%-") and arg[-1]) or "luajit"
        local quoted = "'" .. interpreter:gsub("'", "'\\''") .. "'"
        local status = os.execute(quoted .. " tests/lua/fixtures/array_marker_metamethods.lua " .. case)
        assert.is_true(status == 0 or status == true)
      end)
    end

    it("snapshots eager decoder marking for get and repeated finish", function()
        local c = codec()
        c.decode_array_with_array_mt(true)
        local d = c.new_decoder({ lazyload = false })
        c.decode_array_with_array_mt(false)
        assert(d:feed('{"array":[1]}'))
        local root = assert(d:finish())
        assert.equal(c.array_mt, getmetatable(root.array))
        local child, status = d:get("array")
        assert.equal("READY", status)
        assert.equal(c.array_mt, getmetatable(child))
        root = assert(d:finish())
        assert.equal(c.array_mt, getmetatable(root.array))
        d:close()
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
        for _, mode in ipairs({ "lazy", "eager", "preload" }) do
          for _, safe in ipairs({ false, true }) do
            it("applies marked and unmarked semantics in " .. source .. "/" .. mode .. (safe and "/safe" or "/normal"), function()
                local c = codec(safe)
                local opts = { lazyload = mode ~= "eager", chunk_size = 3 }
                if mode == "preload" then
                    opts.preload_paths = { "$.array", "$.nested" }
                    opts.index_depth, opts.index_array_limit, opts.index_budget_bytes = 0, 0, 0
                end
                for _, marked in ipairs({ false, true }) do
                    c.decode_array_with_array_mt(marked)
                    local raw = '{"array":[],"nested":[[1,2]]}'
                    local root = load(c, source, raw, opts)
                    assert.equal(mode ~= "eager", proxy.is_proxy(root))
                    assert.equal(marked, getmetatable(root.array) == c.array_mt)
                    assert.equal(marked, getmetatable(root.nested[1]) == c.array_mt)
                    c.decode_array_with_array_mt(not marked)
                    assert.equal(marked, getmetatable(root.array) == c.array_mt)
                    if mode == "eager" and not marked then
                        assert.equal("{}", c.encode(root.array))
                    else assert.equal("[]", c.encode(root.array)) end
                    c.encode_number_precision(16)
                    root.precision = 2^53
                    assert.matches('"precision":9007199254740992', c.encode(root), 1, true)
                    root.precision = nil
                    if mode ~= "eager" then
                        assert.equal(raw, c.encode(root))
                        root.nested[1][1] = 3
                        assert.equal("[3,2]", output(c, root.nested[1]))
                        c.close(root.nested[1]); c.close(root.nested)
                    else
                        root.nested[1].hash = 3
                        if marked then assert.equal("[1,2]", c.encode(root.nested[1])) end
                    end
                    c.close(root.array); c.close(root)
                end
            end)
          end
        end
    end
end)
