-- A holder owns one lease per backend plus cancellable transient operations.
-- Raw nodes denote one immutable backend; only synthetic overlays are walked.
local ffi = require("ffi")
local M = {}
local nodes = require("leanjson.nodes")

local function dependencies(node, found)
    local stack = { node }
    while #stack > 0 do
        local current = table.remove(stack)
        if current.backend then found[current.backend] = true
        else nodes.dependencies(current, function(child) stack[#stack + 1] = child end) end
    end
end

local function release_entries(entries)
    for _, entry in ipairs(entries) do entry[1]:release(entry[2]) end
end

local function acquire_entries(node, owner)
    local found, entries = {}, owner and owner.entries or {}
    if node then dependencies(node, found) end
    local ok, err = pcall(function()
        for backend in pairs(found) do
            if backend.retain then
                local token = backend:retain()
                if owner and owner.closed then
                    backend:release(token)
                    error("leanjson: holder closed", 0)
                end
                entries[#entries + 1] = { backend, token }
            end
        end
    end)
    if not ok then
        if owner then M.release(owner) else release_entries(entries) end
        error(err, 0)
    end
    return entries
end

function M.acquire(node) return { entries = acquire_entries(node), active = {} } end

function M.managed(node)
    local found = {}
    dependencies(node, found)
    for backend in pairs(found) do if backend.retain and not backend.memory then return true end end
    return false
end

function M.check(scope)
    if scope and scope.closed then error("leanjson: holder closed", 0) end
    if scope then
        for _, entry in ipairs(scope.entries) do
            local backend = entry[1]
            if backend.check_open then backend:check_open() end
        end
        if scope.closed then error("leanjson: holder closed", 0) end
    end
end

function M.finish(scope, record)
    if not record then return end
    if scope then scope.active[record] = nil end
    local cleanup = record.cleanup
    record.cleanup = nil
    if cleanup then cleanup() end
end

function M.track(scope, cleanup)
    local record = { cleanup = cleanup }
    if scope and scope.closed then cleanup(); error("leanjson: holder closed", 0) end
    if scope then scope.active[record] = true end
    return record
end

function M.release(scope)
    if not scope or scope.closed then return end
    scope.closed = true
    for record in pairs(scope.active) do M.finish(scope, record) end
    release_entries(scope.entries)
    scope.entries = {}
end

-- Prepared dependencies are cancellable by the initiating holder. Adoption is
-- a non-yielding transfer after the caller has validated its logical versions.
function M.prepare(scope, node)
    M.check(scope)
    local prepared = { entries = {}, active = {} }
    local record = M.track(scope, function() M.release(prepared) end)
    local ok, err = pcall(function()
        acquire_entries(node, prepared)
        M.check(scope)
    end)
    if not ok then M.finish(scope, record); error(err, 0) end
    return prepared, record
end

function M.adopt(scope, prepared)
    local previous = scope.entries
    scope.entries, prepared.entries = prepared.entries, {}
    release_entries(previous)
end

function M.pin(scope, node)
    local _, record = M.prepare(scope, node)
    return record
end

function M.guard(scope, node, fn)
    M.check(scope)
    local record = M.pin(scope, node)
    local ok, a, b, c = pcall(fn)
    M.finish(scope, record)
    M.check(scope)
    if not ok then error(a, 0) end
    return a, b, c
end

-- An abandoned iterator has no explicit close API. Its token must be retained
-- only by its closure, never by scope.active, so GC can remove the active pin.
function M.fallback(scope, record)
    return ffi.gc(ffi.new("uint8_t[1]"), function() M.finish(scope, record) end)
end

return M
