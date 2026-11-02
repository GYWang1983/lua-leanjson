local cjson = require "cjson"
local http = require "resty.http"
local port = assert(tonumber(os.getenv("LEANJSON_TEST_PORT")))
local sink_port = assert(tonumber(os.getenv("LEANJSON_SINK_PORT")))
local function request(path, body, id, headers)
    local client = http.new()
    client:set_timeout(15000)
    local res, err = client:request_uri("http://127.0.0.1:" .. port .. path, {
        method = "POST", body = body, headers = headers or { ["x-capture-id"] = id }, keepalive = false,
    })
    assert(res, err)
    local ok, value = pcall(cjson.decode, res.body)
    assert(ok, "HTTP " .. res.status .. ": " .. res.body)
    return res.status, value
end
local count = 0
local failures = 0
local function check(name, fn)
    count = count + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then print("ok " .. count .. " - " .. name)
    else failures = failures + 1; print("not ok " .. count .. " - " .. name .. "\n" .. tostring(err)) end
end
local function get(path, target_port)
    local res = assert(http.new():request_uri("http://127.0.0.1:" .. (target_port or port) .. path, { keepalive = false }))
    return cjson.decode(res.body)
end
local function sink_count() return get("/stats", sink_port).requests end
local initial_health = get("/health")
local function empty_directory(name)
    local directory = os.getenv("LEANJSON_TEST_PREFIX") .. "/" .. name
    local quoted = "'" .. directory:gsub("'", "'\\''") .. "'"
    local listing = assert(io.popen("ls -A " .. quoted, "r"))
    local entries = listing:read("*a")
    assert(listing:close())
    assert(entries == "", "leaked body/spool files in " .. name .. ": " .. entries)
