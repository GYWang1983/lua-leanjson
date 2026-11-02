local method = ngx.var.arg_method or "leanjson"
assert(method == "leanjson" or method == "cjson")
local cjson = require "cjson"
local leanjson, adapter
if method == "leanjson" then
    leanjson, adapter = require("leanjson"), require("leanjson.openresty")
end
local http = require "resty.http"
local metrics = require "metrics"
if method == "cjson" then
    assert(not package.loaded.leanjson and not package.loaded["leanjson.lib"] and not package.loaded["leanjson.openresty"],
        "cjson benchmark requires a fresh worker without LeanJSON")
end
local initial = metrics.sample()
local lua_max = initial.lua_kib
local phases = { baseline = initial }
local function sample()
    lua_max = math.max(lua_max, collectgarbage("count"))
end
local function phase(name)
    phases[name] = metrics.sample()
    sample()
end
local decode_opts = { chunk_size = tonumber(ngx.var.arg_chunk_size) or 65536,
    index_depth = tonumber(ngx.var.arg_index_depth) or 3,
    index_array_limit = tonumber(ngx.var.arg_index_array_limit) or 3,
    index_budget_bytes = tonumber(ngx.var.arg_index_budget_bytes) or 1048576,
    on_chunk = function() sample(); ngx.sleep(0) end }
local opts = { decode = decode_opts, chunk_size = decode_opts.chunk_size, on_chunk = decode_opts.on_chunk }
local body, info, cold, raw
if method == "cjson" or ngx.var.arg_cold == "1" then
    ngx.req.read_body()
    raw = ngx.req.get_body_data()
    local file = not raw and ngx.req.get_body_file()
    info = { mode = file and "completed-file" or "completed-memory" }
    if file and ngx.var.arg_cold == "1" then
        local ok, err = metrics.cold_advice(file)
        cold = ok and "fsync-fadvise-dontneed" or err
    end
    if method == "leanjson" then
        body = file and leanjson.decode_file(file, decode_opts) or leanjson.decode(raw, decode_opts)
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
phase("parsed")
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
local branch_count = tonumber(ngx.var.arg_branches) or 2
for i = 1, branch_count do
    local branch = method == "leanjson" and leanjson.fork(body) or copy(body)
    branch.model = "rewritten-" .. i
    branches[i] = branch
end
if branch_count == 0 then
    body.model = "rewritten-1"
    branches[1] = body
end
phase("modified")
local client = http.new()
client:set_timeout(30000)
assert(client:connect { scheme = "http", host = "127.0.0.1", port = tonumber(os.getenv("LEANJSON_SINK_PORT")) })
local response, err, output
local headers = { ["x-capture-id"] = ngx.req.get_headers()["x-capture-id"] }
if method == "leanjson" then
    response, err, output = adapter.request(client, { method = "POST", path = "/sink", headers = headers }, branches[1], opts)
else
    local encoded = cjson.encode(branches[1])
    sample()
    output = { length = #encoded, delivered_bytes = #encoded, max_chunk = #encoded }
    response, err = client:request { method = "POST", path = "/sink", headers = headers, body = encoded }
end
assert(response, err)
local sink = cjson.decode(assert(response:read_body()))
client:close()
sample()
local final = metrics.sample()
phases.output = final
local index_stats = method == "leanjson" and leanjson.source_stats and leanjson.source_stats(body) or nil
if method == "leanjson" then
    for _, branch in ipairs(branches) do leanjson.close(branch) end
    leanjson.close(body)
end
ngx.header.content_type = "application/json"
ngx.say(cjson.encode { method = method, source_bytes = tonumber(ngx.var.content_length), input = info,
    cold_advice = cold, branches = branch_count, explicit_materialized_bytes = explicit_bytes,
    retained_input_bytes = raw and #raw or 0, phases = phases, index_stats = index_stats,
    structural_index_bytes = cjson.null, rust_heap_bytes = cjson.null, overlay_bytes = cjson.null,
    lua_heap_sample_max_kib = lua_max, rss_kib = final.rss_kib, hwm_kib = final.hwm_kib,
    cpu_ms = (final.cpu_s - initial.cpu_s) * 1000, output = output, sink = sink })
