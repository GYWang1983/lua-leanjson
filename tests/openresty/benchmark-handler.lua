local cjson = require "cjson"
local qjson = require "qjson"
local adapter = require "qjson.openresty"
local http = require "resty.http"
local metrics = require "metrics"
local method = ngx.var.arg_method or "qjson"
local initial = metrics.sample()
local lua_max = initial.lua_kib
local function sample()
    lua_max = math.max(lua_max, collectgarbage("count"))
end
local opts = { chunk_size = tonumber(ngx.var.arg_chunk_size) or 65536, on_chunk = function() sample(); ngx.sleep(0) end }
local body, info, cold
if method == "cjson" or ngx.var.arg_cold == "1" then
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    local file = not raw and ngx.req.get_body_file()
    info = { mode = file and "completed-file" or "completed-memory" }
    if file and ngx.var.arg_cold == "1" then
        local ok, err = metrics.cold_advice(file)
        cold = ok and "fsync-fadvise-dontneed" or err
    end
    if method == "qjson" then
        body = file and qjson.decode_file(file, opts) or qjson.decode(raw, opts)
    else
        if file then
            -- Explicit complete-body baseline: include the original full string
            -- plus cjson's full Lua tree and complete encoded output.
            local source = assert(io.open(file, "rb"))
            raw = assert(source:read("*a"))
            source:close()
        end
        body = cjson.decode(raw)
    end
else
    local err
    body, err, info = adapter.read_body(opts)
    assert(body ~= nil, err)
end
sample()
local explicit_bytes = 0
if ngx.var.arg_explicit == "1" then
    local value = body.prompt or body.input or body.messages[1].content
    explicit_bytes = #value
    sample()
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end
local branches = {}
for i = 1, (tonumber(ngx.var.arg_branches) or 2) do
    local branch = method == "qjson" and qjson.fork(body) or copy(body)
    branch.model = "rewritten-" .. i
    branches[i] = branch
end
sample()
local client = http.new()
client:set_timeout(30000)
assert(client:connect { scheme = "http", host = "127.0.0.1", port = tonumber(os.getenv("QJSON_SINK_PORT")) })
local response, err, output
if method == "qjson" then
    response, err, output = adapter.request(client, { method = "POST", path = "/sink" }, branches[1], opts)
else
    local encoded = cjson.encode(branches[1])
    sample()
    output = { length = #encoded, delivered_bytes = #encoded, max_chunk = #encoded }
    response, err = client:request { method = "POST", path = "/sink", body = encoded }
end
assert(response, err)
local sink = cjson.decode(assert(response:read_body()))
client:close()
sample()
local final = metrics.sample()
if method == "qjson" then
    for _, branch in ipairs(branches) do qjson.close(branch) end
    qjson.close(body)
end
ngx.header.content_type = "application/json"
ngx.say(cjson.encode { method = method, source_bytes = tonumber(ngx.var.content_length), input = info,
    cold_advice = cold, branches = #branches, explicit_materialized_bytes = explicit_bytes,
    structural_index_bytes = cjson.null, rust_heap_bytes = cjson.null, overlay_bytes = cjson.null,
    lua_heap_sample_max_kib = lua_max, rss_kib = final.rss_kib, hwm_kib = final.hwm_kib,
    cpu_ms = (final.cpu_s - initial.cpu_s) * 1000, output = output, sink = sink })
