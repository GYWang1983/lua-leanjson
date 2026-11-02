local leanjson = require("leanjson")
local io_source = require("leanjson.source_io")

describe("file JSON source", function()
    local paths
    local function fixture(raw)
        local path = os.tmpname()
        paths[#paths + 1] = path
        local file = assert(io.open(path, "wb"))
        assert(file:write(raw))
        assert(file:close())
        return path
    end

    before_each(function() paths = {} end)
    after_each(function()
        for _, path in ipairs(paths) do os.remove(path) end
    end)

    it("reads nested values and raw numeric tokens from bounded file windows", function()
        assert.is_function(leanjson.decode_file)
        local path = fixture(' {"a\\u0062":1,"ab":2,"items":[false,null,{"x":"a\\n\\uD83D\\uDE00z"}],"big":9007199254740993} ')
        local progress = {}
        local body = leanjson.decode_file(path, { chunk_size = 3, on_chunk = function(n) progress[#progress + 1] = n end })
        assert.are.equal(2, body.ab)
        assert.is_false(body.items[1])
        assert.are.equal(leanjson.null, body.items[2])
        assert.are.equal("a\n😀z", body.items[3].x)
        body.extra = true
        local encoded = leanjson.encode(body)
        assert.matches('"big":9007199254740993', encoded, 1, true)
        assert.is_true(#progress > 1)
        local original = assert(io.open(path, "rb"))
        original:close()
    end)

    it("rejects malformed complete files and invalid source options", function()
        assert.is_function(leanjson.decode_file)
        local path = fixture('{"a":1} trailing')
        assert.has_error(function() leanjson.decode_file(path) end)
        for _, opts in ipairs({ false, { chunk_size = 0 }, { chunk_size = 1.5 }, { lazy = true },
            { on_chunk = false }, { max_depth = -1 }, { temp_dir = false } }) do
            assert.has_error(function() leanjson.decode_file(path, opts) end)
        end
        assert.has_error(function() leanjson.decode_file(path .. ".missing") end)
    end)

    it("bounds actual reads during scanning, scalar materialization and output", function()
        local raw = '{"model":"old","prompt":"' .. string.rep('a\\n\\uD83D\\uDE00', 2000) .. '"}'
        local path = fixture(raw)
        local original, largest = io_source.read, 0
        io_source.read = function(fd, offset, length)
            largest = math.max(largest, length)
            assert.is_true(length <= 7, "file read exceeded the configured window")
            return original(fd, offset, length)
        end
        local ok, err = pcall(function()
            local root = leanjson.decode_file(path, { chunk_size = 7 })
            root.model = "new"
            assert.are.equal(string.rep("a\n😀", 2000), root.prompt)
            local reader = leanjson.reader(root, { chunk_size = 19 })
            while true do
                local chunk, read_error = reader:next()
                assert.is_nil(read_error)
                if not chunk then break end
                assert.is_true(#chunk <= 19)
            end
            if leanjson.close then leanjson.close(root) end
        end)
        io_source.read = original
        assert.is_true(ok, err)
        assert.are.equal(7, largest)
    end)

    it("reports an early source EOF as failure and keeps the original path", function()
        local path = fixture('{"x":"source bytes"}')
        local root = leanjson.decode_file(path, { chunk_size = 3 })
        local reader = leanjson.reader(root)
        local file = assert(io.open(path, "wb"))
        file:close()
        local chunk, err = reader:next()
        assert.is_nil(chunk)
        assert.matches("EOF", err, 1, true)
        if leanjson.close then leanjson.close(root) end
        local original = assert(io.open(path, "rb"))
        original:close()
    end)
end)
