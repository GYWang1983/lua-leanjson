-- Immutable sparse logical nodes. Raw lookups/iteration never publish a Lua
-- sibling index; durable edits use small object patches or array range pieces.
local M = {}
local DELETE = {}
function M.array_marked(node)
    while node do
        if node.marked_array ~= nil then return node.marked_array end
        if not node.base then
            return node.backend ~= nil and node.backend.opts.decode_array_with_array_mt == true
        end
        node = node.base
    end
    return false
end
function M.raw(backend, handle)
    local identity = backend.identity and backend:identity(handle) or handle
    if backend.preloaded and backend.preloaded[identity] then return backend.preloaded[identity] end
    return { backend = backend, handle = handle, kind = backend:type(handle),
        identity = identity }
end
function M.same(a, b)
    if a == b then return true end
    return a ~= nil and b ~= nil and a.backend ~= nil and a.backend == b.backend
        and a.identity == b.identity and a.kind == b.kind
end
function M.lookup(node, key, scope)
    if node.patches then
        local value = node.patches[key]
        if value ~= nil then if value ~= DELETE then return value end; return nil end
        return M.lookup(node.base, key, scope)
    end
    if node.segments then
        local position = 1
        for _, segment in ipairs(node.segments) do
            if key >= position and key < position + segment.count then
                if segment.value then return segment.value end
                return M.lookup(node.base, segment.first + key - position, scope)
            end
            position = position + segment.count
        end
        return nil
    end
    if node.values then return node.values[key] end
    if node.preload_values then
        local value = node.preload_values[key]
        if value ~= nil or node.preloaded then return value end
    end
    if node.backend.lookup then
        local handle = node.backend:lookup(node.handle, key, scope)
        if handle then return M.raw(node.backend, handle) end
        return nil
    end
    local found
    for name, handle in node.backend:children(node.handle, scope) do
        if name == key then found = M.raw(node.backend, handle) end
    end
    return found
end
-- Resolve edits against an iterator's known logical member. Flattened object
-- patches retain their original base, so unchanged keys need no source rescan.
function M.lookup_known(node, key, original, value, scope)
    if M.same(node, original) then return value end
    if node.patches then
        local patch = node.patches[key]
        if patch ~= nil then if patch ~= DELETE then return patch end; return nil end
        if M.same(node.base, original.patches and original.base or original) then return value end
    end
    return M.lookup(node, key, scope)
end
function M.iter(node, scope, normalize, linked)
    if node.patches then
        local base = M.iter(node.base, scope, true)
        local index, finished = 0, false
        return function()
            while not finished do
                local key, value = base()
                if key == nil then finished = true
                elseif not node.moved[key] then
                    local patch = node.patches[key]
                    if patch ~= DELETE then return key, patch or value, true end
                end
            end
            while true do
                index = index + 1
                local key = node.added[index]
                if key == nil then return nil end
                local value = node.patches[key]
                if value ~= DELETE then return key, value, true end
            end
        end
    end
    if node.segments then
        local base, source_index = node.base and M.iter(node.base, scope, false) or function() end, 0
        local piece, within, index = 1, 0, 0
        return function()
            while node.segments[piece] do
                local segment = node.segments[piece]
                if within == segment.count then piece, within = piece + 1, 0
                else
                    within, index = within + 1, index + 1
                    if segment.value then return index, segment.value end
                    local wanted, value = segment.first + within - 1
                    while source_index < wanted do
                        local key
                        key, value = base()
                        if key == nil then error("leanjson: invalid array source", 0) end
                        source_index = source_index + 1
                    end
                    return index, value
                end
            end
        end
    end
    if node.values then
        local index = 0
        return function()
            index = index + 1
            local key = node.keys[index]
            if key ~= nil then return key, node.values[key], true end
        end
    end
    if node.preloaded then
        local index = 0
        return function()
            index = index + 1
            if normalize then
                local key = node.preload_keys[index]
                if key ~= nil then return key, node.preload_values[key], true end
            else
                local entry = node.preload_entries[index]
                if entry then return entry[1], entry[2], node.preload_values[entry[1]] == entry[2] end
            end
        end
    end
    local next_child = node.backend:children(node.handle, scope, normalize, linked)
    return function()
        local key, handle, current = next_child()
        if key ~= nil then return key, M.raw(node.backend, handle), current end
    end
