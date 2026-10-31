-- Bounded deterministic differential mutation stress. This complements, and
-- does not substitute for, the separately named nightly libFuzzer gate.
local qjson = require "qjson"
local cjson = require "cjson"
local cases = tonumber(os.getenv("QJSON_SOURCE_STRESS_CASES")) or 500
local seed = tonumber(os.getenv("QJSON_SOURCE_STRESS_SEED")) or 760076
local initial_seed = seed
local function random(maximum)
    seed = (seed * 48271) % 2147483647
    return seed % maximum + 1
end
local function streamed(raw, size)
    local decoder = qjson.new_decoder { chunk_size = size }
    for offset = 1, #raw, size do
        local ok, err = decoder:feed(raw:sub(offset, offset + size - 1))
        if not ok then decoder:close(); return nil, err end
    end
    local value, err = decoder:finish()
    decoder:close()
    return value, err
end
local function encode(value, size)
    local reader = qjson.reader(value, { chunk_size = size, normalize_duplicates = true })
    local length = assert(reader:length())
    local output, total = {}, 0
    while true do
        local chunk, err = reader:next()
        assert(not err, err)
        if not chunk then break end
        assert(#chunk <= size)
        output[#output + 1] = chunk
        total = total + #chunk
    end
    reader:close()
    assert(length == total)
    return table.concat(output)
end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, child in pairs(a) do if not same(child, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
for i = 1, cases do
    local expected = { model = "old", prompt = ("a\n\"\\\t"):rep(random(500)),
        items = { random(10000), false, cjson.null, "\240\159\152\128" } }
    local raw = cjson.encode(expected)
    local size = random(257)
    local value, err = streamed(raw, size)
    assert(value ~= nil, err)
    local branch = qjson.fork(value)
    qjson.close(value)
    branch.model = "new"
    expected.model = "new"
    local result = cjson.decode(encode(branch, random(257)))
    qjson.close(branch)
    assert(same(result, expected), "streamed value mismatch at case " .. i)

    local position = random(#raw)
    local mutated = raw:sub(1, position - 1) .. string.char(random(256) - 1) .. raw:sub(position + 1)
    local accepted, contiguous = pcall(qjson.decode, mutated)
    local streamed_value, streamed_err = streamed(mutated, random(257))
    assert(accepted == (streamed_err == nil), "contiguous/source verdict mismatch at case " .. i)
    if accepted then
        assert(same(cjson.decode(encode(contiguous, size)), cjson.decode(encode(streamed_value, size))),
            "mutation output mismatch at case " .. i)
        qjson.close(contiguous)
        qjson.close(streamed_value)
    end
end
print("source stress: " .. cases .. " valid + " .. cases .. " mutated cases; seed " .. initial_seed)
