-- Parsing policy shared by the new memory/file/feed and HTTP source adapters.
-- The legacy leanjson.parse option contract and C ABI remain independent.
local M = {}
local normalized = setmetatable({}, { __mode = "k" })

local function integer(value, name, default, minimum, maximum)
    if value == nil then return default end
    if type(value) ~= "number" or value < minimum or value > maximum or value ~= math.floor(value) then
        error("leanjson: " .. name .. " must be an integer between " .. minimum .. " and " .. maximum, 0)
    end
    return value
end

function M.normalize(opts)
    if opts == nil then opts = {} end
    if type(opts) ~= "table" then error("leanjson: source opts must be a table", 0) end
    if normalized[opts] then return opts end
    if opts.lazy ~= nil and type(opts.lazy) ~= "boolean" then error("leanjson: opts.lazy must be a boolean", 0) end
    if opts.lazy then error("leanjson: source v1 supports eager validation only", 0) end
    if opts.lazyload ~= nil and type(opts.lazyload) ~= "boolean" then error("leanjson: lazyload must be a boolean", 0) end
    if opts.on_chunk ~= nil and type(opts.on_chunk) ~= "function" then error("leanjson: opts.on_chunk must be a function", 0) end
    if opts.temp_dir ~= nil and (type(opts.temp_dir) ~= "string" or opts.temp_dir == "" or opts.temp_dir:find("\0", 1, true)) then
        error("leanjson: opts.temp_dir must be a nonempty path", 0)
    end
    local out = {
        chunk_size = integer(opts.chunk_size, "chunk_size", 65536, 1, 4294967295),
        max_depth = integer(opts.max_depth, "max_depth", 0, 0, 4294967295),
        index_depth = integer(opts.index_depth, "index_depth", 3, 0, 4294967295),
        index_array_limit = integer(opts.index_array_limit, "index_array_limit", 3, 0, 4294967295),
        index_budget_bytes = integer(opts.index_budget_bytes, "index_budget_bytes", 1048576, 0, 4294967295),
        lazyload = opts.lazyload ~= false,
        selector = require("leanjson.loading").compile(opts.preload_paths),
        on_chunk = opts.on_chunk,
        temp_dir = opts.temp_dir or os.getenv("TMPDIR") or "/tmp",
    }
    normalized[out] = true
    return out
end

function M.for_codec(opts, codec)
    local source = M.normalize(opts)
    local out = {}
    for key, value in pairs(source) do out[key] = value end
    out.decode_array_with_array_mt = codec and codec.decode_array_with_array_mt() or false
    out.decode_invalid_numbers = not codec or codec.decode_invalid_numbers()
    out.decode_validate_utf8 = codec and codec.decode_validate_utf8() or false
    normalized[out] = true
    return out
end

return M
