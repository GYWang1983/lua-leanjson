local leanjson = require("leanjson")

local function assert_invalid_precision(value)
    local ok, err = pcall(leanjson.encode_number_precision, value)
    assert.is_false(ok)
    if type(value) == "number" then
        assert.matches("expected integer between 1 and 16", tostring(err))
    else
        assert.matches("number expected", tostring(err))
    end
end

local function with_precision(precision, fn)
    local old = leanjson.encode_number_precision()
    leanjson.encode_number_precision(precision)
    local ok, err = pcall(fn)
    leanjson.encode_number_precision(old)
    if not ok then
        error(err, 0)
    end
end

describe("leanjson.encode_number_precision", function()
    it("defaults to precision 14", function()
        assert.are.equal(14, leanjson.encode_number_precision())
    end)

    it("sets precision and returns the new value", function()
        with_precision(14, function()
            local old = leanjson.encode_number_precision(3)
            assert.are.equal(3, old)
            assert.are.equal(3, leanjson.encode_number_precision())

            local old_again = leanjson.encode_number_precision(14)
            assert.are.equal(14, old_again)
            assert.are.equal(14, leanjson.encode_number_precision())
        end)
    end)

    it("accepts boundary values 1 and 14", function()
        with_precision(14, function()
            assert.are.equal(1, leanjson.encode_number_precision(1))
            assert.are.equal(1, leanjson.encode_number_precision())
            assert.are.equal(14, leanjson.encode_number_precision(14))
            assert.are.equal(14, leanjson.encode_number_precision())
        end)
    end)

    it("rejects invalid precision values with the expected message", function()
        with_precision(14, function()
            assert_invalid_precision(-1)
            assert_invalid_precision(0)
            assert_invalid_precision(0.5)
            assert_invalid_precision(17)
            assert_invalid_precision("three")
            assert_invalid_precision(true)
            assert_invalid_precision({})
            assert.are.equal(14, leanjson.encode_number_precision())
        end)
    end)

    it("uses precision for floating-point encoding", function()
        local n = 1 / 3
        with_precision(5, function()
            assert.are.equal(string.format("%.5g", n), leanjson.encode(n))
        end)
        with_precision(12, function()
            assert.are.equal(string.format("%.12g", n), leanjson.encode(n))
        end)
    end)

    it("applies configured precision to integer numbers", function()
        local n = 12345678901234
        with_precision(1, function()
            assert.are.equal(string.format("%.1g", n), leanjson.encode(n))
        end)
        with_precision(14, function()
            assert.are.equal(string.format("%d", n), leanjson.encode(n))
        end)
    end)

    it("preserves raw numbers until explicitly replaced in dirty lazy proxies", function()
        with_precision(4, function()
            local lazy = leanjson.decode('{"n":3.141592653589793,"k":1}')
            lazy.k = 2
            assert.are.equal('{"n":3.141592653589793,"k":2}', leanjson.encode(lazy))
            lazy.n = lazy.n
            assert.are.equal('{"n":3.142,"k":2}', leanjson.encode(lazy))
        end)
    end)

    it("uses configured precision for dirty lazy proxy tostring", function()
        with_precision(2, function()
            local lazy = leanjson.decode('{"n":3.141592653589793}')
            lazy.n = 3.141592653589793
            assert.are.equal('{"n":3.1}', tostring(lazy))
        end)
    end)

    it("keeps clean lazy proxy fast path as original bytes", function()
        with_precision(2, function()
            local src = '{"n":3.141592653589793,"arr":[0.12345678901234567]}'
            local lazy = leanjson.decode(src)
            assert.are.equal(src, leanjson.encode(lazy))
            assert.are.equal(src, tostring(lazy))
        end)
    end)
end)
