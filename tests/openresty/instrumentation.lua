-- Native lifecycle probes retain only fd numbers, paths and timing flags.
-- They never retain a JSON holder/backend or replace a source read result.
local qjson = require "qjson"
local source_io = require "qjson.source_io"
local ffi = require "ffi"
local lfs = require "lfs"
ffi.cdef[[int fcntl(int, int, ...);]]
local state = {}
local descriptors = {}
package.loaded["qjson.test_state"] = state

local original_open = source_io.open
source_io.open = function(filename)
    local fd, err = original_open(filename)
    local case = ngx.var.arg_case
    if case and fd then
        local record = { fd = fd, filename = filename, opened_at = ngx.now() }
        state[case], descriptors[fd] = record, record
    end
    return fd, err
end

local original_spool = source_io.spool
source_io.spool = function(directory)
    local fd, filename = original_spool(directory)
    local case = ngx.var.arg_case
    if case and fd then
        local record = { fd = fd, filename = filename, owned = true, opened_at = ngx.now() }
        state[case], descriptors[fd] = record, record
    end
    return fd, filename
end

local original_write = source_io.write
source_io.write = function(fd, offset, value, first, length)
    local ok, err = original_write(fd, offset, value, first, length)
    local record = state[ngx.var.arg_case]
    if record and ok then record.written = offset + length; record.written_at = ngx.now() end
    return ok, err
end

local original_decoder = qjson.new_decoder
qjson.new_decoder = function(...)
    local decoder = original_decoder(...)
    local record = state[ngx.var.arg_case]
    if record then
        local finish = decoder.finish
        function decoder:finish(...)
            record.finish_start = ngx.now()
            local value, err = finish(self, ...)
            record.finish_end = ngx.now()
            return value, err
        end
    end
    return decoder
end

local original_close = source_io.close
source_io.close = function(fd, filename)
    original_close(fd, filename)
    local record = descriptors[fd]
    if record then
        -- Check before yielding or accepting another connection, which can
        -- reuse this descriptor number before a later HTTP probe arrives.
        ffi.errno(0)
        record.close_fcntl = ffi.C.fcntl(fd, 1)
        record.close_errno = ffi.errno()
        if record.owned then record.close_unlinked = lfs.attributes(record.filename) == nil end
        record.closed_at = ngx.now()
        descriptors[fd] = nil
    end
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
        record.forked_at = ngx.now()
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
    if record then record.reads = (record.reads or 0) + 1 end
    local fault = ngx.var.arg_fault
    if record and record.after_fork and not record.paused and (fault == "pause" or fault == "await-abort") then
        record.paused = true
        record.paused_at = ngx.now()
        record.pause_phase = record.phase
        if fault == "await-abort" then
            local gate = assert(require("ngx.semaphore").new())
            local unregister = assert(require("qjson.openresty").on_abort(function()
                record.aborted = true
                record.aborted_at = ngx.now()
                gate:post()
            end))
            record.pause_waiting = true
            local ok, err = gate:wait(5)
            record.pause_waiting = false
            unregister()
            if not ok then
                record.pause_timed_out = true
                error("test source-read abort watchdog: " .. tostring(err))
            end
        else
            local marker = assert(io.open(os.getenv("QJSON_TEST_PREFIX") .. "/mutation-" .. case, "w"))
            marker:write("ready")
            marker:close()
            ngx.sleep(0.15)
        end
    end
    return original_read(...)
end
