local leanjson = require("leanjson")
local ffi = require("ffi")

local function without_large_decode(fn)
    local original = ffi.string
    ffi.string = function(ptr, n)
        assert.is_true(n == nil or tonumber(n) <= 64, "a sibling scalar was decoded")
        return original(ptr, n)
    end
    local ok, err = pcall(fn)
    ffi.string = original
    if not ok then error(err, 0) end
end

describe("source proxy overlays", function()
    it("lets an explicit empty-array metatable override a materialized object hint", function()
        local value = leanjson.materialize(leanjson.decode('{}'))
        setmetatable(value, leanjson.empty_array_mt)
        assert.are.equal("array", leanjson.type(value))
        assert.are.equal('[]', leanjson.encode(value))
        local reader = leanjson.reader(value)
        assert.are.equal('[]', reader:next())
    end)
    it("writes beside huge top-level strings without decoding siblings", function()
        local body = leanjson.decode('{"model":"old","prompt":"' .. string.rep("x", 1024 * 1024)
            .. '","input":"' .. string.rep("y", 1024 * 1024) .. '"}')
        without_large_decode(function()
            body.model = "new"
            body.extra = true
            body.extra = nil
        end)
        assert.are.equal("new", body.model)
    end)

    it("replaces an array slot without decoding its huge sibling", function()
        local body = leanjson.decode('[{"x":1},"' .. string.rep("x", 1024 * 1024) .. '"]')
        local old = body[1]
        without_large_decode(function() body[1] = { x = 2 } end)
        old.x = 9
        assert.are.equal(2, body[1].x)
        assert.are.equal(9, old.x)
    end)

    it("keeps every internal-looking JSON key available for reads and writes", function()
        local names = { "_doc", "_dirty", "_parent", "_cur", "_cur_box", "_bs", "_be", "_keys", "_values" }
        local body = leanjson.decode('{}')
        for i, key in ipairs(names) do body[key] = i end
        for i, key in ipairs(names) do assert.are.equal(i, body[key]) end
        local roundtrip = leanjson.decode(leanjson.encode(body))
        for i, key in ipairs(names) do assert.are.equal(i, roundtrip[key]) end
        assert.is_nil(next(body))
    end)

    it("intercepts read-then-write and read-then-delete array elements", function()
        local body = leanjson.decode('[{"x":1},{"x":2}]')
        local old = body[1]
        body[1] = { x = 8 }
        old.x = 7
        assert.are.equal('[{"x":8},{"x":2}]', leanjson.encode(body))
        local replaced = body[1]
        body[2] = nil
        assert.are.equal('[{"x":8}]', leanjson.encode(body))
        body[1] = nil
        replaced.x = 10
        assert.is_nil(body[1])
        assert.are.equal('[]', leanjson.encode(body))
        assert.are.equal(10, replaced.x)
    end)

    it("detaches old child proxies after parent replacement and deletion", function()
        local body = leanjson.decode('{"a":{"x":1},"b":{"y":2}}')
        local a, b = body.a, body.b
        body.a = { x = 3 }
        body.b = nil
        a.x, b.y = 9, 10
        assert.are.equal('{"a":{"x":3}}', leanjson.encode(body))
        assert.are.equal('{"x":9}', leanjson.encode(a))
        assert.are.equal('{"y":10}', leanjson.encode(b))
    end)

    it("retains null, false, empty object and empty array identities", function()
        local body = leanjson.decode('{"a":[],"o":{},"n":null,"b":false}')
        assert.are.equal("array", leanjson.type(body.a))
        assert.are.equal("object", leanjson.type(body.o))
        assert.are.equal("null", leanjson.type(body.n))
        body.a[1] = leanjson.null
        assert.are.equal("array", leanjson.type(body.a))
        body.a[1] = nil
        assert.are.equal('{"a":[],"o":{},"n":null,"b":false}', leanjson.encode(body))
        assert.is_nil(body.missing)
    end)

    it("reads the last duplicate field before any write", function()
        local body = leanjson.decode('{"a":{"x":1},"a":{"x":2},"n":1,"n":2}')
        assert.are.equal(2, body.a.x)
        assert.are.equal(2, body.n)
        body.a.x = 3
        assert.are.equal('{"a":{"x":3},"n":2}', leanjson.encode(body))
        body.a = nil
        assert.are.equal('{"n":2}', leanjson.encode(body))
    end)

    it("forks the current snapshot without mutable aliases", function()
        local body = leanjson.decode('{"a":{"x":1},"v":0}')
        local old_child = body.a
        body.v = 1
        local first, second = leanjson.fork(body), leanjson.fork(body)
        old_child.x = 2
        first.a.x = 3
        second.v = 4
        assert.are.equal('{"a":{"x":2},"v":1}', leanjson.encode(body))
        assert.are.equal('{"a":{"x":3},"v":1}', leanjson.encode(first))
        assert.are.equal('{"a":{"x":1},"v":4}', leanjson.encode(second))
    end)

    it("forks huge source branches without recursively decoding or copying source values", function()
        local body = leanjson.decode('{"model":"old","prompt":"' .. string.rep("x", 2 * 1024 * 1024) .. '"}')
        collectgarbage("collect")
        local before, branches = collectgarbage("count"), {}
        without_large_decode(function()
            for i = 1, 64 do branches[i] = leanjson.fork(body) end
        end)
        collectgarbage("collect")
        assert.is_true(collectgarbage("count") - before < 256, "fork copied a huge source value")
        for i, branch in ipairs(branches) do branch.model = tostring(i) end
        assert.are.equal("old", body.model)
        assert.are.equal("1", branches[1].model)
        assert.are.equal("64", branches[64].model)
    end)

    it("keeps lexical object iteration membership frozen during duplicate-child writes", function()
        local body = leanjson.decode('{"a":{"x":1},"a":{"y":2}}')
        local seen = {}
        for _, child in leanjson.pairs(body) do
            if child.x then
                seen[#seen + 1] = "x=" .. child.x
                child.x = 9
            else
                seen[#seen + 1] = "y=" .. child.y
            end
        end
        assert.are.same({ "x=1", "y=2" }, seen)
        assert.are.equal('{"a":{"y":2}}', leanjson.encode(body))
    end)

    it("snapshots plain table and proxy assignments at assignment time", function()
        local body = leanjson.decode('{"a":{"x":1}}')
        local plain = { child = { x = 2 } }
        body.plain = plain
        body.alias = body.a
        plain.child.x = 7
        body.a.x = 8
        body.alias.x = 9
        assert.are.equal(2, body.plain.child.x)
        assert.are.equal(8, body.a.x)
        assert.are.equal(9, body.alias.x)
        assert.are_not.equal(body.a, body.alias)
    end)

    it("keeps source node identities stable when a backend yields during indexing", function()
        local backend, root = require("leanjson.source_memory").open('{"a":{"x":1}}')
        local original, pause = backend.children, true
        function backend:children(handle)
            local iter = original(self, handle)
            return function()
                if handle == root and pause then
                    pause = false
                    coroutine.yield("index pending")
                end
                return iter()
            end
        end
        local body = require("leanjson.proxy").from_backend(backend, root)
        local co = coroutine.create(function() return body.a end)
        local ok, pending = coroutine.resume(co)
        assert.is_true(ok)
        assert.are.equal("index pending", pending)
        local child = body.a
        local resumed, first_child = coroutine.resume(co)
        assert.is_true(resumed)
        assert.are.equal(child, first_child)
        child.x = 9
        assert.are.equal('{"a":{"x":9}}', leanjson.encode(body))
    end)

    it("detaches pending old reads after object or array replacement and deletion", function()
        local cases = {
            { source = '{"a":{"x":1}}', key = "a", replaced = '{"a":{"x":3}}', deleted = '{}' },
            { source = '[{"x":1}]', key = 1, replaced = '[{"x":3}]', deleted = '[]' },
        }
        for _, case in ipairs(cases) do
            for _, action in ipairs({ "replace", "delete" }) do
                local backend, root = require("leanjson.source_memory").open(case.source)
                local original, pause = backend.children, true
                function backend:children(handle)
                    local iter = original(self, handle)
                    return function()
                        if handle == root and pause then
                            pause = false
                            coroutine.yield("read pending")
                        end
                        return iter()
                    end
                end
                local body = require("leanjson.proxy").from_backend(backend, root)
                local co = coroutine.create(function() return body[case.key] end)
                local ok, pending = coroutine.resume(co)
                assert.is_true(ok)
                assert.are.equal("read pending", pending)
                if action == "replace" then body[case.key] = { x = 2 }
                else body[case.key] = nil end
                local resumed, old = coroutine.resume(co)
                assert.is_true(resumed)
                assert.are.equal(1, old.x)
                old.x = 9
                if action == "replace" then
                    assert.are.equal(2, body[case.key].x)
                    body[case.key].x = 3
                    assert.are.equal(case.replaced, leanjson.encode(body))
                else
                    assert.is_nil(body[case.key])
                    assert.are.equal(case.deleted, leanjson.encode(body))
                    body[case.key] = { x = 3 }
                    assert.are.equal(case.replaced, leanjson.encode(body))
                end
                assert.are.equal(9, old.x)
            end
        end
    end)

    it("does not confuse null-pointer cdata assignments with nil deletion", function()
        local body = leanjson.decode('{}')
        body.unsupported = ffi.cast("void *", 0)
        assert.are.equal("cdata", type(body.unsupported))
        assert.has_error(function() leanjson.encode(body) end, "leanjson.encode: unsupported value type: cdata")
    end)

    it("rejects cyclic plain tables when snapshotting an assignment", function()
        local body, cycle = leanjson.decode('{}'), {}
        cycle.self = cycle
        assert.has_error(function() body.cycle = cycle end, "leanjson.encode: circular reference")
        assert.are.equal('{}', leanjson.encode(body))
    end)

    it("collects source resources after cached parents and children are released", function()
        local function observations()
            local backend, root = require("leanjson.source_memory").open(
                '{"child":{"x":1},"blob":"' .. string.rep("x", 1024 * 1024) .. '"}')
            local body = require("leanjson.proxy").from_backend(backend, root)
            local child = body.child
            child.x = 2
            return setmetatable({ body, child, backend }, { __mode = "v" })
        end
        local weak = observations()
        collectgarbage("collect"); collectgarbage("collect"); collectgarbage("collect")
        assert.is_nil(weak[1])
        assert.is_nil(weak[2])
        assert.is_nil(weak[3])
    end)

    it("rejects interior holes and noncontiguous writes without losing tail values", function()
        local body = leanjson.decode('[1,2,3]')
        assert.has_error(function() body[2] = nil end, "leanjson: sparse proxy arrays require explicit materialization")
        assert.are.equal('[1,2,3]', leanjson.encode(body))
        assert.has_error(function() body[5] = 5 end, "leanjson: sparse proxy arrays require explicit materialization")
        assert.has_error(function() body[1000000000] = 1 end, "leanjson: sparse proxy arrays require explicit materialization")
        assert.are.equal('[1,2,3]', leanjson.encode(body))
        body[4] = 4
        assert.are.equal('[1,2,3,4]', leanjson.encode(body))
        body[4] = nil
        assert.are.equal('[1,2,3]', leanjson.encode(body))
    end)

    it("inserts and removes arrays while keeping existing child identities", function()
        local body = leanjson.decode('[{"x":1},{"x":2}]')
        local second = body[2]
        leanjson.array_insert(body, 1, leanjson.null)
        second.x = 9
        assert.are.equal('[null,{"x":1},{"x":9}]', leanjson.encode(body))
        local removed = leanjson.array_remove(body, 2)
        removed.x = 8
        assert.are.equal('[null,{"x":9}]', leanjson.encode(body))
        assert.are.equal('{"x":8}', leanjson.encode(removed))
        assert.has_error(function() leanjson.array_insert(body, 0, 1) end)
        assert.has_error(function() leanjson.array_remove(body, 3) end)
    end)
end)
