local leanjson = require("leanjson")
local lfs = require("lfs")

describe("consistent source decode policy", function()
    local directory, filename
    local function decode(mode, raw, opts)
        if mode == "memory" then return leanjson.decode(raw, opts) end
        if mode == "file" then
            local output = assert(io.open(filename, "wb"))
            output:write(raw)
            output:close()
            return leanjson.decode_file(filename, opts)
        end
        local input = leanjson.new_decoder(opts)
        local ok, value = pcall(function()
            local fed, err = input:feed(raw)
            assert(fed, err)
            local root, failure = input:finish()
            assert(not failure, failure)
            return root
        end)
        input:close()
        if not ok then error(value, 0) end
        return value
    end
    local function verdict(mode, raw, opts)
        local ok, value = pcall(decode, mode, raw, opts)
        if ok then leanjson.close(value) end
        return ok
    end
    local function nested(n) return string.rep("[", n) .. "0" .. string.rep("]", n) end
    before_each(function()
        directory = os.tmpname()
        os.remove(directory)
        assert(lfs.mkdir(directory))
        filename = directory .. "/input.json"
    end)
    after_each(function()
        os.remove(filename)
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then os.remove(directory .. "/" .. name) end
        end
        lfs.rmdir(directory)
    end)
    for _, mode in ipairs({ "memory", "file", "feed" }) do
        it("applies positive depth limits to " .. mode, function()
            assert.is_true(verdict(mode, '{}', { max_depth = 1, temp_dir = directory }))
            assert.is_false(verdict(mode, '{"a":{}}', { max_depth = 1, temp_dir = directory }))
            assert.is_true(verdict(mode, '{"a":{}}', { max_depth = 2, temp_dir = directory }))
        end)

        it("uses the codec default and honors unclamped source depth limits in " .. mode, function()
            for _, limit in ipairs({ 0, 4097 }) do
                local effective = limit == 0 and 1000 or limit
                local opts = { max_depth = limit, temp_dir = directory }
                assert.is_true(verdict(mode, nested(effective), opts))
                assert.is_false(verdict(mode, nested(effective + 1), opts))
            end
            assert.is_true(verdict(mode, nested(5000), {max_depth=4294967295, temp_dir=directory}))
        end)

        it("propagates metadata bounds and defaults to " .. mode, function()
            local raw = '{"a":{"b":{"c":{"d":7}}},"items":[0,1,2,3,4]}'
            local body = decode(mode, raw, { temp_dir = directory })
            local stats = leanjson.source_stats(body)
            assert.are.equal(3, stats.index_depth)
            assert.are.equal(3, stats.index_array_limit)
            assert.are.equal(1048576, stats.budget_bytes)
            assert.are.equal(3, stats.indexed_depth)
            leanjson.close(body)
            for _, setting in ipairs({ 0, 1, 3 }) do
                for _, budget in ipairs({ 0, 64, 192 }) do
                    body = decode(mode, raw, { temp_dir = directory, chunk_size = 1,
                        index_depth = setting, index_array_limit = setting, index_budget_bytes = budget })
                    stats = leanjson.source_stats(body)
                    assert.are.equal(setting, stats.index_depth)
                    assert.are.equal(setting, stats.index_array_limit)
                    assert.are.equal(budget, stats.budget_bytes)
                    assert.is_true(stats.index_bytes <= budget)
                    assert.is_true(stats.indexed_depth <= setting)
                    assert.are.equal(7, body.a.b.c.d)
                    assert.are.equal(5, leanjson.len(body.items))
                    assert.are.equal(4, body.items[5])
                    assert.are.equal(stats.index_bytes, leanjson.source_stats(body).index_bytes)
                    leanjson.close(body)
                end
            end
        end)

        it("rejects invalid depth and source options consistently in " .. mode, function()
            for _, invalid in ipairs({ -1, 1.5, math.huge, -math.huge, 0 / 0, "1", true, {}, 4294967296 }) do
                assert.is_false(verdict(mode, '{}', { max_depth = invalid, temp_dir = directory }))
            end
            for _, name in ipairs({ "index_depth", "index_array_limit", "index_budget_bytes" }) do
                for _, invalid in ipairs({ -1, 1.5, math.huge, -math.huge, 0 / 0, "1", false, {}, 4294967296 }) do
                    assert.is_false(verdict(mode, '{}', { [name] = invalid, temp_dir = directory }))
                end
            end
            for _, opts in ipairs({ false, 1, "opts", { lazy = true }, { lazy = "yes" },
                { chunk_size = false }, { chunk_size = math.huge }, { on_chunk = false }, { temp_dir = false } }) do
                assert.is_false(verdict(mode, '{}', opts))
            end
        end)
    end

    it("keeps memory-only decode free of file callbacks and spool creation", function()
        local calls = 0
        local root = leanjson.decode('{"a":1}', { max_depth = 1, temp_dir = directory .. "/unused",
            on_chunk = function() calls = calls + 1 end })
        assert.are.equal(1, root.a)
        leanjson.close(root)
        assert.are.equal(0, calls)
        assert.is_nil(lfs.attributes(directory .. "/unused"))
        assert.is_not_nil(leanjson.parse('{}trailing', { lazy = true }))
        assert.has_error(function() leanjson.decode('{}trailing') end)
    end)
end)
