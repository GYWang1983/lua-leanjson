local leanjson = require("leanjson")

describe("leanjson.decode — top-level scalars", function()
    it("decodes top-level numbers", function()
        assert.are.equal(42, leanjson.decode("42"))
        assert.are.equal(3.14, leanjson.decode("3.14"))
    end)

    it("decodes top-level strings (including escapes)", function()
        assert.are.equal("hello", leanjson.decode('"hello"'))
        assert.are.equal('line\n"break"', leanjson.decode('"line\\n\\"break\\""'))
    end)

    it("decodes top-level booleans", function()
        assert.is_true(leanjson.decode("true"))
        assert.is_false(leanjson.decode("false"))
    end)

    it("decodes top-level null as leanjson.null", function()
        assert.are.equal(leanjson.null, leanjson.decode("null"))
    end)

    it("still errors for invalid JSON and empty input", function()
        assert.has_error(function() leanjson.decode("not-json") end)
        assert.has_error(function() leanjson.decode("") end)
    end)
end)

describe("LazyObject __index — scalars", function()
    it("reads a string field", function()
        local t = leanjson.decode('{"k":"hello"}')
        assert.are.equal("hello", t.k)
    end)

    it("reads a number field", function()
        local t = leanjson.decode('{"n":42.5}')
        assert.are.equal(42.5, t.n)
    end)

    it("reads a boolean field", function()
        local t = leanjson.decode('{"b":true,"c":false}')
        assert.is_true(t.b)
        assert.is_false(t.c)
    end)

    it("returns nil for missing key", function()
        local t = leanjson.decode('{"a":1}')
        assert.is_nil(t.missing)
    end)

    it("decodes standard overflow like cjson and rejects it during default encoding", function()
        local t = leanjson.decode('{"n":1e9999}')
        assert.equal(math.huge, t.n)
        assert.has_error(function() leanjson.encode(t) end)
        leanjson.close(t)
    end)
end)

describe("LazyObject __index — nested containers", function()
    it("returns a LazyObject for a nested object", function()
        local t = leanjson.decode('{"a":{"b":"x"}}')
        local inner = t.a
        assert.is_table(inner)
        assert.are.equal("x", inner.b)
    end)

    it("returns a LazyArray for a nested array", function()
        local t = leanjson.decode('{"xs":[10,20]}')
        local xs = t.xs
        assert.is_table(xs)
        -- LazyArray __index is added in a later task; just verify it's
        -- a table-typed value at this stage.
    end)
end)

describe("LazyArray __index", function()
    it("reads scalar elements by integer index (1-based)", function()
        local t = leanjson.decode('[10,"x",true,null]')
        assert.are.equal(10, t[1])
        assert.are.equal("x", t[2])
        assert.is_true(t[3])
        assert.are.equal(leanjson.null, t[4])
    end)

    it("returns nil for out-of-range index", function()
        local t = leanjson.decode('[1,2,3]')
        assert.is_nil(t[0])
        assert.is_nil(t[4])
    end)

    it("returns nil for non-integer key", function()
        local t = leanjson.decode('[1,2,3]')
        assert.is_nil(t.foo)
        assert.is_nil(t[1.5])
    end)

    it("returns a nested LazyObject", function()
        local t = leanjson.decode('[{"a":1},{"a":2}]')
        assert.are.equal(1, t[1].a)
        assert.are.equal(2, t[2].a)
    end)
end)

