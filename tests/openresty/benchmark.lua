local cjson = require "cjson"
local http = require "resty.http"
local port = tonumber(os.getenv("LEANJSON_TEST_PORT"))
local scenario = os.getenv("LEANJSON_BENCH_CASE") or "prompt"
local method = os.getenv("LEANJSON_BENCH_METHOD") or "leanjson"
local size = tonumber(os.getenv("LEANJSON_BENCH_BYTES")) or 1048576
local concurrency = tonumber(os.getenv("LEANJSON_BENCH_CONCURRENCY")) or 2
local requests = tonumber(os.getenv("LEANJSON_BENCH_REQUESTS")) or 3
local branches = tonumber(os.getenv("LEANJSON_BENCH_BRANCHES")) or 2
local chunk_size = tonumber(os.getenv("LEANJSON_BENCH_CHUNK_SIZE")) or 65536
local index_depth = tonumber(os.getenv("LEANJSON_BENCH_INDEX_DEPTH")) or 3
local index_array_limit = tonumber(os.getenv("LEANJSON_BENCH_INDEX_ARRAY_LIMIT")) or 3
local index_budget_bytes = tonumber(os.getenv("LEANJSON_BENCH_INDEX_BUDGET_BYTES")) or 1048576
local raw = require("benchmark-fixtures").build(scenario, size)
local payload_hash = assert(require("resty.sha256"):new())
payload_hash:update(raw)
local payload_sha256 = require("resty.string").to_hex(payload_hash:final())
collectgarbage("collect")
local route = "/benchmark?method=" .. method .. "&branches=" .. branches .. "&chunk_size=" .. chunk_size ..
    "&index_depth=" .. index_depth .. "&index_array_limit=" .. index_array_limit .. "&index_budget_bytes=" .. index_budget_bytes ..
    "&explicit=" .. (scenario == "explicit" and "1" or "0") .. "&cold=" .. (scenario == "cold" and "1" or "0")
local function get(path)
    local res = assert(http.new():request_uri("http://127.0.0.1:" .. port .. path, { keepalive = false }))
    return cjson.decode(res.body)
end
local health_before = get("/health?gc=1")
local lag_max, ping_count, running = 0, 0, true
local ticker = ngx.thread.spawn(function()
    while running do
        local began = ngx.now()
        get("/ping")
        lag_max = math.max(lag_max, (ngx.now() - began) * 1000)
        ping_count = ping_count + 1
        ngx.sleep(0.005)
    end
end)
local latencies, results, first_bytes = {}, {}, {}
local began = ngx.now()
local workers = {}
for _ = 1, concurrency do
    workers[#workers + 1] = ngx.thread.spawn(function()
        for _ = 1, requests do
            local client = http.new()
            client:set_timeout(120000)
            local start = ngx.now()
            local res, err = client:request_uri("http://127.0.0.1:" .. port .. route,
                { method = "POST", body = raw, keepalive = false })
            assert(res, err)
            assert(res.status == 200, res.body)
            local result = cjson.decode(res.body)
            assert(result.sink.bytes == result.output.length)
            if method == "leanjson" then
                assert(result.output.max_chunk <= chunk_size)
                local stats = assert(result.index_stats, "missing effective index settings")
                assert(stats.index_depth == index_depth and stats.index_array_limit == index_array_limit
                    and stats.budget_bytes == index_budget_bytes, "effective index settings differ from request")
                assert(stats.index_bytes <= index_budget_bytes, "effective index budget exceeded")
            end
            latencies[#latencies + 1] = (ngx.now() - start) * 1000
            first_bytes[#first_bytes + 1] = (result.sink.first_byte_at - start) * 1000
            results[#results + 1] = result
        end
    end)
end
for _, worker in ipairs(workers) do local ok, err = ngx.thread.wait(worker); assert(ok, err) end
local elapsed = ngx.now() - began
running = false
ngx.thread.wait(ticker)
local health_after = get("/health")
local io_delta = {}
for key, value in pairs(health_after.io) do io_delta[key] = value - health_before.io[key] end
table.sort(latencies)
table.sort(first_bytes)
local function percentile(values, quantile) return values[math.max(1, math.ceil(#values * quantile))] end
local lua_max, hwm, max_chunk = 0, math.max(health_before.hwm_kib, health_after.hwm_kib), 0
for _, result in ipairs(results) do
    lua_max = math.max(lua_max, result.lua_heap_sample_max_kib)
    hwm = math.max(hwm, result.hwm_kib)
    max_chunk = math.max(max_chunk, result.output.max_chunk)
end
-- Capture/parse only after all timed/worker snapshots. The sink still streams
-- bounded chunks to disk; this separate client owns the complete semantic oracle.
local oracle_response = assert(http.new():request_uri("http://127.0.0.1:" .. port .. route, {
    method = "POST", body = raw, headers = { ["x-capture-id"] = "benchmark-oracle" }, keepalive = false,
}))
assert(oracle_response.status == 200, oracle_response.body)
local oracle = cjson.decode(oracle_response.body)
local capture_file = assert(io.open(assert(oracle.sink.capture), "rb"))
local captured = assert(capture_file:read("*a"))
assert(capture_file:close())
local capture_hash = assert(require("resty.sha256"):new())
capture_hash:update(captured)
local captured_sha256 = require("resty.string").to_hex(capture_hash:final())
assert(captured_sha256 == oracle.sink.sha256 and #captured == oracle.sink.bytes)
local expected = cjson.decode(raw)
expected.model = "rewritten-1"
local function equal(actual, wanted)
    assert(type(actual) == type(wanted), "oracle value type differs")
    if type(wanted) ~= "table" then assert(actual == wanted, "oracle scalar differs"); return end
    for key, value in pairs(wanted) do equal(actual[key], value) end
    for key in pairs(actual) do assert(wanted[key] ~= nil, "oracle contains an extra field") end
end
equal(cjson.decode(captured), expected)
print(cjson.encode { scenario = scenario, method = method, payload_bytes = #raw,
    payload_sha256 = payload_sha256,
    requests = #results, concurrency = concurrency, branches = branches, chunk_size = chunk_size, elapsed_s = elapsed,
    index_depth = index_depth, index_array_limit = index_array_limit, index_budget_bytes = index_budget_bytes,
    mib_per_s = (#raw * #results / 1048576) / elapsed, p50_ms = percentile(latencies, 0.5),
    p95_ms = percentile(latencies, 0.95), first_upstream_byte_p50_ms = percentile(first_bytes, 0.5),
    worker_lag_max_ms = lag_max, ping_samples = ping_count,
    worker_cpu_ms = (health_after.cpu_s - health_before.cpu_s) * 1000,
    lua_heap_sample_max_kib = lua_max, worker_hwm_kib = hwm, output_max_chunk = max_chunk,
    before = health_before, after = health_after, io_delta = io_delta, sample = results[1],
    oracle = { passed = true, requests = 1, bytes = #captured, sha256 = captured_sha256 } })
