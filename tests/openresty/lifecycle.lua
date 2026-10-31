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
        paused = record.paused, truncated = record.truncated })
    return
end

local qjson = require "qjson"
local adapter = require "qjson.openresty"
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
