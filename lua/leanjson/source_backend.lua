-- Shared sparse span protocol for memory, file and incremental sources.
local ffi = require("ffi")
local bit = require("bit")
local C = require("leanjson.lib")
local leases = require("leanjson.leases")
local M = {}
local READY, DONE, NEED_READ, ERROR = 0, 1, 3, 5
local MAX_EXACT = 9007199254740991
local kinds = { [0] = "null", "boolean", "number", "string", "array", "object" }
local U64_MAX = ffi.cast("uint64_t", -1)
local details = { "source I/O error", "source aborted", "source closed", "invalid source window",
    "invalid source offset", "invalid source options" }
function M.exact(value)
    if value > MAX_EXACT then error("leanjson: source offset exceeds Lua exact integer range", 0) end
    return tonumber(value)
end
function M.result_error(result, source)
    if source ~= nil then
        local n = tonumber(C.leanjson_source_v2_format_error(source, nil, 0))
        if n > 0 then
            local out = ffi.new("uint8_t[?]", n + 1)
            C.leanjson_source_v2_format_error(source, out, n + 1)
            return ffi.string(out, n)
        end
    end
    local r = result[0]
    local message = r.detail ~= 0 and (details[tonumber(r.detail)] or "source error")
        or ffi.string(C.leanjson_strerror(r.code))
    if r.offset ~= U64_MAX then message = message .. " at byte " .. tostring(M.exact(r.offset)) end
    return "leanjson: " .. message
end
function M.require_status(status, expected, result, source)
    if status ~= expected then
        if status == ERROR then error(M.result_error(result, source), 0) end
        error("leanjson: unexpected source status " .. status, 0)
    end
