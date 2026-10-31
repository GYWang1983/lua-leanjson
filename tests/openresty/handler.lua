local cjson = require "cjson"
local qjson = require "qjson"
local adapter = require "qjson.openresty"
local http = require "resty.http"
if ngx.var.uri == "/gc" then
    collectgarbage(ngx.var.arg_action == "stop" and "stop" or "restart")
    ngx.say("{}")
    return
end
local started = ngx.now()
local opts = { chunk_size = 16384, temp_dir = os.getenv("QJSON_TEST_PREFIX") .. "/decoder" }
local output_phase = "input"
if ngx.var.arg_hook == "1" then opts.on_chunk = function() error("intentional source hook failure") end end
if ngx.var.arg_temp_error == "1" then opts.temp_dir = "/proc/qjson-unwritable-spool" end
if ngx.var.uri == "/external-abort" then assert(ngx.on_abort(function() end)) end
if ngx.var.uri == "/abort-file-parse" then
    opts.on_chunk = function()
        local marker = assert(io.open(os.getenv("QJSON_TEST_PREFIX") .. "/file-parse-started", "w"))
        marker:write("scanning")
        marker:close()
        ngx.sleep(0.03)
    end
end
if ngx.var.uri == "/abort-output-length" or ngx.var.uri == "/output-hook-failure" then
    opts.on_chunk = function()
        if output_phase == "length" and ngx.var.uri == "/abort-output-length" then
            local marker = assert(io.open(os.getenv("QJSON_TEST_PREFIX") .. "/output-length-started", "w"))
            marker:write("counting")
            marker:close()
            ngx.sleep(0.03)
        elseif output_phase == "body" then
            error("intentional output hook failure")
        else ngx.sleep(0) end
    end
end
local body, session, branch, sibling, nested, httpc, unregister
local function close(fn, value)
    local ok, err = pcall(fn, value)
    if not ok then ngx.log(ngx.ERR, "test handler cleanup failed: ", tostring(err)) end
end
local function cleanup()
    if unregister then unregister(); unregister = nil end
    if nested ~= nil then close(qjson.close, nested); nested = nil end
    if branch ~= nil then close(qjson.close, branch); branch = nil end
    if sibling ~= nil then close(qjson.close, sibling); sibling = nil end
    if session then close(session.close, session); session = nil; body = nil
    elseif body ~= nil then close(qjson.close, body); body = nil end
    if httpc then close(httpc.close, httpc); httpc = nil end
end

local function run()
    local err, info
    if ngx.var.uri == "/incremental" or ngx.var.uri == "/close-waiters" then
        session, err, info = adapter.start_body(opts)
        if session and ngx.var.uri == "/close-waiters" then
            local first = ngx.thread.spawn(function() return session:get("model") end)
            local second = ngx.thread.spawn(function() return session:get("model") end)
            ngx.sleep(0.01)
            session:close()
            local ok1, _, status1, err1 = ngx.thread.wait(first)
            local ok2, _, status2, err2 = ngx.thread.wait(second)
            ngx.header.content_type = "application/json"
            ngx.say(cjson.encode { first = { ok = ok1, status = status1, error = err1 },
                second = { ok = ok2, status = status2, error = err2 } })
            return
        end
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
    -- Own every subsequent holder before its first mutation/read can yield.
    unregister = assert(adapter.on_abort(cleanup))
    if ngx.var.uri == "/abort-callbacks" then
        assert(adapter.on_abort(function() error("intentional abort callback failure") end))
        assert(adapter.on_abort(function()
            local marker = assert(io.open(os.getenv("QJSON_TEST_PREFIX") .. "/abort-cleanup-ran", "w"))
            marker:write("closed")
            marker:close()
            qjson.close(body)
        end))
        ngx.say("ready")
        ngx.flush(true)
        ngx.sleep(2)
        qjson.close(body)
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
    branch = qjson.fork(body)
    branch.model = "rewritten"
    if ngx.var.arg_mixed == "1" then
        branch.remove_me = nil
        branch.added = { enabled = true, value = qjson.null }
        nested = branch.nested
        nested.flag = false
        qjson.close(nested)
        nested = nil
    end
    sibling = qjson.fork(body)
    sibling.model = "independent"
    local original_model, sibling_model = body.model, sibling.model
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
    httpc = http.new()
    httpc:set_timeouts(1000, 3000, 3000)
    local ok
    ok, err = httpc:connect { scheme = "http", host = "127.0.0.1", port = ngx.var.uri == "/connect-failure" and 1 or tonumber(os.getenv("QJSON_SINK_PORT")) }
    if not ok then error(err) end
    local headers = { ["Content-Length"] = "1", ["Transfer-Encoding"] = "chunked",
        ["x-capture-id"] = ngx.req.get_headers()["x-capture-id"] }
    local res, transfer
    output_phase = "length"
    if ngx.var.uri == "/output-hook-failure" then
        opts.cancelled = function() output_phase = "body"; return false end
    end
    res, err, transfer = adapter.request(httpc, {
        method = "POST", path = ngx.var.arg_disconnect == "1" and "/disconnect" or "/sink", headers = headers,
    }, branch, opts)
    local result
    if res then
        local raw, read_err = res:read_body()
        if not raw then err = read_err else result = cjson.decode(raw) end
    end
    cleanup()
    if err then ngx.status = 502 end
    ngx.say(cjson.encode { error = err and tostring(err), sink = result, transfer = transfer,
        input = info, original_model = original_model, sibling_model = sibling_model,
        lua_kib = collectgarbage("count"), elapsed_ms = (ngx.now() - started) * 1000 })
end

local ok, err = pcall(run)
cleanup()
if not ok then
    if ngx.headers_sent then
        ngx.log(ngx.ERR, "test handler request failed: ", tostring(err))
        return ngx.exit(ngx.ERROR)
    end
    ngx.status = 500
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode { error = tostring(err) })
end
