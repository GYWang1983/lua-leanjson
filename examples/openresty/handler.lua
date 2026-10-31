local qjson = require "qjson"
local adapter = require "qjson.openresty"
local http = require "resty.http"
local cjson = require "cjson"
local body, session, branch, httpc, unregister

local function close(fn, value)
    local ok, err = pcall(fn, value)
    if not ok then ngx.log(ngx.ERR, "example cleanup failed: ", tostring(err)) end
end
local function close_json()
    if branch ~= nil then close(qjson.close, branch); branch = nil end
    if session then close(session.close, session); session = nil; body = nil
    elseif body ~= nil then close(qjson.close, body); body = nil end
end
local function cleanup()
    if unregister then unregister(); unregister = nil end
    close_json()
    if httpc then close(httpc.close, httpc); httpc = nil end
end
local function bad(status, message)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode { error = tostring(message) })
end

local function run()
    local err, info
    if ngx.var.uri == "/incremental" then
        session, err, info = adapter.start_body { chunk_size = 65536 }
        if session then body, err = session:finish() end
    else
        body, err, info = adapter.read_body { chunk_size = 65536 }
    end
    if err then return bad(400, err) end
    -- Every holder created below is owned before its first yielding operation.
    -- The protected run also unwinds ordinary source/connect/response failures.
    unregister = assert(adapter.on_abort(cleanup))
    local ok
    ok, branch = pcall(qjson.fork, body)
    if not ok or qjson.type(branch) ~= "object" then
        if not ok then branch = nil end
        return bad(400, "example expects an object with a model field")
    end
    branch.model = ngx.var.arg_model or "example-model"
    httpc = http.new()
    httpc:set_timeouts(1000, 30000, 30000)
    ok, err = httpc:connect { scheme = "http", host = os.getenv("QJSON_UPSTREAM_HOST") or "127.0.0.1",
        port = tonumber(os.getenv("QJSON_UPSTREAM_PORT")) or 8081 }
    local response
    if ok then
        -- All input has passed finish/full validation before connection/send.
        response, err = adapter.request(httpc, { method = "POST", path = "/",
            headers = { ["Content-Type"] = "application/json" } }, branch)
    end
    close_json()
    if not response then return bad(502, err) end
    ngx.status = response.status
    ngx.header.content_type = response.headers["Content-Type"]
    ngx.header["X-QJSON-Input-Mode"] = info.mode
    while true do
        local chunk, read_err = response.body_reader(65536)
        if read_err then error("upstream response failed: " .. tostring(read_err)) end
        if not chunk then break end
        ngx.print(chunk)
    end
end

local ok, err = pcall(run)
cleanup()
if not ok then
    if ngx.headers_sent then
        ngx.log(ngx.ERR, "example request failed: ", tostring(err))
        return ngx.exit(ngx.ERROR)
    end
    return bad(500, err)
end
