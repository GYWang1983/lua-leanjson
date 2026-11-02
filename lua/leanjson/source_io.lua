-- Synchronous POSIX I/O. All read/write sizes are bounded by the source adapter.
local ffi = require("ffi")
ffi.cdef[[
int open(const char *, int, ...);
int close(int);
int mkstemp(char *);
int unlink(const char *);
int64_t pread(int, void *, size_t, int64_t);
int64_t pwrite(int, const void *, size_t, int64_t);
char *strerror(int);
]]
local M = {}

local function failure(operation)
    return "leanjson: " .. operation .. ": " .. ffi.string(ffi.C.strerror(ffi.errno()))
end

function M.open(path)
    local fd = ffi.C.open(path, 0)
    if fd < 0 then return nil, failure("open") end
    return fd
end

function M.spool(directory)
    local template = directory .. "/leanjson-source-XXXXXX"
    local buffer = ffi.new("char[?]", #template + 1, template)
    local fd = ffi.C.mkstemp(buffer)
    if fd < 0 then return nil, failure("create spool") end
    return fd, ffi.string(buffer)
end

function M.close(fd, path)
    ffi.C.close(fd)
    if path then ffi.C.unlink(path) end
end

function M.read(fd, offset, length)
    local buffer = ffi.new("uint8_t[?]", length)
    local n
    repeat n = tonumber(ffi.C.pread(fd, buffer, length, offset)) until n >= 0 or ffi.errno() ~= 4
    if n < 0 then return nil, failure("read") end
    return ffi.string(buffer, n)
end

function M.write(fd, offset, value, first, length)
    local written = 0
    while written < length do
        local n = tonumber(ffi.C.pwrite(fd, ffi.cast("const uint8_t *", value) + first + written,
            length - written, offset + written))
        if n < 0 and ffi.errno() ~= 4 then return nil, failure("write") end
        if n == 0 then return nil, "leanjson: spool write made no progress" end
        if n > 0 then written = written + n end
    end
    return true
end

return M
