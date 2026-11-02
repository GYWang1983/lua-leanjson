-- Shared sparse span protocol for memory, file and incremental sources.
local ffi = require("ffi")
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
function M.result_error(result)
    local r = result[0]
    local message = r.detail ~= 0 and (details[tonumber(r.detail)] or "source error")
        or ffi.string(C.leanjson_strerror(r.code))
    if r.offset ~= U64_MAX then message = message .. " at byte " .. tostring(M.exact(r.offset)) end
    return "leanjson: " .. message
end
function M.require_status(status, expected, result)
    if status ~= expected then
        if status == ERROR then error(M.result_error(result), 0) end
        error("leanjson: unexpected source status " .. status, 0)
    end
end
function M.native_options(opts)
    return ffi.new("leanjson_source_v2_options[1]", { { 2, 0, opts.max_depth, opts.chunk_size,
        opts.index_depth, opts.index_array_limit, opts.index_budget_bytes, 0, opts.temp_dir, #opts.temp_dir } })
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
function M.clean(self, handle) return handle.flags == 1 end
function M.stats(self)
    self:check_open()
    local result, stats = ffi.new("leanjson_source_v1_result[1]"), ffi.new("leanjson_source_v2_stats[1]")
    M.require_status(C.leanjson_source_v2_get_stats(self.state.source, stats, result), READY, result)
    local out = {}
    for _, name in ipairs({ "budget_bytes", "index_bytes", "indexed_nodes", "indexed_depth", "index_depth", "index_array_limit" }) do
        out[name] = M.exact(stats[0][name])
    end
    local workspace = ffi.new("leanjson_source_v2_workspace_stats[1]")
    M.require_status(C.leanjson_source_v2_get_workspace_stats(self.state.source, workspace, result), READY, result)
    for _, name in ipairs({ "spill_file_bytes", "spill_live_regions", "spill_free_regions" }) do
        out[name] = M.exact(workspace[0][name])
    end
    return out
end
function M.clear_indexes(self)
    local result = ffi.new("leanjson_source_v1_result[1]")
    M.require_status(C.leanjson_source_v2_clear_indexes(self.state.source, result), READY, result)
end
function M.scalar(self, handle, scope)
    local kind = self:type(handle)
    if kind == "null" then return nil end
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
    local ok, value = pcall(function()
        local parts, pointer, size = {}, ffi.new("const uint8_t *[1]"), ffi.new("size_t[1]")
        while status ~= DONE do
            leases.check(scope)
            if not fallback or not operation then error("leanjson: source operation closed", 0) end
            if status == NEED_READ then
                local offset, count = M.exact(result[0].offset), M.exact(result[0].length)
                local bytes = self:read(offset, count, scope)
                leases.check(scope)
                M.require_status(C.leanjson_source_v1_provide_window(operation, offset, bytes, #bytes, result), READY, result)
            elseif status == READY then
                parts[#parts + 1] = ffi.string(pointer[0], size[0])
                self:notify(scope)
            else error(M.result_error(result), 0) end
            status = C.leanjson_source_v1_op_step(operation, pointer, size, result)
        end
        local raw = table.concat(parts)
        if kind == "string" then return raw end
        if kind == "boolean" then return raw == "true" end
        local number = tonumber(raw)
        if number == nil or number == math.huge or number == -math.huge then
            if self.memory then error("leanjson: out of range at byte " .. M.exact(handle.raw_start), 0) end
            error("leanjson: number out of range", 0)
        end
        return number
    end)
    leases.finish(scope, record)
    fallback = nil
    if not ok then error(value, 0) end
    return value
end
local function iterator(self, handle, scope, normalize, lookup)
    leases.check(scope)
    local lease = self:retain()
    local out, result = ffi.new("leanjson_source_v2_iter *[1]"), ffi.new("leanjson_source_v1_result[1]")
    local status
    if lookup ~= nil then
        local key = handle.kind == 5 and lookup or ""
        status = C.leanjson_source_v2_lookup_begin(handle, key, #key, handle.kind == 4 and lookup - 1 or 0, out, result)
    else status = C.leanjson_source_v2_iter_begin(handle, normalize and 1 or 0, out, result) end
    if status ~= READY then self:release(lease); error(M.result_error(result), 0) end
    local operation = out[0]
    local record = leases.track(scope, function()
        if operation then local owned = operation; operation = nil; C.leanjson_source_v2_iter_release(owned) end
        self:release(lease)
    end)
    local fallback = leases.fallback(scope, record)
    local member = ffi.new("leanjson_source_v2_member[1]")
    return function()
        leases.check(scope)
        if not fallback or not operation then return nil end
        local ok, key, child = pcall(function()
            while true do
                local rc = C.leanjson_source_v2_iter_next(operation, member, result)
                if rc == DONE then return nil end
                if rc == READY then
                    local value = member[0]
                    local name = handle.kind == 4 and M.exact(value.ordinal) + 1 or ffi.string(value.key, value.key_len)
                    local own = ffi.new("leanjson_source_v2_node", value.value)
                    self:notify(scope)
                    return name, own
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
        return key, child
    end
end
function M.children(self, handle, scope, normalize) return iterator(self, handle, scope, normalize) end
function M.lookup(self, handle, key, scope)
    if handle.kind == 4 and key > M.exact(handle.child_count) then return nil end
    local next_child = iterator(self, handle, scope, false, key)
    local _, child = next_child()
    return child
end
return M
