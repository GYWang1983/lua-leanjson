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

        it("uses the default and clamped depth limits in " .. mode, function()
            for _, limit in ipairs({ 0, 4097, 4294967295 }) do
                local effective = limit == 0 and 1024 or 4096
                local opts = { max_depth = limit, temp_dir = directory }
                assert.is_true(verdict(mode, nested(effective), opts))
                assert.is_false(verdict(mode, nested(effective + 1), opts))
            end
        end)

        it("rejects invalid depth and source options consistently in " .. mode, function()
            for _, invalid in ipairs({ -1, 1.5, math.huge, -math.huge, 0 / 0, "1", true, {}, 4294967296 }) do
                assert.is_false(verdict(mode, '{}', { max_depth = invalid, temp_dir = directory }))
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
