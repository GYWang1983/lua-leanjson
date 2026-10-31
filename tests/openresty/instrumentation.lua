-- Native lifecycle probes retain only fd numbers, paths and timing flags.
-- They never retain a JSON holder/backend or replace a source read result.
local qjson = require "qjson"
local source_io = require "qjson.source_io"
local state = {}
package.loaded["qjson.test_state"] = state

local original_open = source_io.open
source_io.open = function(filename)
    local fd, err = original_open(filename)
    local case = ngx.var.arg_case
    if case and fd then state[case] = { fd = fd, filename = filename } end
    return fd, err
end

local original_spool = source_io.spool
source_io.spool = function(directory)
    local fd, filename = original_spool(directory)
    local case = ngx.var.arg_case
    if case and fd then state[case] = { fd = fd, filename = filename, owned = true } end
    return fd, filename
end

-- The shipped example connects to the real bounded sink in this harness. Its
-- connection-error case still uses a real refused TCP connection.
local http = require "resty.http"
local original_new = http.new
http.new = function(...)
    local client = original_new(...)
    local connect = client.connect
    function client:connect(params, ...)
        if ngx.var.arg_fault == "connect" then params.port = 1 end
        return connect(self, params, ...)
    end
    return client
end

local original_fork = qjson.fork
qjson.fork = function(value)
    local branch = original_fork(value)
    local record = state[ngx.var.arg_case]
    if record then
        record.after_fork = true
        if ngx.var.arg_fault == "truncate" and not record.truncated then
            assert(io.open(record.filename, "wb")):close()
            record.truncated = true
        end
    end
    return branch
end

local original_read = source_io.read
source_io.read = function(...)
    local case = ngx.var.arg_case
    local record = state[case]
    if record and record.after_fork and not record.paused and ngx.var.arg_fault == "pause" then
        record.paused = true
        local marker = assert(io.open(os.getenv("QJSON_TEST_PREFIX") .. "/mutation-" .. case, "w"))
        marker:write("ready")
        marker:close()
        ngx.sleep(0.15)
    end
    return original_read(...)
end