end
function M.length(node, scope)
    if node.length then return node.length end
    if node.preloaded then return #node.preload_keys end
    if node.backend and node.backend.length then return node.backend:length(node.handle, scope) end
    if node.values then return #node.keys end
    local n = 0
    for _ in M.iter(node, scope, true) do n = n + 1 end
    return n
end
function M.members(node, scope)
    if node.values then return node.keys, node.values end
    local keys, values, entries = {}, {}, {}
    for key, child in M.iter(node, scope, false) do
        if values[key] == nil then keys[#keys + 1] = key end
        values[key] = child
        entries[#entries + 1] = { key, child }
    end
    return keys, values, entries
end
local function copy(map)
    local out = {}
    for key, value in pairs(map) do out[key] = value end
    return out
end
local function append(out, segment)
    if segment.count == 0 then return end
    local last = out[#out]
    if last and last.first and segment.first and last.first + last.count == segment.first then
        last.count = last.count + segment.count
    else out[#out + 1] = segment end
end
function M.array_edit(node, index, remove, value, scope)
    local n = M.length(node, scope)
    local base = node.segments and node.base or node
    local original = node.segments or { { first = 1, count = n } }
    local out = {}
    local function slice(first, last)
        local position = 1
        for _, segment in ipairs(original) do
            local left, right = math.max(first, position), math.min(last, position + segment.count - 1)
            if left <= right then
                append(out, segment.value and { value = segment.value, count = 1 }
                    or { first = segment.first + left - position, count = right - left + 1 })
            end
            position = position + segment.count
        end
    end
    slice(1, index - 1)
    if value then append(out, { value = value, count = 1 }) end
    slice(index + remove, n)
    local uses_base = false
    for _, segment in ipairs(out) do if segment.first then uses_base = true; break end end
    return { kind = "array", base = uses_base and base or nil, segments = out,
        length = n - remove + (value and 1 or 0), marked_array = M.array_marked(node) }
end
function M.changed(node, key, value, scope)
    if node.kind == "array" then
        local n = M.length(node, scope)
        if key > n and value == nil then return node end
        return M.array_edit(node, key, key <= n and 1 or 0, value, scope)
    end
    local present = M.lookup(node, key, scope)
    local patches, added, moved, base
    local covered = node.covered or 0
    if node.patches then
        patches, added, moved, base = copy(node.patches), {}, copy(node.moved), node.base
        for _, name in ipairs(node.added) do if name ~= key or value ~= nil then added[#added + 1] = name end end
    else patches, added, moved, base = {}, {}, {}, node end
    if value ~= nil and present == nil then added[#added + 1] = key; moved[key] = true end
    if patches[key] == nil and (node.patches and M.lookup(base, key, scope) or present) ~= nil then covered = covered + 1 end
    patches[key] = value or DELETE
    local base_count = node.base_count or M.length(base, scope)
    local result = { kind = "object", base = base, patches = patches, added = added, moved = moved,
        covered = covered, base_count = base_count }
    if covered == base_count then
        local keys, values = {}, {}
        for name, child in M.iter(result, scope, true) do keys[#keys + 1], values[name] = name, child end
        return { kind = "object", keys = keys, values = values }
    end
    return result
end
function M.dependencies(node, visit)
    if node.base then visit(node.base) end
    if node.patches then
        for _, child in pairs(node.patches) do if child ~= DELETE then visit(child) end end
    elseif node.segments then
        for _, segment in ipairs(node.segments) do if segment.value then visit(segment.value) end end
    elseif node.values then
        for _, child in pairs(node.values) do visit(child) end
        if node.serialized_entries then
            for _, entry in ipairs(node.serialized_entries) do visit(entry[2]) end
        end
    end
end
return M
