-- Immutable logical nodes and mutable proxy cells. Only this weak side table
-- associates a public (always empty) Lua table with its private state.
local M = {}
local ffi = require("ffi")
local leases = require("leanjson.leases")
local nodes = require("leanjson.nodes")
local raw_metatable = debug and debug.getmetatable or getmetatable
local META = setmetatable({}, { __mode = "k" })
local GC_TOKENS = setmetatable({}, { __mode = "k" })
local Object, Array, MarkedArray = {}, {}, {}
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

function M.configure(options)
    config = options
    MarkedArray.__metatable = options.array_mt
end

M.array_marked = nodes.array_marked

local raw_node = nodes.raw
M.members, M.lookup, M.iter = nodes.members, nodes.lookup, nodes.iter

function M.scalar(node, scope)
    if node.kind == "null" then return config.null end
    if node.preloaded then return node.value end
    if node.backend then return node.backend:scalar(node.handle, scope) end
    return node.value
end

function M.span(node)
    if node.backend then
        local first, last = node.backend:span(node.handle)
        if type(first) ~= "number" or type(last) ~= "number"
            or first < 0 or last < first or first ~= math.floor(first) or last ~= math.floor(last)
        then error("leanjson: invalid source span", 0) end
        return node.backend, first, last
    end
end

local changed = nodes.changed

local function new_cell(node, parent, key, lexical, codec)
    return { node = node, parent = parent, key = key, children = setmetatable({}, { __mode = "v" }), version = 0,
        lexical = lexical, codec = codec or (parent and parent.codec) or config }
end

local function wrap(cell, prepared)
    local holder, value = live_holder(cell)
    if holder then return value end
    local mt = Object
    if cell.node.kind == "array" then mt = M.array_marked(cell.node) and MarkedArray or Array end
    value = setmetatable({}, mt)
    local scope
    if prepared then
        scope = leases.acquire()
        leases.adopt(scope, prepared)
    else scope = leases.acquire(cell.node) end
    META[value] = { cell = cell, scope = scope }
    cell.public = setmetatable({ value }, { __mode = "v" })
    watch_resources(cell)
    return value
end

local function child_cell(node, parent, key, lexical, scope, expected, codec)
    if parent and not lexical then
        leases.check(scope)
        if parent.closed or parent.node ~= expected then return new_cell(node, nil, nil, nil, parent.codec) end
        local cached = parent.children[key]
        if cached and nodes.same(cached.node, node) and not cached.closed then return cached end
        if cached then cached.parent = nil end
        local cell = new_cell(node, parent, key)
        parent.children[key] = cell
        return cell
    end
    return new_cell(node, parent, key, lexical, codec)
end

local function expose(node, parent, key, lexical, scope, expected, codec)
    if node == nil then return nil end
    if node.kind ~= "object" and node.kind ~= "array" then return M.scalar(node, scope) end
    return wrap(child_cell(node, parent, key, lexical, scope, expected, codec))
end
local array_length = nodes.length

