-- Streaming encoder over immutable logical nodes. The stack stores traversal
-- state, never encoded subtrees; every string operation is bounded by room.
local proxy = require("leanjson.proxy")
local leases = require("leanjson.leases")
local M = {}
local Reader = {}; Reader.__index = Reader
local bit = require("bit")
local CLOSED = "leanjson.reader: closed"

local function string_length(value, codec)
    local length = #value + 2
    for i = 1, #value do
        local escaped = codec.escape(string.byte(value, i))
        if escaped then length = length + #escaped - 1 end
    end
    return length
end

local function raw_span(node, normalize, scope)
    if node.backend then
        local flags = node.backend.flags and node.backend:flags(node.handle) or 0
        -- Special source strings and numbers must obey the calling codec even
        -- when their surrounding original bytes could otherwise be reused.
        if bit.band(flags, 4) ~= 0 then return end
        if bit.band(flags, 8) ~= 0 then
            if node.kind ~= "number" then return end
            local n = proxy.scalar(node, scope)
            if n ~= n or n == math.huge or n == -math.huge then return end
        end
        if not normalize or (node.kind ~= "object" and node.kind ~= "array")
            or (node.backend.clean and node.backend:clean(node.handle)) then
            return proxy.span(node)
        end
    end
end

local function source_string(node, scope)
    if node.backend and not node.preloaded then
        return node.backend:scalar_chunks(node.handle, scope)
    end
end

local function token(node, codec, scope)
    local kind = node.kind
    if kind == "null" or kind == "nil" then return "null" end
    if kind == "boolean" then return node.value and "true" or "false" end
    if kind == "number" then return codec.number(proxy.scalar(node, scope)) end
    if kind == "cdata" then return codec.cdata(node.value) end
    error("Cannot serialise " .. kind .. ": type not supported", 0)
end

local function output_members(node, scope)
    -- Distinct Lua keys can have identical JSON spellings after numeric
    -- formatting. Preserve both fields when encoding that table snapshot;
    -- logical proxy lookups still use the final value for each JSON name.
    if node.serialized_entries then
        local index = 0
        return function()
            index = index + 1
            local entry = node.serialized_entries[index]
            if entry then return entry[1], entry[2] end
        end
    end
    return proxy.iter(node, scope, true)
end

-- Depth is validated before raw reuse, using one input window and two
-- lexical bits. The accepted source limit is a conservative fast bound.
local function check_depth(node, depth, codec, backend, first, last, scope)
    -- The native empty-array sentinel is emitted as a scalar token; real
    -- source arrays and ordinary empty tables still consume container depth.
    if node.empty_array_sentinel or node.kind ~= "object" and node.kind ~= "array" then return end
    local maximum = codec.max_depth or 1000
    local function excessive() error("Cannot serialise, excessive nesting (" .. (maximum + 1) .. ")", 0) end
    if depth > maximum then excessive() end
    if not backend then return end
    local accepted = backend.opts and backend.opts.max_depth
    if type(accepted) == "number" and accepted > 0 and accepted <= maximum - depth + 1 then return end
    local nested, quoted, escaped = depth - 1, false, false
    while first < last do
        leases.check(scope)
        local bytes = backend:read(first, math.min(last - first, backend.opts and backend.opts.chunk_size or 65536, codec.scan_window or 65536), scope)
        leases.check(scope)
        if #bytes == 0 then error("leanjson.reader: unexpected source EOF", 0) end
        for i = 1, #bytes do
            local byte = bytes:byte(i)
            if quoted then
                if escaped then escaped = false
                elseif byte == 92 then escaped = true
                elseif byte == 34 then quoted = false end
            elseif byte == 34 then quoted = true
            elseif byte == 91 or byte == 123 then
                nested = nested + 1
                if nested > maximum then excessive() end
            elseif byte == 93 or byte == 125 then nested = nested - 1 end
        end
        first = first + #bytes
    end
end

