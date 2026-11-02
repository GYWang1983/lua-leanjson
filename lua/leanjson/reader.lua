-- Streaming encoder over immutable logical nodes. The stack stores traversal
-- state, never encoded subtrees; every string operation is bounded by room.
local proxy = require("leanjson.proxy")
local leases = require("leanjson.leases")
local M = {}
local Reader = {}; Reader.__index = Reader
local ESCAPES = {
    [0x22] = '\\"', [0x5c] = '\\\\', [0x0a] = '\\n', [0x0d] = '\\r',
    [0x09] = '\\t', [0x08] = '\\b', [0x0c] = '\\f',
}
local CLOSED = "leanjson.reader: closed"

local function escape(byte)
    return ESCAPES[byte] or (byte < 0x20 and string.format('\\u%04x', byte) or nil)
end

local function string_length(value)
    local length = #value + 2
    for i = 1, #value do
        local b = string.byte(value, i)
        if ESCAPES[b] then length = length + 1
        elseif b < 0x20 then length = length + 5 end
    end
    return length
end

local function container(node, scope)
    local keys, values = proxy.members(node, scope)
    local n = #keys
    if node.kind == "array" then
        n = 0
        while values[n + 1] ~= nil do n = n + 1 end
    end
    return keys, values, n
end

local function raw_span(node, normalize)
    if node.backend and (not normalize or (node.kind ~= "object" and node.kind ~= "array")) then
        return proxy.span(node)
    end
end

local function token(node, codec)
    local kind = node.kind
    if kind == "null" or kind == "nil" then return "null" end
    if kind == "boolean" then return node.value and "true" or "false" end
    if kind == "number" then return codec.number(node.value) end
    if kind == "cdata" then return codec.cdata(node.value) end
    error("leanjson.encode: unsupported value type: " .. kind, 0)
end

