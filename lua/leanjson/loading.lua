-- Scan-time construction. Eager mode builds ordinary values directly; selective
-- mode keeps immutable decoded values attached to their original source spans.
local ffi = require("ffi")
local C = require("leanjson.lib")
local M, Builder = {}, {}; Builder.__index = Builder
local config
local kinds = { [0] = "null", "boolean", "number", "string", "array", "object" }
function M.configure(options) config = options end

function M.compile(paths)
    if paths == nil then return nil end
    if type(paths) ~= "table" then error("leanjson: preload_paths must be a dense array of JSONPath strings", 0) end
    local count = 0
    for key, value in pairs(paths) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or type(value) ~= "string" then
            error("leanjson: preload_paths must be a dense array of JSONPath strings", 0)
        end
        count = count + 1
    end
    local encoded = {}
    for i = 1, count do
        local path = rawget(paths, i)
        if type(path) ~= "string" or #path > 4294967295 then
            error("leanjson: preload_paths must be a dense array of JSONPath strings", 0)
        end
        local n = #path
        encoded[#encoded + 1] = string.char(n % 256, math.floor(n / 256) % 256,
            math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) .. path
    end
    encoded = table.concat(encoded)
    local result = ffi.new("leanjson_source_v1_result[1]")
    local selector = C.leanjson_source_v2_selector_new(encoded, #encoded, result)
    if selector == nil then error("leanjson: invalid preload_paths JSONPath expression", 0) end
    return ffi.gc(selector, C.leanjson_source_v2_selector_release)
end

function M.new(backend)
    local opts = backend.opts
    if opts.lazyload and opts.selector == nil then return nil end
    local result = ffi.new("leanjson_source_v1_result[1]")
    require("leanjson.source_backend").require_status(
        C.leanjson_source_v2_set_loading(backend.state.source, opts.selector, opts.lazyload and 0 or 1, result), 0, result)
    return setmetatable({ backend = backend, eager = not opts.lazyload, stack = {}, frames = {} }, Builder)
end

local function scalar(kind, raw, first)
    if kind == "null" then return config.null end
    if kind == "string" then return raw end
    if kind == "boolean" then return raw == "true" end
    local value = tonumber(raw)
    if value == nil or value == math.huge or value == -math.huge then
        error("leanjson: number out of range at byte " .. first, 0)
    end
    return value
end

function Builder:drain()
    local event, result = ffi.new("leanjson_source_v2_loading_event[1]"), ffi.new("leanjson_source_v1_result[1]")
    while true do
        local status = C.leanjson_source_v2_next_loading_event(self.backend.state.source, event, result)
        if status == 1 then return end
        require("leanjson.source_backend").require_status(status, 0, result)
        local e = event[0]
        if e.event == 1 then
            local kind = kinds[tonumber(e.kind)]
            local parent = self.stack[#self.stack]
            local key = parent and parent.kind == "array" and tonumber(e.ordinal) + 1 or ffi.string(e.key, e.key_len)
            local depth = #self.stack + 1
            local frame = self.frames[depth]
            if not frame then frame = {}; self.frames[depth] = frame end
            frame.kind, frame.key, frame.selected, frame.first = kind, key, e.selected ~= 0, tonumber(e.raw_start)
            frame.raw, frame.parts = nil, nil
            frame.values, frame.keys, frame.entries = nil, nil, nil
            if kind == "array" or kind == "object" or not self.eager then frame.values = {} end
            if not self.eager and frame.selected then frame.keys, frame.entries = {}, {} end
            self.stack[depth] = frame
        elseif e.event == 2 then
            local frame = self.stack[#self.stack]
            local bytes = ffi.string(e.bytes, e.bytes_len)
            if frame.raw == nil then frame.raw = bytes
            elseif frame.parts then frame.parts[#frame.parts + 1] = bytes
            else frame.parts = { frame.raw, bytes } end
        else
            local frame = table.remove(self.stack)
            local container = frame.kind == "array" or frame.kind == "object"
            local value, node
            if self.eager then
                if container then
                    value = frame.values
                    if frame.kind == "array" then config.hint(value, "array") end
                    if frame.kind == "array" and next(value) == nil then setmetatable(value, config.empty_array_mt) end
                else value = scalar(frame.kind, frame.parts and table.concat(frame.parts) or frame.raw or "", frame.first) end
            elseif frame.selected or next(frame.values) ~= nil then
                local handle = ffi.new("leanjson_source_v2_node", { self.backend.state.source,
                    frame.first, e.raw_end, e.child_count, e.kind, e.flags })
                node = { backend = self.backend, handle = handle, identity = frame.first, kind = frame.kind,
                    preloaded = frame.selected, preload_values = frame.values,
                    preload_keys = frame.keys, preload_entries = frame.entries }
                if not container and frame.selected then
                    local raw = frame.parts and table.concat(frame.parts) or frame.raw or ""
                    node.value = scalar(frame.kind, raw, frame.first)
                    -- Logical scalar payload units, excluding Lua allocations:
                    -- UTF-8 string bytes, 8 per number, 1 per bool, 0 per null.
                    node.preload_bytes = frame.kind == "string" and #raw or frame.kind == "number" and 8
                        or frame.kind == "boolean" and 1 or 0
                end
            end
            local parent = self.stack[#self.stack]
            if parent then
                local child = node
                if self.eager then child = value end
                if not self.eager and parent.selected then
                    parent.entries[#parent.entries + 1] = { frame.key, child }
                end
                if child ~= nil then
                    if not self.eager and parent.selected and parent.values[frame.key] == nil then parent.keys[#parent.keys + 1] = frame.key end
                    parent.values[frame.key] = child
                else
                    -- A later duplicate ancestor without a match replaces the
                    -- entire earlier selection, including all descendants.
                    parent.values[frame.key] = nil
                end
            elseif self.eager then self.root = value
            else self.root = node end
            frame.values, frame.keys, frame.entries, frame.raw, frame.parts, frame.key = nil, nil, nil, nil, nil, nil
        end
    end
end

function Builder:finish()
    self:drain()
    if self.eager then return end
    local cached, stack = {}, { self.root }
    local stats = { preloaded_nodes = 0, preloaded_payload_bytes = 0, preload_path_nodes = 0, preloaded_key_bytes = 0 }
    while #stack > 0 do
        local node = table.remove(stack)
        if node and not cached[node.identity] then
            cached[node.identity] = node
            if node.preloaded then stats.preloaded_nodes = stats.preloaded_nodes + 1
            else stats.preload_path_nodes = stats.preload_path_nodes + 1 end
            stats.preloaded_payload_bytes = stats.preloaded_payload_bytes + (node.preload_bytes or 0)
            if node.preloaded then
                for _, entry in ipairs(node.preload_entries) do
                    if type(entry[1]) == "string" then stats.preloaded_key_bytes = stats.preloaded_key_bytes + #entry[1] end
                    stack[#stack + 1] = entry[2]
                end
            else
                for key, child in pairs(node.preload_values) do
                    if type(key) == "string" then stats.preloaded_key_bytes = stats.preloaded_key_bytes + #key end
                    stack[#stack + 1] = child
                end
            end
        end
    end
    self.backend.preloaded, self.backend.preload_stats = cached, stats
    self.backend.state.preloaded = cached
    self.root = nil
end

function Builder:take()
    local value = self.root
    self.root = nil
    return value
end

-- A completed eager incremental decoder keeps its immutable spool, never a
-- second hidden full Lua value. Later queries construct only their target span.
function M.rebuild(backend, handle, scope)
    local shared = require("leanjson.source_backend")
    local leases = require("leanjson.leases")
    leases.check(scope)
    local result = ffi.new("leanjson_source_v1_result[1]")
    local source = C.leanjson_source_v2_new(shared.native_options(backend.opts), result)
    if source == nil then error(shared.result_error(result), 0) end
    source = ffi.gc(source, C.leanjson_source_v1_release)
    local scratch, builder
    local record = leases.track(scope, function()
        if builder then
            builder.root = nil
            for _, frame in ipairs(builder.frames) do
                frame.values, frame.keys, frame.entries, frame.raw, frame.parts, frame.key = nil, nil, nil, nil, nil, nil
            end
            builder.stack, builder.frames = {}, {}
            builder = nil
        end
        if scratch then scratch.state.source = nil; scratch = nil end
        if source then
            local owned = source
            source = nil
            ffi.gc(owned, nil)
            C.leanjson_source_v1_release(owned)
        end
    end)
    local fallback = leases.fallback(scope, record)
    local ok, value = pcall(function()
        scratch = { state = { source = source }, opts = { lazyload = false } }
        builder = M.new(scratch)
        local first, last, offset = shared.exact(handle.raw_start), shared.exact(handle.raw_end), 0
        while first < last do
            local bytes = backend:read(first, math.min(last - first, backend.opts.chunk_size), scope)
            leases.check(scope)
            if not fallback or not source then error("leanjson: source operation closed", 0) end
            shared.require_status(C.leanjson_source_v1_feed(source, offset, bytes, #bytes, result), 2, result)
            builder:drain()
            first, offset = first + #bytes, offset + #bytes
        end
        shared.require_status(C.leanjson_source_v1_finish(source, offset, result), 0, result)
        builder:finish()
        leases.check(scope)
        return builder:take()
    end)
    leases.finish(scope, record)
    fallback = nil
    if not ok then error(value, 0) end
    return value
end
return M
