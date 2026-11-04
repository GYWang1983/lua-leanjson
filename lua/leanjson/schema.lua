-- Compiled plans have private identity and native ownership. Source retains its
-- own reference when attached, so collecting a Lua plan cannot invalidate it.
local ffi = require('ffi')
local lib = require('leanjson.lib')
local plans = setmetatable({}, { __mode = 'k' })
local M = {}

-- Compiler serialization must not inherit permissive/skipping or low-precision
-- encoder settings from the application codec. Serialize the schema only; this
-- path never visits an instance being validated.
local function serialize(value)
    local codec = require('leanjson.table').new()
    codec.encode_empty_table_as_object(true)
    codec.encode_invalid_numbers(false)
    local proxy = require('leanjson.proxy')
    local active = {}
    local function encode(v, depth)
        if depth > 128 then error('leanjson: schema nesting exceeds 128', 0) end
        if type(v) == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then
                error('leanjson: schema numbers must be finite', 0)
            end
            -- Shortest round-trip decimal for the supplied Lua number. Native
            -- schema literals and streamed instance numbers remain exact.
            for precision = 1, 17 do
                local text = string.format('%.' .. precision .. 'g', v)
                if tonumber(text) == v then return text end
            end
        end
        if type(v) ~= 'table' or proxy.is_proxy(v) then return codec.encode(v) end
        if active[v] then error('leanjson: cyclic schema table', 0) end
        active[v] = true
        local array = codec.type(v) == 'array'
        local parts = {}
        if array then
            local count = 0
            for key in pairs(v) do
                if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then
                    error('leanjson: invalid schema array key', 0)
                end
                count = count + 1
            end
            for i = 1, count do
                if rawget(v, i) == nil then error('leanjson: sparse schema array', 0) end
                parts[#parts + 1] = encode(rawget(v, i), depth + 1)
            end
        else
            for key, child in pairs(v) do
                if type(key) ~= 'string' then error('leanjson: schema object keys must be strings', 0) end
                parts[#parts + 1] = codec.encode(key) .. ':' .. encode(child, depth + 1)
            end
        end
        active[v] = nil
        return (array and '[' or '{') .. table.concat(parts, ',') .. (array and ']' or '}')
    end
    return encode(value, 0)
end

function M.is_compiled(value)
    return plans[value] ~= nil
end

function M.pointer(plan)
    return plans[plan]
end

function M.compile(value, _codec)
    if plans[value] then return value end
    if type(value) ~= 'boolean' and type(value) ~= 'table' then
        error('leanjson: schema must be a boolean, table or compiled plan', 0)
    end
    local bytes = serialize(value)
    local err = ffi.new('uint8_t[2048]')
    local ptr = lib.leanjson_schema_v1_new(bytes, #bytes, err, 2048)
    if ptr == nil then error('leanjson: schema: ' .. ffi.string(err), 0) end
    ptr = ffi.gc(ptr, lib.leanjson_schema_v1_release)
    local plan = newproxy(true)
    local mt = getmetatable(plan)
    mt.__metatable = 'leanjson compiled schema'
    mt.__tostring = function() return 'leanjson compiled schema' end
    plans[plan] = ptr
    return plan
end

return M
