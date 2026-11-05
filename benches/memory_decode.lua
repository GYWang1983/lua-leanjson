-- Pure decode benchmark. File reads, GC, access checks and full semantic
-- receipts are outside timed regions. One process, interleaved implementations.
local cjson, json, ffi = require("cjson"), require("leanjson"), require("ffi")
local input, trials, output = assert(arg[1]), tonumber(arg[2]) or 15, assert(arg[3])
local schema_file = arg[4] ~= "-" and arg[4] or nil
local source_mode = arg[5] or "memory"
local loading_mode = arg[6] or "lazy"
assert(source_mode == "memory" or source_mode == "feed")
assert(loading_mode == "lazy" or loading_mode == "preload" or loading_mode == "eager")
ffi.cdef[[struct leanjson_bench_timeval { long tv_sec; long tv_usec; }; int gettimeofday(void *, void *);]]
local tv = ffi.new("struct leanjson_bench_timeval[1]")
local function wall()
    assert(ffi.C.gettimeofday(tv, nil) == 0)
    return tonumber(tv[0].tv_sec) + tonumber(tv[0].tv_usec) / 1000000
end
local function read(filename)
    local file = assert(io.open(filename, "rb"))
    local value = assert(file:read("*a")); assert(file:close()); return value
end
local raw = read(input)
-- Explicit marker replacement keeps request length fixed; every timed trial
-- uses a different document. Other values are unchanged, as in the load report.
assert(raw:find("0123456789abcdef", 1, true), "fixture needs a fixed-width unique marker")
local schema = schema_file and json.compile_schema(cjson.decode(read(schema_file))) or nil
local names = {"cjson", "legacy", "cjson-scanner"}
local results = {}
local function decode(name, source)
    if name == "cjson" then return cjson.decode(source) end
    local opts = {scanner = name == "legacy" and "legacy" or "cjson", schema = schema,
        lazyload = loading_mode ~= "eager",
        preload_paths = loading_mode == "preload" and {"$.model", "$.stream", "$.messages[*].role"} or nil}
    if source_mode == "memory" then return json.decode(source, opts) end
    local decoder = json.new_decoder(opts)
    for first = 1, #source, 65536 do assert(decoder:feed(source:sub(first, first + 65535))) end
    local value = assert(decoder:finish()); decoder:close(); return value
end
local function run(name, source, trial)
    collectgarbage("collect"); collectgarbage("collect")
    local began_wall, began_cpu = wall(), os.clock()
    local value = decode(name, source)
    local cpu = os.clock() - began_cpu
    local elapsed = wall() - began_wall
    assert(type(value.model) == "string")
    if name ~= "cjson" then json.close(value) end
    if trial > 0 then results[#results + 1] = {name = name, trial = trial, bytes = #source, cpu = cpu, wall = elapsed} end
end
for _ = 1, 3 do for _, name in ipairs(names) do run(name, raw, 0) end end
for trial = 1, trials do
    local token = string.format("%016x", trial)
    local source, count = raw:gsub("0123456789abcdef", token, 1)
    assert(count == 1 and #source == #raw)
    -- Rotate and reverse so every implementation occupies every position.
    for position = 1, 3 do
        local index = trial % 2 == 0 and (trial - position) % 3 + 1 or (trial + position) % 3 + 1
        run(names[index], source, trial)
    end
end
-- Full decode/encode receipts follow all timings, so no oracle tree or decoded
-- large strings are held alive and interned during the measured calls.
for _, name in ipairs(names) do
    collectgarbage("collect"); collectgarbage("collect")
    local value = decode(name, raw)
    local encoded = name == "cjson" and cjson.encode(value) or json.encode(value)
    local file = assert(io.open(output .. "/" .. name .. "-output.json", "wb"))
    assert(file:write(encoded)); assert(file:close())
    if name ~= "cjson" then json.close(value) end
end
print(cjson.encode({measurements = results, cjson_name = cjson._NAME, cjson_version = cjson._VERSION,
    leanjson_name = json._NAME, leanjson_version = json._VERSION, luajit = jit.version,
    schema = schema_file ~= nil, source_mode = source_mode, loading_mode = loading_mode, methodology = "pre-read fixed-size unique-per-trial input; two GCs before each call; 3 warmups; interleaved order; only decode timed; full output oracle after all trials"}))
