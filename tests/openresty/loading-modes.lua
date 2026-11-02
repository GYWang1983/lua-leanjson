-- Independent public-API workload. Fixtures and typed output oracles live in
-- verify-loading.py, outside this fresh native OpenResty process.
local mode, source, scenario = assert(arg[1]), assert(arg[2]), assert(arg[3])
local input, output = assert(arg[4]), assert(arg[5])
assert(mode == "cjson" or mode == "eager" or mode == "preload")
assert(source == "memory" or source == "file" or source == "feed")
local cjson = require "cjson"
local json = mode ~= "cjson" and require("leanjson") or nil
local metrics = require "metrics"
if mode == "cjson" then
    assert(not package.loaded.leanjson and not package.loaded["leanjson.lib"])
    cjson.decode_array_with_array_mt(true) -- retain empty-array identity for the typed oracle
end
local reads = 0
local options = { chunk_size = 65536, index_depth = 0,
    index_array_limit = 0, index_budget_bytes = 0,
    on_chunk = function() reads = reads + 1 end }
if mode == "eager" then options.lazyload = false end
if mode == "preload" then
    options.preload_paths = scenario == "wildcards" and { "$.model", "$.items[*].role" }
        or { "$.model", "$.deep.a.b.c.d.value", "$.items[1023].role" }
end
local body, raw
local phases = {}
local function sample(stage)
    local value = metrics.sample()
    value.stage, value.source_callbacks = stage, reads
    if mode == "preload" and body then
        value.source = json.source_stats(body)
        assert(value.source.index_bytes == 0, "automatic metadata budget must remain zero")
    end
    phases[#phases + 1] = value
end
collectgarbage("collect")
sample("baseline")
local file = assert(io.open(input, "rb"))
local input_bytes = assert(file:seek("end"))
assert(file:seek("set", 0))
if mode == "cjson" or source == "memory" then
    raw = assert(file:read("*a"))
    body = mode == "cjson" and cjson.decode(raw) or json.decode(raw, options)
elseif source == "file" then
    body = json.decode_file(input, options)
else
    local decoder = json.new_decoder(options)
    while true do
        local chunk = file:read(options.chunk_size)
        if not chunk then break end
        assert(decoder:feed(chunk))
    end
    body = assert(decoder:finish())
    decoder:close()
end
assert(file:close())
sample("decoded")
local before = reads
assert(body.model == "original")
if scenario == "wide" then
    -- These operations intentionally bypass all proxy metamethods.
    assert(mode ~= "preload")
    assert(rawget(body, "k32767").id == 32767)
    assert(rawget(rawget(body, "flags"), "enabled") == false)
    local count = 0
    for _ in pairs(body) do count = count + 1 end
    assert(count == 32772 and next(body) ~= nil)
else
    for _ = 1, 3 do
        assert(body.model == "original")
        if scenario == "selected" then
            assert(body.deep.a.b.c.d.value == "route-value")
            assert(body.items[1024].role == "user")
        else
            for _, i in ipairs({ 1, 64, 1024 }) do assert(body.items[i].role == "user") end
        end
    end
    if mode == "preload" and source ~= "memory" then
        assert(reads == before, "selected property read accessed the source")
    end
end
sample("selected_reads")
-- This field is not selected. It remains accessible, independently of whether
-- every automatic index is disabled.
assert(body.unselected == "still-readable")
sample("unselected_read")
local function write(value, path, normalize)
    local sink = assert(io.open(path, "wb"))
    local count = 0
    if mode == "preload" then
        local reader = json.reader(value, { chunk_size = 65536, normalize_duplicates = normalize })
        while true do
            local chunk, err = reader:next()
            assert(not err, err)
            if not chunk then break end
            assert(#chunk <= 65536)
            assert(sink:write(chunk))
            count = count + #chunk
        end
        reader:close()
    else
        local encoded = json and json.encode(value) or cjson.encode(value)
        count = #encoded
        assert(sink:write(encoded))
    end
    assert(sink:close())
    return count
end
local untouched_bytes = write(body, output .. ".untouched", false)
sample("untouched_output")
body.model = "rewritten"
local output_bytes = write(body, output, true)
sample("modified_output")
local peak = 0
for _, phase in ipairs(phases) do peak = math.max(peak, phase.hwm_kib) end
if json then json.close(body) end
print(cjson.encode({ mode = mode, source = source, scenario = scenario,
    input_bytes = input_bytes, output_bytes = output_bytes, untouched_bytes = untouched_bytes,
    peak_rss_kib = peak, phases = phases,
    decode_cpu_s = phases[2].cpu_s - phases[1].cpu_s,
    workload_cpu_s = phases[#phases].cpu_s - phases[1].cpu_s,
    selected_read_callbacks = phases[3].source_callbacks - phases[2].source_callbacks,
    output_strategy = mode == "preload" and "bounded-reader" or "full-encode",
    methodology = "fresh native process; external fixture/oracle; no forced GC during measured phases" }))
