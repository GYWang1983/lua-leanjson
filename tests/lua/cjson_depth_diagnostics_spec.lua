local json = require('leanjson')
local safe = require('leanjson.safe')
local function message(fn, ...)
    local ok, err = pcall(fn, ...)
    assert.is_false(ok)
    return tostring(err)
end
local function nested(n) return string.rep('[', n) .. '0' .. string.rep(']', n) end
local function table_at(n)
    local root = {}
    local current = root
    for _ = 2, n do current[1] = {}; current = current[1] end
    current[1] = 0
    return root
end
local fixtures = {
    { '', 'Expected value but found T_END at character 1' },
    { '{"a": [1, true, null', 'Expected comma or array end but found T_END at character 21' },
    { '{1:2}', 'Expected object key string but found T_INTEGER at character 2' },
    { '{"a" true}', 'Expected colon but found T_BOOLEAN at character 6' },
    { '[1 2]', 'Expected comma or array end but found T_INTEGER at character 4' },
    { '[0.4eg10]', 'Expected comma or array end but found invalid token at character 5' },
    { '{"a" "bad\\q"}', 'Expected colon but found invalid escape code at character 10' },
    { '"\\uD800\\u0041"', 'Expected value but found invalid unicode escape code at character 2' },
    { '[false,}', 'Expected value but found T_OBJ_END at character 8' },
    { 'true false', 'Expected the end but found T_BOOLEAN at character 6' },
    { '"abc', 'Expected value but found unexpected end of string at character 5' },
    { '{"é": false x}', 'Expected comma or object end but found invalid token at character 14' },
    { 'nul', 'Expected value but found invalid token at character 1' },
    { '[1e+]', 'Expected comma or array end but found invalid token at character 3' },
    { '/* comment */', 'Expected value but found invalid token at character 1' },
    { '\0x', 'JSON parser does not support UTF-16 or UTF-32' },
    { '1\0', 'JSON parser does not support UTF-16 or UTF-32' },
}

