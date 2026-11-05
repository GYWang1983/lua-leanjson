local json = require("leanjson")
local proxy = require("leanjson.proxy")
local io_source = require("leanjson.source_io")
local ffi = require("ffi")
ffi.cdef[[int fcntl(int, int, ...);]]

local function decode(mode, raw, opts, codec)
    local api = codec or json
    if mode == "memory" then return api.decode(raw, opts) end
    if mode == "feed" then
        local input = api.new_decoder(opts)
        for i = 1, #raw do assert.is_true(input:feed(raw:sub(i, i))) end
        local value, err = input:finish()
        input:close()
        assert.is_nil(err)
        return value
    end
    local filename = os.tmpname()
    local file = assert(io.open(filename, "wb"))
    file:write(raw); file:close()
    local ok, value = pcall(api.decode_file, filename, opts)
    os.remove(filename)
    if not ok then error(value, 0) end
    return value
end

local function selected(paths)
    return { preload_paths = paths, index_depth = 0, index_array_limit = 0, index_budget_bytes = 0, chunk_size = 1 }
end

describe("decode loading modes", function()
    it("returns ordinary editable eager values", function()
        local value = json.decode('{"a":{"b":false},"items":[null,{},[]]}', { lazyload = false })
        assert.is_table(rawget(value, "a"))
        assert.is_false(rawget(value.a, "b"))
        assert.are.equal(json.null, rawget(value.items, 1))
        assert.is_nil(next(value.items[2]))
        assert.are.equal("{}", json.encode(value.items[3]))
        value.a.b = true
        assert.is_true(rawget(value.a, "b"))
    end)

    it("preloads deep and far paths independently of every index bound", function()
        local raw = '{"a":{"b":{"c":{"d":{"e":"selected"}}}},"items":[0,1,2,3,4,{"x":false}],"ignored":"lazy"}'
        local filename = os.tmpname()
        local file = assert(io.open(filename, "wb"))
        assert(file:write(raw)); assert(file:close())
        local callbacks = 0
        local ok, err = pcall(function()
            local value = json.decode_file(filename, { chunk_size = 1,
                index_depth = 0, index_array_limit = 0, index_budget_bytes = 0,
                preload_paths = { "$.a.b.c.d.e", "$.items[5].x" },
                on_chunk = function() callbacks = callbacks + 1 end })
            local after_scan = callbacks
            for _ = 1, 3 do
                assert.are.equal("selected", value.a.b.c.d.e)
                assert.is_false(value.items[6].x)
            end
            assert.are.equal(after_scan, callbacks)
            assert.are.equal("lazy", value.ignored)
            assert.are.equal(raw, json.encode(value))
            json.close(value)
        end)
        os.remove(filename)
        assert.is_true(ok, err)
    end)

    for _, mode in ipairs({ "memory", "file", "feed" }) do
        it("builds all eager root kinds and final whole duplicate values in " .. mode, function()
            for _, case in ipairs({ { "null", json.null }, { "false", false }, { "true", true },
                { "-1.25e2", -125 }, { '"a\\n\\uD83D\\uDE00"', "a\n😀" } }) do
                assert.are.equal(case[2], decode(mode, case[1], { lazyload = false, chunk_size = 1 }))
            end
            local value = decode(mode, '{"a":{"old":1},"\\u0061":{"new":2},"items":[{},[],false,null]}',
                { lazyload = false, preload_paths = { "$.missing" }, chunk_size = 1 })
            assert.is_false(proxy.is_proxy(value))
            assert.is_nil(rawget(value.a, "old"))
            assert.are.equal(2, rawget(value.a, "new"))
            assert.are.equal(4, #value.items)
            assert.is_false(rawget(value.items, 3))
            assert.are.equal("{}", json.encode(value.items[1]))
            assert.are.equal("{}", json.encode(value.items[2]))
            local count = 0
            for _ in pairs(value) do count = count + 1 end
            assert.are.equal(2, count)
        end)

        it("handles escaped keys wildcards overlaps and missing selections in " .. mode, function()
            local raw = '{"a.b":{"q\\\"uote":{"x":null}},"single\'key":false,"rows":[{"role":"one","n":1},{"role":"two","n":2}],"other":{"n":3}}'
            local opts = selected({ '$["a.b"]["q\\\"uote"].x', "$['single\\'key']", "$.rows[*].role",
                "$.rows[0]", "$.rows[0].role", "$.other.*", "$.missing.x", "$.rows[*].absent" })
            local value = decode(mode, raw, opts)
            assert.are.equal(json.null, value["a.b"]['q"uote'].x)
            assert.is_false(value["single'key"])
            assert.are.equal("one", value.rows[1].role)
            assert.are.equal(1, value.rows[1].n)
            assert.are.equal("two", value.rows[2].role)
            assert.are.equal(3, value.other.n)
            assert.are.equal(raw, json.encode(value))
            local stats = json.source_stats(value)
            assert.are.equal(0, stats.index_bytes)
            assert.are.equal(7, stats.preloaded_nodes)
            assert.are.equal(23, stats.preloaded_payload_bytes)
            assert.is_true(stats.preload_path_nodes > 0)
            json.close(value)
            value = decode(mode, raw, selected({ "$", "$.rows[*].role", "$" }))
            assert.are.equal(raw, json.encode(value))
            assert.are.equal(2, json.len(value.rows))
            json.close(value)
            for _, paths in ipairs({ {}, { "$.missing", "$.rows.no_match" } }) do
                value = decode(mode, raw, selected(paths))
                assert.are.equal(0, json.source_stats(value).preloaded_nodes)
                assert.are.equal("two", value.rows[2].role)
                json.close(value)
            end
        end)

        it("invalidates selected descendants when a later ancestor no longer matches in " .. mode, function()
            for _, replacement in ipairs({ "{}", "false", "null", '{"y":2}', "[]" }) do
                local raw = '{"a":{"x":{"old":1}},"\\u0061":' .. replacement .. '}'
                local value = decode(mode, raw, selected({ "$.a.x" }))
                assert.are.equal(raw, json.encode(value))
                assert.are.equal(0, json.source_stats(value).preloaded_nodes)
                if replacement == "false" then assert.is_false(value.a)
                elseif replacement == "null" then assert.are.equal(json.null, value.a)
                else assert.is_nil(value.a.x) end
                json.close(value)
            end
            local value = decode(mode, '{"a":{"x":1},"\\u0061":{"x":false}}', selected({ "$.a.x" }))
            assert.is_false(value.a.x)
            assert.are.equal(1, json.source_stats(value).preloaded_nodes)
            json.close(value)
        end)

        it("keeps selected nodes immutable beneath linked edits and forks in " .. mode, function()
            local raw = '{"a":{"x":1,"x":2,"big":9007199254740993},"tail":1}'
            local value = decode(mode, raw, selected({ "$.a" }))
            local branch, held = json.fork(value), value.a
            assert.are.equal(2, held.x)
            local entries = {}
            for key, child in json.pairs(held) do entries[#entries + 1] = { key, child } end
            assert.are.same({ { "x", 1 }, { "x", 2 }, { "big", 9007199254740992 } }, entries)
            held.x = 7
            assert.are.equal(7, value.a.x)
            assert.are.equal(2, branch.a.x)
            local encoded = json.encode(value)
            assert.matches('"big":9007199254740993', encoded, 1, true)
            assert.are.equal(raw, json.encode(branch))
            json.close(held); json.close(value); json.close(branch)
        end)

        it("strictly validates ignored subtrees in every loading mode in " .. mode, function()
            local strict = json.new()
            strict.decode_invalid_numbers(false)
            strict.decode_validate_utf8(true)
            for _, opts in ipairs({ selected({ "$.ok" }), { lazyload = false, chunk_size = 1 } }) do
                for _, raw in ipairs({ '{"ok":1,"bad":[1,]}', '{"ok":1,"bad":"\\uD800x"}',
                    '{"ok":1,"bad":01}', '{"ok":1,"bad":"' .. string.char(255) .. '"}' }) do
                    assert.has_error(function() decode(mode, raw, opts, strict) end)
                end
            end
        end)
    end

    it("validates selectors and options before opening files or spools", function()
        local original_open, original_spool = io_source.open, io_source.spool
        local calls = 0
        io_source.open = function(...) calls = calls + 1; return original_open(...) end
        io_source.spool = function(...) calls = calls + 1; return original_spool(...) end
        local ok, err = pcall(function()
            for _, paths in ipairs({ false, "$.a", { [2] = "$.a" }, { "$.a", false }, { name = "$.a" },
                { "" }, { "a" }, { "$..a" }, { "$[?(@.a)]" }, { "$[1:2]" }, { "$[1,2]" },
                { "$[-1]" }, { "$[1.5]" }, { "$[18446744073709551616]" }, { "$['x'" },
                { '$["\\uD800"]' }, { "$.a trailing" }, { "$.*x" } }) do
                for _, eager in ipairs({ false, true }) do
                    local opts = { lazyload = not eager, preload_paths = paths }
                    assert.has_error(function() json.decode("{}", opts) end)
                    assert.has_error(function() json.decode_file("/missing", opts) end)
                    assert.has_error(function() json.new_decoder(opts) end)
                end
            end
            for _, bad in ipairs({ 0, "false", {}, 0 / 0 }) do
                assert.has_error(function() json.decode_file("/missing", { lazyload = bad }) end)
                assert.has_error(function() json.new_decoder({ lazyload = bad }) end)
            end
            assert.are.equal(0, calls)
        end)
        io_source.open, io_source.spool = original_open, original_spool
        assert.is_true(ok, err)
    end)

    it("freezes caller paths and returns independent eager finish and get results", function()
        local paths = { "$.a.x" }
        local callbacks = 0
        local opts = selected(paths)
        opts.on_chunk = function() callbacks = callbacks + 1 end
        local input = json.new_decoder(opts)
        paths[1] = "$.other"
        assert.is_true(input:feed('{"a":{"x":false},"other":2}'))
        local value = assert(input:finish())
        local after_scan = callbacks
        assert.is_false(value.a.x)
        assert.are.equal(after_scan, callbacks)
        input:close(); json.close(value)
        input = json.new_decoder({ lazyload = false, chunk_size = 1 })
        assert.is_true(input:feed('{"a":{"x":false},"items":[[],null]}'))
        local first = assert(input:finish())
        first.a.x = true
        first.items[1][1] = 9
        local second = assert(input:finish())
        assert.is_false(rawget(second.a, "x"))
        assert.are.equal("{}", json.encode(second.items[1]))
        local child, status = input:get("a")
        assert.are.equal("READY", status)
        child.x = 3
        child, status = input:get("a")
        assert.are.equal("READY", status)
        assert.is_false(rawget(child, "x"))
        assert.are.same({ false, "READY" }, { input:get("a.x") })
        assert.are.same({ json.null, "READY" }, { input:get("items[1]") })
        input:close()
        assert.is_false(second.a.x)
    end)

    it("closes eager file descriptors immediately and keeps only the decoder spool lease", function()
        collectgarbage("collect")
        local original_open, original_spool, descriptors = io_source.open, io_source.spool, {}
        io_source.open = function(...)
            local fd, err = original_open(...)
            if fd then descriptors[#descriptors + 1] = fd end
            return fd, err
        end
        io_source.spool = function(...)
            local fd, name = original_spool(...)
            if fd then descriptors[#descriptors + 1] = fd end
            return fd, name
        end
        local ok, err = pcall(function()
            collectgarbage("stop")
            local value = decode("file", '{"x":{"y":1}}', { file_in_memory = false, lazyload = false, chunk_size = 1 })
            assert.are.equal(1, rawget(value.x, "y"))
            assert.are.equal(-1, ffi.C.fcntl(descriptors[1], 1))
            local input = json.new_decoder({ file_in_memory = false, lazyload = false })
            assert.is_true(input:feed('{"x":{"y":1}}'))
            value = assert(input:finish())
            assert.is_not.equal(-1, ffi.C.fcntl(descriptors[2], 1))
            assert.is_nil(input.backend.loading.root)
            input:close()
            assert.are.equal(-1, ffi.C.fcntl(descriptors[2], 1))
            assert.are.equal(1, value.x.y)
        end)
        collectgarbage("restart")
        io_source.open, io_source.spool = original_open, original_spool
        assert.is_true(ok, err)
    end)

    it("drops selected caches at the final lease while a closed decoder remains reachable", function()
        local input = json.new_decoder(selected({ "$" }))
        assert.is_true(input:feed('{"a":{"x":"selected payload"}}'))
        local value = assert(input:finish())
        local child = value.a
        local weak = setmetatable({ proxy.node(child) }, { __mode = "v" })
        input:close()
        json.close(value)
        collectgarbage("collect")
        assert.is_not_nil(weak[1])
        assert.are.equal("selected payload", child.x)
        json.close(child)
        collectgarbage("collect")
        assert.is_nil(weak[1])
        assert.is_nil(next(input.backend.preloaded))
        assert.is_nil(input.backend.loading)
    end)

    it("cancels partial selected and eager builds without exposing values or retaining payload", function()
        for _, lazyload in ipairs({ true, false }) do
            local input, paused
            local opts = selected({ "$" })
            opts.lazyload = lazyload
            opts.on_chunk = function()
                if not paused then paused = true; coroutine.yield("paused") end
            end
            input = json.new_decoder(opts)
            local worker = coroutine.create(function() return input:feed('{"a":[1,2,3]}') end)
            assert.are.same({ true, "paused" }, { coroutine.resume(worker) })
            local _, state = input:get("a")
            assert.are.equal("NEED_INPUT", state)
            input:close()
            local resumed, value, err = coroutine.resume(worker)
            assert.is_true(resumed)
            assert.is_nil(value)
            assert.is_string(err)
            assert.is_nil(input.backend.loading)
            assert.is_nil(input.backend.state.fd)
        end
    end)

    it("handles file I/O failures and cancellation during a repeated eager build", function()
        local input = json.new_decoder({ file_in_memory = false, lazyload = false, chunk_size = 1 })
        assert.is_true(input:feed('{"a":[1,2,3]}'))
        local first = assert(input:finish())
        local pause = true
        input.backend.opts.on_chunk = function()
            if pause then pause = false; coroutine.yield("rebuild paused") end
        end
        local worker = coroutine.create(function() return input:finish() end)
        assert.are.same({ true, "rebuild paused" }, { coroutine.resume(worker) })
        input:close()
        local resumed, value, err = coroutine.resume(worker)
        assert.is_true(resumed)
        assert.is_nil(value)
        assert.is_string(err)
        assert.are.equal(3, #first.a)
        local original = io_source.read
        io_source.read = function() return nil, "intentional loading read failure" end
        local ok, failure = pcall(function()
            assert.has_error(function() decode("file", '{"a":1}', { lazyload = false }) end)
        end)
        io_source.read = original
        assert.is_true(ok, failure)
    end)

    for _, operation in ipairs({ "finish", "get" }) do
        it("immediately releases a partially rebuilt eager " .. operation .. " while its worker stays suspended", function()
            local loading = require("leanjson.loading")
            local original_new = loading.new
            local input = json.new_decoder({ lazyload = false, chunk_size = 64 })
            assert.is_true(input:feed('{"a":[' .. string.rep("123,", 200) .. '0]}'))
            local first = assert(input:finish())
            local observed, calls
            local weak = setmetatable({}, { __mode = "v" })
            local ok, failure = pcall(function()
                loading.new = function(backend)
                    local builder = original_new(backend)
                    observed = builder
                    return builder
                end
                calls = 0
                input.backend.opts.on_chunk = function()
                    if observed then
                        calls = calls + 1
                        if calls == 4 then
                            weak[1] = observed.stack[operation == "finish" and 2 or 1].values
                            coroutine.yield("partial rebuild paused")
                        end
                    end
                end
                local worker = coroutine.create(function()
                    if operation == "finish" then return input:finish() end
                    return input:get("a")
                end)
                assert.are.same({ true, "partial rebuild paused" }, { coroutine.resume(worker) })
                assert.is_true(#weak[1] >= 20, "pause must follow multiple populated source chunks")
                assert.is_not_nil(observed.backend.state.source)
                input:close()
                assert.is_nil(input.backend.state.fd)
                assert.is_nil(observed.backend.state.source, "close retained the scratch native source")
                assert.is_nil(observed.root)
                assert.are.equal(0, #observed.stack)
                assert.are.equal(0, #observed.frames)
                assert.is_nil(next(input.scope.active))
                collectgarbage("collect")
                assert.is_nil(weak[1], "suspended worker retained partially rebuilt values")
                assert.are.equal("suspended", coroutine.status(worker))
                local resumed, value, status, err = coroutine.resume(worker)
                assert.is_true(resumed)
                assert.is_nil(value)
                if operation == "finish" then err = status else assert.are.equal("ERROR", status) end
                assert.matches("closed", err, 1, true)
                assert.is_nil(observed.backend.state.source)
                assert.are.equal(201, #first.a)
            end)
            loading.new = original_new
            input:close()
            assert.is_true(ok, failure)
        end)

        it("cleans eager " .. operation .. " scratch ownership on success and source errors", function()
            local loading = require("leanjson.loading")
            local original_new = loading.new
            local inputs = {}
            local ok, failure = pcall(function()
                for _, fail in ipairs({ false, true }) do
                    local input = json.new_decoder({ lazyload = false, chunk_size = 64 })
                    inputs[#inputs + 1] = input
                    assert.is_true(input:feed('{"a":[' .. string.rep("123,", 200) .. '0]}'))
                    assert(input:finish())
                    local observed, calls
                    local weak = setmetatable({}, { __mode = "v" })
                    loading.new = function(backend)
                        local builder = original_new(backend)
                        observed = builder
                        return builder
                    end
                    calls = 0
                    input.backend.opts.on_chunk = function()
                        if observed then
                            calls = calls + 1
                            if fail and calls == 4 then
                                weak[1] = observed.stack[operation == "finish" and 2 or 1].values
                                assert(#weak[1] >= 20)
                                error("intentional repeated eager source error")
                            end
                        end
                    end
                    local value, status, err
                    if operation == "finish" then value, err = input:finish()
                    else value, status, err = input:get("a") end
                    if fail then
                        assert.is_nil(value)
                        if operation == "get" then assert.are.equal("ERROR", status) end
                        assert.matches("intentional repeated eager source error", err, 1, true)
                    else
                        assert.is_nil(err)
                        if operation == "get" then assert.are.equal("READY", status)
                        else value = value.a end
                        assert.are.equal(201, #value)
                        assert.are.equal(123, value[1])
                        assert.are.equal(0, value[201])
                    end
                    assert.is_nil(observed.backend.state.source)
                    assert.is_nil(observed.root)
                    assert.are.equal(0, #observed.stack)
                    assert.are.equal(0, #observed.frames)
                    assert.is_nil(next(input.scope.active))
                    collectgarbage("collect")
                    assert.is_nil(weak[1])
                    input:close()
                    loading.new = original_new
                end
            end)
            loading.new = original_new
            for _, input in ipairs(inputs) do input:close() end
            assert.is_true(ok, failure)
        end)
    end

    it("supports all loading modes without the optional cjson module", function()
        local interpreter = os.getenv("LUAJIT_BIN") or os.getenv("LUAJIT")
            or (arg and type(arg[-1]) == "string" and not arg[-1]:match("^%-") and arg[-1]) or "luajit"
        local quoted = "'" .. interpreter:gsub("'", "'\\''") .. "'"
        local status = os.execute(quoted .. " tests/lua/fixtures/loading_without_cjson.lua")
        assert.is_true(status == 0 or status == true)
    end)

    it("retains selected payload and route counts independently of ignored body size", function()
        for _, count in ipairs({ 1, 10000 }) do
            local raw = '{"ok":"one","ignored":{"rows":[' .. string.rep('"unselected",', count)
                .. 'null],"large":"' .. string.rep("z", count * 100) .. '"}}'
            local value = json.decode(raw, selected({ "$.ok" }))
            local stats = json.source_stats(value)
            assert.are.equal(1, stats.preloaded_nodes)
            assert.are.equal(1, stats.preload_path_nodes)
            assert.are.equal(3, stats.preloaded_payload_bytes)
            assert.are.equal(2, stats.preloaded_key_bytes)
            assert.are.equal(0, stats.indexed_nodes)
            assert.are.equal(0, stats.index_bytes)
            local cache = proxy.node(value).backend.preloaded
            local nodes = 0
            for _ in pairs(cache) do nodes = nodes + 1 end
            assert.are.equal(2, nodes)
            json.close(value)
        end
    end)

    it("iterates complete preloaded subtrees without reads and links only current duplicate children", function()
        local callbacks = 0
        local opts = selected({ "$.box" })
        opts.on_chunk = function() callbacks = callbacks + 1 end
        local value = decode("file", '{"box":{"child":{"v":1},"child":{"v":2},"unique":{"v":3}}}', opts)
        local box = value.box
        local after_scan = callbacks
        local old, current, unique
        for key, child in json.pairs(box) do
            if key == "unique" then unique = child
            elseif not old then old = child
            else current = child end
        end
        assert.are.equal(after_scan, callbacks)
        assert.are.equal(2, json.len(box))
        old.v = 11
        assert.are.equal(2, box.child.v)
        assert.is_true(rawequal(current, box.child))
        current.v = 22
        unique.v = 33
        assert.are.equal(22, value.box.child.v)
        assert.are.equal(33, value.box.unique.v)
        local reader = json.reader(box, { normalize_duplicates = true, chunk_size = 1 })
        local parts = {}
        while true do
            local chunk, err = reader:next()
            assert.is_nil(err)
            if not chunk then break end
            parts[#parts + 1] = chunk
        end
        assert.are.equal('{"child":{"v":22},"unique":{"v":33}}', table.concat(parts))
        json.close(old); json.close(current); json.close(unique); json.close(box); json.close(value)
    end)
end)
