local qjson = require("qjson")
local lfs = require("lfs")
local io_source = require("qjson.source_io")

describe("source resource leases", function()
    local directory
    local function files()
        local names = {}
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then names[#names + 1] = directory .. "/" .. name end
        end
        return names
    end
    local function decoder(raw, opts)
        opts = opts or {}
        opts.temp_dir = directory
        local value = qjson.new_decoder(opts)
        assert.is_true(value:feed(raw))
        return value, assert(value:finish())
    end
    before_each(function()
        directory = os.tmpname()
        os.remove(directory)
        assert(lfs.mkdir(directory))
    end)
    after_each(function()
        collectgarbage("collect")
        collectgarbage("collect")
        for _, name in ipairs(files()) do os.remove(name) end
        lfs.rmdir(directory)
    end)

    it("creates exclusive owner-only spools and unlinks on the final explicit lease", function()
        assert.is_function(qjson.close)
        local input, root = decoder('{"a":{"x":1},"v":2}')
        assert.are.equal(1, #files())
        assert.are.equal("rw-------", lfs.attributes(files()[1], "permissions"))
        local child = root.a
        local first, second = qjson.fork(root), qjson.fork(root)
        local reader = qjson.reader(first, { chunk_size = 3 })
        input:close()
        qjson.close(root)
        qjson.close(first)
        qjson.close(second)
        assert.are.equal(1, child.x)
        child.x = 9
        qjson.close(child)
        assert.are.equal(1, #files())
        assert.are.equal(19, reader:length())
        reader:close()
        assert.are.equal(0, #files())
        reader:close()
        input:close()
    end)

    it("detaches a closed cached child without changing the open parent", function()
        assert.is_function(qjson.close)
        local input, root = decoder('{"a":{"x":1}}')
        local old = root.a
        qjson.close(old)
        assert.has_error(function() return old.x end)
        assert.has_error(function() old.x = 9 end)
        assert.are.equal(1, root.a.x)
        local fresh = root.a
        assert.is_false(rawequal(old, fresh))
        qjson.close(root)
        fresh.x = 7
        assert.are.equal(7, fresh.x)
        input:close()
        qjson.close(fresh)
        assert.are.equal(0, #files())
    end)

    it("retains each mixed-source dependency until its last holder closes", function()
        assert.is_function(qjson.close)
        local first_input, first = decoder('{"a":{"x":1}}')
        local second_input, second = decoder('{"b":{"x":2}}')
        local held = second.b
        first.b = held
        qjson.close(held)
        local branch = qjson.fork(first)
        local reader = qjson.reader(branch, { chunk_size = 4 })
        first_input:close()
        second_input:close()
        qjson.close(first)
        qjson.close(second)
        qjson.close(branch)
        assert.are.equal(2, #files())
        local parts = {}
        while true do
            local chunk, err = reader:next()
            assert.is_nil(err)
            if not chunk then break end
            parts[#parts + 1] = chunk
        end
        assert.are.equal('{"a":{"x":1},"b":{"x":2}}', table.concat(parts))
        assert.are.equal(0, #files())
    end)

    it("releases removed source dependencies when an overlay becomes independent", function()
        assert.is_function(qjson.close)
        local input, root = decoder('{"a":1}')
        input:close()
        root.a = 2
        assert.are.equal(0, #files())
        assert.are.equal('{"a":2}', qjson.encode(root))
        qjson.close(root)
    end)

    it("holds a path child without hidden intermediate proxy leases", function()
        local input, root = decoder('{"a":{"b":{"x":1}}}')
        local child = qjson.get(root, "a.b")
        input:close()
        qjson.close(root)
        assert.are.equal(1, child.x)
        qjson.close(child)
        assert.are.equal(0, #files())
    end)

    it("cleans unfinished input immediately on abort, close, parse failure and hook failure", function()
        local input = qjson.new_decoder({ temp_dir = directory })
        assert.are.equal(1, #files())
        input:abort("cancelled")
        assert.are.equal(0, #files())
        input = qjson.new_decoder({ temp_dir = directory })
        input:close()
        assert.are.equal(0, #files())
        local _, status = input:get("missing")
        assert.are.equal("ERROR", status)
        input = qjson.new_decoder({ temp_dir = directory })
        assert.is_true(input:feed('{"x":'))
        assert.is_nil(input:finish())
        assert.are.equal(0, #files())
        input = qjson.new_decoder({ temp_dir = directory, chunk_size = 2,
            on_chunk = function() error("hook cancelled") end })
        local ok, err = input:feed('{}')
        assert.is_nil(ok)
        assert.matches("hook cancelled", err, 1, true)
        assert.are.equal(0, #files())
    end)

    it("rejects abort after finish while frozen values remain usable", function()
        assert.is_function(qjson.close)
        local input, root = decoder('{"x":false}')
        local ok, err = input:abort("too late")
        assert.is_nil(ok)
        assert.is_string(err)
        input:close()
        assert.is_false(root.x)
        qjson.close(root)
        assert.are.equal(0, #files())
        qjson.close(false)
        qjson.close(qjson.null)
        qjson.close({ x = 1 })
    end)

    it("uses GC only as a fallback without retaining weak-table keys", function()
        assert.is_function(qjson.close)
        local function abandon()
            local input, root = decoder('{"a":{"x":1}}')
            local child = root.a
            local branch = qjson.fork(root)
            local reader = qjson.reader(branch)
            assert.are.equal(1, child.x)
            assert.is_number(reader:length())
            return input ~= nil
        end
        assert.is_true(abandon())
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(0, #files())
    end)

    it("collects a forgotten parent lease while an independently held child survives", function()
        local function child_only(assigned)
            local input, root = decoder('{"a":{"x":1}}')
            local child = root.a
            if assigned then
                local replacement = qjson.decode('{}')
                replacement.a = child
                qjson.close(child)
                qjson.close(root)
                root = replacement
                child = root.a
            end
            input:close()
            return child
        end
        for _, assigned in ipairs({ false, true }) do
        local child = child_only(assigned)
        collectgarbage("collect")
        collectgarbage("collect")
        assert.are.equal(1, child.x)
        collectgarbage("stop")
        qjson.close(child)
        local remaining = #files()
        collectgarbage("restart")
        assert.are.equal(0, remaining)
        end
    end)

    it("releases a failed reader's leases and propagates the source I/O error", function()
        assert.is_function(qjson.close)
        local input, root = decoder('{"x":1}')
        local reader = qjson.reader(root)
        local original = io_source.read
        io_source.read = function() return nil, "injected disk failure" end
        local chunk, err = reader:next()
        io_source.read = original
        assert.is_nil(chunk)
        assert.matches("injected disk failure", err, 1, true)
        assert.has_error(function() return root.x end)
        input:close()
        qjson.close(root)
        assert.are.equal(0, #files())
    end)

    it("closes suspended scalar and iterator operations without GC or harming other holders", function()
        assert.is_function(qjson.close)
        for _, warm in ipairs({ false, true }) do
            local suspended = false
            local input, root = decoder('{"x":"a long scalar","a":{"n":1}}', { chunk_size = 2,
                on_chunk = function() if suspended then coroutine.yield("source step") end end })
            local fork = qjson.fork(root)
            if warm then assert.are.equal("a long scalar", root.x) end
            suspended = true
            local worker = coroutine.create(function() return pcall(function() return root.x end) end)
            local ok, step = coroutine.resume(worker)
            assert.is_true(ok)
            assert.are.equal("source step", step)
            collectgarbage("stop")
            input:close()
            qjson.close(root)
            suspended = false
            assert.are.equal("a long scalar", fork.x)
            qjson.close(fork)
            local remaining = #files()
            collectgarbage("restart")
            assert.are.equal(0, remaining)
            local resumed, success, err = coroutine.resume(worker)
            assert.is_true(resumed)
            assert.is_false(success)
            assert.is_string(err)
        end
    end)

    it("closes a suspended reader without waiting for its coroutine to resume", function()
        assert.is_function(qjson.close)
        local suspended = false
        local input, root = decoder('{"x":1}', { chunk_size = 2,
            on_chunk = function() if suspended then coroutine.yield("source read") end end })
        local reader = qjson.reader(root)
        suspended = true
        local worker = coroutine.create(function() return reader:next() end)
        assert.are.same({ true, "source read" }, { coroutine.resume(worker) })
        collectgarbage("stop")
        input:close()
        qjson.close(root)
        reader:close()
        local remaining = #files()
        collectgarbage("restart")
        assert.are.equal(0, remaining)
        local ok, chunk, err = coroutine.resume(worker)
        assert.is_true(ok)
        assert.is_nil(chunk)
        assert.matches("closed", err, 1, true)
    end)

    it("closes a suspended feed without requiring collection of the worker stack", function()
        local input = qjson.new_decoder({ temp_dir = directory, chunk_size = 1,
            on_chunk = function() coroutine.yield("feed step") end })
        local worker = coroutine.create(function() return input:feed('{"x":1}') end)
        assert.are.same({ true, "feed step" }, { coroutine.resume(worker) })
        collectgarbage("stop")
        input:close()
        local remaining = #files()
        collectgarbage("restart")
        assert.are.equal(0, remaining)
        local ok, accepted, err = coroutine.resume(worker)
        assert.is_true(ok)
        assert.is_nil(accepted)
        assert.is_string(err)
    end)

    it("constructs without source I/O and closes a suspended normalized length count", function()
        local phase = "input"
        local input, root = decoder('{"a":{"x":1}}', { chunk_size = 2,
            on_chunk = function()
                if phase == "construct" then error("constructor performed source I/O") end
                if phase == "length" then coroutine.yield("count step") end
            end })
        phase = "construct"
        local reader = qjson.reader(root, { normalize_duplicates = true })
        phase = "length"
        local worker = coroutine.create(function() return reader:length() end)
        local ok, step = coroutine.resume(worker)
        assert.is_true(ok)
        assert.are.equal("count step", step)
        collectgarbage("stop")
        input:close()
        qjson.close(root)
        reader:close()
        local remaining = #files()
        collectgarbage("restart")
        assert.are.equal(0, remaining)
        local resumed, length, err = coroutine.resume(worker)
        assert.is_true(resumed)
        assert.is_nil(length)
        assert.matches("closed", err, 1, true)
    end)

    it("cancels first writes, array indexing and materialization while metadata is suspended", function()
        for _, operation in ipairs({ "write", "len", "materialize", "insert", "remove" }) do
            local suspended = false
            local raw = (operation == "write" or operation == "materialize") and '{"a":{"x":1}}' or '[{"x":1},2]'
            local input, root = decoder(raw, { chunk_size = 2,
                on_chunk = function() if suspended then coroutine.yield("metadata step") end end })
            suspended = true
            local worker = coroutine.create(function()
                return pcall(function()
                    if operation == "write" then root.extra = 3
                    elseif operation == "len" then return qjson.len(root)
                    elseif operation == "materialize" then return qjson.materialize(root)
                    elseif operation == "insert" then return qjson.array_insert(root, 1, false)
                    else return qjson.array_remove(root, 1) end
                end)
            end)
            local ok, step = coroutine.resume(worker)
            assert.is_true(ok)
            assert.are.equal("metadata step", step, operation)
            collectgarbage("stop")
            input:close()
            qjson.close(root)
            local remaining = #files()
            collectgarbage("restart")
            assert.are.equal(0, remaining, operation)
            local resumed, success = coroutine.resume(worker)
            assert.is_true(resumed)
            assert.is_false(success)
        end
    end)

    it("materializes independent file values and rejects file provenance explicitly", function()
        local input, root = decoder('{"a":{"x":1}}')
        assert.has_error(function() qjson.materialize(root, { keep_origin = true }) end)
        local plain = qjson.materialize(root)
        input:close()
        qjson.close(root)
        assert.are.equal(0, #files())
        assert.are.same({ a = { x = 1 } }, plain)
        assert.are.equal('{"a":{"x":1}}', qjson.encode(plain))
    end)
end)
