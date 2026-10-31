local qjson = require("qjson")
local ffi = require("ffi")
local lfs = require("lfs")
local source_io = require("qjson.source_io")
ffi.cdef[[int fcntl(int, int, ...);]]

describe("source review ownership regressions", function()
    local directory, held, inputs, fds, spools, originals
    local original_open, original_spool
    local function hold(value) held[#held + 1] = value; return value end
    local function root(mode, raw, opts)
        opts = opts or {}
        opts.temp_dir = directory
        if mode == "memory" then return hold(qjson.decode(raw)) end
        if mode == "file" then
            local filename = directory .. "/input-" .. (#originals + 1) .. ".json"
            originals[#originals + 1] = filename
            local output = assert(io.open(filename, "wb"))
            output:write(raw)
            output:close()
            return hold(qjson.decode_file(filename, opts))
        end
        local input = qjson.new_decoder(opts)
        inputs[#inputs + 1] = input
        assert.is_true(input:feed(raw))
        local value, err = input:finish()
        assert.is_nil(err)
        input:close()
        return hold(value)
    end
    local function descriptors_closed()
        for _, fd in ipairs(fds) do
            assert.are.equal(-1, ffi.C.fcntl(fd, 1))
            assert.are.equal(9, ffi.errno())
        end
        for _, filename in ipairs(spools) do assert.is_nil(lfs.attributes(filename)) end
        for _, filename in ipairs(originals) do assert.is_not_nil(lfs.attributes(filename)) end
    end
    before_each(function()
        directory = os.tmpname()
        os.remove(directory)
        assert(lfs.mkdir(directory))
        held, inputs, fds, spools, originals = {}, {}, {}, {}, {}
        original_open, original_spool = source_io.open, source_io.spool
        source_io.open = function(filename)
            local fd, err = original_open(filename)
            if fd then fds[#fds + 1] = fd end
            return fd, err
        end
        source_io.spool = function(temp_dir)
            local fd, filename = original_spool(temp_dir)
            if fd then fds[#fds + 1] = fd; spools[#spools + 1] = filename end
            return fd, filename
        end
    end)
    after_each(function()
        collectgarbage("restart")
        for _, input in ipairs(inputs) do input:close() end
        for _, value in ipairs(held) do qjson.close(value) end
        source_io.open, source_io.spool = original_open, original_spool
        collectgarbage("collect")
        collectgarbage("collect")
        for filename in lfs.dir(directory) do
            if filename ~= "." and filename ~= ".." then os.remove(directory .. "/" .. filename) end
        end
        lfs.rmdir(directory)
    end)

    for _, mode in ipairs({ "memory", "file", "spool" }) do
        it("keeps cold path aliases canonical through ordinary ancestor edits in " .. mode, function()
            for _, wrapped in ipairs({ false, true }) do
                local value = root(mode, '{"a":{"b":{"x":1},"sibling":2}}')
                local container = wrapped and { value = value } or value
                local path = wrapped and "value.a.b" or "a.b"
                local first = hold(qjson.get(container, path))
                local second = hold(qjson.get(container, path))
                assert.is_true(rawequal(first, second))
                local ancestor = hold(value.a)
                ancestor.sibling = 3
                first.x = 7
                assert.are.equal(7, value.a.b.x)
                assert.are.equal(7, second.x)
                second.x = 8
                assert.are.equal('{"a":{"b":{"x":8},"sibling":3}}', qjson.encode(value))
                value.a = { b = { x = 20 } }
                first.x = 9
                assert.are.equal(20, value.a.b.x)
            end
        end)

        it("moves canonical cold array paths through insert and remove in " .. mode, function()
            local value = root(mode, '{"items":[{"b":{"x":1},"sibling":2},{"b":{"x":10}}]}')
            local child = hold(qjson.get(value, "items[0].b"))
            local array = hold(value.items)
            local ancestor = hold(array[1])
            ancestor.sibling = 3
            child.x = 7
            assert.are.equal(7, array[1].b.x)
            qjson.array_insert(array, 1, { b = { x = 99 } })
            child.x = 8
            assert.are.equal(8, array[2].b.x)
            local removed = hold(qjson.array_remove(array, 2))
            child.x = 9
            assert.are.equal(9, removed.b.x)
            assert.are.equal(99, array[1].b.x)
            assert.are.equal(10, array[2].b.x)
        end)

        it("preserves live descendant linkage when intermediate wrappers are collected in " .. mode, function()
            local value = root(mode, '{"a":{"b":{"x":1}}}')
            local child = hold(value.a.b)
            collectgarbage("collect")
            collectgarbage("collect")
            child.x = 7
            assert.are.equal(7, value.a.b.x)
            assert.are.equal('{"a":{"b":{"x":7}}}', qjson.encode(value))
            local ancestor = hold(value.a)
            qjson.close(ancestor)
            child.x = 8
            assert.are.equal(7, value.a.b.x)
            assert.are.equal(8, child.x)
        end)
    end

    for _, mode in ipairs({ "file", "spool" }) do
        it("cancels nested cold and warm scalar paths through the actual holder in " .. mode, function()
            for _, warm in ipairs({ false, true }) do
                local pause = false
                local value = root(mode, '{"a":{"x":"abcdef"}}', { chunk_size = 2,
                    on_chunk = function() if pause then pause = false; coroutine.yield("scalar paused") end end })
                local ancestor
                if warm then ancestor = hold(value.a) end
                assert.is_nil(qjson.get(value, "a.missing"))
                pause = true
                local worker = coroutine.create(function() return pcall(qjson.get, value, "a.x") end)
                assert.are.same({ true, "scalar paused" }, { coroutine.resume(worker) })
                collectgarbage("stop")
                qjson.close(value)
                if ancestor then qjson.close(ancestor) end
                local ok, err = pcall(descriptors_closed)
                collectgarbage("restart")
                assert.is_true(ok, err)
                local resumed, success, failure = coroutine.resume(worker)
                assert.is_true(resumed)
                assert.is_false(success)
                assert.is_string(failure)
            end
        end)
    end

    it("rejects finish and concurrent feed while an accepted chunk is suspended", function()
        local pause = true
        local input = qjson.new_decoder({ temp_dir = directory, chunk_size = 2,
            on_chunk = function() if pause then pause = false; coroutine.yield("feed paused") end end })
        inputs[#inputs + 1] = input
        local worker = coroutine.create(function() return input:feed('{}  ') end)
        assert.are.same({ true, "feed paused" }, { coroutine.resume(worker) })
        local value, err = input:finish()
        assert.is_nil(value)
        assert.matches("in progress", err, 1, true)
        local accepted, overlap = input:feed("junk")
        assert.is_nil(accepted)
        assert.matches("in progress", overlap, 1, true)
        local _, status = input:get("")
        assert.are.equal("NEED_INPUT", status)
        assert.are.same({ true, true }, { coroutine.resume(worker) })
        assert.is_true(input:feed(" "))
        local completed, failure = input:finish()
        assert.is_nil(failure)
        hold(completed)
        assert.are.equal("{}", qjson.encode(completed))
        assert.is_nil(input:feed(" "))
        assert.are.equal("{}", qjson.encode(completed))
        hold(assert(input:finish()))
    end)

    it("rejects overlapping completion while a scalar finish is suspended", function()
        local pause = false
        local input = qjson.new_decoder({ temp_dir = directory, chunk_size = 2,
            on_chunk = function() if pause then pause = false; coroutine.yield("finish paused") end end })
        inputs[#inputs + 1] = input
        assert.is_true(input:feed('"abcdef"'))
        pause = true
        local worker = coroutine.create(function() return input:finish() end)
        assert.are.same({ true, "finish paused" }, { coroutine.resume(worker) })
        local value, err = input:finish()
        assert.is_nil(value)
        assert.matches("in progress", err, 1, true)
        local accepted, overlap = input:feed(" ")
        assert.is_nil(accepted)
        assert.matches("in progress", overlap, 1, true)
        local pending, status = input:get("")
        assert.is_nil(pending)
        assert.are.equal("NEED_INPUT", status)
        assert.are.same({ true, "abcdef" }, { coroutine.resume(worker) })
        assert.are.equal("abcdef", input:finish())
    end)

    it("cancels a first scalar completion through abort or close without GC", function()
        for _, operation in ipairs({ "abort", "close" }) do
            local pause = false
            local input = qjson.new_decoder({ temp_dir = directory, chunk_size = 2,
                on_chunk = function() if pause then pause = false; coroutine.yield("finish paused") end end })
            inputs[#inputs + 1] = input
            assert.is_true(input:feed('"abcdef"'))
            pause = true
            local worker = coroutine.create(function() return input:finish() end)
            assert.are.same({ true, "finish paused" }, { coroutine.resume(worker) })
            collectgarbage("stop")
            if operation == "abort" then assert.is_true(input:abort("finish cancelled")) else input:close() end
            local ok, err = pcall(descriptors_closed)
            collectgarbage("restart")
            assert.is_true(ok, err)
            local resumed, value, failure = coroutine.resume(worker)
            assert.is_true(resumed)
            assert.is_nil(value)
            assert.is_string(failure)
            local _, status = input:get("")
            assert.are.equal("ERROR", status)
        end
    end)
end)
