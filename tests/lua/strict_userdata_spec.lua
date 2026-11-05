local json = require("leanjson")
local safe = require("leanjson.safe")
local proxy = require("leanjson.proxy")
local lfs = require("lfs")
local ffi = require("ffi")
ffi.cdef[[int fcntl(int, int, ...);]]
local native_ipairs_metamethod = false
for _ in ipairs(setmetatable({}, { __ipairs = function()
    native_ipairs_metamethod = true
    return function() end
end })) do end

describe("strict userdata carriers", function()
    local held, files
    local function keep(value) held[#held + 1] = function() json.close(value) end; return value end
    local function decoder(api, opts)
        local input = assert(api.new_decoder(opts))
        held[#held + 1] = function() input:close() end
        return input
    end
    local function decode(source, raw, opts, api)
        api = api or json
        if source == "memory" then return keep(assert(api.decode(raw, opts))) end
        if source == "feed" then
            local input = decoder(api, opts)
            for i = 1, #raw do assert.is_true(input:feed(raw:sub(i, i))) end
            local value = keep(assert(input:finish()))
            input:close()
            return value
        end
        local path = os.tmpname()
        files[#files + 1] = path
        local file = assert(io.open(path, "wb"))
        assert(file:write(raw)); assert(file:close())
        return keep(assert(api.decode_file(path, opts)))
    end
    local function drain(reader)
        local parts = {}
        while true do
            local chunk, err = reader:next()
            assert.is_nil(err)
            if not chunk then break end
            assert.is_true(#chunk <= 7)
            parts[#parts + 1] = chunk
        end
        return table.concat(parts)
    end
    before_each(function() held, files = {}, {} end)
    after_each(function()
        for i = #held, 1, -1 do held[i]() end
        for _, path in ipairs(files) do os.remove(path) end
        collectgarbage("collect")
        collectgarbage("collect")
    end)

    for _, api_name in ipairs({ "module", "new", "safe", "safe.new" }) do
        local function api()
            if api_name == "new" then return json.new() end
            if api_name == "safe.new" then return safe.new() end
            return api_name == "safe" and safe or json
        end
        it("validates supplied modes before I/O for " .. api_name, function()
            local codec = api()
            for _, mode in ipairs({ false, true, 1, {}, "", "strict", "TABLE" }) do
                for _, lazy in ipairs({ false, true }) do
                    local opts = { proxy_mode = mode, lazyload = lazy }
                    for _, call in ipairs({ function() codec.decode("{}", opts) end,
                        function() codec.decode_file("/missing/f18-input", opts) end,
                        function() codec.new_decoder(opts) end }) do
                        local ok, err = pcall(call)
                        assert.is_false(ok)
                        assert.matches("proxy_mode", tostring(err), 1, true)
                    end
                end
            end
        end)
        for _, source in ipairs({ "memory", "file", "feed" }) do
            for _, loading in ipairs({ "lazy", "preload", "eager" }) do
                it("carries nested " .. loading .. " values through " .. source .. " for " .. api_name, function()
                    local opts = { proxy_mode = "userdata", chunk_size = 7,
                        index_depth = 0, index_array_limit = 0, index_budget_bytes = 0 }
                    if loading == "eager" then opts.lazyload = false end
                    if loading == "preload" then opts.preload_paths = { "$.child", "$.items[*]" } end
                    local codec = api()
                    assert.are.equal("table", type(codec))
                    local value = decode(source, '{"child":{"x":false},"items":[{},[],null],"n":null}', opts, codec)
                    local kind = loading == "eager" and "table" or "userdata"
                    local child, items = keep(value.child), keep(value.items)
                    local first, second = keep(items[1]), keep(items[2])
                    for _, container in ipairs({ value, child, items, first, second }) do
                        assert.are.equal(kind, type(container))
                    end
                    assert.are.equal("object", codec.type(child))
                    assert.are.equal("array", codec.type(items))
                    assert.is_false(child.x)
                    assert.are.equal(json.null, value.n)
                    assert.are.equal(json.null, items[3])
                    if loading == "eager" then
                        assert.is_false(proxy.is_proxy(value))
                        assert.are.equal(child, rawget(value, "child"))
                    else
                        assert.are.equal(0, json.source_stats(value).index_bytes)
                        child.x = true
                        assert.is_true(value.child.x)
                        local plain = json.materialize(value)
                        assert.are.equal("table", type(plain))
                        assert.is_true(rawget(plain.child, "x"))
                    end
                end)
            end
        end
    end

    it("keeps default and explicit table carriers alongside strict views", function()
        for _, opts in ipairs({ {}, { proxy_mode = "table" } }) do
            local value = keep(json.decode('{"a":[]} ', opts))
            assert.are.equal("table", type(value))
            assert.are.equal("table", type(keep(value.a)))
            assert.is_nil(next(value))
        end
        local scalar = json.decode("false", { proxy_mode = "userdata" })
        assert.is_false(scalar)
        assert.are.equal(json.null, json.decode("null", { proxy_mode = "userdata" }))
    end)

    it("fails clearly without a userdata factory while table mode remains available", function()
        local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
        local interpreter = os.getenv("LUAJIT_BIN") or os.getenv("LUAJIT")
            or (arg and type(arg[-1]) == "string" and not arg[-1]:match("^%-") and arg[-1]) or "luajit"
        local status = os.execute(quote(interpreter) .. " tests/lua/fixtures/strict_without_factory.lua")
        assert.is_true(status == 0 or status == true, "missing-factory contract failed")
    end)

    it("rejects native raw and table-only operations without changing builtins", function()
        local value = keep(json.decode('[{"x":1}]', { proxy_mode = "userdata" }))
        assert.are.equal("userdata", type(value))
        for _, call in ipairs({ function() return rawget(value, 1) end,
            function() rawset(value, 1, 2) end, function() return next(value) end,
            function() return table.getn(value) end, function() table.insert(value, 2) end,
            function() table.remove(value, 1) end, function() table.sort(value) end,
            function() return table.concat(value) end, function() setmetatable(value, {}) end }) do
            assert.has_error(call)
        end
        assert.are.equal(1, #value)
        assert.are.equal(1, json.len(value))
        local seen = {}
        for i, child in json.ipairs(value) do seen[i] = keep(child).x end
        assert.are.same({ 1 }, seen)
        assert.are.equal('[{"x":1}]', json.encode(value))
    end)

    for _, mode in ipairs({ "table", "userdata" }) do
        for _, raw in ipairs({ "{}", '{"1":"string-key"}' }) do
            it("preserves portable and native ipairs behavior for " .. mode .. " object " .. raw, function()
                local value = keep(json.decode(raw, { proxy_mode = mode }))
                local count = 0
                for _ in json.ipairs(value) do count = count + 1 end
                assert.are.equal(0, count)
                local ok, err = pcall(function()
                    for _ in ipairs(value) do count = count + 1 end
                end)
                if native_ipairs_metamethod or mode == "table" then
                    assert.is_true(ok, tostring(err))
                else
                    assert.is_false(ok)
                    assert.matches("table expected, got userdata", tostring(err), 1, true)
                end
                assert.are.equal(0, count)
                assert.are.equal("object", json.type(value))
            end)
        end
        it("checks closed " .. mode .. " object ownership with portable and native ipairs", function()
            local value = keep(json.decode('{"1":"string-key"}', { proxy_mode = mode }))
            local iterator, state, initial = json.ipairs(value)
            local native_ok, native_iterator, native_state, native_initial = pcall(ipairs, value)
            if native_ipairs_metamethod or mode == "table" then
                assert.is_true(native_ok, tostring(native_iterator))
            else
                assert.is_false(native_ok)
                assert.matches("table expected, got userdata", tostring(native_iterator), 1, true)
            end
            json.close(value)
            local resumed, err = pcall(iterator, state, initial)
            assert.is_false(resumed)
            assert.matches("closed", tostring(err), 1, true)
            local started, start_error = pcall(json.ipairs, value)
            assert.is_false(started)
            assert.matches("closed", tostring(start_error), 1, true)
            if native_ipairs_metamethod then
                resumed, err = pcall(native_iterator, native_state, native_initial)
                assert.is_false(resumed)
                assert.matches("closed", tostring(err), 1, true)
                started, start_error = pcall(ipairs, value)
                assert.is_false(started)
                assert.matches("closed", tostring(start_error), 1, true)
            elseif mode == "table" then
                assert.is_nil(native_iterator(native_state, native_initial))
                local next_item, closed_state, first_item = ipairs(value)
                assert.is_nil(next_item(closed_state, first_item))
            else
                started, start_error = pcall(ipairs, value)
                assert.is_false(started)
                assert.matches("table expected, got userdata", tostring(start_error), 1, true)
            end
        end)
    end

    it("shares carrier metatables and preserves array marker exposure", function()
        local codec = json.new()
        codec.decode_array_with_array_mt(true)
        local value = keep(codec.decode('{"a":[],"b":[],"c":{},"d":{}}', { proxy_mode = "userdata" }))
        local a, b, c, d = keep(value.a), keep(value.b), keep(value.c), keep(value.d)
        assert.are.equal("userdata", type(a))
        assert.are.equal(json.array_mt, getmetatable(a))
        assert.are.equal(debug.getmetatable(a), debug.getmetatable(b))
        assert.are.equal(debug.getmetatable(c), debug.getmetatable(d))
        assert.are.equal(json.array_mt, getmetatable(json.materialize(a)))
        assert.are.equal("[]", tostring(a))
        local plain = json.materialize(value)
        assert.are.equal("table", type(plain.a))
        assert.are.equal(json.array_mt, getmetatable(plain.b))
    end)

    it("preserves independent decoder get and repeated finish carriers after close", function()
        local input = decoder(json, { proxy_mode = "userdata" })
        assert.is_true(input:feed('{"child":{"x":1},"items":[{"x":2}]}'))
        local missing, status = input:get("child")
        assert.is_nil(missing); assert.are.equal("NEED_INPUT", status)
        local first = keep(assert(input:finish()))
        local child, ready = input:get("child")
        keep(child)
        local second = keep(assert(input:finish()))
        assert.are.equal("READY", ready)
        assert.are.equal("userdata", type(child))
        assert.are.equal("userdata", type(first))
        assert.are.equal("userdata", type(second))
        input:close(); json.close(first)
        child.x = 8
        assert.are.equal(1, second.child.x)
        assert.are.equal(8, child.x)
        assert.are.equal("userdata", type(keep(second.items)))
    end)

    for _, mode in ipairs({ "table", "userdata" }) do
        it("uses the destination " .. mode .. " carrier for assignment and dense edits", function()
            local source = keep(json.decode('{"x":1,"nested":{}}', { proxy_mode = mode == "table" and "userdata" or "table" }))
            local value = keep(json.decode('{"items":[]}', { proxy_mode = mode }))
            value.assigned = { mixed = source }
            local assigned, items = keep(value.assigned), keep(value.items)
            local mixed = keep(assigned.mixed)
            json.array_insert(items, 1, source)
            local inserted = keep(items[1])
            source.x = 9
            assert.are.equal(mode, type(assigned))
            assert.are.equal(mode, type(mixed))
            assert.are.equal(mode, type(keep(mixed.nested)))
            assert.are.equal(mode, type(inserted))
            assert.are.equal(1, mixed.x)
            assert.are.equal(1, inserted.x)
            local removed = keep(json.array_remove(items, 1))
            json.close(value); json.close(items); json.close(source)
            assert.are.equal(mode, type(removed))
            removed.extra = { flag = false }
            assert.are.equal(mode, type(keep(removed.extra)))
            assert.is_false(removed.extra.flag)
            assert.are.equal(1, mixed.x)
        end)
        it("keeps uncached array-remove and detached children in " .. mode .. " mode", function()
            local value = keep(json.decode('[{"child":{}},{"child":{}}]', { proxy_mode = mode }))
            local removed = keep(json.array_remove(value, 1))
            local detached = keep(value[1])
            value[1] = nil
            json.close(value)
            assert.are.equal(mode, type(removed))
            assert.are.equal(mode, type(detached))
            assert.are.equal(mode, type(keep(removed.child)))
            assert.are.equal(mode, type(keep(detached.child)))
        end)
        it("forks source " .. mode .. " carrier across independent codecs", function()
            local codec = json.new()
            local source = keep(codec.decode('{"a":{"x":1}}', { proxy_mode = mode }))
            local branch = keep(safe.new().fork(source))
            json.close(source)
            assert.are.equal(mode, type(branch))
            assert.are.equal(mode, type(keep(branch.a)))
            branch.a.x = 2
            assert.are.equal('{"a":{"x":2}}', json.encode(branch))
        end)
    end

    it("forks ordinary tables into the default carrier including nested strict snapshots", function()
        local strict = keep(json.decode('{"x":1}', { proxy_mode = "userdata" }))
        local branch = keep(json.fork({ child = strict }))
        assert.are.equal("table", type(branch))
        assert.are.equal("table", type(keep(branch.child)))
        strict.x = 2
        assert.are.equal(1, branch.child.x)
    end)

    it("encodes own userdata before unsupported filtering in mixed trees", function()
        local codec = json.new()
        local value = keep(codec.decode('{"a":[1],"b":{}}', { proxy_mode = "userdata" }))
        assert.are.equal('{"a":[1],"b":{}}', codec.encode(value))
        codec.encode_skip_unsupported_value_types(true)
        assert.are.equal('{"a":[1],"b":{}}', codec.encode(value))
        local table_view = keep(json.decode('[2]'))
        local encoded = codec.encode({ value, table_view, { value }, newproxy(true), function() end })
        assert.are.equal('[{"a":[1],"b":{}},[2],[{"a":[1],"b":{}}]]', encoded)
        local reader = codec.reader({ value, table_view, { value }, newproxy(true) }, { chunk_size = 7 })
        assert.are.equal('[{"a":[1],"b":{}},[2],[{"a":[1],"b":{}}]]', drain(reader))
        reader:close()
        codec.encode_skip_unsupported_value_types(false)
        assert.has_error(function() codec.encode(newproxy(true)) end)
    end)

    it("applies output settings to edited strict proxies and reader snapshots", function()
        local codec = json.new()
        codec.encode_number_precision(3)
        codec.encode_escape_forward_slash(false)
        codec.encode_invalid_numbers("null")
        codec.encode_indent(" ")
        local value = keep(codec.decode('{"number":1,"text":"old","items":[]}', { proxy_mode = "userdata" }))
        value.number, value.text, value.invalid = 1.23456, "/\127", math.huge
        value.items[1] = false
        local reader = codec.reader(value, { chunk_size = 7 })
        value.number = 8
        json.close(value)
        local output = drain(reader)
        assert.are.equal('{\n "number": 1.23,\n "text": "/\\u007f",\n "items": [\n  false\n ],\n "invalid": null\n}', output)
        reader:close()
    end)

    it("retains preloaded values without additional source reads", function()
        local calls = 0
        local value = decode("file", '{"a":{"b":{"x":false}},"items":[{"x":2}],"tail":true}',
            { proxy_mode = "userdata", chunk_size = 1, index_depth = 0, index_array_limit = 0,
                index_budget_bytes = 0, preload_paths = { "$.a", "$.items[*]" },
                on_chunk = function() calls = calls + 1 end })
        local scanned = calls
        assert.are.equal("userdata", type(keep(value.a)))
        assert.is_false(value.a.b.x)
        assert.are.equal(2, value.items[1].x)
        assert.are.equal(scanned, calls)
        assert.are.equal(0, json.source_stats(value).index_bytes)
    end)

    it("keeps strict source leases through GC and releases the last reader", function()
        local directory = os.tmpname()
        os.remove(directory); assert(lfs.mkdir(directory))
        local spool, fd
        local io_source = require("leanjson.source_io")
        local original = io_source.spool
        io_source.spool = function(path)
            fd, spool = original(path)
            return fd, spool
        end
        local ok, err = pcall(function()
            local function abandon()
                local input = json.new_decoder({ file_in_memory = false, temp_dir = directory, proxy_mode = "userdata" })
                assert(input:feed('{"a":{"x":1}}'))
                local root = assert(input:finish())
                local child = root.a
                local branch = json.fork(child)
                assert.are.equal("userdata", type(branch))
                return json.reader(branch, { chunk_size = 7 })
            end
            local reader = abandon()
            collectgarbage("collect"); collectgarbage("collect")
            assert.is_not_nil(lfs.attributes(spool))
            assert.are.equal('{"x":1}', drain(reader))
            reader:close(); reader:close()
            collectgarbage("collect"); collectgarbage("collect")
            assert.is_nil(lfs.attributes(spool))
            assert.are.equal(-1, ffi.C.fcntl(fd, 1))
            assert.are.equal(9, ffi.errno())
        end)
        io_source.spool = original
        if spool then os.remove(spool) end
        lfs.rmdir(directory)
        assert.is_true(ok, err)
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
    it("cancels a yielding strict " .. source .. " view without cancelling an independent fork", function()
        local value = decode(source, '{"a":{"x":1}}', { proxy_mode = "userdata", index_budget_bytes = 0 })
        local backend = proxy.node(value).backend
        local branch = keep(json.fork(value))
        local original, pause = backend.lookup, true
        function backend:lookup(handle, key, scope)
            if pause then pause = false; coroutine.yield("pending") end
            return original(self, handle, key, scope)
        end
        local co = coroutine.create(function() return value.a end)
        local ok, pending = coroutine.resume(co)
        assert.is_true(ok); assert.are.equal("pending", pending)
        json.close(value)
        local resumed, failure = coroutine.resume(co)
        assert.is_false(resumed); assert.matches("closed", tostring(failure), 1, true)
        assert.are.equal("userdata", type(branch))
        assert.are.equal(1, branch.a.x)
    end)
    end
end)
