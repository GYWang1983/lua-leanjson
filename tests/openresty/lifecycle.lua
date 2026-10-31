local cjson = require "cjson"
local ffi = require "ffi"
ffi.cdef[[int fcntl(int, int, ...);]]
ngx.header.content_type = "application/json"
if ngx.var.uri == "/lifecycle/probe" then
    if ngx.var.arg_gc == "1" then
        for _ = 1, 3 do collectgarbage("collect") end
    end
    local record = assert(require("qjson.test_state")[ngx.var.arg_case], "source fd was not recorded")
    ffi.errno(0)
    local result = ffi.C.fcntl(record.fd, 1)
    ngx.say(cjson.encode { fd = record.fd, fcntl = result, errno = ffi.errno(),
        paused = record.paused, truncated = record.truncated, owned = record.owned,
        path_exists = require("lfs").attributes(record.filename) ~= nil })
    return
end

local qjson = require "qjson"
local adapter = require "qjson.openresty"
if ngx.var.uri == "/lifecycle/retained" then
    local session, child, unregister
    local function cleanup()
        qjson.close(child)
        if session then session:close() end
    end
    local ok, result = pcall(function()
        session = assert(adapter.start_body { temp_dir = os.getenv("QJSON_TEST_PREFIX") .. "/decoder" })
        unregister = assert(adapter.on_abort(cleanup))
        local status, err
        child, status, err = session:get("model")
        assert(status == "READY", err)
        session:close()
        local record = assert(require("qjson.test_state")[ngx.var.arg_case])
        local alive = ffi.C.fcntl(record.fd, 1) ~= -1 and require("lfs").attributes(record.filename) ~= nil
        return { alive_after_close = alive, value = qjson.materialize(child) }
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
    value = qjson.decode_file(assert(ngx.req.get_body_file()))
    info = { mode = "completed-file" }
elseif ngx.var.uri == "/lifecycle/adapter" then
    value, err, info = adapter.read_body()
else
    local session
    session, err, info = adapter.start_body()
    if session then value, err = session:finish() end
end
assert(not err, err)
assert(qjson.type(value) == "object")
ngx.say(cjson.encode { decoded = true, input = info })
-- Deliberately omit close: test the promised GC fallback after request end.
