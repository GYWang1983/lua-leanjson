-- Parsing policy shared by the new memory/file/feed and HTTP source adapters.
-- The legacy qjson.parse option contract and C ABI remain independent.
local M = {}

local function integer(value, name, default, minimum, maximum)
    if value == nil then return default end
    if type(value) ~= "number" or value < minimum or value > maximum or value ~= math.floor(value) then
        error("qjson: " .. name .. " must be an integer between " .. minimum .. " and " .. maximum, 0)
    end
    return value
end

function M.normalize(opts)
    if opts == nil then opts = {} end
    if type(opts) ~= "table" then error("qjson: source opts must be a table", 0) end
    if opts.lazy ~= nil and type(opts.lazy) ~= "boolean" then error("qjson: opts.lazy must be a boolean", 0) end
    if opts.lazy then error("qjson: source v1 supports eager validation only", 0) end
    if opts.on_chunk ~= nil and type(opts.on_chunk) ~= "function" then error("qjson: opts.on_chunk must be a function", 0) end
    if opts.temp_dir ~= nil and (type(opts.temp_dir) ~= "string" or opts.temp_dir == "" or opts.temp_dir:find("\0", 1, true)) then
        error("qjson: opts.temp_dir must be a nonempty path", 0)
    end
    return {
        chunk_size = integer(opts.chunk_size, "chunk_size", 65536, 1, 4294967295),
        max_depth = integer(opts.max_depth, "max_depth", 0, 0, 4294967295),
        on_chunk = opts.on_chunk,
        temp_dir = opts.temp_dir or os.getenv("TMPDIR") or "/tmp",
    }
end

return M
