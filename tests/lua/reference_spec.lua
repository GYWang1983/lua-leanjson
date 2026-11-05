local json = require("leanjson")
local proxy = require("leanjson.proxy")
local source_io = require("leanjson.source_io")
local lfs = require("lfs")
local ffi = require("ffi")
ffi.cdef[[int fcntl(int, int, ...);]]

local raw = [=[{"prompt":"A\u4e2d\n","obj":{"x":1},"items":[1,2],"flag":false,"null":null,"empty":"","n":7,"dup":"old","dup":"last"}]=]

describe("explicit immutable value references", function()
    local directory, held, fds, serial, original_open, original_spool
    local function hold(value) if value ~= nil then held[#held + 1] = value end; return value end
    local function closed()
        for _, fd in ipairs(fds) do
            assert.are.equal(-1, ffi.C.fcntl(fd, 1), "source descriptor remained open")
            assert.are.equal(9, ffi.errno())
        end
    end
    before_each(function()
        held, fds, serial = {}, {}, 0
        directory = os.tmpname(); os.remove(directory); assert(lfs.mkdir(directory))
        original_open, original_spool = source_io.open, source_io.spool
        source_io.open = function(filename)
            local fd, err = original_open(filename)
            if fd then fds[#fds + 1] = fd end
            return fd, err
        end
        source_io.spool = function(path)
            local fd, filename = original_spool(path)
            if fd then fds[#fds + 1] = fd end
            return fd, filename
        end
    end)
    after_each(function()
        collectgarbage("restart")
        for i = #held, 1, -1 do json.close(held[i]) end
        source_io.open, source_io.spool = original_open, original_spool
        collectgarbage("collect"); collectgarbage("collect")
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then assert(os.remove(directory .. "/" .. name)) end
        end
        assert(lfs.rmdir(directory))
    end)
    local function decode(mode, bytes, opts, codec)
        codec, opts = codec or json, opts or {}
        opts.temp_dir = directory
        if mode == "memory" then return hold(codec.decode(bytes, opts)) end
        if mode == "file" then
            serial = serial + 1
            local filename = directory .. "/input-" .. serial .. ".json"
            local file = assert(io.open(filename, "wb")); assert(file:write(bytes)); assert(file:close())
            return hold(codec.decode_file(filename, opts))
        end
        local decoder = codec.new_decoder(opts)
        for first = 1, #bytes, 65536 do assert(decoder:feed(bytes:sub(first, first + 65535))) end
        local value, err = decoder:finish(); decoder:close(); assert(not err, err)
        return hold(value)
    end
    local function drain(reader, bound)
        local parts = {}
        while true do
            local bytes, err = reader:next(); assert.is_nil(err)
            if not bytes then break end
            assert.is_true(#bytes <= bound)
            parts[#parts + 1] = bytes
        end
        reader:close()
        return table.concat(parts)
    end

    for _, mode in ipairs({ "memory", "file", "feed" }) do
        for _, loading in ipairs({ "lazy", "eager", "preload" }) do
            for _, carrier in ipairs({ "table", "userdata" }) do
                it("maps snapshots over " .. mode .. "/" .. loading .. "/" .. carrier, function()
                    local opts = { chunk_size = 3, proxy_mode = carrier, index_budget_bytes = 0 }
                    if loading == "eager" then opts.lazyload = false end
                    if loading == "preload" then opts.preload_paths = { "$.prompt", "$.obj" } end
                    local a = decode(mode, raw, opts)
                    local b = decode("memory", '{"base":1}', { proxy_mode = carrier })
                    local refs = {}
                    for _, key in ipairs({ "prompt", "obj", "items", "flag", "null", "empty", "n", "dup" }) do
                        local ref = hold(json.ref(a, "$." .. key)); refs[#refs + 1] = ref
                        b[key] = ref
                    end
                    assert.are.equal("string", json.type(refs[1]))
                    assert.are.equal(5, json.len(refs[1]))
                    assert.is_false(json.is_empty(refs[1]))
                    assert.is_true(json.is_empty(refs[4]))
                    assert.is_true(json.exists(refs[4]))
                    assert.is_false(json.is_empty(refs[5]))
                    a.prompt = "changed"
                    local child = hold(a.obj); child.x = 9
                    for _, ref in ipairs(refs) do json.close(ref) end
                    json.close(a)
                    assert.are.equal("A中\n", b.prompt)
                    assert.are.equal(1, b.obj.x)
                    assert.are.equal(2, json.len(b, "items"))
                    assert.are.equal(false, b.flag)
                    assert.are.equal(json.null, b.null)
                    assert.are.equal("", b.empty)
                    assert.are.equal(7, b.n)
                    assert.are.equal("last", b.dup)
                    local result = hold(json.decode(drain(json.reader(b, { chunk_size = 5 }), 5)))
                    assert.are.equal("A中\n", result.prompt)
                    assert.are.equal(false, result.flag)
                    assert.are.equal(json.null, result.null)
                end)
            end
        end
    end

    for _, mode in ipairs({ "memory", "file", "feed" }) do
        for _, shape in ipairs({
            { name = "plain", token = "a", decoded = 1, encoded = 1 },
            { name = "unicode", token = "\\u0061", decoded = 1, encoded = 6 },
            { name = "escape-policy", token = "/\\u007f", decoded = 2, encoded = 8 },
        }) do
        it("maps and streams long " .. shape.name .. " strings without decoded copies in " .. mode, function()
            local count = 131072
            local bytes = '{"prompt":"' .. string.rep(shape.token, count) .. '"}'
            local a = decode(mode, bytes, { chunk_size = 257, index_budget_bytes = 0 })
            proxy.node(a).backend.scalar = function() error("full scalar read forbidden") end
            local b = decode("memory", '{}')
            local concatenate = table.concat
            rawset(table, "concat", function(...)
                local result = concatenate(...)
                assert.is_true(#result <= 257, "full payload concatenation")
                return result
            end)
            local reader
            local ok, err = pcall(function()
                local ref = hold(json.ref(a, "$.prompt"))
                local copy = hold(json.fork(ref))
                assert.are.equal("string", json.type(copy))
                assert.are.equal(count * shape.decoded, json.len(copy))
                b.messages = { { role = "user", content = copy } }
                reader = json.reader(b, { chunk_size = 257 })
                json.close(a); json.close(ref); json.close(copy); json.close(b)
                local expected = #'{"messages":[{"role":"user","content":' + count * shape.encoded + 2 + #'}]}'
                assert.are.equal(expected, reader:length())
                local total = 0
                while true do
                    local chunk, failure = reader:next(); assert.is_nil(failure)
                    if chunk == nil then break end
                    assert.is_true(#chunk <= 257); total = total + #chunk
                end
                assert.are.equal(expected, total)
            end)
            rawset(table, "concat", concatenate)
            if reader then reader:close() end
            assert(ok, err)
            closed()
        end)
        end
    end

    it("captures current edits and plain values without following later writes", function()
        local a = decode("file", raw)
        a.prompt = "edited"
        local ref = hold(json.ref(a, "prompt"))
        a.prompt = "later"
        assert.are.equal('"edited"', json.encode(ref))
        local ordinary = { value = { x = 1 } }
        local object = hold(json.ref(ordinary, "value"))
        ordinary.value.x = 2
        assert.are.equal('{"x":1}', json.encode(object))
        for _, value in ipairs({ false, json.null, "", 0 }) do
            local item = hold(json.ref(value))
            assert.are.equal(json.encode(value), json.encode(item))
        end
        assert.is_nil(json.ref(nil))
        assert.is_nil(json.ref(a, "missing"))
        assert.is_nil(json.ref(a, "flag.x"))
        assert.is_nil(json.ref(a, "items[99]"))
    end)

    it("keeps handles read-only while derived container views and forks are independent", function()
        local a = decode("file", '{"obj":{"nested":{"x":1}},"items":[{"x":1}]}')
        local object = hold(json.ref(a, "obj"))
        local array = hold(json.ref(a, "items"))
        assert.has_error(function() return object.nested end)
        assert.has_error(function() object.nested = {} end)
        assert.has_error(function() rawset(object, "nested", {}) end)
        assert.has_error(function() json.array_insert(array, 1, {}) end)
        assert.has_error(function() json.array_remove(array, 1) end)
        local child = hold(json.get(object, "nested")); child.x = 7
        assert.are.equal('{"nested":{"x":1}}', json.encode(object))
        for _, value in json.ipairs(array) do
            hold(value); value.x = 9
        end
        assert.are.equal('[{"x":1}]', json.encode(array))
        local branch = hold(json.fork(object))
        local nested = hold(branch.nested); nested.x = 8
        assert.are.equal(8, branch.nested.x)
        assert.are.equal('{"nested":{"x":1}}', json.encode(object))
        assert.are.equal(1, json.len(array))
        assert.is_true(#tostring(object) < 80)
    end)

    it("supports explicit materialization and all public codec variants", function()
        local a = decode("file", raw)
        for _, codec in ipairs({ json, json.new(), require("leanjson.safe"), require("leanjson.safe").new() }) do
            local ref = hold(codec.ref(a, "$.prompt"))
            assert.are.equal('"A\\u4e2d\\n"', codec.encode(ref))
            assert.are.equal("A中\n", json.materialize(ref))
            assert.are.equal(5, codec.len(ref))
        end
        local root = hold(json.ref(a, "$"))
        assert.are.equal("object", json.type(root))
        assert.are.equal(8, json.len(root))
    end)

    it("uses destination encoding policies and depth checks", function()
        local source = json.new(); source.decode_allow_comment(true)
        local a = decode("file", [=[{"s":"/\u007f","n":NaN,"obj":{/*comment*/"x":1}}]=], nil, source)
        local string_ref = hold(json.ref(a, "s"))
        local number_ref = hold(json.ref(a, "n"))
        local object_ref = hold(json.ref(a, "obj"))
        local codec = json.new()
        codec.encode_escape_forward_slash(false)
        assert.are.equal('"/\\u007f"', drain(codec.reader(string_ref, { chunk_size = 1 }), 1))
        assert.has_error(function() codec.encode(number_ref) end)
        codec.encode_invalid_numbers("null")
        assert.are.equal("null", codec.encode(number_ref))
        codec.encode_skip_unsupported_value_types(true)
        assert.are.equal('{"s":"/\\u007f"}', codec.encode({ s = string_ref }))
        assert.are.equal('{"x":1}', codec.encode(object_ref))
        codec.encode_max_depth(1)
        assert.has_error(function() codec.encode({ obj = object_ref }) end)
    end)

    it("skips unsupported scalar references before emitting object keys or array items", function()
        local codec = json.new()
        for _, value in ipairs({ function() end, coroutine.create(function() end), newproxy(), ffi.new("int[1]") }) do
            local ref = hold(codec.ref(value))
            assert.has_error(function() codec.encode({ x = ref }) end)
            codec.encode_skip_unsupported_value_types(true)
            assert.are.equal('{"keep":1}', codec.encode({ x = ref, keep = 1 }))
            assert.are.equal('["ok"]', codec.encode({ ref, "ok" }))
            assert.are.equal('', codec.encode(ref))
            assert.are.equal('{"keep":1}', drain(codec.reader({ x = ref, keep = 1 }), 65536))
            local b = decode("memory", '{}', nil, codec)
            b.x = ref
            assert.are.equal('{}', codec.encode(b))
            codec.encode_skip_unsupported_value_types(false)
        end
    end)

    it("captures ordinary Lua table references when passed to a snapshot or reader", function()
        local a = decode("file", '{"text":"hello"}')
        local ref = hold(json.ref(a, "text"))
        local ordinary = { x = ref }
        local branch = hold(json.fork(ordinary))
        local reader = json.reader(ordinary, { chunk_size = 2 })
        json.close(a); json.close(ref)
        assert.has_error(function() json.encode(ordinary) end)
        local invalid = json.reader(ordinary)
        local bytes, err = invalid:next()
        assert.is_nil(bytes)
        assert.matches("holder closed", err)
        assert.are.equal('{"x":"hello"}', json.encode(branch))
        json.close(branch)
        assert.are.equal('{"x":"hello"}', drain(reader, 2))
        closed()
    end)

    it("retains sources independently across handles, assignment, readers and reference-of-reference", function()
        local a = decode("feed", '{"text":"hello"}')
        local first = hold(json.ref(a, "text"))
        local second = hold(json.ref(first))
        local b = decode("memory", '{}'); b.text = second
        local reader = json.reader(b, { chunk_size = 2 })
        json.close(a); json.close(first); json.close(second); json.close(b)
        assert.are.equal('{"text":"hello"}', drain(reader, 2))
        closed()
    end)

    it("pins an accepted reference before later snapshot callbacks close it", function()
        local a = decode("file", '{"text":"hello"}')
        local ref = hold(json.ref(a, "text")); json.close(a)
        local virtual = setmetatable({}, { __len = function() json.close(ref); return 0 end })
        local b = decode("memory", '{}'); b.items = { ref, virtual }
        assert.are.equal('{"items":["hello",[]]}', json.encode(b))
        json.close(b); closed()
    end)

    it("releases abandoned reference leases through GC", function()
        local a = decode("file", raw)
        local ref = json.ref(a, "prompt")
        assert.are.equal("string", json.type(ref))
        json.close(a); ref = nil
        assert.is_nil(ref)
        collectgarbage("collect"); collectgarbage("collect")
        closed()
    end)

    it("releases a newly acquired handle if its initiating holder closes before return", function()
        local a = decode("file", raw)
        local backend = proxy.node(a).backend
        local retain, reference_node = backend.retain, proxy.reference_node
        local phase = false
        backend.retain = function(self)
            local token = retain(self)
            if phase then json.close(a) end
            return token
        end
        proxy.reference_node = function(...)
            phase = true
            local result = reference_node(...)
            phase = false
            return result
        end
        collectgarbage("stop")
        local ok, err = pcall(json.ref, a, "prompt")
        proxy.reference_node = reference_node
        backend.retain = retain
        assert.is_false(ok)
        assert.is_not_nil(err)
        closed() -- Must not depend on eventual GC of an unreturned handle.
    end)

    it("preserves independent destination views for same-source mappings and array insertion", function()
        local a = decode("file", raw)
        local b = hold(json.fork(a))
        local ref = hold(json.ref(a, "obj"))
        b.copy = ref
        local child = hold(b.copy); child.x = 42
        assert.are.equal('{"x":1}', json.encode(ref))
        assert.are.equal(1, a.obj.x)
        local values = decode("memory", '[]')
        json.array_insert(values, 1, ref)
        assert.are.equal('[{"x":1}]', json.encode(values))
        json.close(a); json.close(ref)
        assert.are.equal(42, b.copy.x)
    end)

    it("works with the private table carrier when newproxy is unavailable", function()
        local executable = os.getenv("LUAJIT_BIN") or "luajit"
        local command = string.format("%q tests/lua/fixtures/reference_without_factory.lua", executable)
        local status, reason, code = os.execute(command)
        assert.is_true(status == 0 or status == true and reason == "exit" and code == 0)
    end)

    it("propagates construction errors and rejects closed references", function()
        local armed
        local a = decode("file", raw, { chunk_size = 1, on_chunk = function()
            if armed then error("reference lookup failed") end
        end })
        armed = true
        local ok, err = pcall(json.ref, a, "prompt")
        assert.is_false(ok)
        assert.is_true(tostring(err):find("reference lookup failed", 1, true) ~= nil)
        assert.is_nil(next(proxy.scope(a).active))
        armed = false; json.close(a)
        a = decode("file", raw)
        local ref = hold(json.ref(a, "prompt")); json.close(ref)
        for _, operation in ipairs({ json.ref, json.encode, json.len, json.type, json.exists, json.is_empty }) do
            assert.has_error(function() operation(ref) end)
        end
        assert.has_error(function() json.ref() end)
        assert.has_error(function() json.ref(a, "prompt", "extra") end)
        for _, path in ipairs({ false, {}, "$.", "items[-1]" }) do
            assert.has_error(function() json.ref(a, path) end)
        end
    end)
end)
