local cjson = require "cjson"
local qjson = require "qjson"
local adapter = require "qjson.openresty"
local http = require "resty.http"
local started = ngx.now()
local opts = { chunk_size = 16384, temp_dir = os.getenv("QJSON_TEST_PREFIX") .. "/decoder" }
local body, err, info, session
if ngx.var.uri == "/incremental" then
    session, err, info = adapter.start_body(opts)
    if session then
        -- This may yield until last-wins has a final value. It must not return
        -- the first duplicate while a later upload chunk is still pending.
        local waiter = ngx.thread.spawn(function() return session:get("model") end)
        local value, status, get_err = session:get("model")
        if status == "ERROR" then err = get_err end
        info.model = value
        local waited, other, other_status = ngx.thread.wait(waiter)
        info.other_model = waited and other or nil
        info.other_status = other_status
        if not err then body, err = session:finish() end
    end
else
    body, err, info = adapter.read_body(opts)
end
ngx.header.content_type = "application/json"
if err then
    if session then session:close() end
    ngx.status = 400
    ngx.say(cjson.encode { error = tostring(err), input = info })
    return
end
if ngx.var.uri == "/scalar" then
    ngx.say(cjson.encode { value = body, input = info })
    qjson.close(body)
    return
end
if ngx.var.uri == "/ownership" then
    local _, ownership_error = adapter.start_body(opts)
    ngx.say(cjson.encode { error = ownership_error })
    qjson.close(body)
    return
end
local branch = qjson.fork(body)
branch.model = "rewritten"
if ngx.var.arg_mixed == "1" then
    branch.remove_me = nil
    branch.added = { enabled = true, value = qjson.null }
    branch.nested.flag = false
end
local sibling = qjson.fork(body)
sibling.model = "independent"
if ngx.var.uri == "/io-failure" then
    local source = assert(ngx.req.get_body_file())
    assert(io.open(source, "wb")):close() -- real source truncation, no mocked reader
elseif ngx.var.uri == "/unlink-source" then
    assert(os.remove(assert(ngx.req.get_body_file())))
end
if ngx.var.uri == "/cancel-output" then
    local calls = 0
    opts.cancelled = function() calls = calls + 1; return calls > 1 end
end
local httpc = http.new()
httpc:set_timeouts(1000, 3000, 3000)
local ok
ok, err = httpc:connect { scheme = "http", host = "127.0.0.1", port = tonumber(os.getenv("QJSON_SINK_PORT")) }
if not ok then error(err) end
local headers = { ["Content-Length"] = "1", ["Transfer-Encoding"] = "chunked",
    ["x-capture-id"] = ngx.req.get_headers()["x-capture-id"] }
local res, transfer
res, err, transfer = adapter.request(httpc, {
    method = "POST", path = ngx.var.arg_disconnect == "1" and "/disconnect" or "/sink", headers = headers,
}, branch, opts)
local result
if res then
    local raw, read_err = res:read_body()
    if not raw then err = read_err else result = cjson.decode(raw) end
end
httpc:close()
local original_model, sibling_model = body.model, sibling.model
qjson.close(branch)
qjson.close(sibling)
if session then session:close() else qjson.close(body) end
if err then ngx.status = 502 end
ngx.say(cjson.encode { error = err and tostring(err), sink = result, transfer = transfer,
    input = info, original_model = original_model, sibling_model = sibling_model,
    lua_kib = collectgarbage("count"), elapsed_ms = (ngx.now() - started) * 1000 })
