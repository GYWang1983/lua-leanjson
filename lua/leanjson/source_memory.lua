-- Memory input uses the same bounded native validator and span ABI as disk
-- sources. The original Lua string is pinned by the backend, never a full tree.
local ffi = require("ffi")
local C = require("leanjson.lib")
local shared = require("leanjson.source_backend")
local Memory = {}; Memory.__index = Memory
for name, method in pairs(shared) do Memory[name] = method end
function Memory:retain() self:check_open() end
function Memory:release() end
function Memory:check_open() end
function Memory:notify() end
function Memory:read(offset, length)
    return ffi.string(ffi.cast("const uint8_t *", self.raw) + offset, math.min(length, self.opts.chunk_size))
end
local M = {}
function M.open(raw, opts)
    if type(raw) ~= "string" then error("leanjson: input must be a string", 0) end
    opts = require("leanjson.options").normalize(opts)
    local result = ffi.new("leanjson_source_v1_result[1]")
    local source = C.leanjson_source_v2_new(shared.native_options(opts), result)
    if source == nil then error(shared.result_error(result), 0) end
    source = ffi.gc(source, C.leanjson_source_v1_release)
    -- Validation borrows input and stores no token bytes or input pointer.
    shared.require_status(C.leanjson_source_v1_feed(source, 0, raw, #raw, result), 2, result)
    shared.require_status(C.leanjson_source_v1_finish(source, #raw, result), 0, result)
    local root = ffi.new("leanjson_source_v2_node[1]")
    shared.require_status(C.leanjson_source_v2_root(source, root, result), 0, result)
    return setmetatable({ raw = raw, memory = true, opts = opts, state = { source = source } }, Memory),
        ffi.new("leanjson_source_v2_node", root[0])
end
return M
