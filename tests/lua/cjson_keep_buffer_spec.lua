local json = require("leanjson")
local safe = require("leanjson.safe")

local function collect(codec, value)
    local reader, parts = codec.reader(value, { chunk_size = 7 }), {}
    local length, err = reader:length()
    assert.is_nil(err)
    while true do
        local chunk, failure = reader:next()
        assert.is_nil(failure)
        if not chunk then break end
        assert.is_true(#chunk <= 7)
        parts[#parts + 1] = chunk
    end
    local result = table.concat(parts)
    assert.equal(#result, length)
    return result
end

describe("cjson encode_keep_buffer compatibility setting", function()
    it("exports a true-default getter on module and codec surfaces", function()
        for _, codec in ipairs({ json, safe, require("leanjson.table"), json.new(), safe.new() }) do
            assert.is_function(codec.encode_keep_buffer)
            assert.is_true(codec.encode_keep_buffer())
            assert.is_true(codec.encode_keep_buffer(nil))
            assert.equal(1, select("#", codec.encode_keep_buffer()))
        end
    end)

    for name, factory in pairs({ normal = json.new, safe = safe.new }) do
        it("normalizes boolean and native option values for " .. name, function()
            local codec = factory()
            assert.is_function(codec.encode_keep_buffer)
            for _, case in ipairs({
                { false, false }, { "on", true }, { "off", false }, { true, true },
                { "off\0ignored", false }, { "on\0ignored", true },
            }) do
                assert.equal(case[2], codec.encode_keep_buffer(case[1]))
                assert.equal(case[2], codec.encode_keep_buffer())
                assert.equal(case[2], codec.encode_keep_buffer(nil))
            end
        end)

        it("throws on invalid arguments without updating " .. name .. " state", function()
            local codec = factory()
            assert.is_function(codec.encode_keep_buffer)
            codec.encode_keep_buffer(false)
            for _, case in ipairs({
                { { "ON" }, 1, "bad argument #1 to '?' (invalid option 'ON')" },
                { { 1 }, 1, "bad argument #1 to '?' (invalid option '1')" },
                { { {} }, 1, "bad argument #1 to '?' (string expected, got table)" },
                { { function() end }, 1, "bad argument #1 to '?' (string expected, got function)" },
                { { nil, true }, 2, "bad argument #2 to '?' (found too many arguments)" },
                { { true, nil }, 2, "bad argument #2 to '?' (found too many arguments)" },
            }) do
                local ok, err = pcall(codec.encode_keep_buffer, unpack(case[1], 1, case[2]))
                assert.is_false(ok)
                assert.equal(case[3], err)
                assert.is_false(codec.encode_keep_buffer())
            end
        end)
    end

    it("isolates settings and starts child instances from defaults", function()
        local a, b, s = json.new(), json.new(), safe.new()
        assert.is_function(a.encode_keep_buffer)
        assert.is_function(s.encode_keep_buffer)
        a.encode_keep_buffer(false)
        s.encode_keep_buffer(false)
        assert.is_false(a.encode_keep_buffer())
        assert.is_false(s.encode_keep_buffer())
        for _, codec in ipairs({ json, safe, b, a.new(), s.new() }) do
            assert.is_true(codec.encode_keep_buffer())
        end
    end)

    it("leaves repeated large and small ordinary encodes unchanged", function()
        local large = string.rep("abcdef", 32768)
        local expected = '["' .. large .. '",1]'
        for _, factory in ipairs({ json.new, safe.new }) do
            local codec = factory()
            assert.is_function(codec.encode_keep_buffer)
            for _, enabled in ipairs({ false, true, false }) do
                codec.encode_keep_buffer(enabled)
                assert.equal(expected, codec.encode({ large, 1 }))
                assert.equal('["small",2]', codec.encode({ "small", 2 }))
            end
        end
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
        for _, mode in ipairs({ "lazy", "eager", "preload" }) do
            it("keeps full and reader output unchanged for " .. source .. "/" .. mode, function()
                for _, factory in ipairs({ json.new, safe.new }) do
                    local codec = factory()
                    assert.is_function(codec.encode_keep_buffer)
                    local raw = '[1,{"s":"original"},3]'
                    local opts = { lazyload = mode ~= "eager", index_depth = 0,
                        index_array_limit = 0, index_budget_bytes = 0,
                        preload_paths = mode == "preload" and { "$[1].s" } or nil }
                    local value
                    if source == "memory" then value = assert(codec.decode(raw, opts))
                    elseif source == "file" then
                        local path = os.tmpname()
                        local file = assert(io.open(path, "wb"))
                        assert(file:write(raw)); file:close()
                        local ok, result = pcall(codec.decode_file, path, opts)
                        os.remove(path); assert.is_true(ok); value = assert(result)
                    else
                        local decoder = assert(codec.new_decoder(opts))
                        for i = 1, #raw do assert(decoder:feed(raw:sub(i, i))) end
                        value = assert(decoder:finish()); decoder:close()
                    end
                    value[2].s = "changed"
                    codec.encode_keep_buffer(false)
                    local reader = codec.reader(value, { chunk_size = 2 })
                    codec.encode_keep_buffer(true)
                    local expected = '[1,{"s":"changed"},3]'
                    assert.equal(expected, codec.encode(value))
                    assert.equal(expected, collect(codec, value))
                    local parts = {}
                    while true do
                        local chunk, err = reader:next(); assert.is_nil(err)
                        if not chunk then break end
                        parts[#parts + 1] = chunk
                    end
                    assert.equal(expected, table.concat(parts))
                    codec.encode_keep_buffer(false)
                    assert.equal(expected, codec.encode(value))
                    codec.close(value)
                end
            end)
        end
    end
end)