end
local function capture(result)
    local file = assert(io.open(assert(result.sink.capture), "rb"))
    local raw = assert(file:read("*a")) -- client-side semantic oracle, not the upstream sink
    file:close()
    assert(#raw == result.sink.bytes)
    local hash = assert(require("resty.sha256"):new())
    hash:update(raw)
    assert(require("resty.string").to_hex(hash:final()) == result.sink.sha256)
    return cjson.decode(raw), raw
end
local function wait_source(case, event, sock)
    local client = http.new()
    client:set_timeout(6000)
    local res, err = client:request_uri("http://127.0.0.1:" .. port .. "/lifecycle/wait?case=" .. case .. "&event=" .. event,
        { keepalive = false })
    local result = res and cjson.decode(res.body) or { error = err }
    if not result.ready then
        local response
        if sock then
            sock:settimeout(100)
            local status, receive_err, partial = sock:receive("*l")
            local body, body_err, tail
            if status then body, body_err, tail = sock:receive("*a") end
            response = { status = status, body = body or tail, error = receive_err or body_err, partial = partial }
        end
        error("source-read " .. event .. " watchdog: " .. cjson.encode { probe = result, response = response })
    end
    return result
end
local function closed_source(probe)
    -- Check the actual close before a later HTTP connection can reuse its fd.
    -- A still-live holder has no successful close record, including after GC.
    local state = probe.state
    assert(state and state.closed_at and state.close_fcntl == -1 and state.close_errno == 9, cjson.encode(probe))
    if probe.owned then
        assert(state.close_unlinked and not probe.path_exists, cjson.encode(probe))
    end
end

for _, eager in ipairs { false, true } do
    for _, input in ipairs { "memory", "file", "incremental", "fallback" } do
        check((eager and "eager" or "preloaded") .. " loading options reach HTTP " .. input, function()
            local ignored = ("p"):rep(input == "file" and 131072 or 32)
            local raw = '{"a":{"b":{"c":{"d":{"e":"selected"}}}},"items":[0,1,2,3,4,{"x":false}],"n":null,"big":9007199254740993,"ignored":"' .. ignored .. '"}'
            local body, headers = raw
            local endpoint = (input == "incremental" or input == "fallback") and "/loading/incremental" or "/loading/completed"
            if input == "fallback" then
                body = string.format("%x\r\n%s\r\n0\r\n\r\n", #raw, raw)
                headers = { ["Transfer-Encoding"] = "chunked" }
            end
            local status, result = request(endpoint .. "?eager=" .. (eager and "1" or "0"), body, nil, headers)
            assert(status == 200, cjson.encode(result))
            assert(result.ordinary == eager, cjson.encode(result))
            assert(result.before == result.after, "selected reads performed source I/O")
            if eager then
                local decoded = cjson.decode(result.encoded)
                assert(decoded.a.b.c.d.e == "selected" and decoded.items[6].x == false and decoded.n == cjson.null)
                assert(decoded.ignored == ignored)
            else
                assert(result.encoded == raw, "preloading changed untouched source tokens")
                assert(result.stats.index_bytes == 0 and result.stats.preloaded_nodes == 4)
            end
            if input == "file" then assert(result.mode == "completed-file")
            elseif input == "incremental" then assert(result.mode == "incremental")
            else assert(result.mode == "completed-memory") end
            if input == "fallback" then assert(result.fallback == "transfer-encoding") end
            if input == "incremental" or input == "fallback" then assert(result.session_observes_edits) end
        end)
    end
end
check("HTTP eager scalar roots preserve false and null", function()
    for _, endpoint in ipairs { "/loading/completed", "/loading/incremental" } do
        for _, raw in ipairs { "false", "null" } do
            local status, result = request(endpoint .. "?eager=1&scalar=1", raw)
            assert(status == 200, cjson.encode(result))
            if raw == "false" then assert(result.value == false and result.kind == "boolean")
            else assert(result.value == cjson.null and result.kind == "null") end
        end
    end
end)
check("HTTP invalid selector options reject before decoding or forwarding", function()
    local before = sink_count()
    for _, endpoint in ipairs { "/loading/completed", "/loading/incremental" } do
        local status, result = request(endpoint .. "?invalid=1&eager=1", '{"a":1}')
        assert(status == 400 and result.error:find("preload_paths", 1, true), cjson.encode(result))
    end
    assert(sink_count() == before)
end)

check("memory source rewrites a field and sends exact bounded bytes", function()
    local status, result = request("/completed", '{"model":"original","prompt":"hello"}', "memory")
    assert(status == 200, cjson.encode(result))
    assert(result.input.mode == "completed-memory", cjson.encode(result.input))
    assert(result.transfer.reader_closed and result.transfer.delivered_bytes == result.sink.bytes)
    assert(result.sink.bytes == result.sink.length and result.transfer.max_chunk <= 16384)
    local decoded = capture(result)
    assert(decoded.model == "rewritten" and decoded.prompt == "hello")
    assert(result.original_model == "original" and result.sibling_model == "independent")
end)
check("file source preserves a huge sibling and mixed modifications", function()
    local prompt = ("abcdef0123456789"):rep(131072)
    local status, result = request("/completed?mixed=1", cjson.encode {
        model = "original", prompt = prompt, nested = { flag = true }, remove_me = "delete",
    }, "large")
    assert(status == 200, cjson.encode(result))
    assert(result.input.mode == "completed-file", cjson.encode(result.input))
    local decoded = capture(result)
    assert(decoded.prompt == prompt and decoded.model == "rewritten")
    assert(decoded.remove_me == nil and decoded.nested.flag == false)
    assert(decoded.added.enabled and decoded.added.value == cjson.null)
    assert(result.transfer.max_chunk <= 16384 and result.sink.max_chunk <= 16384)
end)
check("malformed completed JSON produces no upstream request", function()
    local client = http.new()
    local function stats()
        local res = assert(client:request_uri("http://127.0.0.1:" .. sink_port .. "/stats", { keepalive = false }))
        return cjson.decode(res.body).requests
    end
    local before = stats()
    local status, result = request("/completed", '{"model":"valid","bad":[1,]}')
    assert(status == 400 and result.error)
    assert(stats() == before)
end)
check("upstream disconnect is a single failed attempt and closes the reader", function()
    local before = sink_count()
    local status, result = request("/completed?disconnect=1", '{"model":"original","prompt":"hello"}')
    assert(status == 502 and result.error)
    assert(result.transfer.attempts == 1 and result.transfer.reader_closed)
    assert(result.transfer.headers_may_have_been_sent)
    assert(sink_count() == before + 1)
end)
check("fixed-length incremental upload waits for the final duplicate", function()
    local status, result = request("/incremental", '{"model":"first","prompt":"hello","model":"last"}', "incremental")
    assert(status == 200, cjson.encode(result))
    assert(result.input.mode == "incremental" and result.input.model == "last")
    assert(result.input.other_model == "last" and result.input.other_status == "READY")
    assert(capture(result).model == "rewritten")
end)

for _, endpoint in ipairs { "/example-incremental", "/incremental" } do
    for _, model in ipairs { { name = "scalar", raw = '"old"' }, { name = "object", raw = '{"nested":1}' },
        { name = "array", raw = '[1,2]' } } do
        check(endpoint:sub(2) .. " releases " .. model.name .. " query holders and the owned spool without GC", function()
            get("/gc?action=stop")
            local ok, err = xpcall(function()
                local case = endpoint:sub(2) .. "-query-" .. model.name
                local status, result = request(endpoint .. "?case=" .. case, '{"model":' .. model.raw .. ',"prompt":"x"}')
                assert(status == 200, cjson.encode(result))
                local probe = get("/lifecycle/probe?case=" .. case)
                assert(probe.owned, cjson.encode(probe))
                closed_source(probe)
            end, debug.traceback)
            get("/gc?action=restart")
            assert(ok, err)
        end)
    end

    check(endpoint:sub(2) .. " releases container query holders after a post-fork source-read abort without GC", function()
        get("/gc?action=stop")
        local sock
        local ok, err = xpcall(function()
            local case = endpoint:sub(2) .. "-query-abort"
            sock = assert(ngx.socket.tcp())
            assert(sock:connect("127.0.0.1", port))
            local raw = '{"model":{"nested":1},"prompt":"' .. ("p"):rep(200000) .. '"}'
            local delay = endpoint == "/incremental" and "&prepare_delay=1" or ""
            assert(sock:send("POST " .. endpoint .. "?case=" .. case .. "&fault=await-abort" .. delay .. " HTTP/1.1\r\nHost: localhost\r\nContent-Length: " ..
                #raw .. "\r\n\r\n" .. raw))
            local paused = wait_source(case, "paused", sock)
            assert(paused.state.pause_waiting and not paused.state.aborted and paused.fcntl ~= -1
                and paused.path_exists, cjson.encode(paused))
            sock:close()
            sock = nil
            local probe = wait_source(case, "aborted")
            assert(probe.state.aborted and not probe.state.pause_timed_out and probe.paused and probe.owned, cjson.encode(probe))
            closed_source(probe)
        end, debug.traceback)
        if sock then sock:close() end
        get("/gc?action=restart")
        assert(ok, err)
    end)

    check(endpoint:sub(2) .. " releases container query holders after a real connection error without GC", function()
        get("/gc?action=stop")
        local ok, err = xpcall(function()
            local case = endpoint:sub(2) .. "-query-error"
            local status, result = request(endpoint .. "?case=" .. case .. "&fault=connect", '{"model":[1,2],"prompt":"x"}')
            assert((status == 500 or status == 502) and result.error, cjson.encode(result))
            local probe = get("/lifecycle/probe?case=" .. case)
            assert(probe.owned, cjson.encode(probe))
            closed_source(probe)
        end, debug.traceback)
        get("/gc?action=restart")
        assert(ok, err)
    end)
end

check("isolated incremental requests wake both query waiters and finish without control traffic", function()
    get("/gc?action=stop")
    local client
    local ok, err = xpcall(function()
        for _, route in ipairs { { endpoint = "/example-incremental" }, { endpoint = "/incremental" },
            { endpoint = "/incremental", delay = true } } do
            local case = route.endpoint:sub(2) .. "-isolated" .. (route.delay and "-delay" or "")
            client = http.new()
            client:set_timeout(5000)
            assert(client:connect { scheme = "http", host = "127.0.0.1", port = port })
            local raw = '{"model":{"nested":1},"prompt":"' .. ("p"):rep(200000) .. '"}'
            local path = route.endpoint .. "?case=" .. case .. "&fault=pause" .. (route.delay and "&prepare_delay=1" or "")
            assert(client.sock:send("POST " .. path .. " HTTP/1.1\r\nHost: localhost\r\nContent-Length: " ..
                #raw .. "\r\n\r\n" .. raw))
            -- Only receive this response until it is complete: no ping, marker
            -- polling or lifecycle/control request may wake the source worker.
            local res, response_err = client:read_response { method = "POST", headers = {} }
            local body, read_err
            if res then body, read_err = res:read_body() end
            if not res or res.status ~= 200 or not body then
                error(cjson.encode { error = response_err or read_err, status = res and res.status, response = body,
                    probe = get("/lifecycle/probe?case=" .. case) })
            end
            client:close()
            client = nil
            local probe = get("/lifecycle/probe?case=" .. case)
            assert(probe.state.finish_end and probe.state.paused_at and probe.owned, cjson.encode(probe))
            closed_source(probe)
            if route.endpoint == "/incremental" then
                assert(probe.state.phases["main-READY"] and probe.state.phases["waiter-READY"], cjson.encode(probe))
                local result = cjson.decode(body)
                assert(result.input.model.nested == 1 and result.input.other_model.nested == 1, body)
            end
        end
    end, debug.traceback)
    if client then client:close() end
    get("/gc?action=restart")
    assert(ok, err)
end)

check("an intentionally retained query child survives session close until its own close", function()
    get("/gc?action=stop")
    local ok, err = xpcall(function()
        for _, model in ipairs { '{"nested":1}', '[1,2]' } do
            local case = "retained-query-" .. #model
            local status, result = request("/lifecycle/retained?case=" .. case, '{"model":' .. model .. '}')
            assert(status == 200 and result.alive_after_close and type(result.value) == "table", cjson.encode(result))
            local probe = get("/lifecycle/probe?case=" .. case)
            assert(probe.owned, cjson.encode(probe))
            closed_source(probe)
        end
    end, debug.traceback)
    get("/gc?action=restart")
    assert(ok, err)
end)

check("HTTP depth policy has identical memory, file, feed and fallback verdicts", function()
    for _, incremental in ipairs { false, true } do
        for _, large in ipairs { false, true } do
            for _, fallback in ipairs { false, true } do
                local endpoint = incremental and "/policy/incremental" or "/policy/completed"
                local raw = '{"a":{}' .. (large and ',"pad":"' .. ("p"):rep(200000) .. '"' or '') .. '}'
                local headers
                if fallback then
                    raw = string.format("%x\r\n%s\r\n0\r\n\r\n", #raw, raw)
                    headers = { ["Transfer-Encoding"] = "chunked" }
                end
                for _, limit in ipairs { 1, 2, 0, 4294967295 } do
                    local status, result = request(endpoint .. "?depth=" .. limit, raw, nil, headers)
                    assert(status == 200 and result.accepted == (limit ~= 1), cjson.encode(result))
                    if incremental and not fallback then assert(result.mode == "incremental", cjson.encode(result))
                    else assert(result.mode == (large and "completed-file" or "completed-memory"), cjson.encode(result)) end
                end
            end
        end
    end
end)

check("HTTP rejects invalid depth, lazy and source options in every input mode", function()
    local invalid = { "depth=-1", "depth=1.5", "depth=nan", "depth=infinity", "depth=string", "depth=boolean",
        "depth=table", "depth=4294967296", "lazy=true", "lazy=invalid", "options=false", "options=decode-false",
        "options=chunk-false", "options=hook-false", "options=temp-false" }
    for _, endpoint in ipairs { "/policy/completed", "/policy/incremental" } do
        for _, large in ipairs { false, true } do
            for _, fallback in ipairs { false, true } do
                local raw = '{"a":1' .. (large and ',"pad":"' .. ("p"):rep(100000) .. '"' or '') .. '}'
                local headers
                if fallback then
                    raw = string.format("%x\r\n%s\r\n0\r\n\r\n", #raw, raw)
                    headers = { ["Transfer-Encoding"] = "chunked" }
                end
                for _, option in ipairs(invalid) do
                    local status, result = request(endpoint .. "?" .. option, raw, nil, headers)
                    assert(status == 200 and not result.accepted and result.error, cjson.encode(result))
                end
            end
        end
    end
end)
check("HTTP forwarding normalizes duplicate keys in untouched nested containers", function()
    local status, result = request("/completed", '{"model":"original","nested":{"key":"first","key":"last"}}', "duplicates")
    assert(status == 200, cjson.encode(result))
    local decoded, raw = capture(result)
    assert(decoded.nested.key == "last")
    local _, occurrences = raw:gsub('"key"%s*:', "")
    assert(occurrences == 1, raw)
end)
check("root false and null are values, not input failures", function()
    local status, result = request("/scalar", "false")
    assert(status == 200 and result.value == false)
    status, result = request("/scalar", "null")
    assert(status == 200 and result.value == cjson.null)
end)
check("the example rejects an array root and releases both root and fork", function()
    local before = get("/health")
    get("/gc?action=stop")
    local ok, err = xpcall(function()
        local status, result = request("/example", '["' .. ("r"):rep(200000) .. '"]')
        assert(status == 400 and result.error, cjson.encode(result))
        local after = get("/health")
        assert(after.fd_count <= before.fd_count + 2, cjson.encode { before = before, after = after })
    end, debug.traceback)
    get("/gc?action=restart")
    assert(ok, err)
end)
for _, endpoint in ipairs { "/example", "/completed" } do
    local name = endpoint:sub(2)
    check(name .. " closes a fork cancelled during its first yielding write without GC", function()
        local before = sink_count()
        get("/gc?action=stop")
        local ok, err = xpcall(function()
            local case = name .. "-first-write-abort"
            local marker = os.getenv("LEANJSON_TEST_PREFIX") .. "/mutation-" .. case
            local sock = assert(ngx.socket.tcp())
            assert(sock:connect("127.0.0.1", port))
            local raw = '{"model":"old","prompt":"' .. ("p"):rep(200000) .. '"}'
            local route = endpoint .. "?case=" .. case .. "&fault=pause"
            assert(sock:send("POST " .. route .. " HTTP/1.1\r\nHost: localhost\r\nContent-Length: " ..
                #raw .. "\r\n\r\n" .. raw))
            local paused
            for _ = 1, 100 do
                local file = io.open(marker, "r")
                if file then file:close(); paused = true; break end
                ngx.sleep(0.01)
            end
            assert(paused, "first mutation never reached a source read")
            sock:close()
            ngx.sleep(0.3)
            local probe = get("/lifecycle/probe?case=" .. case)
            assert(probe.paused, cjson.encode(probe))
            closed_source(probe)
            assert(sink_count() == before)
        end, debug.traceback)
        get("/gc?action=restart")
        assert(ok, err)
    end)
    check(name .. " unwinds a first-write source error and closes its fd without GC", function()
        local before = sink_count()
        get("/gc?action=stop")
        local ok, err = xpcall(function()
            local case = name .. "-first-write-error"
            local raw = '{"model":"old","prompt":"' .. ("p"):rep(200000) .. '"}'
            local client = http.new()
            local response = assert(client:request_uri("http://127.0.0.1:" .. port .. endpoint ..
                "?case=" .. case .. "&fault=truncate", { method = "POST", body = raw, keepalive = false }))
            assert(response.status == 500, response.body)
            local probe = get("/lifecycle/probe?case=" .. case)
            assert(probe.truncated, cjson.encode(probe))
            closed_source(probe)
            assert(sink_count() == before)
        end, debug.traceback)
        get("/gc?action=restart")
        assert(ok, err)
    end)
end
for _, endpoint in ipairs { "/example", "/connect-failure" } do
    check(endpoint:sub(2) .. " releases all file holders after an upstream connection failure without GC", function()
        get("/gc?action=stop")
        local ok, err = xpcall(function()
            local case = endpoint:sub(2) .. "-connection-error"
            local raw = '{"model":"old","prompt":"' .. ("c"):rep(200000) .. '"}'
            local status, result = request(endpoint .. "?case=" .. case .. "&fault=connect", raw)
            assert((status == 500 or status == 502) and result.error, cjson.encode(result))
            local probe = get("/lifecycle/probe?case=" .. case)
            closed_source(probe)
        end, debug.traceback)
        get("/gc?action=restart")
        assert(ok, err)
    end)
end
for _, kind in ipairs { "core", "adapter", "fallback" } do
    check(kind .. " completed-file roots release the real fd after request-end GC", function()
        local raw = '{"model":"old","prompt":"' .. ("g"):rep(200000) .. '"}'
        local case = "forgotten-" .. kind
        local headers
        if kind == "fallback" then
            raw = string.format("%x\r\n%s\r\n0\r\n\r\n", #raw, raw)
            headers = { ["Transfer-Encoding"] = "chunked" }
        end
        local status, result = request("/lifecycle/" .. kind .. "?case=" .. case, raw, nil, headers)
        assert(status == 200 and result.decoded and result.input.mode == "completed-file", cjson.encode(result))
        if kind == "fallback" then assert(result.input.fallback == "transfer-encoding") end
        ngx.sleep(0.05)
        local probe = get("/lifecycle/probe?case=" .. case .. "&gc=1")
        closed_source(probe)
    end)
end
check("request body has one input owner", function()
    local status, result = request("/ownership", '{"model":"original"}')
    assert(status == 200 and result.error:find("already owned", 1, true))
end)
check("HTTP/1.1 chunked upload uses the completed fallback", function()
    local raw = '{"model":"original","prompt":"chunked"}'
    local framed = string.format("%x\r\n%s\r\n0\r\n\r\n", #raw, raw)
    local status, result = request("/incremental", framed, nil, { ["Transfer-Encoding"] = "chunked" })
    assert(status == 200, cjson.encode(result))
    assert(result.input.mode == "completed-memory" and result.input.fallback == "transfer-encoding")
    assert(result.sink.transfer_encoding == nil and result.sink.length == result.sink.bytes)
end)
check("HTTP/2 upload uses the completed fallback", function()
    local command = "curl --http2-prior-knowledge --silent --show-error --fail-with-body --data-binary " ..
        "'{\"model\":\"original\",\"prompt\":\"http2\"}' http://127.0.0.1:" .. port .. "/incremental"
    local pipe = assert(io.popen(command, "r"))
    local raw = pipe:read("*a")
    local ok = pipe:close()
    assert(ok, raw)
    local result = cjson.decode(raw)
    assert(result.input.mode == "completed-memory" and result.input.fallback == "http-version", raw)
end)
check("a slow duplicate does not trigger an upstream side effect before finish", function()
    local before = sink_count()
    local first = '{"model":"first","prompt":"'
    local last = 'hello","model":"last"}'
    local client = http.new()
    client:set_timeout(5000)
    assert(client:connect { scheme = "http", host = "127.0.0.1", port = port })
    local sent_first = false
    local worker = ngx.thread.spawn(function()
        local step = 0
        local res, err = client:request { method = "POST", path = "/incremental",
            headers = { ["Content-Length"] = tostring(#first + #last) }, body = function()
                step = step + 1
                if step == 1 then sent_first = true; return first end
                if step == 2 then ngx.sleep(0.2); return last end
            end }
        assert(res, err)
        local raw = assert(res:read_body())
        client:close()
        return res.status, cjson.decode(raw)
    end)
    while not sent_first do ngx.sleep(0.001) end
    ngx.sleep(0.05)
    assert(sink_count() == before)
    local ok, status, result = ngx.thread.wait(worker)
    assert(ok and status == 200, cjson.encode(result))
    assert(result.input.model == "last" and result.input.other_model == "last")
end)
check("malformed incremental JSON wakes all waiters without forwarding", function()
    local before = sink_count()
    for _, raw in ipairs { '{"model":"first","bad":[1,]}', '{"model":"first"} trailing' } do
        local status, result = request("/incremental", raw)
        assert(status == 400 and result.error)
    end
    assert(sink_count() == before)
end)
check("source hook failures wake waiters and never send upstream", function()
    local before = sink_count()
    local raw = '{"model":"original","prompt":"' .. ("h"):rep(200000) .. '"}'
    for _, endpoint in ipairs { "/completed?hook=1", "/incremental?hook=1" } do
        local status, result = request(endpoint, raw)
        assert(status == 400 and result.error:find("intentional source hook failure", 1, true), cjson.encode(result))
    end
    assert(sink_count() == before)
end)
check("spool creation failure is explicit without an in-memory fallback", function()
    local before = sink_count()
    local status, result = request("/incremental?temp_error=1", '{"model":"original"}')
    assert(status == 400 and result.error, cjson.encode(result))
    assert(sink_count() == before)
end)
check("an external abort callback conflict is reported explicitly", function()
    local status, result = request("/external-abort", '{"model":"original"}')
    assert(status == 400 and result.error:find("ngx.on_abort", 1, true), cjson.encode(result))
end)
check("source read failure is preserved as failure instead of EOF", function()
    local status, result = request("/io-failure", '{"model":"original","prompt":"' .. ("x"):rep(200000) .. '"}')
    assert(status == 502 and result.error, cjson.encode(result))
    assert(result.transfer.reader_error and result.transfer.reader_closed)
    assert(result.transfer.attempts <= 1)
end)
check("an unlinked Nginx source remains readable through its open file lease", function()
    local prompt = ("z"):rep(200000)
    local status, result = request("/unlink-source", '{"model":"original","prompt":"' .. prompt .. '"}', "unlinked")
    assert(status == 200, cjson.encode(result))
    assert(capture(result).prompt == prompt)
end)
check("output cancellation stops a transfer, closes its reader, and never retries", function()
    local status, result = request("/cancel-output", '{"model":"original","prompt":"' .. ("y"):rep(200000) .. '"}')
    assert(status == 502 and result.error == "request cancelled", cjson.encode(result))
    assert(result.transfer.reader_closed and result.transfer.attempts == 1)
    assert(result.transfer.delivered_bytes <= 16384)
end)
check("aborted uploads release resources and the same worker stays alive", function()
    local before = sink_count()
    local health = get("/health")
    for _ = 1, 8 do
        local sock = assert(ngx.socket.tcp())
        assert(sock:connect("127.0.0.1", port))
        assert(sock:send("POST /incremental HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\n\r\n" ..
            '{"model":"partial","prompt":"' .. ("a"):rep(40000)))
        ngx.sleep(0.01)
        sock:close()
    end
    ngx.sleep(0.1)
    local after = get("/health")
    assert(after.pid == health.pid)
    assert(after.fd_count <= health.fd_count + 2, cjson.encode { before = health, after = after })
    assert(sink_count() == before)
    empty_directory("decoder")
end)
check("client abort during yielding completed-file scanning closes its fd without GC", function()
    local before = get("/health")
    local upstream_before = sink_count()
    get("/gc?action=stop")
    local ok, err = xpcall(function()
        local marker = os.getenv("LEANJSON_TEST_PREFIX") .. "/file-parse-started"
        local sock = assert(ngx.socket.tcp())
        assert(sock:connect("127.0.0.1", port))
        local raw = '{"model":"original","prompt":"' .. ("p"):rep(200000) .. '"}'
        assert(sock:send("POST /abort-file-parse HTTP/1.1\r\nHost: localhost\r\nContent-Length: " .. #raw .. "\r\n\r\n" .. raw))
        local scanning
        for _ = 1, 100 do
            local file = io.open(marker, "r")
            if file then file:close(); scanning = true; break end
            ngx.sleep(0.01)
        end
        assert(scanning, "file decoder never entered its yielding scan")
        sock:close()
        ngx.sleep(0.1)
        local after = get("/health")
        assert(after.pid == before.pid and after.fd_count <= before.fd_count + 2,
            cjson.encode { before = before, after = after })
        assert(sink_count() == upstream_before)
    end, debug.traceback)
    get("/gc?action=restart")
    assert(ok, err)
end)
check("explicit session close wakes every pending get waiter", function()
    local raw = '{"model":"pending","prompt":"' .. ("w"):rep(40000) .. '"}'
    local client = http.new()
    client:set_timeout(5000)
    assert(client:connect { scheme = "http", host = "127.0.0.1", port = port })
    local step = 0
    local res, err = client:request { method = "POST", path = "/close-waiters",
        headers = { ["Content-Length"] = tostring(#raw) }, body = function()
            step = step + 1
            if step == 1 then return raw:sub(1, 100) end
            if step == 2 then ngx.sleep(0.05); return raw:sub(101) end
        end }
    assert(res, err)
    local result = cjson.decode(assert(res:read_body()))
    client:close()
    assert(result.first.ok and result.second.ok)
    assert(result.first.status == "ERROR" and result.second.status == "ERROR")
    assert(result.first.error and result.second.error)
end)
check("client abort during normalized output length closes the reader before sending", function()
    local before = get("/health")
    local upstream_before = sink_count()
    get("/gc?action=stop")
    local ok, err = xpcall(function()
        local marker = os.getenv("LEANJSON_TEST_PREFIX") .. "/output-length-started"
        local sock = assert(ngx.socket.tcp())
        assert(sock:connect("127.0.0.1", port))
        local raw = '{"model":"original","nested":{"small":"value","prompt":"' .. ("p"):rep(200000) .. '"}}'
        assert(sock:send("POST /abort-output-length HTTP/1.1\r\nHost: localhost\r\nContent-Length: " .. #raw .. "\r\n\r\n" .. raw))
        local counting
        for _ = 1, 100 do
            local file = io.open(marker, "r")
            if file then file:close(); counting = true; break end
            ngx.sleep(0.01)
        end
        assert(counting, "normalized length never entered a yielding source read")
        sock:close()
        ngx.sleep(0.1)
        local after = get("/health")
        assert(after.pid == before.pid and after.fd_count <= before.fd_count + 2,
            cjson.encode { before = before, after = after })
        assert(sink_count() == upstream_before)
    end, debug.traceback)
    get("/gc?action=restart")
    assert(ok, err)
end)
check("an output source hook failure stays a reader failure and closes the transfer", function()
    local raw = '{"model":"original","prompt":"' .. ("o"):rep(200000) .. '"}'
    local status, result = request("/output-hook-failure", raw)
    assert(status == 502 and result.error:find("intentional output hook failure", 1, true), cjson.encode(result))
    assert(result.transfer.reader_error and result.transfer.reader_closed)
    assert(result.transfer.attempts == 1 and result.transfer.headers_may_have_been_sent)
end)
check("one failing abort callback cannot suppress other cleanup callbacks", function()
    local marker = os.getenv("LEANJSON_TEST_PREFIX") .. "/abort-cleanup-ran"
    local sock = assert(ngx.socket.tcp())
    assert(sock:connect("127.0.0.1", port))
    local raw = '{"model":"original"}'
    assert(sock:send("POST /abort-callbacks HTTP/1.1\r\nHost: localhost\r\nContent-Length: " .. #raw .. "\r\n\r\n" .. raw))
    while true do
        local line = assert(sock:receive("*l"))
        if line == "ready" then break end
    end
    sock:close()
    local ran
    for _ = 1, 100 do
        local file = io.open(marker, "r")
        if file then file:close(); ran = true; break end
        ngx.sleep(0.01)
    end
    assert(ran, "cleanup following the throwing callback did not run")
end)
check("concurrent file uploads preserve isolated values and release descriptors", function()
    local baseline = get("/health")
    local before = sink_count()
    local threads = {}
    for i = 1, 8 do
        threads[i] = ngx.thread.spawn(function()
            local prompt = string.char(64 + i):rep(300000)
            local status, result = request("/completed", '{"model":"original","prompt":"' .. prompt .. '"}', "parallel-" .. i)
            assert(status == 200, cjson.encode(result))
            assert(result.input.mode == "completed-file")
            assert(capture(result).prompt == prompt)
        end)
    end
    for _, thread in ipairs(threads) do local ok, err = ngx.thread.wait(thread); assert(ok, err) end
    local final = get("/health")
    assert(final.pid == baseline.pid and final.fd_count <= baseline.fd_count + 2)
    assert(sink_count() == before + 8)
end)
check("all completed and failed paths clean file leases without forcing GC", function()
    local final = get("/health")
    assert(final.pid == initial_health.pid)
    assert(final.fd_count <= initial_health.fd_count + 2, cjson.encode { initial = initial_health, final = final })
    empty_directory("client-body")
    empty_directory("decoder")
end)
print("1.." .. count)
assert(failures == 0, failures .. " native OpenResty acceptance checks failed")
