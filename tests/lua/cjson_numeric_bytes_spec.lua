local json = require("leanjson")
local safe = require("leanjson.safe")

local function read_all(reader)
    local parts = {}
    while true do
        local chunk, err = reader:next()
        assert.is_nil(err)
        if not chunk then break end
        parts[#parts + 1] = chunk
    end
    return table.concat(parts)
end

local function assert_encode_error(codec, protected, value)
    if protected then
        local encoded, err = codec.encode(value)
        assert.is_nil(encoded)
        assert.is_string(err)
    else
        assert.has_error(function() codec.encode(value) end)
    end
end

local bytes = {}
for byte = 0, 255 do bytes[#bytes + 1] = string.char(byte) end
local ALL_BYTES = table.concat(bytes)
-- Literal ASCII prefix from the pinned OpenResty cjson all-octets output.
-- Bytes 128..255 are copied verbatim, including invalid UTF-8 sequences.
local ALL_BYTES_ENCODED = [=["\u0000\u0001\u0002\u0003\u0004\u0005\u0006\u0007\b\t\n\u000b\f\r\u000e\u000f\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001a\u001b\u001c\u001d\u001e\u001f !\"#$%&'()*+,-.\/0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\u007f]=]
    .. ALL_BYTES:sub(129) .. '"'

for _, entry in ipairs({ { name = "normal", module = json }, { name = "safe", module = safe, protected = true } }) do
    describe("cjson number and byte codec settings (" .. entry.name .. ")", function()
        it("starts each codec with native-compatible independent defaults", function()
            local a, b = entry.module.new(), entry.module.new()
            assert.is_true(a.decode_invalid_numbers())
            assert.is_false(a.decode_validate_utf8())
            assert.is_false(a.encode_invalid_numbers())
            assert.is_true(a.encode_escape_forward_slash())
            a.decode_invalid_numbers(false)
            a.decode_validate_utf8(true)
            a.encode_invalid_numbers("null")
            a.encode_escape_forward_slash(false)
            for _, c in ipairs({ b, a.new() }) do
                assert.is_true(c.decode_invalid_numbers())
                assert.is_false(c.decode_validate_utf8())
                assert.is_false(c.encode_invalid_numbers())
                assert.is_true(c.encode_escape_forward_slash())
            end
            assert.equal('"\\/\\u007f"', b.encode("/\127"))
            assert_encode_error(b, entry.protected, math.huge)
        end)

        it("normalizes boolean/on/off values and leaves each field isolated", function()
            local c = entry.module.new()
            local names = { "decode_invalid_numbers", "decode_validate_utf8", "encode_invalid_numbers", "encode_escape_forward_slash" }
            for _, name in ipairs(names) do
                for _, value in ipairs({ false, "on", true, "off" }) do
                    local expected = value == true or value == "on"
                    assert.equal(expected, c[name](value))
                    assert.equal(expected, c[name]())
                    assert.equal(expected, c[name](nil))
                end
            end
            assert.equal("null", c.encode_invalid_numbers("null"))
            assert.equal("null", c.encode_invalid_numbers(nil))
            assert.is_false(c.decode_invalid_numbers())
            assert.is_false(c.decode_validate_utf8())
            assert.is_false(c.encode_escape_forward_slash())
        end)

        it("rejects invalid setting values and extra arguments without mutation", function()
            local c = entry.module.new()
            for _, name in ipairs({ "decode_invalid_numbers", "decode_validate_utf8", "encode_invalid_numbers", "encode_escape_forward_slash" }) do
                c[name](true)
                for _, value in ipairs({ "ON", "true", 0, 1, {}, function() end }) do
                    assert.has_error(function() c[name](value) end)
                    assert.is_true(c[name]())
                end
                assert.has_error(function() c[name](false, nil) end,
                    "bad argument #2 to '?' (found too many arguments)")
                assert.is_true(c[name]())
                assert.has_error(function() c[name]({}) end,
                    "bad argument #1 to '?' (string expected, got table)")
                assert.has_error(function() c[name]("ON") end,
                    "bad argument #1 to '?' (invalid option 'ON')")
                if name ~= "encode_invalid_numbers" then
                    assert.has_error(function() c[name]("null") end)
                    assert.is_true(c[name]())
                end
            end
        end)

        it("formats nonfinite numbers independently of number precision", function()
            local c = entry.module.new()
            local values = { 0/0, math.huge, -math.huge }
            for _, precision in ipairs({ 1, 14, 16 }) do
                c.encode_number_precision(precision)
                c.encode_invalid_numbers(true)
                for i, token in ipairs({ "NaN", "Infinity", "-Infinity" }) do
                    assert.equal(token, c.encode(values[i]))
                end
                assert.equal("[NaN,Infinity,-Infinity]", c.encode(values))
                c.encode_invalid_numbers("null")
                assert.equal("[null,null,null]", c.encode(values))
                c.encode_invalid_numbers(false)
                for _, value in ipairs(values) do assert_encode_error(c, entry.protected, value) end
            end
        end)

        it("applies precision and nonfinite policy to numeric object keys", function()
            local c = entry.module.new()
            c.encode_number_precision(3)
            assert.equal('{"-1.23e+04":1}', c.encode({ [-12345.6789] = 1 }))
            c.encode_sparse_array(true)
            for _, key in ipairs({ math.huge, -math.huge }) do
                assert_encode_error(c, entry.protected, { [key] = 1 })
            end
            c.encode_invalid_numbers(true)
            assert.equal('{"Infinity":1}', c.encode({ [math.huge] = 1 }))
            assert.equal('{"-Infinity":1}', c.encode({ [-math.huge] = 1 }))
            c.encode_invalid_numbers("null")
            assert.equal('{"null":1}', c.encode({ [math.huge] = 1 }))
            assert.equal('{"null":1}', c.encode({ [-math.huge] = 1 }))
        end)

        it("uses numeric key policy when snapshotting readers and lazy assignments", function()
            local c = entry.module.new()
            c.decode_invalid_numbers(false)
            c.decode_validate_utf8(true)
            c.encode_number_precision(3)
            c.encode_invalid_numbers(true)
            local reader = c.reader({ [-math.huge] = 1 }, { chunk_size = 2 })
            c.encode_invalid_numbers("null")
            assert.equal('{"-Infinity":1}', read_all(reader))
            local finite = c.reader({ [-12345.6789] = 1 })
            c.encode_number_precision(16)
            assert.equal('{"-1.23e+04":1}', read_all(finite))

            local body = c.decode('{}')
            body.value = { [-math.huge] = 1 }
            assert.equal('{"value":{"null":1}}', c.encode(body))
            c.encode_invalid_numbers(true)
            body.value = { [-math.huge] = 1 }
            assert.equal('{"value":{"-Infinity":1}}', c.encode(body))
            c.encode_invalid_numbers(false)
            assert.has_error(function() body.value = { [-math.huge] = 1 } end)
            assert.equal('{"value":{"-Infinity":1}}', c.encode(body))
            c.close(body)
        end)

        it("encodes all 256 bytes exactly like the pinned native default", function()
            local c = entry.module.new()
            assert.equal(ALL_BYTES_ENCODED, c.encode(ALL_BYTES))
        end)

        it("applies slash mode and DEL escaping to both object keys and values", function()
            local c = entry.module.new()
            local value = { ["/\127"] = "a/b\127" }
            assert.equal('{"\\/\\u007f":"a\\/b\\u007f"}', c.encode(value))
            c.encode_escape_forward_slash(false)
            assert.equal('{"/\\u007f":"a/b\\u007f"}', c.encode(value))
            c.encode_escape_forward_slash(true)
            assert.equal('{"\\/\\u007f":"a\\/b\\u007f"}', c.encode(value))
        end)

        it("freezes nonfinite and slash settings when constructing a reader", function()
            local c = entry.module.new()
            c.encode_invalid_numbers("null")
            local reader = c.reader({ "/\127", math.huge }, { chunk_size = 1 })
            c.encode_invalid_numbers(false)
            c.encode_escape_forward_slash(false)
            local expected = '["\\/\\u007f",null]'
            assert.equal(#expected, reader:length())
            assert.equal(expected, read_all(reader))

            c.encode_invalid_numbers(true)
            local unescaped = c.reader({ "/", -math.huge }, { chunk_size = 2 })
            c.encode_invalid_numbers("null")
            c.encode_escape_forward_slash(true)
            assert.equal('["/",-Infinity]', read_all(unescaped))
        end)

        it("counts and streams every byte using the frozen escape policy", function()
            local c = entry.module.new()
            local reader = c.reader(ALL_BYTES, { chunk_size = 1 })
            c.encode_escape_forward_slash(false)
            assert.equal(#ALL_BYTES_ENCODED, reader:length())
            assert.equal(ALL_BYTES_ENCODED, read_all(reader))
        end)

        it("does not reuse keep_origin strings containing decoded slash or DEL", function()
            local c = entry.module.new()
            c.decode_invalid_numbers(false)
            c.decode_validate_utf8(true)
            local raw_value = string.rep("\\u002f", 12) .. "\\u007F"
            local body = c.decode('{"blob":"' .. raw_value .. '","x":1}')
            local plain = c.materialize(body, { keep_origin = true })
            plain.x = 2
            assert.equal('{"blob":"' .. string.rep("\\/", 12) .. '\\u007f","x":2}', c.encode(plain))
            c.encode_escape_forward_slash(false)
            assert.equal('{"blob":"' .. string.rep("/", 12) .. '\\u007f","x":2}', c.encode(plain))
            c.close(body)
        end)

        it("invalidates recursive keep_origin container reuse for affected keys", function()
            local c = entry.module.new()
            c.decode_invalid_numbers(false)
            c.decode_validate_utf8(true)
            local raw_value = string.rep("\\u0061", 12)
            local body = c.decode('{ "outer" : { "\\u002f\\u007F" : "' .. raw_value .. '" } }')
            local plain = c.materialize(body, { keep_origin = true })
            assert.equal('{"outer":{"\\/\\u007f":"' .. raw_value .. '"}}', c.encode(plain))
            c.encode_escape_forward_slash(false)
            assert.equal('{"outer":{"/\\u007f":"' .. raw_value .. '"}}', c.encode(plain))
            c.close(body)
        end)
    end)
end

describe("public codec number and byte settings", function()
    it("exports setters on both default modules", function()
        for _, module in ipairs({ json, safe }) do
            assert.is_function(module.decode_invalid_numbers)
            assert.is_function(module.decode_validate_utf8)
            assert.is_function(module.encode_invalid_numbers)
            assert.is_function(module.encode_escape_forward_slash)
        end
    end)
end)
