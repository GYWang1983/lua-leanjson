local leanjson = require "leanjson"

describe("parse with options", function()
    it("accepts no second arg (default eager)", function()
        assert.is_not_nil(leanjson.parse('{"a":1}'))
    end)

    it("accepts an empty opts table", function()
        assert.is_not_nil(leanjson.parse('{"a":1}', {}))
    end)

    it("accepts lazy=true and tolerates trailing content", function()
        -- Trailing content is eager-only; lazy must parse OK.
        assert.is_not_nil(leanjson.parse('{}garbage', { lazy = true }))
    end)

    it("accepts max_depth", function()
        assert.is_not_nil(leanjson.parse('[[[1]]]', { max_depth = 1024 }))
    end)

    it("reports effective max_depth in nesting errors", function()
        local ok, err = pcall(leanjson.parse, '[[[1]]]', { max_depth = 2 })
        assert.is_false(ok)
        assert.is_truthy(
            string.find(tostring(err), "nesting too deep at byte 2 (max 2)", 1, true),
            tostring(err)
        )
    end)

    it("rejects invalid mode key value", function()
        assert.has_error(function()
            leanjson.parse('{}', { lazy = "yes please" })
        end)
    end)

    it("accepts lazy=true and max_depth combined", function()
        assert.is_not_nil(leanjson.parse('[[1]]', { lazy = true, max_depth = 256 }))
    end)

    it("rejects fractional max_depth", function()
        assert.has_error(function()
            leanjson.parse('{}', { max_depth = 1.5 })
        end)
    end)

    -- Depth boundaries surfaced through the wrapper (issue #140). Deterministic
    -- Rust coverage lives in tests/ffi_depth_stress.rs; here we only confirm the
    -- Lua layer propagates accept/reject at the default and ceiling limits.
    local function nested(depth)
        return string.rep("[", depth) .. "1" .. string.rep("]", depth)
    end

    it("accepts exactly the default depth of 1024", function()
        assert.is_not_nil(leanjson.parse(nested(1024)))
    end)

    it("propagates the default-depth nesting error one past 1024", function()
        local ok, err = pcall(leanjson.parse, nested(1025))
        assert.is_false(ok)
        assert.is_truthy(
            string.find(tostring(err), "nesting too deep at byte 1024 (max 1024)", 1, true),
            tostring(err)
        )
    end)

    it("propagates the default-depth nesting error in lazy mode too", function()
        local ok, err = pcall(leanjson.parse, nested(1025), { lazy = true })
        assert.is_false(ok)
        assert.is_truthy(
            string.find(tostring(err), "nesting too deep at byte 1024 (max 1024)", 1, true),
            tostring(err)
        )
    end)

    it("clamps an over-ceiling max_depth to 4096", function()
        -- A request above the 4096 ceiling behaves exactly like max_depth=4096:
        -- 4096 levels parse, 4097 fail at the clamped limit.
        assert.is_not_nil(leanjson.parse(nested(4096), { max_depth = 9000 }))
        local ok, err = pcall(leanjson.parse, nested(4097), { max_depth = 9000 })
        assert.is_false(ok)
        assert.is_truthy(
            string.find(tostring(err), "nesting too deep at byte 4096 (max 4096)", 1, true),
            tostring(err)
        )
    end)
end)
