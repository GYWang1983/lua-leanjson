-- The byte grammar deliberately matches src/path.rs, including leading and
-- repeated dots and zero-based uint32 bracket indexes.
local proxy = require("leanjson.proxy")
local M = {}

function M.parse(path)
    if type(path) ~= "string" then error("leanjson.get: path must be a string", 0) end
    local segments, pos = {}, 1
    while pos <= #path do
        local byte = path:byte(pos)
        if byte == 46 then
            pos = pos + 1
            if pos > #path then error("leanjson.get: invalid path", 0) end
        elseif byte == 91 then
            local last = path:find("]", pos + 1, true)
            if not last or last == pos + 1 then error("leanjson.get: invalid path", 0) end
            local index = 0
            for i = pos + 1, last - 1 do
                local digit = path:byte(i) - 48
                if digit < 0 or digit > 9 then error("leanjson.get: invalid path", 0) end
                index = index * 10 + digit
                if index > 4294967295 then error("leanjson.get: invalid path", 0) end
            end
            segments[#segments + 1] = { kind = "array", key = index + 1 }
            pos = last + 1
        else
            local last = path:find("[%.%[]", pos) or (#path + 1)
            segments[#segments + 1] = { kind = "object", key = path:sub(pos, last - 1) }
            pos = last
        end
    end
    return segments
end

function M.from_node(node, segments, scope)
    for _, segment in ipairs(segments) do
        if node.kind ~= segment.kind then error("leanjson.get: type mismatch", 0) end
        local _, values = proxy.members(node, scope)
        node = values[segment.key]
        if node == nil then return nil end
    end
    if node.kind == "array" or node.kind == "object" then return proxy.from_node(node) end
    return proxy.scalar(node, scope)
end

function M.get(value, path)
    local segments = M.parse(path)
    local node = proxy.node(value)
    if node then return proxy.get_path(value, segments) end
    for i, segment in ipairs(segments) do
        if proxy.is_proxy(value) then
            local rest = {}
            for j = i, #segments do rest[#rest + 1] = segments[j] end
            return proxy.get_path(value, rest)
        end
        if proxy.type(value) ~= segment.kind then error("leanjson.get: type mismatch", 0) end
        value = value[segment.key]
        if type(value) == "nil" then return nil end
    end
    return value
end

return M
