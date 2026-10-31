local qjson = require "qjson"
local adapter = require "qjson.openresty"
local http = require "resty.http"
local cjson = require "cjson"
local body, err, info, session
if ngx.var.uri == "/incremental" then
    session, err, info = adapter.start_body { chunk_size = 65536 }
    if session then
        -- get may yield; last-wins is final only when its object has closed.
        local _, status, get_err = session:get("model")
        if status == "ERROR" then err = get_err end
        if not err then body, err = session:finish() end
    end
else
    body, err, info = adapter.read_body { chunk_size = 65536 }
end
local function bad(status, message)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode { error = tostring(message) })
end
if err then
    if session then session:close() end
    return bad(400, err)
end
local ok, branch = pcall(qjson.fork, body)
if not ok or type(branch) ~= "table" then
    if session then session:close() else qjson.close(body) end
    return bad(400, "example expects an object with a model field")
end
branch.model = ngx.var.arg_model or "example-model"
local httpc = http.new()
httpc:set_timeouts(1000, 30000, 30000)
ok, err = httpc:connect { scheme = "http", host = os.getenv("QJSON_UPSTREAM_HOST") or "127.0.0.1",
    port = tonumber(os.getenv("QJSON_UPSTREAM_PORT")) or 8081 }
local response
if ok then
    -- All input has passed finish/full validation before the connection/send.
    response, err = adapter.request(httpc, { method = "POST", path = "/",
        headers = { ["Content-Type"] = "application/json" } }, branch)
end
qjson.close(branch)
if session then session:close() else qjson.close(body) end
if not response then httpc:close(); return bad(502, err) end
ngx.status = response.status
ngx.header.content_type = response.headers["Content-Type"]
ngx.header["X-QJSON-Input-Mode"] = info.mode
while true do
    local chunk, read_err = response.body_reader(65536)
    if read_err then
        httpc:close()
        ngx.log(ngx.ERR, "upstream response failed: ", read_err)
        return ngx.exit(ngx.ERROR)
    end
    if not chunk then break end
    ngx.print(chunk)
end
httpc:close()
