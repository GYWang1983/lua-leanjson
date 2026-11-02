-- Adapter for the unchanged contiguous-input C ABI. Other backends need only
-- implement the protocol consumed by leanjson.proxy; they need no FFI cursor.
local ffi = require("ffi")
local C = require("leanjson.lib")
local M = {}
local Memory = {}; Memory.__index = Memory
local kinds = { [0] = "null", "boolean", "number", "string", "array", "object" }
local SIZE_MAX = ffi.cast("size_t", -1)

local function check(self, rc)
    if rc == 0 then return true end
    if rc == 2 then return false end
    local offset = C.leanjson_doc_last_error_offset(self.doc._ptr)
    local size = tonumber(C.leanjson_format_error(rc, offset, SIZE_MAX, self.doc._hold,
        #self.doc._hold, nil, 0))
    local buf = ffi.new("char[?]", size + 1)
    local written = C.leanjson_format_error(rc, offset, SIZE_MAX, self.doc._hold,
        #self.doc._hold, buf, size + 1)
    error("leanjson: " .. ffi.string(buf, written), 0)
end

local function cursor_copy(box)
    local own = ffi.new("leanjson_cursor[1]")
    ffi.copy(own, box, ffi.sizeof("leanjson_cursor"))
    return own
end

function Memory:type(handle)
    local out = ffi.new("int[1]")
    check(self, C.leanjson_cursor_typeof(handle[0], "", 0, out))
    return kinds[tonumber(out[0])]
end

function Memory:scalar(handle)
    local kind = self:type(handle)
    if kind == "string" then
        local ptr, size = ffi.new("const uint8_t*[1]"), ffi.new("size_t[1]")
        check(self, C.leanjson_cursor_get_str(handle[0], "", 0, ptr, size))
        -- Copy before another FFI call can reuse the document scratch storage.
        return ffi.string(ptr[0], size[0])
    elseif kind == "number" then
        local out = ffi.new("double[1]")
        check(self, C.leanjson_cursor_get_f64(handle[0], "", 0, out))
        return tonumber(out[0])
    elseif kind == "boolean" then
        local out = ffi.new("int[1]")
        check(self, C.leanjson_cursor_get_bool(handle[0], "", 0, out))
        return out[0] ~= 0
    elseif kind == "null" then
        return nil
    end
    error("leanjson: expected scalar", 0)
end

function Memory:children(handle)
    local box = ffi.new("leanjson_cursor[1]")
    if self:type(handle) == "object" then
        local it = ffi.new("leanjson_iter[1]")
        local ptr, size = ffi.new("const uint8_t*[1]"), ffi.new("size_t[1]")
        check(self, C.leanjson_iter_init(handle[0], it))
        return function()
            if not check(self, C.leanjson_iter_next(it, ptr, size, box)) then return nil end
            local key = ffi.string(ptr[0], size[0])
            return key, cursor_copy(box)
        end
    end
    local index = 0
    return function()
        if not check(self, C.leanjson_cursor_index(handle[0], index, box)) then return nil end
        index = index + 1
        return index, cursor_copy(box)
    end
end

function Memory:span(handle)
    local first, last = ffi.new("size_t[1]"), ffi.new("size_t[1]")
    check(self, C.leanjson_cursor_bytes(handle[0], first, last))
    return tonumber(first[0]), tonumber(last[0])
end

function Memory:read(offset, length)
    return self.doc._hold:sub(offset + 1, offset + length)
end

function M.open(raw, opts)
    local policy
    if opts ~= nil then
        local normalized = require("leanjson.options").normalize(opts)
        policy = { max_depth = normalized.max_depth, lazy = false }
    end
    local doc = require("leanjson").parse(raw, policy)
    local backend = setmetatable({ doc = doc }, Memory)
    local root = ffi.new("leanjson_cursor[1]")
    check(backend, C.leanjson_open(doc._ptr, "", 0, root))
    return backend, root
end

return M
