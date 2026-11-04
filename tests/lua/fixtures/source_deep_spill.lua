package.path = "./lua/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[
struct leanjson_test_rlimit { unsigned long current; unsigned long maximum; };
int getrlimit(int resource, struct leanjson_test_rlimit *limit);
int setrlimit(int resource, const struct leanjson_test_rlimit *limit);
]]
local limit = ffi.new("struct leanjson_test_rlimit[1]")
local resource = ffi.os == "OSX" and 8 or 7
assert(ffi.C.getrlimit(resource, limit) == 0)
-- Set the soft limit in this VM: Valgrind's traced exec can reset an inherited
-- shell limit, and lowering the hard limit conflicts with its reserved FDs.
limit[0].current = 64
assert(ffi.C.setrlimit(resource, limit) == 0, "cannot set deep spill descriptor limit")
assert(ffi.C.getrlimit(resource, limit) == 0)
assert(tonumber(limit[0].current) == 64, "deep spill fixture requires a 64-descriptor soft limit")
local json = require("leanjson")
local raw, expected = 'null', 'null'
for _ = 1, 48 do
    raw = '{"child":' .. raw .. ',"a":0,"b":1,"c":2,"d":3,"e":4,"f":5,"g":6,"h":7,"i":8,"a":9}'
    expected = '{"child":' .. expected .. ',"a":9,"b":1,"c":2,"d":3,"e":4,"f":5,"g":6,"h":7,"i":8}'
end
for _, mode in ipairs({ "memory", "file", "feed" }) do
    local body
    if mode == "memory" then body = json.decode(raw, { index_budget_bytes = 0 })
    elseif mode == "file" then
        local filename = os.tmpname()
        local output = assert(io.open(filename, "wb"))
        output:write(raw); output:close()
        body = json.decode_file(filename, { index_budget_bytes = 0, chunk_size = 7 })
        os.remove(filename)
    else
        local input = json.new_decoder({ index_budget_bytes = 0, chunk_size = 7 })
        assert(input:feed(raw)); body = assert(input:finish()); input:close()
    end
    local reader = json.reader(body, { normalize_duplicates = true, chunk_size = 31 })
    local length, length_error = reader:length()
    assert(length == #expected, length_error or "incorrect output length")
    local pieces = {}
    while true do
        local chunk, err = reader:next()
        assert(not err, err)
        if not chunk then break end
        pieces[#pieces + 1] = chunk
    end
    assert(table.concat(pieces) == expected)
    json.close(body)
end
