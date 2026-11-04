local source_io = require("leanjson.source_io")

describe("bounded synchronous source reads", function()
    local filename, fd
    after_each(function()
        collectgarbage("restart")
        if fd then source_io.close(fd); fd = nil end
        if filename then os.remove(filename); filename = nil end
    end)

    it("keeps repeated read buffers bounded even before garbage collection", function()
        filename = os.tmpname()
        local expected = string.rep("x", 65536)
        local file = assert(io.open(filename, "wb"))
        assert(file:write(expected, "tail")); assert(file:close())
        fd = assert(source_io.open(filename))
        assert.are.equal(expected, source_io.read(fd, 0, 65536))
        collectgarbage("collect")
        collectgarbage("stop")
        local before = collectgarbage("count")
        for _ = 1, 64 do assert.are.equal(expected, source_io.read(fd, 0, 65536)) end
        local growth = collectgarbage("count") - before
        collectgarbage("restart")
        assert.is_true(growth < 1024, "bounded reads allocated " .. growth .. " KiB before GC")
        local held = source_io.read(fd, 0, 4)
        assert.are.equal("tail", source_io.read(fd, 65536, 4))
        assert.are.equal("xxxx", held)
    end)
end)
