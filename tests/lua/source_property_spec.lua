local leanjson = require("leanjson")
local cjson = require("cjson")
local prop = require("tests.lua.property_json")
local lfs = require("lfs")

local function drain(value, normalized)
    local reader = leanjson.reader(value, { chunk_size = 7, normalize_duplicates = normalized })
    local length, err = reader:length()
    assert.is_nil(err)
    local parts = {}
    while true do
        local chunk, read_error = reader:next()
        assert.is_nil(read_error)
        if not chunk then break end
        assert.is_true(#chunk <= 7)
        parts[#parts + 1] = chunk
    end
    local raw = table.concat(parts)
    assert.are.equal(length, #raw)
    return raw
end

describe("file and feed source differential coverage", function()
    local filename
    before_each(function() filename = os.tmpname() end)
    after_each(function() os.remove(filename) end)

    it("matches generated values, frozen forks and edited output across bounded windows", function()
        local rng = prop.rng(2026103102)
        for i = 1, 100 do
            local nested = prop.encode_json(prop.gen_container(rng))
            local raw = '{"value":' .. nested .. ',"tag":"old","array":[false,null,{"x":1}]}'
            local file = assert(io.open(filename, "wb"))
            file:write(raw)
            file:close()
            local decoder = leanjson.new_decoder({ chunk_size = i % 11 + 1 })
            local position = 1
            while position <= #raw do
                local last = math.min(#raw, position + rng:int(17))
                assert.is_true(decoder:feed(raw:sub(position, last)))
                position = last + 1
            end
            local feed, err = decoder:finish()
            assert.is_nil(err)
            local disk = leanjson.decode_file(filename, { chunk_size = i % 13 + 1 })
            local frozen = leanjson.fork(disk)
            disk.tag = "new"
            feed.tag = "new"
            local expected = cjson.decode('{"value":' .. nested .. ',"tag":"new","array":[false,null,{"x":1}]}')
            assert.are.same(expected, cjson.decode(drain(disk, true)))
            assert.are.same(expected, leanjson.materialize(feed))
            assert.are.same(cjson.decode(raw), cjson.decode(drain(frozen, false)))
            decoder:close()
            leanjson.close(disk)
            leanjson.close(feed)
            leanjson.close(frozen)
        end
    end)

    it("accepts every required-valid and rejects every required-invalid JSONTestSuite file", function()
        local base = "tests/vendor/JSONTestSuite/test_parsing/"
        local valid, invalid = 0, 0
        for name in lfs.dir(base) do
            local requirement = name:sub(1, 2)
            if requirement == "y_" or requirement == "n_" then
                local ok, value = pcall(leanjson.decode_file, base .. name, { chunk_size = 3 })
                if requirement == "y_" then
                    assert.is_true(ok, name .. ": " .. (ok and "" or tostring(value)))
                    leanjson.close(value)
                    valid = valid + 1
                else
                    assert.is_false(ok, name)
                    invalid = invalid + 1
                end
            end
        end
        assert.are.equal(95, valid)
        assert.are.equal(188, invalid)
    end)
end)