local function count_length(root, normalize, codec, scope)
    local stack, length = { { node = root, depth = codec.depth or 1 } }, 0
    while #stack > 0 do
        local frame = stack[#stack]
        local node = frame.node
        if frame.iterator then
            local key, child = frame.iterator()
            leases.check(scope)
            if key == nil then stack[#stack] = nil
            else
                if frame.index > 0 then length = length + 1 end
                frame.index = frame.index + 1
                if node.kind == "object" then length = length + string_length(key, codec) + 1 end
                stack[#stack + 1] = { node = child, depth = frame.depth + 1 }
            end
        else
            local backend, first, last = raw_span(node, normalize, scope)
            leases.check(scope)
            check_depth(node, frame.depth, codec, backend, first, last, scope)
            if backend then
                length = length + last - first
                stack[#stack] = nil
            elseif node.kind == "object" or node.kind == "array" then
                frame.iterator = output_members(node, scope)
                leases.check(scope)
                frame.index = 0
                length = length + 2
            elseif node.kind == "string" then
                local chunks = source_string(node, scope)
                if chunks then
                    length = length + 2
                    while true do
                        local chunk = chunks()
                        leases.check(scope)
                        if chunk == nil then break end
                        length = length + string_length(chunk, codec) - 2
                    end
                else length = length + string_length(node.value, codec) end
                stack[#stack] = nil
            else
                length = length + #token(node, codec, scope)
                stack[#stack] = nil
            end
        end
    end
    return length
end

local function literal(value) return { tag = "literal", value = value, pos = 1 } end
local function string_frame(value, chunks)
    return { tag = "string", value = value or "", pos = 1, phase = "open", chunks = chunks }
end

local function next_chunk(self)
    local stack, parts, room = self.stack, {}, self.chunk_size
    while room > 0 and #stack > 0 do
        if self.closed then return nil end
        local frame = stack[#stack]
        local tag, fragment = frame.tag
        if tag == "value" then
            local node = frame.node
            local backend, first, last = raw_span(node, self.normalize, self.scope)
            if self.closed then return nil end
            if backend then
                if self.closed then return nil end
                stack[#stack] = { tag = "raw", backend = backend, pos = first, last = last }
            elseif node.kind == "object" or node.kind == "array" then
                local iterator = output_members(node, self.scope)
                if self.closed then return nil end
                stack[#stack] = { tag = "container", node = node, iterator = iterator, index = 0, open = true, depth = frame.depth }
            elseif node.kind == "string" then
                stack[#stack] = string_frame(node.value, source_string(node, self.scope))
            else
                stack[#stack] = literal(token(node, self.codec, self.scope))
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
                local chunk = frame.chunks and frame.chunks()
                if self.closed then return nil end
                if chunk then frame.value, frame.pos = chunk, 1
                else
                    fragment = '"'
                    stack[#stack] = nil
                end
            else
                local first = frame.pos
                local last = math.min(#frame.value, first + room - 1)
                local i = first
                while i <= last and not self.codec.escape(string.byte(frame.value, i)) do i = i + 1 end
                if i > first then
                    fragment = frame.value:sub(first, i - 1)
                    frame.pos = i
                else
                    local escaped = self.codec.escape(string.byte(frame.value, i))
                    frame.pos = i + 1
                    stack[#stack + 1] = literal(escaped)
                end
            end
        elseif tag == "container" then
            if frame.open then
                fragment = frame.node.kind == "array" and "[" or "{"
                frame.open = false
            else
                local key, child = frame.iterator()
                if self.closed then return nil end
                frame.index = frame.index + 1
                if key == nil then
                    fragment = frame.node.kind == "array" and "]" or "}"
                    stack[#stack] = nil
                else
                    stack[#stack + 1] = { tag = "value", node = child, depth = frame.depth + 1 }
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
    codec.scan_window = size
    local self = setmetatable({ chunk_size = size, normalize = options.normalize_duplicates == true, codec = codec }, Reader)
    local ok, result = pcall(function()
        local root = proxy.snapshot(value, codec.classify, codec.key, codec.max_depth)
        self.scope = leases.acquire(root)
        self.root = root
        self.stack = { { tag = "value", node = root, depth = codec.depth or 1 } }
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