describe('cjson public depth and diagnostic contract', function()
    it('provides isolated depth settings with the full native range', function()
        local a, b, s = json.new(), json.new(), safe.new()
        for _, name in ipairs({ 'decode_max_depth', 'encode_max_depth' }) do
            assert.equal(1000, a[name]())
            assert.equal(2147483647, a[name](2147483647))
            assert.equal(5, a[name]('5.9'))
            assert.equal(5, a[name](nil))
            assert.equal(1000, b[name]())
            assert.equal(1000, s[name]())
            assert.equal("bad argument #1 to '?' (expected integer between 1 and 2147483647)", message(a[name], 0))
            assert.equal("bad argument #2 to '?' (found too many arguments)", message(a[name], 2, 3))
            assert.equal(5, a[name]())
        end
    end)

    it('counts containers and enforces decode snapshots on every source/loading path', function()
        for _, opts in ipairs({ {}, {lazyload=false}, {preload_paths={'$'}} }) do
            local c = json.new(); c.decode_max_depth(3)
            local v = c.decode(nested(3), opts); c.close(v)
            assert.equal('Found too many nested data structures (4) at character 4', message(c.decode, nested(4), opts))
            local decoder = c.new_decoder(opts)
            c.decode_max_depth(1)
            assert.is_true(decoder:feed(nested(3)))
            local value = assert(decoder:finish()); c.close(value)
            local again = assert(decoder:finish()); c.close(again); decoder:close()
            local filename = os.tmpname(); local f = assert(io.open(filename, 'wb')); f:write(nested(2)); f:close()
            assert.equal('Found too many nested data structures (2) at character 2', message(c.decode_file, filename, opts))
            os.remove(filename)
        end
    end)

    it('honors limits above4096 with bounded indexes and late rescans', function()
        local c = json.new(); c.decode_max_depth(6000); c.encode_max_depth(6000)
        local raw = nested(5000)
        local v = c.decode(raw, {index_depth=0, index_budget_bytes=0})
        assert.equal(0, c.source_stats(v).indexed_nodes)
        assert.equal(raw, c.encode(v))
        assert.equal(raw, c.encode(table_at(5000)))
        local r = c.reader(v, {chunk_size=97}); c.encode_max_depth(2)
        assert.equal(#raw, assert(r:length()))
        r:close(); c.close(v)
    end)

    it('materializes and rebuilds accepted depths above4096 in every loading mode', function()
        local c = json.new(); c.decode_max_depth(6000); c.encode_max_depth(6000)
        local raw = nested(5000)
        for _, opts in ipairs({{index_depth=0, index_budget_bytes=0}, {lazyload=false}, {preload_paths={'$'}}, {preload_paths={'$[0]'}}}) do
            local v = c.decode(raw, opts)
            local plain = c.materialize(v)
            assert.equal(raw, c.encode(plain))
            c.close(v)
        end
        local v = c.decode(raw, {index_depth=0, index_budget_bytes=0})
        assert.equal(raw, c.encode(c.materialize(v, {keep_origin=true}))); c.close(v)
        local d = c.new_decoder({lazyload=false, chunk_size=79})
        assert(d:feed(raw)); local first = assert(d:finish()); assert.equal(raw, c.encode(first))
        local again = assert(d:finish()); assert.equal(raw, c.encode(again))
        local child, status = d:get('[0]'); assert.equal('READY', status)
        assert.equal(nested(4999), c.encode(child)); d:close()
    end)

    it('checks raw proxy spans, assigned values, keep_origin and reader snapshots', function()
        local c = json.new(); c.encode_max_depth(2)
        local v = c.decode('{"a":[[0]],"z":1}')
        assert.equal('Cannot serialise, excessive nesting (3)', message(c.encode, v))
        local r = c.reader(v)
        c.encode_max_depth(10)
        local n, err = r:length(); assert.is_nil(n); assert.equal('Cannot serialise, excessive nesting (3)', err); r:close()
        v.a = { { 1 } }; c.encode_max_depth(2)
        assert.equal('Cannot serialise, excessive nesting (3)', message(c.encode, v))
        local plain = c.materialize(v, {keep_origin=true})
        assert.equal('Cannot serialise, excessive nesting (3)', message(c.encode, plain)); c.close(v)
        assert.equal('[[0]]', c.encode({{0}}))
    end)

    it('matches syntax wording and positions for every split', function()
        for _, fixture in ipairs(fixtures) do
            local raw, expected = fixture[1], fixture[2]
            assert.equal(expected, message(json.decode, raw), raw)
            local value, err = safe.decode(raw); assert.is_nil(value); assert.equal(expected, err)
            for split = 0, #raw do
                local d = json.new_decoder({chunk_size=2})
                local ok, actual = d:feed(raw:sub(1,split))
                if ok then ok, actual = d:feed(raw:sub(split+1)) end
                if ok then ok, actual = d:finish() end
                assert.is_nil(ok, raw .. ' at split ' .. split)
                assert.equal(expected, actual, raw .. ' at split ' .. split)
                d:close()
            end
        end
    end)

    it('validates raw spans even without an accepted source-depth bound', function()
        local backend, raw = {}, '{"a":{"b":{}}}'
        function backend:type() return 'object' end
        function backend:span() return 0, #raw end
        function backend:read(offset, length) return raw:sub(offset+1, offset+length) end
        local value = require('leanjson.proxy').from_backend(backend, {})
        local c = json.new(); c.encode_max_depth(2)
        local r = c.reader(value)
        local length, err = r:length()
        assert.is_nil(length); assert.equal('Cannot serialise, excessive nesting (3)', err)
        r:close(); c.close(value)
    end)

    it('uses native strict numeric rejection diagnostics, including signed forms', function()
        local c = json.new(); c.decode_invalid_numbers(false)
        for _, raw in ipairs({'01', '0x6', '-01', '-0x6', '-0X6', '-Inf', '-Infinity', '-NaN', '[-01]'}) do
            local position = raw:sub(1,1) == '[' and 2 or 1
            assert.equal('Expected value but found invalid number at character ' .. position, message(c.decode, raw), raw)
        end
        assert.equal('Expected object key string but found invalid number at character 2', message(c.decode, '{-01:0}'))
        assert.equal('Expected value but found invalid token at character 1', message(c.decode, '+1'))
        assert.equal('Expected colon but found T_NUMBER at character 6', message(json.decode, '{"k" -Inf}'))
    end)

    it('aligns conversion arguments, unsupported values and cycles', function()
        for _, codec in ipairs({json, safe}) do
            for _, name in ipairs({'encode', 'decode'}) do
                assert.equal("bad argument #1 to '?' (expected 1 argument)", message(codec[name]))
                assert.equal("bad argument #1 to '?' (expected 1 argument)", message(codec[name], 1, nil, nil))
            end
        end
        for _, raw in ipairs({false, {}, function() end}) do
            local expected = "bad argument #1 to '?' (string expected, got " .. type(raw) .. ")"
            assert.equal(expected, message(json.decode, raw))
            local value, err = safe.decode(raw); assert.is_nil(value); assert.equal(expected, err)
        end
        local value, err = safe.decode(nil)
        assert.is_nil(value); assert.equal("bad argument #1 to '?' (string expected, got nil)", err)
        assert.equal('Cannot serialise table: excessively sparse array', message(json.encode, {[100]=1}))
        assert.equal("bad argument #1 to '?' (expected 1 argument)", message(json.encode))
        assert.equal("bad argument #1 to '?' (expected 1 argument)", message(json.encode, 1, 2))
        assert.equal("bad argument #1 to '?' (expected 1 argument)", message(json.decode))
        assert.equal("bad argument #1 to '?' (string expected, got nil)", message(json.decode, nil))
        assert.equal('1', json.encode(json.decode(1)))
        for _, v in ipairs({function() end, coroutine.create(function() end), newproxy(false)}) do
            assert.equal('Cannot serialise ' .. type(v) .. ': type not supported', message(json.encode, v))
        end
        assert.equal('Cannot serialise number: must not be NaN or Infinity', message(json.encode, math.huge))
        assert.equal('Cannot serialise boolean: table key must be a number or string', message(json.encode, {[true]=1}))
        local c = json.new(); c.encode_max_depth(5)
        local cycle = {}; cycle[1] = cycle
        assert.equal('Cannot serialise, excessive nesting (6)', message(c.encode, cycle))
        local s = safe.new(); s.encode_max_depth(5)
        local value, err = s.encode(cycle); assert.is_nil(value); assert.equal('Cannot serialise, excessive nesting (6)', err)
    end)
end)
