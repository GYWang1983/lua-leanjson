-- Immutable logical nodes and mutable proxy cells. Only this weak side table
-- associates a public (always empty) Lua table with its private state.
local M = {}
local ffi = require("ffi")
local leases = require("qjson.leases")
local META = setmetatable({}, { __mode = "k" })
local GC_TOKENS = setmetatable({}, { __mode = "k" })
local Object, Array = {}, {}
local config
local function live_holder(cell)
    local value = cell.public and cell.public[1]
    local holder = value and META[value]
    if holder and not holder.closed then return holder, value end
end

local function watch_resources(cell)
    local holder, value = live_holder(cell)
    if holder and #holder.scope.entries > 0 and not GC_TOKENS[value] then
        local scope = holder.scope
        -- GC releases this public holder only. It never changes logical links.
        GC_TOKENS[value] = ffi.gc(ffi.new("uint8_t[1]"), function() leases.release(scope) end)
    end
end

function M.configure(options) config = options end

local function raw_node(backend, handle)
    return { backend = backend, handle = handle, kind = backend:type(handle) }
end

function M.members(node, scope)
    if node.values then return node.keys, node.values, node.entries end
    local keys, values, entries = {}, {}, {}
    for key, handle in node.backend:children(node.handle, scope) do
        local child = raw_node(node.backend, handle)
        if values[key] == nil then keys[#keys + 1] = key end
        values[key] = child
        entries[#entries + 1] = { key, child }
    end
    -- Backends may yield while loading structural metadata. Another coroutine
    -- can publish the same index first; retain its stable child-node identities.
    if node.values then return node.keys, node.values, node.entries end
    node.keys, node.values, node.entries = keys, values, entries
    return keys, values, entries
end

function M.scalar(node, scope)
    if node.kind == "null" then return config.null end
    if node.backend then return node.backend:scalar(node.handle, scope) end
    return node.value
end

function M.span(node)
    if node.backend then
        local first, last = node.backend:span(node.handle)
        if type(first) ~= "number" or type(last) ~= "number"
            or first < 0 or last < first or first ~= math.floor(first) or last ~= math.floor(last)
        then error("qjson: invalid source span", 0) end
        return node.backend, first, last
    end
end

local function copy_map(original)
    local out = {}
    for key, value in pairs(original) do out[key] = value end
    return out
end

local function changed(node, key, value, scope)
    local keys, values = M.members(node, scope)
    local new_keys, new_values = {}, copy_map(values)
    for _, k in ipairs(keys) do
        if k ~= key or value ~= nil then new_keys[#new_keys + 1] = k end
    end
    if values[key] == nil and value ~= nil then new_keys[#new_keys + 1] = key end
    new_values[key] = value
    return { kind = node.kind, keys = new_keys, values = new_values }
end

local function replace(cell, node, scope)
    leases.check(scope)
    if cell.closed then error("qjson: holder closed", 0) end
    local holder = live_holder(cell)
    if holder then leases.retarget(holder.scope, node); watch_resources(cell) end
    local old = cell.node
    cell.node, cell.version = node, cell.version + 1
    local parent = cell.parent
    if parent and not parent.closed then
        local _, values = M.members(parent.node, scope)
        if parent.closed then cell.parent = nil; return end
        if values[cell.key] == old then
            replace(parent, changed(parent.node, cell.key, node, scope), scope)
        elseif cell.lexical then
            -- Earlier duplicate occurrences may be traversed for compatibility,
            -- but only the last occurrence participates in the logical value.
            replace(parent, changed(parent.node, cell.key, values[cell.key], scope), scope)
        end
    end
end

local function new_cell(node, parent, key, lexical)
    return { node = node, parent = parent, key = key, children = {}, version = 0, lexical = lexical }
end

local function wrap(cell)
    local holder, value = live_holder(cell)
    if holder then return value end
    value = setmetatable({}, cell.node.kind == "array" and Array or Object)
    META[value] = { cell = cell, scope = leases.acquire(cell.node) }
    cell.public = setmetatable({ value }, { __mode = "v" })
    watch_resources(cell)
    return value
end

local function child_cell(node, parent, key, lexical, scope)
    if parent and not lexical then
        -- A metadata load can yield while the mutable parent cell is replaced.
        -- Only attach/cache the child if it still belongs to the current node;
        -- otherwise the in-flight read returns its detached old snapshot.
        while true do
            leases.check(scope)
            if parent.closed then return new_cell(node) end
            local current, version = parent.node, parent.version
            local _, values = M.members(current, scope)
            if parent.node == current and parent.version == version then
                if values[key] ~= node then return new_cell(node) end
                break
            end
        end
        local cached = parent.children[key]
        if cached and cached.node == node and not cached.closed then return cached end
        if cached then cached.parent = nil end
        local cell = new_cell(node, parent, key)
        parent.children[key] = cell
        return cell
    end
    return new_cell(node, parent, key, lexical)
end

local function expose(node, parent, key, lexical, scope)
    if node == nil then return nil end
    if node.kind ~= "object" and node.kind ~= "array" then return M.scalar(node, scope) end
    return wrap(child_cell(node, parent, key, lexical, scope))
end

local function array_length(node, scope)
    local _, values = M.members(node, scope)
    local n = 0
    while values[n + 1] ~= nil do n = n + 1 end
    return n
end

local snapshot
snapshot = function(value, active, depth)
    if rawequal(value, config.null) or type(value) == "nil" then return { kind = "null" } end
    local holder = META[value]
    if holder then leases.check(holder.scope); return holder.cell.node end
    local tv = type(value)
    if tv ~= "table" then return { kind = tv, value = value } end
    if active[value] then error("qjson.encode: circular reference", 0) end
    if depth > 1000 then error("qjson.encode: max depth exceeded", 0) end
    active[value] = true
    local kind, n = config.classify(value)
    local node = { kind = kind, keys = {}, values = {} }
    if kind == "array" then
        for i = 1, n do
            node.keys[i] = i
            node.values[i] = snapshot(value[i], active, depth + 1)
        end
    else
        for key, child in pairs(value) do
            local kt = type(key)
            if kt ~= "string" and kt ~= "number" then
                error("qjson.encode: object key must be a string or number, got " .. kt, 0)
            end
            key = tostring(key)
            if node.values[key] == nil then node.keys[#node.keys + 1] = key end
            node.values[key] = snapshot(child, active, depth + 1)
        end
    end
    active[value] = nil
    return node
end

function M.snapshot(value) return snapshot(value, {}, 1) end
function M.is_proxy(value) return META[value] ~= nil end
function M.node(value)
    local holder = META[value]
    if holder then leases.check(holder.scope); return holder.cell.node end
end
function M.scope(value) return META[value] and META[value].scope end
function M.from_backend(backend, handle) return expose(raw_node(backend, handle)) end
function M.from_node(node) return expose(node) end
function M.fork(value) return expose(M.snapshot(value)) end

function M.get_path(value, segments)
    if #segments == 0 then return value end
    local owner = META[value]
    return leases.guard(owner.scope, owner.cell.node, function()
        local cell, node = owner.cell, owner.cell.node
        for i, segment in ipairs(segments) do
            if node.kind ~= segment.kind then error("qjson.get: type mismatch", 0) end
            local _, values = M.members(node, owner.scope)
            leases.check(owner.scope)
            node = values[segment.key]
            if node == nil then return nil end
            if i == #segments then return expose(node, cell, segment.key, false, owner.scope) end
            if node.kind ~= "object" and node.kind ~= "array" then error("qjson.get: type mismatch", 0) end
            -- Intermediate cells are canonical logical links, not public
            -- holders. Every yielded operation still uses the initiating scope.
            cell = child_cell(node, cell, segment.key, false, owner.scope)
        end
    end)
end

local function close_cell(cell)
    cell.closed, cell.version = true, cell.version + 1
    local parent = cell.parent
    if parent and parent.children[cell.key] == cell then
        parent.children[cell.key] = nil
    end
    for _, child in pairs(cell.children) do
        if child.parent == cell then child.parent = nil end
    end
    cell.parent, cell.node, cell.children = nil, nil, {}
end

function M.close(value)
    local holder = META[value]
    if not holder or holder.closed then return end
    holder.closed = true
    local token = GC_TOKENS[value]
    if token then ffi.gc(token, nil); GC_TOKENS[value] = nil end
    close_cell(holder.cell)
    leases.release(holder.scope)
end

function M.type(value)
    if rawequal(value, config.null) then return "null" end
    local holder = META[value]
    if holder then leases.check(holder.scope); return holder.cell.node.kind end
    if type(value) == "table" then
        local kind = config.classify(value)
        return kind
    end
    return type(value)
end

local function read(proxy, key)
    local holder = META[proxy]
    local cell = holder.cell
    return leases.guard(holder.scope, cell.node, function()
        if cell.node.kind == "object" then
            if type(key) ~= "string" then return nil end
        elseif type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil
        end
        local _, values = M.members(cell.node, holder.scope)
        leases.check(holder.scope)
        return expose(values[key], cell, key, false, holder.scope)
    end)
end

local function write(proxy, key, value)
    local holder = META[proxy]
    local cell = holder.cell
    return leases.guard(holder.scope, cell.node, function()
        if cell.node.kind == "object" then
            if type(key) ~= "string" then error("qjson: object key must be a string, got " .. type(key), 0) end
        elseif type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key == math.huge then
            error("qjson: array index must be a positive integer", 0)
        end
        local present = type(value) ~= "nil"
        if cell.node.kind == "array" then
            local n = array_length(cell.node, holder.scope)
            if (present and key > n + 1) or (not present and key < n) then
                error("qjson: sparse proxy arrays require explicit materialization", 0)
            end
        end
        local node = present and M.snapshot(value) or nil
        local cached = cell.children[key]
        if cached then cached.parent = nil; cell.children[key] = nil end
        replace(cell, changed(cell.node, key, node, holder.scope), holder.scope)
    end)
end

Object.__index, Array.__index = read, read
Object.__newindex, Array.__newindex = write, write

function M.len(value)
    local holder = META[value]
    if not holder then return #value end
    local cell = holder.cell
    return leases.guard(holder.scope, cell.node, function()
        if cell.node.kind == "array" then return array_length(cell.node, holder.scope) end
        local keys = M.members(cell.node, holder.scope)
        return #keys
    end)
end
Object.__len, Array.__len = M.len, M.len

function M.ipairs(value)
    local holder = META[value]
    if not holder then return ipairs(value) end
    local cell = holder.cell
    leases.check(holder.scope)
    local index, version = 0, cell.version
    return function()
        leases.check(holder.scope)
        if cell.version ~= version then error("qjson: invalid argument", 0) end
        index = index + 1
        local child = read(value, index)
        if child ~= nil then return index, child end
    end, nil, 0
end

function M.pairs(value)
    local holder = META[value]
    if not holder then return pairs(value) end
    local cell = holder.cell
    leases.check(holder.scope)
    if cell.node.kind == "array" then return M.ipairs(value) end
    local pin = leases.pin(holder.scope, cell.node)
    local fallback = leases.fallback(holder.scope, pin)
    local keys, values, entries = M.members(cell.node, holder.scope)
    local lexical_entries = cell.node.backend and entries
    local index = 0
    return function()
        -- The iterator is itself a live use of the public source proxy.
        leases.check(META[value].scope)
        if not fallback then return nil end
        index = index + 1
        local key, node
        if lexical_entries then
            local entry = lexical_entries[index]
            if entry then key, node = entry[1], entry[2] end
        else
            key = keys[index]
            if key ~= nil then node = values[key] end
        end
        if key ~= nil then
            local _, current = M.members(cell.node, holder.scope)
            local lexical = current[key] ~= node
            return key, expose(node, cell, key, lexical, holder.scope)
        end
        leases.finish(holder.scope, pin)
        fallback = nil
    end, nil, nil
end
Object.__pairs, Array.__pairs, Array.__ipairs = M.pairs, M.pairs, M.ipairs

local function check_array(value, index, inserting)
    local holder = META[value]
    if M.type(value) ~= "array" then error("qjson: expected array", 0) end
    local n = M.len(value)
    if not holder then
        local count = 0
        for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > n then
                error("qjson: array operations require a dense array", 0)
            end
            count = count + 1
        end
        if count ~= n then error("qjson: array operations require a dense array", 0) end
    end
    if type(index) ~= "number" or index ~= math.floor(index) or index < 1
        or index > n + (inserting and 1 or 0)
    then error("qjson: array index out of range", 0) end
    return holder, n
end

function M.array_insert(value, index, child)
    local holder, n = check_array(value, index, true)
    if type(child) == "nil" then error("qjson: array_insert requires a value", 0) end
    if not holder then table.insert(value, index, child); return end
    local cell = holder.cell
    local inserted = M.snapshot(child)
    local _, old = M.members(cell.node, holder.scope)
    local values, keys = copy_map(old), {}
    for i = n, index, -1 do
        values[i + 1] = values[i]
        cell.children[i + 1] = cell.children[i]
        if cell.children[i + 1] then cell.children[i + 1].key = i + 1 end
    end
    cell.children[index] = nil
    values[index] = inserted
    for i = 1, n + 1 do keys[i] = i end
    replace(cell, { kind = "array", keys = keys, values = values }, holder.scope)
end

function M.array_remove(value, index)
    local holder, n = check_array(value, index, false)
    if not holder then return table.remove(value, index) end
    local cell = holder.cell
    local removed = read(value, index)
    if META[removed] then META[removed].cell.parent = nil end
    local _, old = M.members(cell.node, holder.scope)
    local values, keys = copy_map(old), {}
    for i = index, n - 1 do
        values[i] = values[i + 1]
        cell.children[i] = cell.children[i + 1]
        if cell.children[i] then cell.children[i].key = i end
    end
    values[n], cell.children[n] = nil, nil
    for i = 1, n - 1 do keys[i] = i end
    replace(cell, { kind = "array", keys = keys, values = values }, holder.scope)
    return removed
end

M.Object, M.Array = Object, Array
return M
