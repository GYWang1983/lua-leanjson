local cjson = require "cjson"
local http = require "resty.http"
local port = tonumber(os.getenv("QJSON_TEST_PORT"))
local scenario = os.getenv("QJSON_BENCH_CASE") or "prompt"
local method = os.getenv("QJSON_BENCH_METHOD") or "qjson"
local size = tonumber(os.getenv("QJSON_BENCH_BYTES")) or 1048576
local concurrency = tonumber(os.getenv("QJSON_BENCH_CONCURRENCY")) or 2
local requests = tonumber(os.getenv("QJSON_BENCH_REQUESTS")) or 3
local branches = tonumber(os.getenv("QJSON_BENCH_BRANCHES")) or 2
local raw
do
local body = { model = "original" }
if scenario == "messages" then body.messages = { { role = "user", content = ("m"):rep(size) } }
elseif scenario == "input" then body.input = ("i"):rep(size)
elseif scenario == "escaped" then body.prompt = ("\n\t\"\\"):rep(math.floor(size / 8))
elseif scenario == "short-elements" then
    body.items = {}
    for i = 1, math.max(1, math.floor(size / 32)) do body.items[i] = { id = i, value = "small" } end
else body.prompt = ("p"):rep(size) end
raw = cjson.encode(body)
end
collectgarbage("collect")
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
            local path = "/benchmark?method=" .. method .. "&branches=" .. branches ..
                "&explicit=" .. (scenario == "explicit" and "1" or "0") .. "&cold=" .. (scenario == "cold" and "1" or "0")
            local res, err = client:request_uri("http://127.0.0.1:" .. port .. path,
                { method = "POST", body = raw, keepalive = false })
            assert(res, err)
            assert(res.status == 200, res.body)
            local result = cjson.decode(res.body)
            assert(result.sink.bytes == result.output.length)
            if method == "qjson" then assert(result.output.max_chunk <= 16384) end
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
table.sort(latencies)
table.sort(first_bytes)
local function percentile(values, quantile) return values[math.max(1, math.ceil(#values * quantile))] end
local lua_max, hwm, max_chunk = 0, 0, 0
for _, result in ipairs(results) do
    lua_max = math.max(lua_max, result.lua_heap_sample_max_kib)
    hwm = math.max(hwm, result.hwm_kib)
    max_chunk = math.max(max_chunk, result.output.max_chunk)
end
print(cjson.encode { scenario = scenario, method = method, payload_bytes = #raw,
    requests = #results, concurrency = concurrency, branches = branches, elapsed_s = elapsed,
    mib_per_s = (#raw * #results / 1048576) / elapsed, p50_ms = percentile(latencies, 0.5),
    p95_ms = percentile(latencies, 0.95), first_upstream_byte_p50_ms = percentile(first_bytes, 0.5),
    worker_lag_max_ms = lag_max, ping_samples = ping_count,
    worker_cpu_ms = (health_after.cpu_s - health_before.cpu_s) * 1000,
    lua_heap_sample_max_kib = lua_max, worker_hwm_kib = hwm, output_max_chunk = max_chunk,
    before = health_before, after = health_after, sample = results[1] })