-- Snapshot plain assignments iteratively: high configured depths must not
-- consume the Lua call stack. Only active ancestors detect genuine cycles.
function M.snapshot(value, classify, encode_key, maximum)
    classify, encode_key = classify or config.classify, encode_key or config.key or tostring
    maximum = maximum or 1000
    local active, stack = {}, {}
    local function accept(value, depth)
        if rawequal(value, config.null) or type(value) == "nil" then return { kind = "null" } end
        if rawequal(value, config.empty_array) then return { kind = "array", keys = {}, values = {}, marked_array = true, empty_array_sentinel = true } end
        local holder = META[value]
        if holder then leases.check(holder.scope); return holder.cell.node end
        local tv = type(value)
        if tv ~= "table" then return { kind = tv, value = value } end
        if active[value] or depth > maximum then
            error("Cannot serialise, excessive nesting (" .. (maximum + 1) .. ")", 0)
        end
        local kind, length, raw = classify(value)
        local node = { kind = kind, keys = {}, values = {} }
        if kind == "array" then node.marked_array = rawequal(raw_metatable(value), config.array_mt) end
        active[value] = true
        stack[#stack + 1] = { value = value, node = node, depth = depth, length = length, raw = raw, index = 0 }
        return node
    end
    local result = accept(value, 1)
    while #stack > 0 do
        local frame = stack[#stack]
        local key, child
        if frame.node.kind == "array" then
            frame.index = frame.index + 1
            if frame.index <= frame.length then
                key = frame.index
                if frame.raw then child = rawget(frame.value, key) else child = frame.value[key] end
            end
        else key, child = next(frame.value, frame.previous); frame.previous = key end
        if key == nil then active[frame.value] = nil; stack[#stack] = nil
        else
            if frame.node.kind == "object" then key = encode_key(key) end
            local member = accept(child, frame.depth + 1)
            local node = frame.node
            if node.values[key] ~= nil and not node.serialized_entries then
                node.serialized_entries = {}
                for _, name in ipairs(node.keys) do node.serialized_entries[#node.serialized_entries + 1] = { name, node.values[name] } end
            end
            if node.serialized_entries then node.serialized_entries[#node.serialized_entries + 1] = { key, member } end
            if node.values[key] == nil then node.keys[#node.keys + 1] = key end
            node.values[key] = member
        end
    end
    return result
end
function M.is_proxy(value) return META[value] ~= nil end
function M.node(value)
    local holder = META[value]
    if holder then leases.check(holder.scope); return holder.cell.node end
end
function M.scope(value) return META[value] and META[value].scope end
function M.codec(value) return (META[value] and META[value].cell.codec) or config end
function M.from_backend(backend, handle, codec) return expose(raw_node(backend, handle), nil, nil, nil, nil, nil, codec) end
function M.from_node(node, codec) return expose(node, nil, nil, nil, nil, nil, codec) end
function M.fork(value, codec)
    codec = codec or M.codec(value)
    return M.from_node(M.snapshot(value, codec.classify, codec.key, codec.encode_max_depth and codec.encode_max_depth() or 1000), codec)
end

function M.get_path(value, segments)
    if #segments == 0 then return value end
    local owner = META[value]
    return leases.guard(owner.scope, owner.cell.node, function()
        local cell, node = owner.cell, owner.cell.node
        for i, segment in ipairs(segments) do
            if node.kind ~= segment.kind then error("leanjson.get: type mismatch", 0) end
            local parent_node = node
            node = M.lookup(node, segment.key, owner.scope)
            leases.check(owner.scope)
            if node == nil then return nil end
            if i == #segments then return expose(node, cell, segment.key, false, owner.scope, parent_node) end
            if node.kind ~= "object" and node.kind ~= "array" then error("leanjson.get: type mismatch", 0) end
            -- Intermediate cells are canonical logical links, not public
            -- holders. Every yielded operation still uses the initiating scope.
            cell = child_cell(node, cell, segment.key, false, owner.scope, parent_node)
            node = cell.node
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

function M.type(value, classify)
    if rawequal(value, config.null) then return "null" end
    if rawequal(value, config.empty_array) then return "array" end
    local holder = META[value]
    if holder then leases.check(holder.scope); return holder.cell.node.kind end
    if type(value) == "table" then
        local kind = (classify or config.classify)(value)
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
        local original = cell.node
        local child = M.lookup(original, key, holder.scope)
        leases.check(holder.scope)
        return expose(child, cell, key, false, holder.scope, original)
    end)
end

-- Metadata, scalar reads and dependency checks may yield. Prepare immutable
-- target/ancestor replacements first, then validate every captured version and
-- link in one non-yielding step before moving children or publishing any node.
local function mutate(holder, prepare)
    local scope = holder.scope
    return leases.guard(scope, holder.cell.node, function()
        local records, chain = {}, {}
        local function dependencies(node)
            local prepared, record = leases.prepare(scope, node)
            records[#records + 1] = record
            return prepared
        end
        local ok, result = pcall(function()
            local cell = holder.cell
            while cell and not cell.closed do
                local current, public = live_holder(cell)
                chain[#chain + 1] = { cell = cell, node = cell.node, version = cell.version,
                    parent = cell.parent, key = cell.key, holder = current, public = public }
                cell = cell.parent
            end
            for _, entry in ipairs(chain) do
                -- Synthetic private ancestors have no I/O and are non-owning.
                -- Their unrelated source dependencies may already be closed
                -- after an unreachable public wrapper was collected.
                if entry.node.backend then dependencies(entry.node) end
            end
            local node, publish, complete = prepare(chain[1].node, scope, dependencies)
            local updates = { { entry = chain[1], node = node } }
            for i = 2, #chain do
                local child, parent = chain[i - 1], chain[i]
                local current = M.lookup(parent.node, child.key, scope)
                if nodes.same(current, child.node) then
                    node = changed(parent.node, child.key, node, scope)
                elseif child.cell.lexical then
                    -- Only the final duplicate occurrence is a logical member.
                    node = changed(parent.node, child.key, current, scope)
                else break end
                updates[#updates + 1] = { entry = parent, node = node }
            end
            for _, update in ipairs(updates) do
                if update.entry.holder then update.prepared = dependencies(update.node) end
            end
            -- Finish all potentially yielding checks before the atomic test.
            leases.check(scope)
            for _, update in ipairs(updates) do
                if update.entry.holder then leases.check(update.entry.holder.scope) end
                if update.prepared then leases.check(update.prepared) end
            end
            for _, entry in ipairs(chain) do
                local current = live_holder(entry.cell)
                if entry.cell.closed or entry.cell.node ~= entry.node or entry.cell.version ~= entry.version
                    or entry.cell.parent ~= entry.parent or entry.cell.key ~= entry.key or current ~= entry.holder
                then error("leanjson: stale proxy mutation", 0) end
            end
            -- Backend lease transfers, cache edits and publication do not yield.
            for _, update in ipairs(updates) do
                if update.prepared then
                    leases.adopt(update.entry.holder.scope, update.prepared)
                    watch_resources(update.entry.cell)
                end
            end
            if publish then publish() end
            for _, update in ipairs(updates) do
                update.entry.cell.node = update.node
                update.entry.cell.version = update.entry.version + 1
            end
            if complete then return complete() end
        end)
        for _, record in ipairs(records) do leases.finish(scope, record) end
        if not ok then error(result, 0) end
        return result
    end)
end

local function write(proxy, key, value)
    local holder = META[proxy]
    local cell = holder.cell
    return mutate(holder, function(original, scope, dependencies)
        if original.kind == "object" then
            if type(key) ~= "string" then error("leanjson: object key must be a string, got " .. type(key), 0) end
        elseif type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key == math.huge then
            error("leanjson: array index must be a positive integer", 0)
        end
        local present = type(value) ~= "nil"
        if original.kind == "array" then
            local n = array_length(original, scope)
            if (present and key > n + 1) or (not present and key < n) then
                error("leanjson: sparse proxy arrays require explicit materialization", 0)
            end
        end
        local node = present and M.snapshot(value, cell.codec.classify, cell.codec.key, cell.codec.encode_max_depth and cell.codec.encode_max_depth() or 1000) or nil
        if node then dependencies(node) end
        return changed(original, key, node, scope), function()
            local cached = cell.children[key]
            if cached then cached.parent = nil; cell.children[key] = nil end
        end
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
        return nodes.length(cell.node, holder.scope)
    end)
end
Object.__len, Array.__len = M.len, M.len

local function iterate(value, array)
    local holder, cell = META[value], META[value].cell
    leases.check(holder.scope)
    local original, version = cell.node, cell.version
    local pin = leases.pin(holder.scope, original)
    local fallback = leases.fallback(holder.scope, pin)
    local next_member = M.iter(original, holder.scope, false, not array)
    return function()
        leases.check(META[value].scope)
        if array and cell.version ~= version then error("leanjson: invalid argument", 0) end
        if not fallback then return nil end
        local key, node, current = next_member()
        leases.check(holder.scope)
        if key ~= nil then
            local lexical, expected = false, original
            if not array and (node.kind == "object" or node.kind == "array") then
                expected = cell.node
                lexical = not current or not nodes.same(nodes.lookup_known(expected, key, original, node, holder.scope), node)
                leases.check(holder.scope)
            end
            return key, expose(node, cell, key, lexical, holder.scope, expected)
        end
        leases.finish(holder.scope, pin)
        fallback = nil
    end, nil, array and 0 or nil
end
function M.ipairs(value)
    local holder = META[value]
    if not holder then return ipairs(value) end
    leases.check(holder.scope)
    if holder.cell.node.kind ~= "array" then
        local cell, version = holder.cell, holder.cell.version
        return function()
            leases.check(META[value].scope)
            if cell.version ~= version then error("leanjson: invalid argument", 0) end
        end, nil, 0
    end
    return iterate(value, true)
end
function M.pairs(value)
    if not META[value] then return pairs(value) end
    return iterate(value, META[value].cell.node.kind == "array")
end
Object.__pairs, Array.__pairs, Array.__ipairs = M.pairs, M.pairs, M.ipairs

local function check_index(index, n, inserting)
    if type(index) ~= "number" or index ~= math.floor(index) or index < 1
        or index > n + (inserting and 1 or 0)
    then error("leanjson: array index out of range", 0) end
end

local function check_plain_array(value, index, inserting)
    if M.type(value) ~= "array" then error("leanjson: expected array", 0) end
    local n = #value
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > n then
            error("leanjson: array operations require a dense array", 0)
        end
        count = count + 1
    end
    if count ~= n then error("leanjson: array operations require a dense array", 0) end
    check_index(index, n, inserting)
end

function M.array_insert(value, index, child)
    local holder = META[value]
    if not holder then check_plain_array(value, index, true) end
    if type(child) == "nil" then error("leanjson: array_insert requires a value", 0) end
    if not holder then table.insert(value, index, child); return end
    local cell = holder.cell
    return mutate(holder, function(original, scope, dependencies)
        if original.kind ~= "array" then error("leanjson: expected array", 0) end
        local n = array_length(original, scope)
        check_index(index, n, true)
        local inserted = M.snapshot(child, cell.codec.classify, cell.codec.key, cell.codec.encode_max_depth and cell.codec.encode_max_depth() or 1000)
        dependencies(inserted)
        return nodes.array_edit(original, index, 0, inserted, scope), function()
            local moved = {}
            for key, cached in pairs(cell.children) do
                local target = key >= index and key + 1 or key
                cached.key, moved[target] = target, cached
            end
            cell.children = setmetatable(moved, { __mode = "v" })
        end
    end)
end

function M.array_remove(value, index)
    local holder = META[value]
    if not holder then check_plain_array(value, index, false); return table.remove(value, index) end
    local cell = holder.cell
    return mutate(holder, function(original, scope, dependencies)
        if original.kind ~= "array" then error("leanjson: expected array", 0) end
        local n = array_length(original, scope)
        check_index(index, n, false)
        local removed_node = M.lookup(original, index, scope)
        local removed, removed_cell
        local container = removed_node.kind == "array" or removed_node.kind == "object"
        local prepared
        if container then prepared = dependencies(removed_node)
        else removed = M.scalar(removed_node, scope) end
        return nodes.array_edit(original, index, 1, nil, scope), function()
            removed_cell = cell.children[index]
            if removed_cell then removed_cell.parent = nil end
            local moved = {}
            for key, cached in pairs(cell.children) do
                if key ~= index then
                    local target = key > index and key - 1 or key
                    cached.key, moved[target] = target, cached
                end
            end
            cell.children = setmetatable(moved, { __mode = "v" })
        end, function()
            if container then return wrap(removed_cell or new_cell(removed_node, nil, nil, nil, cell.codec), prepared) end
            return removed
        end
    end)
end

function M.stats(value)
    local node = M.node(value)
    while node and node.base do node = node.base end
    if not node or not node.backend or not node.backend.stats then error("leanjson: value has no source diagnostics", 0) end
    return node.backend:stats()
end
for key, value in pairs(Array) do MarkedArray[key] = value end
M.Object, M.Array, M.MarkedArray = Object, Array, MarkedArray
return M
