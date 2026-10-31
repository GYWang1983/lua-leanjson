-- Immutable logical nodes and mutable proxy cells. Only this weak side table
-- associates a public (always empty) Lua table with its private state.
local M = {}
local META = setmetatable({}, { __mode = "k" })
local Object, Array = {}, {}
local config

function M.configure(options) config = options end

local function raw_node(backend, handle)
    return { backend = backend, handle = handle, kind = backend:type(handle) }
end

function M.members(node)
    if node.values then return node.keys, node.values, node.entries end
    local keys, values, entries = {}, {}, {}
    for key, handle in node.backend:children(node.handle) do
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

function M.scalar(node)
    if node.kind == "null" then return config.null end
    if node.backend then return node.backend:scalar(node.handle) end
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

local function changed(node, key, value)
    local keys, values = M.members(node)
    local new_keys, new_values = {}, copy_map(values)
    for _, k in ipairs(keys) do
        if k ~= key or value ~= nil then new_keys[#new_keys + 1] = k end
    end
    if values[key] == nil and value ~= nil then new_keys[#new_keys + 1] = key end
    new_values[key] = value
    return { kind = node.kind, keys = new_keys, values = new_values }
end

local function replace(cell, node)
    local old = cell.node
    cell.node, cell.version = node, cell.version + 1
    local parent = cell.parent
    if parent then
        local _, values = M.members(parent.node)
        if values[cell.key] == old then
            replace(parent, changed(parent.node, cell.key, node))
        elseif cell.lexical then
            -- Earlier duplicate occurrences may be traversed for compatibility,
            -- but only the last occurrence participates in the logical value.
            replace(parent, changed(parent.node, cell.key, values[cell.key]))
        end
    end
end

local function wrap(node, parent, key, lexical)
    local proxy = setmetatable({}, node.kind == "array" and Array or Object)
    META[proxy] = { node = node, parent = parent, key = key, cache = setmetatable({}, { __mode = "v" }), version = 0, lexical = lexical }
    return proxy
end

local function expose(node, parent, key, lexical)
    if node == nil then return nil end
    if node.kind ~= "object" and node.kind ~= "array" then return M.scalar(node) end
    if parent and not lexical then
        -- A metadata load can yield while the mutable parent cell is replaced.
        -- Only attach/cache the child if it still belongs to the current node;
        -- otherwise the in-flight read returns its detached old snapshot.
        while true do
            local current, version = parent.node, parent.version
            local _, values = M.members(current)
            if parent.node == current and parent.version == version then
                if values[key] ~= node then return wrap(node) end
                break
            end
        end
        local cached = parent.cache[key]
        if cached then return cached end
        local proxy = wrap(node, parent, key)
        parent.cache[key] = proxy
        return proxy
    end
    return wrap(node, parent, key, lexical)
end

local function array_length(node)
    local _, values = M.members(node)
    local n = 0
    while values[n + 1] ~= nil do n = n + 1 end
    return n
end

local snapshot
snapshot = function(value, active, depth)
    if rawequal(value, config.null) or type(value) == "nil" then return { kind = "null" } end
    local cell = META[value]
    if cell then return cell.node end
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
function M.node(value) return META[value] and META[value].node end
function M.from_backend(backend, handle) return expose(raw_node(backend, handle)) end
function M.from_node(node) return expose(node) end
function M.fork(value) return expose(M.snapshot(value)) end

function M.type(value)
    if rawequal(value, config.null) then return "null" end
    local cell = META[value]
    if cell then return cell.node.kind end
    if type(value) == "table" then
        local kind = config.classify(value)
        return kind
    end
    return type(value)
end

local function read(proxy, key)
    local cell = META[proxy]
    if cell.node.kind == "object" then
        if type(key) ~= "string" then return nil end
    elseif type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
        return nil
    end
    local _, values = M.members(cell.node)
    return expose(values[key], cell, key)
end

local function write(proxy, key, value)
    local cell = META[proxy]
    if cell.node.kind == "object" then
        if type(key) ~= "string" then error("qjson: object key must be a string, got " .. type(key), 0) end
    elseif type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key == math.huge then
        error("qjson: array index must be a positive integer", 0)
    end
    local present = type(value) ~= "nil"
    if cell.node.kind == "array" then
        local n = array_length(cell.node)
        if (present and key > n + 1) or (not present and key < n) then
            error("qjson: sparse proxy arrays require explicit materialization", 0)
        end
    end
    local node = present and M.snapshot(value) or nil
    local cached = cell.cache[key]
    if cached then META[cached].parent = nil; cell.cache[key] = nil end
    replace(cell, changed(cell.node, key, node))
end

Object.__index, Array.__index = read, read
Object.__newindex, Array.__newindex = write, write

function M.len(value)
    local cell = META[value]
    if not cell then return #value end
    if cell.node.kind == "array" then return array_length(cell.node) end
    local keys = M.members(cell.node)
    return #keys
end
Object.__len, Array.__len = M.len, M.len

function M.ipairs(value)
    local cell = META[value]
    if not cell then return ipairs(value) end
    local index, version = 0, cell.version
    return function()
        if cell.version ~= version then error("qjson: invalid argument", 0) end
        index = index + 1
        local child = read(value, index)
        if child ~= nil then return index, child end
    end, nil, 0
end

function M.pairs(value)
    local cell = META[value]
    if not cell then return pairs(value) end
    if cell.node.kind == "array" then return M.ipairs(value) end
    local keys, values, entries = M.members(cell.node)
    local lexical_entries = cell.node.backend and entries
    local index = 0
    return function()
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
            local _, current = M.members(cell.node)
            local lexical = current[key] ~= node
            return key, expose(node, cell, key, lexical)
        end
    end, nil, nil
end
Object.__pairs, Array.__pairs, Array.__ipairs = M.pairs, M.pairs, M.ipairs

local function check_array(value, index, inserting)
    local cell = META[value]
    if M.type(value) ~= "array" then error("qjson: expected array", 0) end
    local n = M.len(value)
    if not cell then
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
    return cell, n
end

function M.array_insert(value, index, child)
    local cell, n = check_array(value, index, true)
    if type(child) == "nil" then error("qjson: array_insert requires a value", 0) end
    if not cell then table.insert(value, index, child); return end
    local inserted = M.snapshot(child)
    local _, old = M.members(cell.node)
    local values, keys = copy_map(old), {}
    for i = n, index, -1 do
        values[i + 1] = values[i]
        cell.cache[i + 1] = cell.cache[i]
        if cell.cache[i + 1] then META[cell.cache[i + 1]].key = i + 1 end
    end
    cell.cache[index] = nil
    values[index] = inserted
    for i = 1, n + 1 do keys[i] = i end
    replace(cell, { kind = "array", keys = keys, values = values })
end

function M.array_remove(value, index)
    local cell, n = check_array(value, index, false)
    if not cell then return table.remove(value, index) end
    local removed = read(value, index)
    if META[removed] then META[removed].parent = nil end
    local _, old = M.members(cell.node)
    local values, keys = copy_map(old), {}
    for i = index, n - 1 do
        values[i] = values[i + 1]
        cell.cache[i] = cell.cache[i + 1]
        if cell.cache[i] then META[cell.cache[i]].key = i end
    end
    values[n], cell.cache[n] = nil, nil
    for i = 1, n - 1 do keys[i] = i end
    replace(cell, { kind = "array", keys = keys, values = values })
    return removed
end

M.Object, M.Array = Object, Array
return M
