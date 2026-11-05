local cjson = require "cjson"
local leanjson = require "leanjson"
local adapter = require "leanjson.openresty"
local http = require "resty.http"
if ngx.var.uri == "/gc" then
    collectgarbage(ngx.var.arg_action == "stop" and "stop" or "restart")
    ngx.say("{}")
    return
end
local started = ngx.now()
local opts = { chunk_size = 16384, temp_dir = os.getenv("LEANJSON_TEST_PREFIX") .. "/decoder",
    decode = { proxy_mode = ngx.var.arg_proxy_mode or "table" },
    file_in_memory = ngx.var.arg_file_in_memory ~= "false" }
-- Completed-input and file-fault cases deliberately exercise Nginx buffering;
-- other routes exercise read_body's socket-first behavior.
if ngx.var.uri == "/completed" or ngx.var.uri == "/snapshot-file" or ngx.var.uri == "/io-failure" or ngx.var.uri == "/unlink-source"
    or ngx.var.uri == "/abort-file-parse" or ngx.var.uri == "/abort-output-length"
    or ngx.var.uri == "/output-hook-failure" then ngx.req.read_body() end
if ngx.var.uri == "/io-failure" then opts.file_in_memory = false end
local output_phase = "input"
if ngx.var.arg_prepare_delay == "1" then
    local delayed = false
    opts.on_chunk = function()
        if not delayed then delayed = true; ngx.sleep(1.05) else ngx.sleep(0) end
    end
end
if ngx.var.arg_hook == "1" then opts.on_chunk = function() error("intentional source hook failure") end end
if ngx.var.arg_temp_error == "1" then
    opts.temp_dir = "/proc/leanjson-unwritable-spool"
    opts.file_in_memory = false
end
if ngx.var.uri == "/memory-upload" then
    opts.on_chunk = function()
        local marker = assert(io.open(os.getenv("LEANJSON_TEST_PREFIX") .. "/memory-upload-scanning", "w"))
        marker:write(ngx.req.get_body_file() == nil and "socket" or "buffered")
        marker:close()
        ngx.sleep(0)
    end
end
if ngx.var.uri == "/external-abort" then assert(ngx.on_abort(function() end)) end
if ngx.var.uri == "/abort-file-parse" then
    opts.on_chunk = function()
        local marker = assert(io.open(os.getenv("LEANJSON_TEST_PREFIX") .. "/file-parse-started", "w"))
        marker:write("scanning")
        marker:close()
        ngx.sleep(0.03)
    end
end
if ngx.var.uri == "/abort-output-length" or ngx.var.uri == "/output-hook-failure" then
    opts.on_chunk = function()
        if output_phase == "length" and ngx.var.uri == "/abort-output-length" then
            local marker = assert(io.open(os.getenv("LEANJSON_TEST_PREFIX") .. "/output-length-started", "w"))
            marker:write("counting")
            marker:close()
            ngx.sleep(0.03)
        elseif output_phase == "body" then
            error("intentional output hook failure")
        else ngx.sleep(0) end
    end
end
local body, session, branch, sibling, nested, httpc, unregister
local body_type, branch_type, child_type
local model_view, other_view, original_view
local function phase(name)
    local records = package.loaded["leanjson.test_state"]
    local record = records and records[ngx.var.arg_case]
    if record then
        record.phase = name
        record.phase_at = ngx.now()
        record.phases = record.phases or {}
        record.phases[name] = ngx.now()
    end
end
local function close(fn, value)
    local ok, err = pcall(fn, value)
    if not ok then ngx.log(ngx.ERR, "test handler cleanup failed: ", tostring(err)) end
end
local function cleanup()
    if unregister then unregister(); unregister = nil end
    if model_view ~= nil then close(leanjson.close, model_view); model_view = nil end
    if other_view ~= nil then close(leanjson.close, other_view); other_view = nil end
    if original_view ~= nil then close(leanjson.close, original_view); original_view = nil end
    if nested ~= nil then close(leanjson.close, nested); nested = nil end
    if branch ~= nil then close(leanjson.close, branch); branch = nil end
    if sibling ~= nil then close(leanjson.close, sibling); sibling = nil end
    if session then close(session.close, session); session = nil; body = nil
    elseif body ~= nil then close(leanjson.close, body); body = nil end
    if httpc then close(httpc.close, httpc); httpc = nil end
end

