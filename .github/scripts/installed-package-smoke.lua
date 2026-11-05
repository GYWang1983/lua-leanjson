-- Run outside the checkout with LUA_PATH/LUA_CPATH restricted to the installed tree.
local leanjson = require("leanjson")
local input = require("leanjson.openresty")
assert(type(input.read_body) == "function")
assert(type(input.start_body) == "function")
assert(type(input.request) == "function")

do
    local doc = leanjson.parse('{"a":42}')
    assert(tonumber(doc:get_i64("a")) == 42)
end

local raw = '{"model":"original","nested":{"n":42},"items":[false,null]}'
local memory = leanjson.decode(raw)
assert(memory.model == "original")
leanjson.close(memory)

local path = os.tmpname()
local file = assert(io.open(path, "wb"))
assert(file:write(raw))
assert(file:close())
local ok, failure = pcall(function()
    local body = leanjson.decode_file(path, { chunk_size = 3 })
    local branch = leanjson.fork(body)
    leanjson.close(body)
    local nested = leanjson.get(branch, "nested")
    nested.n = 43
    assert(nested.n == 43)
    leanjson.close(nested)
    branch.model = "rewritten"
    assert(leanjson.len(branch, "$.model") == #"rewritten")
    assert(leanjson.len(branch, "$.items") == 2)
    assert(leanjson.exists(branch, "$.items[0]"))
    assert(leanjson.is_empty(branch, "$.items[0]"))
    assert(leanjson.exists(branch, "$.items[1]"))
    assert(not leanjson.is_empty(branch, "$.items[1]"))
    assert(not leanjson.exists(branch, "$.missing"))
    assert(leanjson.is_empty(branch, "$.missing"))
    local reader = leanjson.reader(branch, { chunk_size = 7, normalize_duplicates = true })
    leanjson.close(branch)
    local length = assert(reader:length())
    local parts = {}
    while true do
        local chunk, err = reader:next()
        assert(not err, err)
        if chunk == nil then break end
        assert(#chunk <= 7)
        parts[#parts + 1] = chunk
    end
    reader:close()
    local encoded = table.concat(parts)
    assert(#encoded == length)
    local result = leanjson.decode(encoded)
    assert(result.model == "rewritten")
    local result_nested = leanjson.get(result, "nested")
    assert(result_nested.n == 43)
    leanjson.close(result_nested)
    local result_items = leanjson.get(result, "items")
    assert(result_items[1] == false)
    assert(result_items[2] == leanjson.null)
    leanjson.close(result_items)
    leanjson.close(result)
end)
assert(os.remove(path))
assert(ok, failure)

local decoder = leanjson.new_decoder({ chunk_size = 2 })
for byte in raw:gmatch(".") do assert(decoder:feed(byte)) end
local body, err = decoder:finish()
assert(not err, err)
local model, status = decoder:get("model")
assert(model == "original" and status == "READY")
local branch = leanjson.fork(body)
decoder:close()
leanjson.close(body)
assert(branch.model == "original")
leanjson.close(branch)
local source = leanjson.decode('{"prompt":"reference","flag":false}')
local reference = leanjson.ref(source, "$.prompt")
local target = leanjson.decode('{}')
target.messages = { { role = "user", content = reference } }
assert(leanjson.type(reference) == "string")
assert(leanjson.len(reference) == #"reference")
leanjson.close(source); leanjson.close(reference)
local mapped = leanjson.decode(leanjson.encode(target))
assert(leanjson.len(mapped) == 1)
assert(leanjson.len(mapped, "messages") == 1)
assert(leanjson.len(mapped, "messages[0]") == 2)
assert(leanjson.get(mapped, "messages[0].role") == "user")
assert(leanjson.get(mapped, "messages[0].content") == "reference")
leanjson.close(mapped)
leanjson.close(target)
for _, codec in ipairs({ leanjson.new(), require("leanjson.safe"), require("leanjson.safe").new() }) do
    local ref = codec.ref("installed")
    assert(codec.encode(ref) == '"installed"')
    leanjson.close(ref)
end
print("Installed LeanJSON memory/file/feed/fork/get/ref/query/reader/close and OpenResty imports passed")
