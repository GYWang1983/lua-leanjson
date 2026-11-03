local json = require("leanjson")
local native = require("cjson")

local function collect(c, value, size, normalize)
    local reader, parts = c.reader(value, { chunk_size = size or 3, normalize_duplicates = normalize }), {}
    local length, err = reader:length(); assert.is_nil(err)
    while true do
        local chunk, failure = reader:next(); assert.is_nil(failure)
        if not chunk then break end
        assert.is_true(#chunk <= (size or 3)); parts[#parts + 1] = chunk
    end
    local raw = table.concat(parts); assert.equal(#raw, length)
    return raw
end

describe("cjson comment policy", function()
    local files, held
    before_each(function() files, held = {}, {} end)
    after_each(function()
        for _, value in ipairs(held) do json.close(value) end
        for _, path in ipairs(files) do os.remove(path) end
    end)
    local function hold(value)
        if type(value) == "table" then held[#held + 1] = value end
        return value
    end
    local function load(c, source, raw, mode)
        local opts = { lazyload = mode ~= "eager", chunk_size = 1,
            index_depth = 0, index_array_limit = 0, index_budget_bytes = 0,
            preload_paths = mode == "preload" and { "$.selected" } or nil }
        if source == "memory" then return hold(assert(c.decode(raw, opts))) end
        if source == "file" then
            local path = os.tmpname(); files[#files + 1] = path
            local file = assert(io.open(path, "wb")); assert(file:write(raw)); file:close()
            return hold(assert(c.decode_file(path, opts)))
        end
        local decoder = assert(c.new_decoder(opts))
        local ok, result = pcall(function()
            for i = 1, #raw do assert(decoder:feed(raw:sub(i, i))) end
            return assert(decoder:finish())
        end)
        decoder:close(); if not ok then error(result, 0) end
        return hold(result)
    end

    it("isolates false defaults and atomic native setting errors", function()
        local safe = require("leanjson.safe")
        local a, b, s = json.new(), json.new(), safe.new()
        for _, c in ipairs({ json, safe, a, b, s }) do
            assert.is_function(c.decode_allow_comment)
            assert.is_false(c.decode_allow_comment())
        end
        local oracle = native.new()
        for _, value in ipairs({ true, false, "on", "off" }) do
            assert.equal(oracle.decode_allow_comment(value), a.decode_allow_comment(value))
        end
        a.decode_allow_comment(true)
        assert.is_true(a.decode_allow_comment(nil))
        assert.is_false(b.decode_allow_comment()); assert.is_false(s.decode_allow_comment())
        for _, args in ipairs({ { "ON" }, { 1 }, { {} }, { true, false } }) do
            local good, want = pcall(oracle.decode_allow_comment, unpack(args))
            local ok, err = pcall(a.decode_allow_comment, unpack(args))
            assert.equal(good, ok); assert.equal(want, err)
            assert.is_true(a.decode_allow_comment())
        end
        assert.has_error(function() b.decode('{/*x*/}') end)
        assert.is_table(a.decode('{/*x*/}'))
        assert.has_error(function() json.parse('{/*legacy remains strict*/}') end)
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
        for _, mode in ipairs({ "lazy", "eager", "preload" }) do
            it("removes real comments in " .. source .. "/" .. mode, function()
                for _, safe in ipairs({ false, true }) do
                    local c = safe and require("leanjson.safe").new() or json.new()
                    assert.is_function(c.decode_allow_comment); c.decode_allow_comment(true)
                    local raw = '/*lead*//*adjacent*/{"selected"/*key*/:/*value*/{"x":1/*end*/},' ..
                        '"late":[//line\r\n{/*empty*/},[/*empty*/],"// /* */"],"clean":{ "n" : 1.00 }}//tail'
                    local root = load(c, source, raw, mode)
                    c.decode_allow_comment(false)
                    assert.equal(1, root.selected.x); assert.equal("// /* */", root.late[3])
                    local strict = json.new()
                    strict.encode_escape_forward_slash(false); c.encode_escape_forward_slash(false)
                    local encoded = collect(c, root, 2)
                    local result = hold(strict.decode(encoded))
                    assert.equal(1, result.selected.x); assert.equal("// /* */", result.late[3])
                    assert.is_table(result.late[1]); assert.is_table(result.late[2])
                    if mode ~= "eager" then
                        assert.is_truthy(encoded:find('{ "n" : 1.00 }', 1, true))
                    end
                    assert.equal(encoded, c.encode(root))
                    if mode ~= "eager" then
                        local fork = hold(strict.fork(root)); fork.added = 2
                        local changed = hold(strict.decode(collect(strict, fork)))
                        assert.equal(2, changed.added); assert.equal(1, changed.selected.x)
                    end
                end
            end)
        end
    end

    it("snapshots decoder policy through repeated finish get and eager rebuild", function()
        for _, eager in ipairs({ false, true }) do
            local c = json.new(); assert.is_function(c.decode_allow_comment); c.decode_allow_comment(true)
            local decoder = c.new_decoder({ lazyload = not eager, chunk_size = 1, index_depth = 0, index_budget_bytes = 0 })
            c.decode_allow_comment(false)
            assert(decoder:feed('{"x":{/*nested*/"n":1},/*between*/"y":2}'))
            for _ = 1, 2 do
                local value = hold(assert(decoder:finish())); assert.equal(1, value.x.n)
                local x, state = decoder:get("x"); hold(x); assert.equal("READY", state); assert.equal(1, x.n)
                local raw = collect(c, value)
                assert.is_nil(raw:find("/*", 1, true))
                local output = hold(json.decode(raw)); assert.equal(1, output.x.n); assert.equal(2, output.y)
            end
            decoder:close()
            local strict = c.new_decoder(); c.decode_allow_comment(true)
            local ok = strict:feed('{/*strict snapshot*/}'); assert.is_nil(ok); strict:close()
        end
    end)

    it("matches native errors and comment transitions at every feed split", function()
        local oracle = native.new(); oracle.decode_allow_comment(true)
        local cases = { '{}/*Unclosed', '/*', '/','/*x*', '{/*x*/', '[1/*x*/0]', '{"a":1/*x*/0}',
            '[tru/*x*/e]', '[nul/*x*/l]', '[1e/*x*/2]', '[1./*x*/2]', '[0x/*x*/1]',
            '[/*x*/]', '{//line\r\n}', '1//through\rEOF', '[1//cr\r]', '/*"\\[{{\255*/{"/*key*/":"//text"}',
            '/*a/*b*/{}', 'true/*a*//*b*/', '/*before*/[1,/*x*/2]/*after*/', '"/*string*/"//tail',
            '/\0', '\0/', '/*\0*/true', '[/*\0*/1]', '/*x*\0*/{}', '[1,//\0x]', '//\0' }
        for _, raw in ipairs(cases) do
            local want_ok, want = pcall(oracle.decode, raw)
            for split = 0, #raw do
                local c = json.new(); assert.is_function(c.decode_allow_comment); c.decode_allow_comment(true)
                local decoder = c.new_decoder({ chunk_size = 1, index_depth = 0, index_budget_bytes = 0 })
                local value, err = decoder:feed(raw:sub(1, split))
                if value then value, err = decoder:feed(raw:sub(split + 1)) end
                if value then value, err = decoder:finish() end
                assert.equal(want_ok, value ~= nil, raw .. " split " .. split)
                if not want_ok then assert.equal(want, err, raw .. " split " .. split) else hold(value) end
                decoder:close()
            end
        end
    end)

    it("removes comments through duplicate normalization and keep_origin reuse", function()
        local c = json.new(); assert.is_function(c.decode_allow_comment); c.decode_allow_comment(true)
        local long = string.rep("a", 80)
        local root = hold(c.decode('{/*root*/"x":"' .. long .. '","nested":{/*nested*/"s":"' .. long .. '"},"empty":{/*empty*/}}'))
        for _, value in ipairs({ root, c.materialize(root, { keep_origin = true }) }) do
            local encoded = c.encode(value)
            assert.is_nil(encoded:find("/*", 1, true)); hold(json.decode(encoded))
        end
        local duplicates = hold(c.decode('{"a":{/*old*/"x":1},/*between*/"a":{/*last*/"x":2}}',
            { index_depth = 0, index_budget_bytes = 0 }))
        assert.equal('{"a":{"x":2}}', collect(c, duplicates, 1, true))
        duplicates.more = 3
        local out = hold(json.decode(c.encode(duplicates))); assert.equal(2, out.a.x); assert.equal(3, out.more)
    end)

    it("ignores comment brackets for encoding depth and rejects real excess depth", function()
        local c = json.new(); assert.is_function(c.decode_allow_comment); c.decode_allow_comment(true)
        local root = hold(c.decode('{/*[[[[{{{{*/"empty":{/*]]]]}}}}*/}}'))
        c.encode_max_depth(2); assert.equal('{"empty":{}}', collect(c, root, 1))
        c.encode_max_depth(1); assert.has_error(function() c.encode(root) end)
        local reader = c.reader(root); local n, err = reader:length()
        assert.is_nil(n); assert.is_string(err); reader:close()
    end)

    it("keeps large comment output reads bounded without scalar materialization", function()
        local c = json.new(); assert.is_function(c.decode_allow_comment); c.decode_allow_comment(true)
        local raw = '{/*' .. string.rep('"\\[{}]\255', 200000) .. '*/"x":{/*empty*/},"n":1.00}'
        local backend, handle = require("leanjson.source_memory").open(raw,
            { chunk_size = 127, index_depth = 0, index_budget_bytes = 0 }, c)
        local root = hold(require("leanjson.proxy").from_backend(backend, handle, c))
        local original = backend.read
        function backend:read(offset, length, scope)
            assert.is_true(length <= 127)
            return original(self, offset, length, scope)
        end
        function backend:scalar() error("comment stripping must not materialize scalars") end
        backend.memory = false
        assert.equal('{"x":{},"n":1.00}', collect(c, root, 7))
        assert.equal(0, c.source_stats(root).index_bytes)
    end)

    it("cancels comment-container iterators suspended during length and output", function()
        for _, phase in ipairs({ "length", "next" }) do
            local c = json.new(); assert.is_function(c.decode_allow_comment); c.decode_allow_comment(true)
            local backend, handle = require("leanjson.source_memory").open('{/*x*/"a":{/*y*/}}', { chunk_size = 1 }, c)
            local root = hold(require("leanjson.proxy").from_backend(backend, handle, c))
            local reader = c.reader(root, { chunk_size = 1 })
            if phase == "next" then assert.equal(#'{"a":{}}', reader:length()) end
            local original = backend.read
            function backend:read(offset, length)
                coroutine.yield("comment read pending")
                return original(self, offset, length)
            end
            -- Force native iterator windows through the observable backend read.
            backend.memory = false
            local co = coroutine.create(function()
                if phase == "length" then return reader:length() end
                while true do local chunk, err = reader:next(); if not chunk then return chunk, err end end
            end)
            local ok, pending = coroutine.resume(co); assert.is_true(ok); assert.equal("comment read pending", pending)
            reader:close()
            local resumed, chunk, err = coroutine.resume(co)
            assert.is_true(resumed); assert.is_nil(chunk); assert.equal("leanjson.reader: closed", err)
        end
    end)
end)