local function count_length(root, normalize, codec, scope)
    local stack, length = { { node = root, depth = codec.depth or 1 } }, 0
    while #stack > 0 do
        local frame = stack[#stack]
        local node = frame.node
        if frame.values then
            frame.index = frame.index + 1
            if frame.index > frame.n then
                stack[#stack] = nil
            else
                local key = node.kind == "array" and frame.index or frame.keys[frame.index]
                if frame.index > 1 then length = length + 1 end
                if node.kind == "object" then length = length + string_length(key) + 1 end
                stack[#stack + 1] = { node = frame.values[key], depth = frame.depth + 1 }
            end
        else
            local backend, first, last = raw_span(node, normalize)
            leases.check(scope)
            if backend then
                length = length + last - first
                stack[#stack] = nil
            elseif node.kind == "object" or node.kind == "array" then
                if frame.depth > 1000 then error("leanjson.encode: max depth exceeded", 0) end
                frame.keys, frame.values, frame.n = container(node, scope)
                leases.check(scope)
                frame.index = 0
                length = length + 2
            elseif node.kind == "string" then
                length = length + string_length(node.value)
                stack[#stack] = nil
            else
                length = length + #token(node, codec)
                stack[#stack] = nil
            end
        end
    end
    return length
end

local function literal(value) return { tag = "literal", value = value, pos = 1 } end
local function string_frame(value) return { tag = "string", value = value, pos = 1, phase = "open" } end

local function next_chunk(self)
    local stack, parts, room = self.stack, {}, self.chunk_size
    while room > 0 and #stack > 0 do
        if self.closed then return nil end
        local frame = stack[#stack]
        local tag, fragment = frame.tag
        if tag == "value" then
            local node = frame.node
            local backend, first, last = raw_span(node, self.normalize)
            if self.closed then return nil end
            if backend then
                stack[#stack] = { tag = "raw", backend = backend, pos = first, last = last }
            elseif node.kind == "object" or node.kind == "array" then
                local keys, values, n = container(node, self.scope)
                if self.closed then return nil end
                stack[#stack] = { tag = "container", node = node, keys = keys, values = values,
                    n = n, index = 0, open = true }
            elseif node.kind == "string" then
                stack[#stack] = string_frame(node.value)
            else
                stack[#stack] = literal(token(node, self.codec))
            end
        elseif tag == "raw" then
            local wanted = math.min(room, frame.last - frame.pos)
            if wanted == 0 then stack[#stack] = nil
            else
                local chunk, err = frame.backend:read(frame.pos, wanted, self.scope)
                if self.closed then return nil end
                if type(chunk) ~= "string" then error(err or "leanjson.reader: source read failed", 0) end
                if #chunk == 0 then error("leanjson.reader: unexpected source EOF", 0) end
                if #chunk > wanted then error("leanjson.reader: source exceeded read bound", 0) end
                frame.pos = frame.pos + #chunk
                fragment = chunk
            end
        elseif tag == "literal" then
            local last = math.min(#frame.value, frame.pos + room - 1)
            fragment = frame.value:sub(frame.pos, last)
            frame.pos = last + 1
            if frame.pos > #frame.value then stack[#stack] = nil end
        elseif tag == "string" then
            if frame.phase == "open" then
                fragment, frame.phase = '"', "body"
            elseif frame.pos > #frame.value then
                fragment = '"'
                stack[#stack] = nil
            else
                local first = frame.pos
                local last = math.min(#frame.value, first + room - 1)
                local i = first
                while i <= last and not escape(string.byte(frame.value, i)) do i = i + 1 end
                if i > first then
                    fragment = frame.value:sub(first, i - 1)
                    frame.pos = i
                else
                    local escaped = escape(string.byte(frame.value, i))
                    frame.pos = i + 1
                    stack[#stack + 1] = literal(escaped)
                end
            end
        elseif tag == "container" then
            if frame.open then
                fragment = frame.node.kind == "array" and "[" or "{"
                frame.open = false
            else
                frame.index = frame.index + 1
                if frame.index > frame.n then
                    fragment = frame.node.kind == "array" and "]" or "}"
                    stack[#stack] = nil
                else
                    local key = frame.node.kind == "array" and frame.index or frame.keys[frame.index]
                    stack[#stack + 1] = { tag = "value", node = frame.values[key] }
                    if frame.node.kind == "object" then
                        stack[#stack + 1] = literal(":")
                        stack[#stack + 1] = string_frame(key)
                    end
                    if frame.index > 1 then stack[#stack + 1] = literal(",") end
                end
            end
        end
        if fragment and #fragment > 0 then
            parts[#parts + 1] = fragment
            room = room - #fragment
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

function Reader:length()
    if self.failure then return nil, self.failure end
    if self.output_length ~= nil then return self.output_length end
    if self.closed then return nil, CLOSED end
    local ok, result = pcall(count_length, self.root, self.normalize, self.codec, self.scope)
    if self.closed then return nil, CLOSED end
    if not ok then
        self.failure = tostring(result)
        self.root, self.stack, self.codec = nil, nil, nil
        leases.release(self.scope)
        return nil, self.failure
    end
    self.output_length = result
    return result
end

function Reader:close()
    self.closed = true
    self.root, self.stack, self.codec = nil, nil, nil
    leases.release(self.scope)
end

function Reader:next()
    if self.closed then return nil, CLOSED end
    if not self.failure and self.output_length == nil then self:length() end
    if self.closed then return nil, CLOSED end
    if self.failure then
        self:close()
        return nil, self.failure
    end
    local ok, result = pcall(next_chunk, self)
    -- close() can run while a backend operation is suspended. Cancellation
    -- wins over late bytes/errors and no buffered prefix may be published.
    if self.closed then return nil, CLOSED end
    if not ok then
        self.failure = tostring(result)
        self:close()
        return nil, self.failure
    end
    if result == nil then self:close() end
    return result
end

function M.new(value, options, codec)
    if options == nil then options = {} end
    if type(options) ~= "table" then error("leanjson.reader: opts must be a table", 0) end
    local size = options.chunk_size
    if size == nil then size = 65536 end
    if type(size) ~= "number" or size < 1 or size ~= math.floor(size) or size == math.huge then
        error("leanjson.reader: chunk_size must be a positive integer", 0)
    end
    if options.normalize_duplicates ~= nil and type(options.normalize_duplicates) ~= "boolean" then
        error("leanjson.reader: normalize_duplicates must be a boolean", 0)
    end
    local self = setmetatable({ chunk_size = size, normalize = options.normalize_duplicates == true, codec = codec }, Reader)
    local ok, result = pcall(function()
        local root = proxy.snapshot(value)
        self.scope = leases.acquire(root)
        self.root = root
        self.stack = { { tag = "value", node = root } }
        return true
    end)
    if not ok then
        self.failure = tostring(result)
        self.root, self.stack, self.codec = nil, nil, nil
        leases.release(self.scope)
    end
    return self
end

return M
