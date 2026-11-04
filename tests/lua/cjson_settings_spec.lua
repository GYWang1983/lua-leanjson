local json = require("leanjson")

describe("cjson-compatible codec settings", function()
    it("sets precision across 1 through 16 and returns the new value", function()
        local a, b = json.new(), json.new()
        for _, p in ipairs({ 1, 3, 14, 15, 16 }) do
            assert.equal(p, a.encode_number_precision(p))
            assert.equal(p, a.encode_number_precision())
        end
        assert.equal(14, b.encode_number_precision())
        assert.equal(3, a.encode_number_precision("3.9"))
        assert.equal(15, a.encode_number_precision(15.9))
        assert.equal(15, a.encode_number_precision(nil))
    end)

    it("rejects invalid precision and excess arguments without mutating settings", function()
        local c = json.new()
        c.encode_number_precision(3)
        for _, v in ipairs({ 0, -1, 17, 0/0, math.huge, "no", true, {}, 4294967297 }) do
            assert.has_error(function() c.encode_number_precision(v) end)
            assert.equal(3, c.encode_number_precision())
        end
        assert.has_error(function() c.encode_number_precision(14, nil) end)
        assert.equal(3, c.encode_number_precision())
    end)

    it("formats integers, negative zero, large doubles and rewritten proxy tokens", function()
        local c = json.new()
        c.encode_number_precision(3)
        assert.equal("1.23e+13", c.encode(12345678901234))
        -- Older LuaJIT parsers fold the literal -0.0 to positive zero.
        assert.equal("-0", c.encode(-1 / math.huge))
        c.encode_number_precision(16)
        assert.equal("9007199254740992", c.encode(2^53))
        local body = c.decode('{"n":9007199254740993,"new":0}')
        body.new = 2^53
        assert.equal('{"n":9007199254740993,"new":9007199254740992}', c.encode(body))
        local r = c.reader(body, { chunk_size = 3 })
        c.encode_number_precision(3)
        local parts = {}
        while true do
            local chunk, err = r:next()
            assert.is_nil(err)
            if not chunk then break end
            parts[#parts + 1] = chunk
        end
        assert.equal('{"n":9007199254740993,"new":9007199254740992}', table.concat(parts))
        c.close(body)
    end)

    it("accepts sparse boolean and exact on/off options", function()
        local c = json.new()
        for _, value in ipairs({ true, "on", false, "off" }) do
            local enabled = value == true or value == "on"
            assert.same({ enabled, 2, 10 }, { c.encode_sparse_array(value) })
        end
        assert.same({ true, 3, 16 }, { c.encode_sparse_array("on", "3.9", "0x10") })
        assert.same({ true, 0, 2147483647 }, { c.encode_sparse_array(nil, -0.5, 2147483647) })
        assert.same({ true, 0, 2147483647 }, { c.encode_sparse_array() })
    end)

    it("rejects invalid sparse values atomically including later arguments", function()
        local c = json.new()
        c.encode_sparse_array(false, 2, 10)
        for _, v in ipairs({ "not quite on", "ON", "true", 0, 1, {} }) do
            assert.has_error(function() c.encode_sparse_array(v) end)
            assert.same({ false, 2, 10 }, { c.encode_sparse_array() })
        end
        for _, v in ipairs({ -1, 2147483648, 4294967296, math.huge, 0/0, false, "no" }) do
            assert.has_error(function() c.encode_sparse_array(true, v, 5) end)
            assert.has_error(function() c.encode_sparse_array(true, 4, v) end)
            assert.same({ false, 2, 10 }, { c.encode_sparse_array() })
        end
        assert.has_error(function() c.encode_sparse_array(true, 4, 5, nil) end)
        assert.same({ false, 2, 10 }, { c.encode_sparse_array() })
    end)

    it("uses sparse policy in real ordinary and lazy assignment paths", function()
        local c = json.new()
        local value = { [100] = 1 }
        assert.has_error(function() c.encode(value) end)
        c.encode_sparse_array("on")
        assert.equal('{"100":1}', c.encode(value))
        local body = c.decode('{}')
        body.value = value
        assert.equal('{"value":{"100":1}}', c.encode(body))
        c.encode_sparse_array("off", 0)
        assert.matches('null,1%]$', c.encode(value))
        c.close(body)
    end)
end)
