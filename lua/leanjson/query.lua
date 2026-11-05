-- Inspect immutable logical nodes without exposing/materializing their values.
local proxy = require("leanjson.proxy")
local nodes = require("leanjson.nodes")
local leases = require("leanjson.leases")
local paths = require("leanjson.path")
local M = {}

local function arity(operation, count)
    if count < 1 or count > 2 then
        error("leanjson." .. operation .. ": expected 1 or 2 arguments", 0)
    end
end

local function parse(path, operation)
    if path == nil then return {} end
    if type(path) == "string" and path:sub(1, 1) == "$"
        and (#path == 1 or path:sub(2, 2) == "." or path:sub(2, 2) == "[") then
        path = path:sub(2)
    end
    return paths.parse(path, "leanjson." .. operation)
end

local function inspect(value, path, codec, operation, action)
    local segments, index = parse(path, operation), 1
    while true do
        if proxy.is_proxy(value) then
            local node, scope = proxy.node(value), proxy.scope(value)
            return leases.guard(scope, node, function()
                -- All lookup operations see the captured immutable root, even
                -- if another coroutine edits the public proxy during a yield.
                for i = index, #segments do
                    local segment = segments[i]
                    if node.kind ~= segment.kind then return action(nil) end
                    node = nodes.lookup(node, segment.key, scope)
                    leases.check(scope)
                    if node == nil then return action(nil) end
                end
                return action(node, scope, true, proxy.mode(value))
            end)
        end
        if index > #segments then return action(value) end
        local segment = segments[index]
        if value == nil or proxy.type(value, codec.classify) ~= segment.kind then return action(nil) end
        value, index = value[segment.key], index + 1
    end
end

local function string_length(node, scope)
    if not node.backend or node.preloaded then return #node.value end
    local next_chunk, close = node.backend:scalar_chunks(node.handle, scope)
    local length = 0
    while true do
        local bytes = next_chunk()
        if bytes == nil then break end
        length = length + #bytes
    end
    close()
    return length
end

function M.len(codec, ...)
    arity("len", select("#", ...))
    local value, path = ...
    -- Preserve the historical root API, including ordinary Lua table length.
    if path == nil then return proxy.len(value) end
    return inspect(value, path, codec, "len", function(item, scope, logical)
        if item == nil then return nil end
        local length
        local kind = logical and item.kind or proxy.type(item, function(value)
            local classified
            classified, length = codec.classify(value)
            return classified
        end)
        if kind == "string" then return logical and string_length(item, scope) or #item end
        if logical and (kind == "array" or kind == "object") then return nodes.length(item, scope) end
        if not logical and kind == "array" then return length or 0 end
        if not logical and type(item) == "table" and kind == "object" then
            local count = 0
            for _ in pairs(item) do count = count + 1 end
            return count
        end
        error("leanjson.len: length is only defined for strings, arrays and objects", 0)
    end)
end

function M.ref(codec, ...)
    arity("ref", select("#", ...))
    local value, path = ...
    local captured
    local ok, result = pcall(inspect, value, path, codec, "ref", function(item, _, logical, mode)
        if item == nil then return nil end
        if logical then captured = proxy.reference_node(item, codec, mode)
        else captured = proxy.reference(item, codec) end
        return captured
    end)
    -- A retain callback can close the initiating holder after the new handle
    -- acquires its own lease. guard's final check must not leak that handle.
    if not ok then
        if captured then proxy.close(captured) end
        error(result, 0)
    end
    return result
end

function M.exists(codec, ...)
    arity("exists", select("#", ...))
    local value, path = ...
    return inspect(value, path, codec, "exists", function(item) return item ~= nil end)
end

function M.is_empty(codec, ...)
    arity("is_empty", select("#", ...))
    local value, path = ...
    return inspect(value, path, codec, "is_empty", function(item, scope, logical)
        if item == nil then return true end
        if not logical then return not item end
        -- Lua's null sentinel, empty strings/containers and zero are truthy.
        -- Only boolean nodes need a value read; strings never do.
        return item.kind == "boolean" and proxy.scalar(item, scope) == false
    end)
end

return M
