local M = {}
function M.sample()
    local file = assert(io.open("/proc/self/status", "r"))
    local raw = file:read("*a")
    file:close()
    return { rss_kib = tonumber(raw:match("VmRSS:%s+(%d+)")),
        hwm_kib = tonumber(raw:match("VmHWM:%s+(%d+)")), lua_kib = collectgarbage("count"), cpu_s = os.clock() }
end
function M.cold_advice(path)
    local ffi = require "ffi"
    ffi.cdef [[ int open(const char *, int, ...); int fsync(int); int close(int);
        int posix_fadvise(int, int64_t, int64_t, int); ]]
    local fd = ffi.C.open(path, 0)
    if fd < 0 then return nil, "open failed" end
    local synced = ffi.C.fsync(fd)
    local advised = ffi.C.posix_fadvise(fd, 0, 0, 4) -- Linux POSIX_FADV_DONTNEED
    ffi.C.close(fd)
    if synced ~= 0 or advised ~= 0 then return nil, "fsync/fadvise failed" end
    return true -- advisory eviction, not proof that every page was evicted
end
return M
