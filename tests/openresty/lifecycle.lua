local cjson = require "cjson"
local ffi = require "ffi"
ffi.cdef[[int fcntl(int, int, ...);]]
ngx.header.content_type = "application/json"
local function probe(record)
    if not record then return { present = false } end
    ffi.errno(0)
    local result = ffi.C.fcntl(record.fd, 1)
    return { fd = record.fd, fcntl = result, errno = ffi.errno(),
        paused = record.paused, truncated = record.truncated, owned = record.owned,
        path_exists = require("lfs").attributes(record.filename) ~= nil, state = record }
end
if ngx.var.uri == "/lifecycle/wait" then
    local records = require("leanjson.test_state")
    local deadline = ngx.now() + 5
    local record, ready
    repeat
        record = records[ngx.var.arg_case]
        ready = record and (ngx.var.arg_event == "aborted" and record.aborted
            or ngx.var.arg_event ~= "aborted" and record.pause_waiting and not record.aborted)
        if ready or (record and (record.closed_at or record.pause_timed_out)) then break end
        ngx.sleep(0.01)
    until ngx.now() >= deadline
    local result = probe(record)
    result.ready = ready or false
    ngx.say(cjson.encode(result))
    return
end
if ngx.var.uri == "/lifecycle/probe" then
    if ngx.var.arg_gc == "1" then
        for _ = 1, 3 do collectgarbage("collect") end
    end
    ngx.say(cjson.encode(probe(require("leanjson.test_state")[ngx.var.arg_case])))
    return
end

local leanjson = require "leanjson"
local adapter = require "leanjson.openresty"
if ngx.var.uri == "/lifecycle/retained" then
    local session, child, unregister
    local function cleanup()
        leanjson.close(child)
        if session then session:close() end
    end
    local ok, result = pcall(function()
        session = assert(adapter.start_body { file_in_memory = false, temp_dir = os.getenv("LEANJSON_TEST_PREFIX") .. "/decoder" })
        unregister = assert(adapter.on_abort(cleanup))
        local status, err
        child, status, err = session:get("model")
        assert(status == "READY", err)
        session:close()
        local record = assert(require("leanjson.test_state")[ngx.var.arg_case])
        local alive = ffi.C.fcntl(record.fd, 1) ~= -1 and require("lfs").attributes(record.filename) ~= nil
        return { alive_after_close = alive, value = leanjson.materialize(child) }
    end)
    cleanup()
    if unregister then unregister() end
    assert(ok, result)
    ngx.say(cjson.encode(result))
    return
end
local value, err, info
if ngx.var.uri == "/lifecycle/core" then
    ngx.req.read_body()
    value = leanjson.decode_file(assert(ngx.req.get_body_file()), {file_in_memory = false})
    info = { mode = "completed-file" }
elseif ngx.var.uri == "/lifecycle/adapter" then
    ngx.req.read_body()
    value, err, info = adapter.read_body({file_in_memory = false})
else
    local session
    session, err, info = adapter.start_body({file_in_memory = false})
    if session then value, err = session:finish() end
end
assert(not err, err)
assert(leanjson.type(value) == "object")
ngx.say(cjson.encode { decoded = true, input = info })
-- Deliberately omit close: test the promised GC fallback after request end.
