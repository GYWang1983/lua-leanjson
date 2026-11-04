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
function M.open(raw, opts, codec)
    if type(raw) ~= "string" then error("leanjson: input must be a string", 0) end
    opts = require("leanjson.options").for_codec(opts, codec)
    local result = ffi.new("leanjson_source_v1_result[1]")
    local source = C.leanjson_source_v2_new(shared.native_options(opts), result)
    if source == nil then error(shared.result_error(result), 0) end
    source = ffi.gc(source, C.leanjson_source_v1_release)
    local backend = setmetatable({ raw = raw, memory = true, opts = opts, state = { source = source } }, Memory)
    -- Construction events are drained per bounded feed; unselected bytes and
    -- native input pointers are never retained by the validator.
    local ok, value = pcall(function()
    shared.configure_source(backend, codec)
    backend.loading = require("leanjson.loading").new(backend)
    local first = 0
    repeat
        local count = math.min(#raw - first, opts.chunk_size)
        shared.require_status(C.leanjson_source_v1_feed(source, first,
            ffi.cast("const uint8_t *", raw) + first, count, result), 2, result, source)
        if backend.loading then backend.loading:drain() end
        first = first + count
    until first == #raw
    shared.require_status(C.leanjson_source_v1_finish(source, #raw, result), 0, result, source)
    if backend.loading then backend.loading:finish() end
    local root = ffi.new("leanjson_source_v2_node[1]")
    shared.require_status(C.leanjson_source_v2_root(source, root, result), 0, result)
    return ffi.new("leanjson_source_v2_node", root[0])
    end)
    if not ok then
        ffi.gc(source, nil); C.leanjson_source_v1_release(source); backend.state.source = nil
        error(value, 0)
    end
    return backend, value
end
return M
