local cjson = require "cjson"
local http = require "resty.http"
local port = assert(tonumber(os.getenv("QJSON_TEST_PORT")))
local sink_port = assert(tonumber(os.getenv("QJSON_SINK_PORT")))
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
    local directory = os.getenv("QJSON_TEST_PREFIX") .. "/" .. name
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
        local marker = os.getenv("QJSON_TEST_PREFIX") .. "/file-parse-started"
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
        local marker = os.getenv("QJSON_TEST_PREFIX") .. "/output-length-started"
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
    local marker = os.getenv("QJSON_TEST_PREFIX") .. "/abort-cleanup-ran"
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