local function run()
    local err, info
    if ngx.var.uri == "/incremental" or ngx.var.uri == "/close-waiters" then
        session, err, info = adapter.start_body(opts)
        phase("input-started")
        if session then unregister = assert(adapter.on_abort(cleanup)) end
        if session and ngx.var.uri == "/close-waiters" then
            local first = ngx.thread.spawn(function()
                local status, get_err
                model_view, status, get_err = session:get("model")
                return status, get_err
            end)
            local second = ngx.thread.spawn(function()
                local status, get_err
                other_view, status, get_err = session:get("model")
                return status, get_err
            end)
            ngx.sleep(0.01)
            session:close()
            local ok1, status1, err1 = ngx.thread.wait(first)
            local ok2, status2, err2 = ngx.thread.wait(second)
            ngx.header.content_type = "application/json"
            ngx.say(cjson.encode { first = { ok = ok1, status = status1, error = err1 },
                second = { ok = ok2, status = status2, error = err2 } })
            return
        end
        if session then
            -- This may yield until last-wins has a final value. It must not return
            -- the first duplicate while a later upload chunk is still pending.
            local waiter = ngx.thread.spawn(function()
                local status, get_err
                phase("waiter-get")
                other_view, status, get_err = session:get("model")
                phase("waiter-" .. status)
                return status, get_err
            end)
            local status, get_err
            phase("main-get")
            model_view, status, get_err = session:get("model")
            phase("main-" .. status)
            if status == "ERROR" then err = get_err end
            local waited, other_status, other_err = ngx.thread.wait(waiter)
            phase("queries-ready")
            if not waited then err = other_status elseif other_status == "ERROR" then err = other_err end
            info.other_status = other_status
            if not err then
                phase("materialize-query")
                info.model = leanjson.materialize(model_view)
                info.other_model = leanjson.materialize(other_view)
            end
            -- Repeated attached queries may alias one public child. Materialize
            -- both results before closing either; close is idempotent on aliases.
            leanjson.close(model_view)
            leanjson.close(other_view)
            model_view, other_view = nil, nil
            phase("queries-closed")
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
    local node = require("leanjson.proxy").node(body)
    info.retained_source_fd = node and node.backend and node.backend.state.fd ~= nil or false
    info.nginx_body_file = ngx.req.get_body_file() ~= nil
    body_type = type(body)
    if not unregister then unregister = assert(adapter.on_abort(cleanup)) end
    if ngx.var.uri == "/abort-callbacks" then
        assert(adapter.on_abort(function() error("intentional abort callback failure") end))
        assert(adapter.on_abort(function()
            local marker = assert(io.open(os.getenv("LEANJSON_TEST_PREFIX") .. "/abort-cleanup-ran", "w"))
            marker:write("closed")
            marker:close()
            leanjson.close(body)
        end))
        ngx.say("ready")
        ngx.flush(true)
        ngx.sleep(2)
        leanjson.close(body)
        return
    end
    if ngx.var.uri == "/scalar" then
        ngx.say(cjson.encode { value = body, input = info })
        leanjson.close(body)
        return
    end
    if ngx.var.uri == "/ownership" then
        local _, ownership_error = adapter.start_body(opts)
        ngx.say(cjson.encode { error = ownership_error })
        leanjson.close(body)
        return
    end
    branch = leanjson.fork(body)
    branch_type = type(branch)
    phase("forked")
    branch.model = "rewritten"
    if ngx.var.arg_mixed == "1" then
        branch.remove_me = nil
        branch.added = { enabled = true, value = leanjson.null }
        nested = branch.nested
        child_type = type(nested)
        nested.flag = false
        leanjson.close(nested)
        nested = nil
    end
    sibling = leanjson.fork(body)
    sibling.model = "independent"
    original_view = body.model
    phase("materialize-original")
    local original_model, sibling_model = leanjson.materialize(original_view), sibling.model
    leanjson.close(original_view)
    original_view = nil
    phase("original-closed")
    if ngx.var.uri == "/io-failure" or ngx.var.uri == "/snapshot-file" then
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
    ok, err = httpc:connect { scheme = "http", host = "127.0.0.1", port = ngx.var.uri == "/connect-failure" and 1 or tonumber(os.getenv("LEANJSON_SINK_PORT")) }
    if not ok then error(err) end
    phase("connected")
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
    phase("request-returned")
    local result
    if res then
        local raw, read_err = res:read_body()
        if not raw then err = read_err else result = cjson.decode(raw) end
    end
    cleanup()
    phase("cleaned")
    if err then ngx.status = 502 end
    ngx.say(cjson.encode { error = err and tostring(err), sink = result, transfer = transfer,
        lua_type = body_type, branch_lua_type = branch_type, child_lua_type = child_type,
        input = info, original_model = original_model, sibling_model = sibling_model,
        lua_kib = collectgarbage("count"), elapsed_ms = (ngx.now() - started) * 1000 })
end

local ok, err = pcall(run)
cleanup()
if not ok then
    phase("failed")
    if ngx.headers_sent then
        ngx.log(ngx.ERR, "test handler request failed: ", tostring(err))
        return ngx.exit(ngx.ERROR)
    end
    ngx.status = 500
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode { error = tostring(err) })
end
