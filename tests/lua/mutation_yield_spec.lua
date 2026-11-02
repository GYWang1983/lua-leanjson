local leanjson = require("leanjson")
local proxy = require("leanjson.proxy")
local source_io = require("leanjson.source_io")
local ffi = require("ffi")
local lfs = require("lfs")
ffi.cdef[[int fcntl(int, int, ...);]]

describe("mutation publication across source yields", function()
    local directory, held, originals, descriptors, spools, restore_open, restore_spool
    local function hold(value) held[#held + 1] = value; return value end
    local function source(mode, raw)
        local pause = false
        local function checkpoint()
            if pause then pause = false; coroutine.yield("mutation paused") end
        end
        local value
        if mode == "memory" then
            local backend, root = require("leanjson.source_memory").open(raw)
            local children, scalar, lookup, length = backend.children, backend.scalar, backend.lookup, backend.length
            function backend:children(handle)
                local next_child = children(self, handle)
                return function() checkpoint(); return next_child() end
            end
            function backend:scalar(handle) checkpoint(); return scalar(self, handle) end
            function backend:lookup(handle, key, scope) checkpoint(); return lookup(self, handle, key, scope) end
            function backend:length(handle, scope) checkpoint(); return length(self, handle, scope) end
            value = proxy.from_backend(backend, root)
        elseif mode == "file" then
            local filename = directory .. "/input-" .. (#originals + 1)
            originals[#originals + 1] = filename
            local output = assert(io.open(filename, "wb"))
            output:write(raw)
            output:close()
            value = leanjson.decode_file(filename, { chunk_size = 2, on_chunk = checkpoint })
        else
            local input = leanjson.new_decoder({ temp_dir = directory, chunk_size = 2, on_chunk = checkpoint })
            assert.is_true(input:feed(raw))
            value = assert(input:finish())
            input:close()
        end
        return hold(value), function(fn)
            pause = true
            local worker = coroutine.create(function() return pcall(fn) end)
            assert.are.same({ true, "mutation paused" }, { coroutine.resume(worker) })
            return worker
        end
    end
    local function stale(worker)
        local resumed, ok, err = coroutine.resume(worker)
        assert.is_true(resumed)
        assert.is_false(ok, "a stale mutation committed successfully")
        assert.matches("stale proxy mutation", err, 1, true)
    end
    local function closed()
        for _, fd in ipairs(descriptors) do
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
        held, originals, descriptors, spools = {}, {}, {}, {}
        restore_open, restore_spool = source_io.open, source_io.spool
        source_io.open = function(filename)
            local fd, err = restore_open(filename)
            if fd then descriptors[#descriptors + 1] = fd end
            return fd, err
        end
        source_io.spool = function(temp_dir)
            local fd, filename = restore_spool(temp_dir)
            if fd then descriptors[#descriptors + 1] = fd; spools[#spools + 1] = filename end
            return fd, filename
        end
    end)
    after_each(function()
        collectgarbage("restart")
        for _, value in ipairs(held) do leanjson.close(value) end
        source_io.open, source_io.spool = restore_open, restore_spool
        collectgarbage("collect")
        collectgarbage("collect")
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then os.remove(directory .. "/" .. name) end
        end
        lfs.rmdir(directory)
    end)

    for _, mode in ipairs({ "memory", "file", "spool" }) do
        it("preserves a completed disjoint object write in " .. mode, function()
            local root, suspend = source(mode, '{"a":0,"b":0}')
            local worker = suspend(function() root.a = 1 end)
            root.b = 2
            stale(worker)
            assert.are.equal('{"a":0,"b":2}', leanjson.encode(root))
            root.a = 3
            assert.are.equal('{"a":3,"b":2}', leanjson.encode(root))
        end)

        it("rejects stale array insertion before shifting children in " .. mode, function()
            local root, suspend = source(mode, '["first",2]')
            local worker = suspend(function() leanjson.array_insert(root, 1, 99) end)
            root[3] = 3
            stale(worker)
            assert.are.equal('["first",2,3]', leanjson.encode(root))
            assert.are.equal(3, leanjson.len(root))
            leanjson.array_insert(root, 1, 99)
            assert.are.equal('[99,"first",2,3]', leanjson.encode(root))
        end)

        it("preserves density when append or tail deletion is stale in " .. mode, function()
            for _, append in ipairs({ true, false }) do
                local root, suspend = source(mode, '["first",2]')
                local worker = suspend(function()
                    if append then root[3] = 3 else root[2] = nil end
                end)
                if append then root[2] = nil else root[3] = 3 end
                stale(worker)
                assert.are.equal(append and '["first"]' or '["first",2,3]', leanjson.encode(root))
                assert.are.equal(append and 1 or 3, leanjson.len(root))
                assert.is_nil(root[leanjson.len(root) + 1])
                root[leanjson.len(root) + 1] = 4
                assert.are.equal(4, root[leanjson.len(root)])
            end
        end)

        it("rejects removal after a yielding scalar read in " .. mode, function()
            local root, suspend = source(mode, '["first",2]')
            assert.are.equal(2, leanjson.len(root))
            local worker = suspend(function() return leanjson.array_remove(root, 1) end)
            root[3] = 3
            stale(worker)
            assert.are.equal('["first",2,3]', leanjson.encode(root))
            assert.are.equal(3, leanjson.len(root))
            assert.is_nil(root[4])
            assert.are.equal("first", leanjson.array_remove(root, 1))
            assert.are.equal('[2,3]', leanjson.encode(root))
        end)

        it("keeps held child links and positions after rejected removal in " .. mode, function()
            local root, suspend = source(mode, '["first",{"x":2}]')
            local child = hold(root[2])
            local worker = suspend(function() return leanjson.array_remove(root, 1) end)
            root[3] = 3
            stale(worker)
            assert.is_true(rawequal(child, root[2]))
            child.x = 7
            assert.are.equal('["first",{"x":7},3]', leanjson.encode(root))
            assert.are.equal("first", leanjson.array_remove(root, 1))
            assert.is_true(rawequal(child, root[1]))
            assert.is_true(rawequal(child, leanjson.array_remove(root, 1)))
            child.x = 9
            assert.are.equal('[3]', leanjson.encode(root))
            assert.are.equal(9, child.x)
        end)

        it("validates ancestors before publishing a nested mutation in " .. mode, function()
            for _, replacement in ipairs({ false, true }) do
                local root, suspend = source(mode, '{"a":{"x":1},"b":0}')
                local child = hold(root.a)
                local worker = suspend(function() child.x = 7 end)
                if replacement then root.a = { x = 8 } else root.b = 2 end
                stale(worker)
                assert.are.equal(1, child.x)
                assert.are.equal(replacement and '{"a":{"x":8},"b":0}' or '{"a":{"x":1},"b":2}', leanjson.encode(root))
                child.x = 9
                assert.are.equal(replacement and 8 or 9, root.a.x)
            end
        end)

        it("allows independent fork mutations while preparation yields in " .. mode, function()
            local root, suspend = source(mode, '{"a":0,"b":0}')
            local branch = hold(leanjson.fork(root))
            local worker = suspend(function() root.a = 1 end)
            branch.b = 2
            assert.are.same({ true, true }, { coroutine.resume(worker) })
            assert.are.equal('{"a":1,"b":0}', leanjson.encode(root))
            assert.are.equal('{"a":0,"b":2}', leanjson.encode(branch))
        end)
    end

    for _, mode in ipairs({ "file", "spool" }) do
        it("keeps collected mixed-source ancestors non-owning in " .. mode, function()
            local function orphan()
                local first = source(mode, '{"a":{"x":1}}')
                held[#held] = nil
                local second = source(mode, '{"b":{"y":2}}')
                held[#held] = nil
                local child, other = first.a, second.b
                first.other = other
                leanjson.close(other)
                leanjson.close(second)
                return hold(child)
            end
            local child = orphan()
            collectgarbage("collect")
            collectgarbage("collect")
            assert.are.equal(0, ffi.C.fcntl(descriptors[1], 1))
            assert.are.equal(-1, ffi.C.fcntl(descriptors[2], 1))
            assert.are.equal(9, ffi.errno())
            child.x = 7
            assert.are.equal('{"x":7}', leanjson.encode(child))
            collectgarbage("stop")
            leanjson.close(child)
            local ok, err = pcall(closed)
            collectgarbage("restart")
            assert.is_true(ok, err)
        end)

        it("cancels prepared assignment dependencies without hidden holders in " .. mode, function()
            local root, suspend = source(mode, '{"b":0}')
            local external = source(mode, '{"a":{"x":1}}')
            local child = hold(external.a)
            local worker = suspend(function() root.a = child end)
            collectgarbage("stop")
            leanjson.close(child)
            leanjson.close(external)
            leanjson.close(root)
            local ok, err = pcall(closed)
            collectgarbage("restart")
            assert.is_true(ok, err)
            local resumed, success, failure = coroutine.resume(worker)
            assert.is_true(resumed)
            assert.is_false(success)
            assert.matches("closed", failure, 1, true)
        end)

        it("cancels nested mutation preparation immediately through its owner in " .. mode, function()
            local root, suspend = source(mode, '{"a":{"x":1},"b":0}')
            local child = hold(root.a)
            local worker = suspend(function() child.x = 7 end)
            collectgarbage("stop")
            leanjson.close(root)
            leanjson.close(child)
            local ok, err = pcall(closed)
            collectgarbage("restart")
            assert.is_true(ok, err)
            local resumed, success, failure = coroutine.resume(worker)
            assert.is_true(resumed)
            assert.is_false(success)
            assert.matches("closed", failure, 1, true)
        end)
    end
end)