-- LuaJIT 5.1 only invokes __len on userdata; it ignores the metamethod on
-- tables unless built with LUAJIT_ENABLE_LUA52COMPAT (OpenResty's default).
-- Probe once so the `#t` cases only run where they can pass; leanjson.len(t) is
-- the supported path everywhere.
local LJ52_LEN = (#setmetatable({}, {__len = function() return 99 end}) == 99)

describe("leanjson.len", function()
    it("counts object keys", function()
        local t = leanjson.decode('{"a":1,"b":2,"c":3}')
        assert.are.equal(3, leanjson.len(t))
    end)

    it("counts array elements", function()
        local t = leanjson.decode('[10,20,30,40]')
        assert.are.equal(4, leanjson.len(t))
    end)

    it("returns 0 for empty containers", function()
        assert.are.equal(0, leanjson.len(leanjson.decode('{}')))
        assert.are.equal(0, leanjson.len(leanjson.decode('[]')))
    end)

    it("falls back to # on a plain table", function()
        assert.are.equal(3, leanjson.len({10, 20, 30}))
    end)

    it("counts materialized object keys after add and delete", function()
        local t = leanjson.decode('{"a":1,"b":2}')
        t.c = 3
        assert.are.equal(3, leanjson.len(t))
        t.a = nil
        assert.are.equal(2, leanjson.len(t))
    end)
end)

describe("__len (LJ52 only)", function()
    it("counts object keys via #t", function()
        if not LJ52_LEN then return pending("LuaJIT built without LUAJIT_ENABLE_LUA52COMPAT") end
        local t = leanjson.decode('{"a":1,"b":2,"c":3}')
        assert.are.equal(3, #t)
    end)

    it("counts array elements via #t", function()
        if not LJ52_LEN then return pending("LuaJIT built without LUAJIT_ENABLE_LUA52COMPAT") end
        local t = leanjson.decode('[10,20,30,40]')
        assert.are.equal(4, #t)
    end)

    it("returns 0 for empty containers via #t", function()
        if not LJ52_LEN then return pending("LuaJIT built without LUAJIT_ENABLE_LUA52COMPAT") end
        assert.are.equal(0, #leanjson.decode('{}'))
        assert.are.equal(0, #leanjson.decode('[]'))
    end)
end)

describe("__pairs / leanjson.pairs over LazyObject", function()
    local function make_object(n)
        local parts = {}
        for i = 1, n do
            parts[#parts + 1] = string.format('"k%d":%d', i, i)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    it("iterates string keys in source order", function()
        local t = leanjson.decode('{"a":1,"b":2,"c":3}')
        local keys = {}
        local values = {}
        for k, v in leanjson.pairs(t) do
            keys[#keys+1] = k
            values[#values+1] = v
        end
        assert.are.same({"a","b","c"}, keys)
        assert.are.same({1, 2, 3}, values)
    end)

    for _, n in ipairs({1, 10, 100}) do
        it("iterates " .. n .. " keys in source order", function()
            local t = leanjson.decode(make_object(n))
            local seen = 0
            for k, v in leanjson.pairs(t) do
                seen = seen + 1
                assert.are.equal("k" .. seen, k)
                assert.are.equal(seen, v)
            end
            assert.are.equal(n, seen)
        end)
    end

    it("allows early break without disturbing later access", function()
        local t = leanjson.decode(make_object(100))
        local iter, state, initial = leanjson.pairs(t)
        local first_key, first_value = iter(state, initial)
        assert.are.equal("k1", first_key)
        assert.are.equal(1, first_value)
        assert.are.equal(100, t.k100)
    end)

    it("returns nested containers as lazy proxies, not materialized", function()
        local t = leanjson.decode('{"a":{"x":1}}')
        for _, v in leanjson.pairs(t) do
            assert.is_table(v)
            assert.are.equal(1, v.x)
        end
    end)

    it("handles empty object", function()
        local count = 0
        for _ in leanjson.pairs(leanjson.decode('{}')) do count = count + 1 end
        assert.are.equal(0, count)
    end)
end)

describe("__ipairs / leanjson.ipairs over LazyArray", function()
    it("keeps object proxies empty and delegates plain tables to numeric iteration", function()
        local object = leanjson.decode('{"a":1,"1":2}')
        for _ = 1, 2 do
            local next_value, state, initial = leanjson.ipairs(object)
            assert.are.equal(0, initial)
            assert.is_nil(next_value(state, initial))
            object.extra = 3
        end
        leanjson.close(object)
        local plain, seen = { 10, 20, a = 30 }, {}
        for index, value in leanjson.ipairs(plain) do seen[index] = value end
        assert.are.same({ 10, 20 }, seen)
    end)

    it("iterates elements 1..n in order", function()
        local t = leanjson.decode('[10,20,30]')
        local got = {}
        for i, v in leanjson.ipairs(t) do got[i] = v end
        assert.are.same({10,20,30}, got)
    end)

    it("yields lazy proxies for nested containers", function()
        local t = leanjson.decode('[{"a":1},{"a":2}]')
        local seen = {}
        for _, v in leanjson.ipairs(t) do
            assert.is_table(v)
            seen[#seen+1] = v.a
        end
        assert.are.same({1, 2}, seen)
    end)

    it("handles empty array", function()
        local count = 0
        for _ in leanjson.ipairs(leanjson.decode('[]')) do count = count + 1 end
        assert.are.equal(0, count)
    end)
end)

describe("__newindex — first-write materialization", function()
    it("preserves LazyObject metatable after modification for ordered encoding", function()
        local t = leanjson.decode('{"a":1,"b":2}')
        t.c = 3
        assert.are.equal(leanjson._LazyObject, getmetatable(t))
        assert.are.equal(1, t.a)
        assert.are.equal(2, t.b)
        assert.are.equal(3, t.c)
    end)

    it("nested containers remain lazy after parent modification", function()
        local t = leanjson.decode('{"inner":{"x":1}}')
        t.extra = "y"
        assert.are.equal(leanjson._LazyObject, getmetatable(t))
        local inner = t.inner
        assert.are.equal(leanjson._LazyObject, getmetatable(inner))
        assert.are.equal(1, inner.x)
    end)

    it("LazyArray keeps a private proxy after writes", function()
        local t = leanjson.decode('[]')
        t[1] = "x"
        assert.are.equal(leanjson._LazyArray, getmetatable(t))
        assert.are.equal("array", leanjson.type(t))
        assert.are.equal("x", t[1])
    end)

    it("simple write leaves other keys intact", function()
        local t = leanjson.decode('{"a":1}')
        t.b = 2
        assert.are.equal(1, t.a)
        assert.are.equal(2, t.b)
    end)
end)

describe("leanjson.materialize", function()
    it("converts a LazyObject and its nested containers into real tables", function()
        local m = leanjson.materialize(leanjson.decode('{"a":1,"b":{"c":[10,20]}}'))
        assert.is_nil(getmetatable(m))
        assert.are.equal(1, m.a)
        assert.is_nil(getmetatable(m.b))
        assert.are.equal(10, m.b.c[1])
        assert.are.equal(20, m.b.c[2])
    end)

    it("tags empty arrays with empty_array_mt", function()
        local m = leanjson.materialize(leanjson.decode('[]'))
        assert.are.equal(leanjson.empty_array_mt, getmetatable(m))
    end)

    it("preserves cjson.null", function()
        local m = leanjson.materialize(leanjson.decode('{"x":null}'))
        assert.are.equal(leanjson.null, m.x)
    end)

    it("passes through scalars and plain tables unchanged", function()
        assert.are.equal(42, leanjson.materialize(42))
        assert.are.equal("hi", leanjson.materialize("hi"))
        local raw = {1, 2, 3}
        assert.are.equal(raw, leanjson.materialize(raw))
    end)

    it("preserves cached child mutations in parent materialize", function()
        local t = leanjson.decode('{"a":{"x":1},"b":2}')
        t.a.x = 99
        local m = leanjson.materialize(t)
        assert.are.equal(99, m.a.x)
        assert.are.equal(2, m.b)
    end)
end)

describe("leanjson.encode — lazy proxy substring fast path", function()
    it("re-emits the original JSON for an unmodified LazyObject", function()
        local src = '{"a":1,"b":[2,3],"c":"x"}'
        local t = leanjson.decode(src)
        assert.are.equal(src, leanjson.encode(t))
    end)

    it("re-emits the original JSON for an unmodified LazyArray", function()
        local src = '[10,20,{"k":"v"}]'
        local t = leanjson.decode(src)
        assert.are.equal(src, leanjson.encode(t))
    end)

    it("trims leading/trailing whitespace at the boundary", function()
        local src = '  {"a":1}  '
        local t = leanjson.decode(src)
        -- byte span is the value, not its outer whitespace.
        assert.are.equal('{"a":1}', leanjson.encode(t))
    end)
end)

describe("leanjson.encode — scalars", function()
    it("encodes strings with JSON escapes", function()
        assert.are.equal('"hello"', leanjson.encode("hello"))
        assert.are.equal('"a\\nb"', leanjson.encode("a\nb"))
        assert.are.equal('"a\\"b"', leanjson.encode('a"b'))
        assert.are.equal('"a\\\\b"', leanjson.encode("a\\b"))
    end)

    it("encodes booleans", function()
        assert.are.equal("true", leanjson.encode(true))
        assert.are.equal("false", leanjson.encode(false))
    end)

    it("encodes numbers", function()
        assert.are.equal("42", leanjson.encode(42))
        assert.are.equal("-3.14", leanjson.encode(-3.14))
    end)

    it("encodes leanjson.null as JSON null", function()
        assert.are.equal("null", leanjson.encode(leanjson.null))
    end)

    it("errors on unsupported values", function()
        assert.has_error(function() leanjson.encode(function() end) end)
    end)
end)

describe("leanjson.encode — real and mixed tables", function()
    it("encodes a real Lua object", function()
        local cjson = require("cjson")
        local s = leanjson.encode({a = 1, b = "x"})
        assert.are.same({a = 1, b = "x"}, cjson.decode(s))
    end)

    it("encodes a real Lua array", function()
        assert.are.equal("[1,2,3]", leanjson.encode({1,2,3}))
    end)

    it("encodes a hand-built empty array with empty_array_mt", function()
        local arr = setmetatable({}, leanjson.empty_array_mt)
        assert.are.equal("[]", leanjson.encode(arr))
    end)

    it("encodes mixed lazy + materialized", function()
        local t = leanjson.decode('{"keep":{"x":1},"changed":{"y":2}}')
        t.changed = "now a string"
        local out = leanjson.encode(t)
        local cjson = require("cjson")
        local parsed = cjson.decode(out)
        assert.are.same({x=1}, parsed.keep)
        assert.are.equal("now a string", parsed.changed)
    end)
end)

local cjson = require("cjson")

-- Deep-equal aware of cjson.null and empty_array_mt (which leanjson aliases).
local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

describe("cjson round-trip equivalence", function()
    local fixtures = {
        '{"a":1,"b":"x","c":null,"d":true,"e":false,"f":[1,2,3],"g":{"h":4.5}}',
        '[1,"x",true,null,{},[]]',
        '{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}',
        '{}',
        '[]',
        '{"escapes":"a\\nb\\tc\\\"d\\\\e"}',
    }
    for _, src in ipairs(fixtures) do
        it("materialize matches cjson.decode for: " .. src:sub(1, 40), function()
            local from_leanjson = leanjson.materialize(leanjson.decode(src))
            local from_cj = cjson.decode(src)
            assert.is_true(deep_equal(from_leanjson, from_cj))
        end)

        it("encode round-trips for: " .. src:sub(1, 40), function()
            local out = leanjson.encode(leanjson.decode(src))
            local back_leanjson = cjson.decode(out)
            local back_cj = cjson.decode(src)
            assert.is_true(deep_equal(back_leanjson, back_cj))
        end)
    end
end)

describe("sentinel handling", function()
    it("JSON null reads as leanjson.null and encodes back", function()
        local t = leanjson.decode('{"x":null}')
        assert.are.equal(leanjson.null, t.x)
        assert.are.equal('{"x":null}', leanjson.encode(t))
    end)

    it("empty array stays an array through materialize and encode", function()
        local t = leanjson.decode('{"xs":[]}')
        local m = leanjson.materialize(t)
        assert.are.equal(leanjson.empty_array_mt, getmetatable(m.xs))
        assert.are.equal('{"xs":[]}', leanjson.encode(t))
    end)
end)

describe("leanjson.encode — nested mutations propagate", function()
    it("emits nested object mutation, not original bytes", function()
        local cjson = require("cjson")
        local t = leanjson.decode('{"a":{"b":{"c":1}},"d":2}')
        t.a.b.c = 999
        local out = leanjson.encode(t)
        local parsed = cjson.decode(out)
        assert.are.equal(999, parsed.a.b.c)
        assert.are.equal(2, parsed.d)
    end)

    it("emits nested array mutation", function()
        local cjson = require("cjson")
        local t = leanjson.decode('{"xs":[10,20,30]}')
        t.xs[2] = 999
        local out = leanjson.encode(t)
        local parsed = cjson.decode(out)
        assert.are.equal(10, parsed.xs[1])
        assert.are.equal(999, parsed.xs[2])
        assert.are.equal(30, parsed.xs[3])
    end)

    it("preserves cached proxy identity across parent materialization", function()
        local t = leanjson.decode('{"a":{"x":1}}')
        local inner = t.a
        t.c = 3
        assert.are.equal(inner, t.a)
        inner.x = 99
        assert.are.equal(99, t.a.x)
    end)

    it("modifies top-level field and encodes correctly", function()
        local cjson = require("cjson")
        local t = leanjson.decode('{"model":"gpt-4","temperature":0.7}')
        t.model = "gpt-5"
        local out = leanjson.encode(t)
        local parsed = cjson.decode(out)
        assert.are.equal("gpt-5", parsed.model)
        assert.are.equal(0.7, parsed.temperature)
    end)

    it("adds new field and encodes correctly", function()
        local cjson = require("cjson")
        local t = leanjson.decode('{"a":1}')
        t.b = true
        local out = leanjson.encode(t)
        local parsed = cjson.decode(out)
        assert.are.equal(1, parsed.a)
        assert.are.equal(true, parsed.b)
    end)

    it("modifies nested field and encodes correctly", function()
        local cjson = require("cjson")
        local t = leanjson.decode('{"messages":[{"role":"user","content":"hello"}]}')
        t.messages[1].content = "world"
        local out = leanjson.encode(t)
        local parsed = cjson.decode(out)
        assert.are.equal("user", parsed.messages[1].role)
        assert.are.equal("world", parsed.messages[1].content)
    end)

    it("encodes unmodified proxy via fast path", function()
        local json = '{"a":1,"b":"text","c":true}'
        local t = leanjson.decode(json)
        local out = leanjson.encode(t)
        local cjson = require("cjson")
        local parsed = cjson.decode(out)
        assert.are.equal(1, parsed.a)
        assert.are.equal("text", parsed.b)
        assert.are.equal(true, parsed.c)
    end)

    it("encodes string with escapes correctly", function()
        local t = leanjson.decode('{"key":"value"}')
        t.key = 'line1\nline2\t"quoted"'
        local out = leanjson.encode(t)
        local cjson = require("cjson")
        local parsed = cjson.decode(out)
        assert.are.equal('line1\nline2\t"quoted"', parsed.key)
    end)
end)