end
function M.native_options(opts)
    local mode = (opts.decode_invalid_numbers and 1 or 0) + (not opts.decode_validate_utf8 and 2 or 0)
        + (opts.decode_allow_comment and 4 or 0)
    return ffi.new("leanjson_source_v2_options[1]", { { 2, mode, opts.max_depth, opts.chunk_size,
        opts.index_depth, opts.index_array_limit, opts.index_budget_bytes, 0, opts.temp_dir, #opts.temp_dir } })
end
function M.configure_source(backend, codec)
    local result = ffi.new("leanjson_source_v1_result[1]")
    M.require_status(C.leanjson_source_v2_set_structural_index(backend.state.source,
        backend.opts.structural_index and 1 or 0, result), READY, result, backend.state.source)
    if backend.opts.schema ~= nil then
        local schema = require("leanjson.schema")
        local plan = schema.compile(backend.opts.schema, codec)
        M.require_status(C.leanjson_source_v2_set_schema(backend.state.source,
            schema.pointer(plan), result), READY, result, backend.state.source)
        -- The native validator owns its own plan reference. Do not keep a Lua
        -- wrapper alive for the lifetime of an already decoded request body.
        backend.opts.schema = nil
    end
end
function M.type(self, handle) self:check_open(); return kinds[tonumber(handle.kind)] end
function M.identity(self, handle) return M.exact(handle.raw_start) end
function M.span(self, handle) self:check_open(); return M.exact(handle.raw_start), M.exact(handle.raw_end) end
function M.lexical_length(self, handle) return M.exact(handle.child_count) end
function M.length(self, handle, scope)
    self:check_open()
    if handle.kind == 4 then self:notify(scope); return M.exact(handle.child_count) end
    local n = 0
    for _ in self:children(handle, scope, true) do n = n + 1 end
    return n
end
function M.flags(self, handle) return tonumber(handle.flags) end
function M.clean(self, handle) return bit.band(handle.flags, 3) == 1 end
function M.stats(self)
    self:check_open()
    local result, stats = ffi.new("leanjson_source_v1_result[1]"), ffi.new("leanjson_source_v2_stats[1]")
    M.require_status(C.leanjson_source_v2_get_stats(self.state.source, stats, result), READY, result)
    local out = {}
    for _, name in ipairs({ "budget_bytes", "index_bytes", "indexed_nodes", "indexed_depth", "index_depth", "index_array_limit" }) do
        out[name] = M.exact(stats[0][name])
    end
    local index = ffi.new("leanjson_source_v2_index_stats[1]")
    M.require_status(C.leanjson_source_v2_get_index_stats(self.state.source, index, result), READY, result)
    for _, name in ipairs({ "structural_index_bytes", "lookup_cache_bytes", "lookup_cache_hits", "lookup_cache_misses" }) do
        out[name] = M.exact(index[0][name])
    end
    local workspace = ffi.new("leanjson_source_v2_workspace_stats[1]")
    M.require_status(C.leanjson_source_v2_get_workspace_stats(self.state.source, workspace, result), READY, result)
    for _, name in ipairs({ "spill_file_bytes", "spill_live_regions", "spill_free_regions" }) do
        out[name] = M.exact(workspace[0][name])
    end
    for _, name in ipairs({ "preloaded_nodes", "preloaded_payload_bytes", "preload_path_nodes", "preloaded_key_bytes" }) do
        out[name] = self.preload_stats and self.preload_stats[name] or 0
    end
    return out
end
function M.clear_indexes(self)
    local result = ffi.new("leanjson_source_v1_result[1]")
    M.require_status(C.leanjson_source_v2_clear_indexes(self.state.source, result), READY, result)
end
-- The iterator owns one resumable native operation. Its cleanup is attached
-- to the initiating lease scope, so closing a reader also cancels a suspended
-- source read without keeping a decoded long string in memory.
function M.scalar_chunks(self, handle, scope)
    self:check_open()
    local lease = self:retain()
    local out, result = ffi.new("leanjson_source_v1_op *[1]"), ffi.new("leanjson_source_v1_result[1]")
    local status = C.leanjson_source_v2_node_scalar_begin(handle, out, result)
    if status == ERROR then self:release(lease); error(M.result_error(result), 0) end
    local operation = out[0]
    local record = leases.track(scope, function()
        if operation then local owned = operation; operation = nil; C.leanjson_source_v1_op_release(owned) end
        self:release(lease)
    end)
    local fallback = leases.fallback(scope, record)
    local pointer, size = ffi.new("const uint8_t *[1]"), ffi.new("size_t[1]")
    local function close()
        if fallback then leases.finish(scope, record); fallback = nil end
    end
    local function next_chunk()
        leases.check(scope)
        if not fallback or not operation then return nil end
        local ok, value = pcall(function()
            while status ~= DONE do
                leases.check(scope)
                if not operation then error("leanjson: source operation closed", 0) end
                if status == NEED_READ then
                    local offset, count = M.exact(result[0].offset), M.exact(result[0].length)
                    local bytes = self:read(offset, count, scope)
                    leases.check(scope)
                    M.require_status(C.leanjson_source_v1_provide_window(operation, offset, bytes, #bytes, result), READY, result)
                    status = C.leanjson_source_v1_op_step(operation, pointer, size, result)
                elseif status == READY then
                    local chunk = ffi.string(pointer[0], size[0])
                    self:notify(scope)
                    leases.check(scope)
                    status = C.leanjson_source_v1_op_step(operation, pointer, size, result)
                    if #chunk > 0 then return chunk end
                else error(M.result_error(result), 0) end
            end
        end)
        if not ok or value == nil then close() end
        if not ok then error(value, 0) end
        return value
    end
    return next_chunk, close
end

function M.scalar(self, handle, scope)
    local kind = self:type(handle)
    if kind == "null" then return nil end
    if kind == "number" and bit.band(handle.flags, 8) ~= 0 then
        -- Validation already proved this token nonfinite. Only its sign and
        -- NaN prefix are needed, even for a multi-megabyte NaN payload.
        local next_chunk, close = M.scalar_chunks(self, handle, scope)
        local bytes = next_chunk() or ""
        local first = bytes:byte(1)
        local negative, signed = first == 45, first == 45 or first == 43
        local initial = bytes:byte(signed and 2 or 1)
        if signed and initial == nil then initial = (next_chunk() or ""):byte(1) end
        close()
        if initial == 110 or initial == 78 then return 0/0 end
        return negative and -math.huge or math.huge
    end
    local next_chunk, parts = M.scalar_chunks(self, handle, scope), {}
    while true do
        local chunk = next_chunk()
        if chunk == nil then break end
        parts[#parts + 1] = chunk
    end
    local raw = table.concat(parts)
    if kind == "string" then return raw end
    if kind == "boolean" then return raw == "true" end
    return require("leanjson.number").decode(raw)
end
local function iterator(self, handle, scope, normalize, lookup, linked)
    leases.check(scope)
    local lease = self:retain()
    local out, result = ffi.new("leanjson_source_v2_iter *[1]"), ffi.new("leanjson_source_v1_result[1]")
    local status
    if lookup ~= nil then
        local key = handle.kind == 5 and lookup or ""
        status = C.leanjson_source_v2_lookup_begin(handle, key, #key, handle.kind == 4 and lookup - 1 or 0, out, result)
    else status = C.leanjson_source_v2_iter_begin(handle, normalize and 1 or linked and 2 or 0, out, result) end
    if status ~= READY then self:release(lease); error(M.result_error(result), 0) end
    local operation = out[0]
    local record = leases.track(scope, function()
        if operation then local owned = operation; operation = nil; C.leanjson_source_v2_iter_release(owned) end
        self:release(lease)
    end)
    local fallback = leases.fallback(scope, record)
    local member = ffi.new("leanjson_source_v2_member[1]")
    local current = linked and ffi.new("uint32_t[1]")
    return function()
        leases.check(scope)
        if not fallback or not operation then return nil end
        local ok, key, child, is_current = pcall(function()
            while true do
                local rc
                if linked then rc = C.leanjson_source_v2_iter_next_current(operation, member, current, result)
                else rc = C.leanjson_source_v2_iter_next(operation, member, result) end
                if rc == DONE then return nil end
                if rc == READY then
                    local value = member[0]
                    local name = handle.kind == 4 and M.exact(value.ordinal) + 1 or ffi.string(value.key, value.key_len)
                    local own = ffi.new("leanjson_source_v2_node", value.value)
                    self:notify(scope)
                    return name, own, linked and current[0] ~= 0
                end
                M.require_status(rc, NEED_READ, result)
                local offset, count = M.exact(result[0].offset), M.exact(result[0].length)
                local bytes, length
                if self.memory then
                    bytes = ffi.cast("const uint8_t *", self.raw) + offset
                    length = math.min(count, self.opts.chunk_size)
                else bytes = self:read(offset, count, scope); length = #bytes end
                leases.check(scope)
                if not operation then error("leanjson: source iterator closed", 0) end
                M.require_status(C.leanjson_source_v2_iter_provide_window(operation, offset, bytes, length, result), READY, result)
            end
        end)
        if not ok or key == nil or lookup ~= nil then leases.finish(scope, record); fallback = nil end
        if not ok then error(key, 0) end
        return key, child, is_current
    end
end
function M.children(self, handle, scope, normalize, linked) return iterator(self, handle, scope, normalize, nil, linked) end
function M.lookup(self, handle, key, scope)
    if handle.kind == 4 and key > M.exact(handle.child_count) then return nil end
    local next_child = iterator(self, handle, scope, false, key)
    local _, child = next_child()
    return child
end
return M
