local json = require("leanjson")
local proxy = require("leanjson.proxy")
local lfs = require("lfs")

local raw = [=[{"prompt":"A\u4e2d\n","selected":"cached\u0000","items":[false,null,{"x":1}],"opts":{"x":1,"\u0078":2,"y":false},"empty":"","spaces":" ","arr":[],"obj":{},"flag":false,"yes":true,"zero":0,"null":null,"dupe":"old","dupe":false}]=]

describe("non-materializing path queries", function()
    local directory, filename
    before_each(function()
        directory = os.tmpname(); os.remove(directory)
        assert(lfs.mkdir(directory)); filename = directory .. "/input.json"
    end)
    after_each(function()
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then assert(os.remove(directory .. "/" .. name)) end
        end
        assert(lfs.rmdir(directory))
    end)
    local function decode(mode, bytes, opts, codec)
        codec = codec or json
        opts = opts or {}
        opts.temp_dir = directory
        if mode == "memory" then return codec.decode(bytes, opts) end
        if mode == "file" then
            local output = assert(io.open(filename, "wb")); assert(output:write(bytes)); assert(output:close())
            return codec.decode_file(filename, opts)
        end
        local decoder = codec.new_decoder(opts)
        for first = 1, #bytes, 65536 do assert(decoder:feed(bytes:sub(first, first + 65535))) end
        local root, err = decoder:finish(); decoder:close(); assert(not err, err)
        return root
    end

    for _, mode in ipairs({ "memory", "file", "feed" }) do
        for _, loading in ipairs({ "lazy", "eager", "preload" }) do
            for _, carrier in ipairs({ "table", "userdata" }) do
                it("queries " .. mode .. "/" .. loading .. "/" .. carrier, function()
                    local opts = { chunk_size = 7, proxy_mode = carrier, index_depth = 0,
                        index_array_limit = 0, index_budget_bytes = 0 }
                    if loading == "eager" then opts.lazyload = false end
                    if loading == "preload" then opts.preload_paths = { "$.selected" } end
                    local body = decode(mode, raw, opts)
                    assert.are.equal(5, json.len(body, "$.prompt"))
                    assert.are.equal(7, json.len(body, "selected"))
                    assert.are.equal(3, json.len(body, ".items"))
                    assert.are.equal(2, json.len(body, "opts"))
                    assert.are.equal(1, json.len(body, "items[2]"))
                    assert.are.equal(0, json.len(body, "arr"))
                    assert.are.equal(0, json.len(body, "obj"))
                    assert.are.equal(13, json.len(body, "$"))
                    assert.are.equal(13, json.len(body, ""))
                    for _, key in ipairs({ "prompt", "selected", "items", "opts", "empty", "spaces", "arr", "obj", "yes", "zero", "null" }) do
                        assert.is_true(json.exists(body, key), key)
                        assert.is_false(json.is_empty(body, key), key)
                    end
                    for _, key in ipairs({ "flag", "dupe", "items[0]" }) do
                        assert.is_true(json.exists(body, key), key)
                        assert.is_true(json.is_empty(body, key), key)
                    end
                    for _, key in ipairs({ "missing", "missing.x", "flag.x", "items[99]", "items.key", "prompt.x" }) do
                        assert.is_false(json.exists(body, key), key)
                        assert.is_true(json.is_empty(body, key), key)
                        assert.is_nil(json.len(body, key), key)
                    end
                    assert.is_true(json.exists(body))
                    assert.is_false(json.is_empty(body))
                    json.close(body)
                end)
            end
        end
    end

    it("preserves legacy lengths and Lua root truthiness", function()
        local ordinary = { k = "v" }
        assert.are.equal(#ordinary, json.len(ordinary))
        assert.are.equal(#ordinary, json.len(ordinary, nil))
        assert.are.equal(3, json.len("中"))
        for _, value in ipairs({ false, json.null, 0, "", {}, json.empty_array }) do
            assert.is_true(json.exists(value))
            assert.are.equal(not value, json.is_empty(value))
        end
        assert.is_false(json.exists(nil))
        assert.is_true(json.is_empty(nil))
        assert.are.equal(2, json.len({ 1, 2 }))
        local array = json.decode('["x", ""]')
        assert.are.equal(1, json.len(array, "$[0]"))
        assert.is_false(json.is_empty(array, "$[1]"))
        json.close(array)
    end)

    it("queries empty-array sentinels", function()
        assert.are.equal(0, json.len(json.empty_array, "$"))
    end)

    it("evaluates external lengths once", function()
        local calls = 0
        local array = setmetatable({}, { __len = function() calls = calls + 1; return calls + 1 end })
        assert.are.equal(2, json.len(array, "$"))
        assert.are.equal(1, calls)
    end)

    it("exports helpers on independent and safe codecs", function()
        for _, codec in ipairs({ json, json.new(), require("leanjson.safe"), require("leanjson.safe").new() }) do
            local body = codec.decode('{"s":"hello","b":false}')
            assert.are.equal(5, codec.len(body, "s"))
            assert.is_true(codec.exists(body, "b"))
            assert.is_true(codec.is_empty(body, "b"))
            json.close(body)
        end
    end)

    it("counts decoded bytes across every escape and UTF-8 chunk boundary", function()
        local bytes = [=[{"s":"a\n\u4e2d\uD83D\uDE00\u0000\\\"é"}]=]
        local expected = #("a\n中😀\0\\\"é")
        for size = 1, 12 do
            local body = decode("file", bytes, { chunk_size = size })
            assert.are.equal(expected, json.len(body, "s"))
            json.close(body)
        end
    end)

    for _, mode in ipairs({ "memory", "file", "feed" }) do
        it("never materializes lazy strings or sibling values in " .. mode, function()
            local count = 131072
            local bytes = '{"prompt":"' .. string.rep("\\u0061", count) .. '","unused":"' .. string.rep("z", count) .. '"}'
            local body = decode(mode, bytes, { chunk_size = 257, index_budget_bytes = 0 })
            local backend = proxy.node(body).backend
            backend.scalar = function() error("scalar materialization forbidden") end
            local concatenate = table.concat
            rawset(table, "concat", function(...)
                local result = concatenate(...)
                assert.is_true(#result <= 257, "unbounded scalar concatenation")
                return result
            end)
            local ok, err = pcall(function()
                assert.are.equal(count, json.len(body, "prompt"))
                assert.is_true(json.exists(body, "prompt"))
                assert.is_false(json.is_empty(body, "prompt"))
                assert.are.equal(2, json.len(body, "$"))
            end)
            rawset(table, "concat", concatenate)
            assert.is_nil(next(proxy.scope(body).active), "query leaked a source operation")
            json.close(body)
            assert(ok, err)
        end)
    end

    it("uses already decoded preloads and edited strings without rescanning payloads", function()
        local body = decode("file", raw, { chunk_size = 3, preload_paths = { "$.selected" } })
        local backend = proxy.node(body).backend
        backend.scalar_chunks = function() error("decoded string should not be scanned") end
        assert.are.equal(7, json.len(body, "selected"))
        body.selected = string.rep("中", 1000)
        assert.are.equal(3000, json.len(body, "selected"))
        assert.is_false(json.is_empty(body, "selected"))
        json.close(body)
    end)

    it("observes duplicate final values, edits, forks and mixed plain/proxy paths", function()
        local a = decode("file", raw)
        local b = json.fork(a)
        b.prompt = "new"
        b.dupe = nil
        local options = b.opts; options.x = nil; json.close(options)
        assert.are.equal(3, json.len(b, "prompt"))
        assert.are.equal(5, json.len(a, "prompt"))
        assert.is_false(json.exists(b, "dupe"))
        assert.is_true(json.is_empty(a, "dupe"))
        assert.are.equal(1, json.len(b, "opts"))
        local mixed = { branch = b, list = { "abc" } }
        assert.are.equal(3, json.len(mixed, "branch.prompt"))
        assert.are.equal(3, json.len(mixed, "list[0]"))
        json.close(a)
        assert.are.equal(3, json.len(b, "prompt"))
        json.close(b)
    end)

    it("propagates closed holders and source callback errors", function()
        local armed, body
        body = decode("file", raw, { chunk_size = 1, on_chunk = function()
            if armed then error("query I/O callback failed") end
        end })
        armed = true
        for _, operation in ipairs({ json.len, json.exists, json.is_empty }) do
            local ok, err = pcall(operation, body, "prompt")
            assert.is_false(ok)
            assert.is_true(tostring(err):find("query I/O callback failed", 1, true) ~= nil)
            assert.is_nil(next(proxy.scope(body).active))
        end
        armed = false; json.close(body)
        for _, operation in ipairs({ json.len, json.exists, json.is_empty }) do
            assert.has_error(function() operation(body, "prompt") end)
            assert.has_error(function() operation(body) end)
        end
    end)

    it("cancels lookups and string counting when the initiating holder closes", function()
        for _, operation in ipairs({ json.len, json.exists, json.is_empty }) do
            local armed, body
            body = decode("file", raw, { chunk_size = 1, on_chunk = function()
                if armed then armed = false; json.close(body) end
            end })
            armed = true
            assert.has_error(function() operation(body, "prompt") end)
            json.close(body)
        end
    end)

    it("cancels in the scalar counting phase and keeps readonly queries snapshotted", function()
        local armed, counting, body
        body = decode("file", raw, { chunk_size = 1, on_chunk = function()
            if armed and counting then armed = false; json.close(body) end
        end })
        local backend = proxy.node(body).backend
        local scalar_chunks = backend.scalar_chunks
        backend.scalar_chunks = function(...)
            counting = true
            return scalar_chunks(...)
        end
        armed = true
        assert.has_error(function() json.len(body, "prompt") end)
        json.close(body)

        armed = false
        body = decode("file", raw, { chunk_size = 1, on_chunk = function()
            if armed then armed = false; body.prompt = "new" end
        end })
        armed = true
        assert.are.equal(5, json.len(body, "prompt"))
        assert.are.equal(3, json.len(body, "prompt"))
        json.close(body)
    end)

    it("rejects malformed paths and unsupported resolved length types", function()
        local body = json.decode(raw)
        for _, operation in ipairs({ json.len, json.exists, json.is_empty }) do
            for _, path in ipairs({ 1, false, {}, "a.", "$.", "items[-1]", "items[*]", "items[4294967296]" }) do
                assert.has_error(function() operation(body, path) end)
            end
            assert.has_error(function() operation() end)
            assert.has_error(function() operation(body, "prompt", "extra") end)
        end
        for _, key in ipairs({ "flag", "yes", "zero", "null" }) do
            assert.has_error(function() json.len(body, key) end)
        end
        local dollars = json.decode('{"$":"literal","$field":"value"}')
        assert.are.equal(7, json.len(dollars, ".$"))
        assert.are.equal(5, json.len(dollars, "$field"))
        assert.are.equal("literal", json.get(dollars, "$"))
        json.close(dollars); json.close(body)
    end)
end)
