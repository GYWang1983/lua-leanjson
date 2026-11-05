-- Lazy JSON views, explicit materialization and the compatible full encoder.
local ffi = require("ffi")
local proxy = require("leanjson.proxy")
local bounded_reader = require("leanjson.reader")
local leases = require("leanjson.leases")
local settings = require("leanjson.settings")
local bit = require("bit")
local raw_metatable = debug and debug.getmetatable or getmetatable
local raw_length = rawget(_G, "rawlen") or table.getn
local has_cjson, cjson = pcall(require, "cjson")
local _M = {}
_M.null = has_cjson and cjson.null or setmetatable({}, { __tostring = function() return "null" end })
_M.empty_array_mt = (has_cjson and cjson.empty_array_mt) or { __jsontype = "array" }
_M.array_mt = (has_cjson and cjson.array_mt) or { __jsontype = "array" }
_M.empty_array = (has_cjson and cjson.empty_array) or setmetatable({}, { __tostring = function() return "empty_array" end })
local TABLE_TYPE_HINT = setmetatable({}, { __mode = "k" })
local TABLE_ORIGIN = setmetatable({}, { __mode = "k" })
local LazyObject, LazyArray = proxy.Object, proxy.Array
local loading = require("leanjson.loading")
loading.configure({ null = _M.null, array_mt = _M.array_mt })

_M.pairs, _M.ipairs, _M.len = proxy.pairs, proxy.ipairs, proxy.len
_M.fork, _M.type, _M.close = proxy.fork, proxy.type, proxy.close
_M.source_stats = proxy.stats
_M.array_insert, _M.array_remove = proxy.array_insert, proxy.array_remove

local function decode(raw, opts, codec)
    local backend, root = require("leanjson.source_memory").open(raw, opts, codec)
    if not backend.opts.lazyload then
        local value = backend.loading:take()
        local source = ffi.gc(backend.state.source, nil)
        require("leanjson.lib").leanjson_source_v1_release(source)
        backend.state.source = nil
        return value
    end
    return proxy.from_backend(backend, root, codec)
end

-- Full reads exist only in explicitly materializing/complete-encode paths.
-- The bounded reader uses backend:read directly and never calls this helper.
local function read_all(backend, first, last, scope)
    local parts = {}
    while first < last do
        local wanted = math.min(65536, last - first)
        local chunk, err = backend:read(first, wanted, scope)
        if type(chunk) ~= "string" then error(err or "leanjson: source read failed", 0) end
        if #chunk == 0 then error("leanjson: unexpected source EOF", 0) end
        if #chunk > wanted then error("leanjson: source exceeded read bound", 0) end
        parts[#parts + 1] = chunk
        first = first + #chunk
    end
    return table.concat(parts)
end

local function string_needs_escape_policy(value)
    return type(value) == "string"
        and (value:find("/", 1, true) or value:find("\127", 1, true))
end

local function materialize_node(root, keep_origin, scope, backends)
    local stack, result = {}, nil
    local function begin(node, keep)
        if node.backend then backends[node.backend] = true end
        if node.kind ~= "array" and node.kind ~= "object" then return proxy.scalar(node, scope), true end
        keep = keep and node.backend ~= nil
        local flags = node.backend and node.backend.flags and node.backend:flags(node.handle) or 0
        stack[#stack + 1] = { node = node, keep = keep, out = {}, records = {}, keys = {}, complete = bit.band(flags, 16) == 0,
            count = 0, iterator = proxy.iter(node, scope, true) }
        return nil, false
    end
    local function attach(frame, key, child, value)
        frame.count = frame.count + 1
        frame.out[key] = value
        if not frame.keep then return end
        frame.keys[frame.count] = key
        local backend, first, last = proxy.span(child)
        local record
        if backend and child.kind == "string" and last - first > 24 and not string_needs_escape_policy(value) then
            record = { tag = "string", value = value, raw = read_all(backend, first, last, scope) }
        elseif backend and (child.kind == "object" or child.kind == "array") then
            local origin = TABLE_ORIGIN[value]
            if origin and origin.complete and last - first > 64 then record = { tag = "table", origin = origin } end
        end
        frame.records[key] = record
        if not record or string_needs_escape_policy(key) then frame.complete = false end
    end
    local scalar, done = begin(root, keep_origin)
    if done then return scalar end
    while #stack > 0 do
        local frame = stack[#stack]
        local key, child = frame.iterator()
        if key == nil then
            local node, out = frame.node, frame.out
            if node.kind == "array" then
                if proxy.array_marked(node) then setmetatable(out, _M.array_mt)
                elseif frame.count == 0 then setmetatable(out, _M.empty_array_mt) end
            end
            TABLE_TYPE_HINT[out] = node.kind
            if frame.keep then
                local backend, first, last = proxy.span(node)
                TABLE_ORIGIN[out] = { kind = node.kind, complete = frame.complete, backend = backend,
                    bs = first, be = last, keys = frame.keys, len = frame.count, records = frame.records,
                    had_duplicates = node.kind == "object" and node.backend.lexical_length
                        and node.backend:lexical_length(node.handle) ~= frame.count or false }
            end
            stack[#stack] = nil
            local parent = stack[#stack]
            if parent then attach(parent, frame.parent_key, node, out) else result = out end
        else
            local value, complete = begin(child, frame.keep)
            if complete then attach(frame, key, child, value)
            else stack[#stack].parent_key = key end
        end
    end
    return result
end

function _M.materialize(value, options)
    if options ~= nil and type(options) ~= "table" then error("leanjson.materialize: opts must be a table", 0) end
    local keep = options and options.keep_origin
    if keep ~= nil and type(keep) ~= "boolean" then error("leanjson.materialize: opts.keep_origin must be a boolean", 0) end
    local node = proxy.node(value)
    if node then
        if keep and leases.managed(node) then
            error("leanjson.materialize: keep_origin is unsupported for file and incremental sources", 0)
        end
        return (leases.guard(proxy.scope(value), node, function()
            local backends = {}
            local plain = materialize_node(node, keep == true, proxy.scope(value), backends)
            -- Explicit full values no longer need duplicate source indexes.
            for backend in pairs(backends) do if backend.clear_indexes then backend:clear_indexes() end end
            return plain
        end))
    end
    return value
end

local string_byte = string.byte
local string_format = string.format
local int64_ct = ffi.typeof("int64_t")
local uint64_ct = ffi.typeof("uint64_t")
local function unsupported(kind, value)
    return kind == "function" or kind == "thread" or kind == "userdata"
        or kind == "cdata" and not (ffi.istype(int64_ct, value) or ffi.istype(uint64_ct, value))
end
-- Each codec owns its mutable settings and closures. Proxy/loading sentinels
-- and origin/type metadata remain shared so values cross codec boundaries.
local function new_codec()
    local codec = {}
    local classify_plain_table
    local ENCODE_EMPTY_AS_OBJECT = true
    local DECODE_ARRAY_WITH_MT = false
    local DECODE_INVALID_NUMBERS = true
    local DECODE_VALIDATE_UTF8 = false
    local DECODE_ALLOW_COMMENT = false
    local DECODE_MAX_DEPTH = 1000
    local ENCODE_INVALID_NUMBERS = false
    local ENCODE_ESCAPE_FORWARD_SLASH = true
    local ENCODE_INDENT = ""
    local ENCODE_SKIP_UNSUPPORTED = false
    -- Migration-only setting: encoding does not retain a cross-call buffer.
    local ENCODE_KEEP_BUFFER = true

    function codec.encode_keep_buffer(...)
        settings.arity(select("#", ...), 1)
        local value = (...)
        if type(value) == "string" then
            local zero = value:find("\0", 1, true)
            if zero then value = value:sub(1, zero - 1) end
        end
        ENCODE_KEEP_BUFFER = settings.boolean(value, ENCODE_KEEP_BUFFER, 1)
        return ENCODE_KEEP_BUFFER
    end

    function codec.encode_indent(...)
        settings.arity(select("#", ...), 1)
        local value = (...)
        if value ~= nil then
            local kind = type(value)
            if kind == "number" then value = tostring(value)
            elseif kind ~= "string" then
                error("bad argument #1 to '?' (string expected, got " .. kind .. ")", 0)
            end
            local zero = value:find("\0", 1, true)
            ENCODE_INDENT = zero and value:sub(1, zero - 1) or value
        end
        return ENCODE_INDENT
    end

    function codec.encode_skip_unsupported_value_types(...)
        settings.arity(select("#", ...), 1)
        local value = (...)
        if type(value) == "string" then
            local zero = value:find("\0", 1, true)
            if zero then value = value:sub(1, zero - 1) end
        end
        ENCODE_SKIP_UNSUPPORTED = settings.boolean(value, ENCODE_SKIP_UNSUPPORTED, 1)
        return ENCODE_SKIP_UNSUPPORTED
    end

    function codec.decode_max_depth(...)
        settings.arity(select("#", ...), 1)
        DECODE_MAX_DEPTH = settings.integer((...), DECODE_MAX_DEPTH, 1, 2147483647, 1)
        return DECODE_MAX_DEPTH
    end

    function codec.decode_invalid_numbers(...)
        settings.arity(select("#", ...), 1)
        DECODE_INVALID_NUMBERS = settings.boolean((...), DECODE_INVALID_NUMBERS, 1)
        return DECODE_INVALID_NUMBERS
    end

    function codec.decode_validate_utf8(...)
        settings.arity(select("#", ...), 1)
        DECODE_VALIDATE_UTF8 = settings.boolean((...), DECODE_VALIDATE_UTF8, 1)
        return DECODE_VALIDATE_UTF8
    end

    function codec.decode_allow_comment(...)
        settings.arity(select("#", ...), 1)
        DECODE_ALLOW_COMMENT = settings.boolean((...), DECODE_ALLOW_COMMENT, 1)
        return DECODE_ALLOW_COMMENT
    end

    function codec.encode_invalid_numbers(...)
        settings.arity(select("#", ...), 1)
        local value = (...)
        if value == "null" then ENCODE_INVALID_NUMBERS = value
        else ENCODE_INVALID_NUMBERS = settings.boolean(value, ENCODE_INVALID_NUMBERS, 1) end
        return ENCODE_INVALID_NUMBERS
    end

    function codec.encode_escape_forward_slash(...)
        settings.arity(select("#", ...), 1)
        ENCODE_ESCAPE_FORWARD_SLASH = settings.boolean((...), ENCODE_ESCAPE_FORWARD_SLASH, 1)
        return ENCODE_ESCAPE_FORWARD_SLASH
    end

    function codec.encode_empty_table_as_object(...)
        settings.arity(select("#", ...), 1)
        ENCODE_EMPTY_AS_OBJECT = settings.boolean((...), ENCODE_EMPTY_AS_OBJECT, 1)
        return ENCODE_EMPTY_AS_OBJECT
    end

    function codec.decode_array_with_array_mt(...)
        settings.arity(select("#", ...), 1)
        DECODE_ARRAY_WITH_MT = settings.boolean((...), DECODE_ARRAY_WITH_MT, 1)
        return DECODE_ARRAY_WITH_MT
    end

    local function external_length_method(value, mt)
        mt = mt or raw_metatable(value)
        if mt and not rawequal(mt, _M.array_mt) then return rawget(mt, "__len") end
    end

    local function external_array_length(value, method)
        -- pcall itself invokes callable metadata and gives native diagnostics
        -- for non-callable values without adding a Lua source location.
        local ok, result = pcall(method, value)
        if not ok then error(result, 0) end
        local kind = type(result)
        local length = (kind == "number" or kind == "string") and tonumber(result) or 0
        length = length or 0
        if length ~= length or length == math.huge or length == -math.huge then
            error("Cannot serialise table: external array length must be finite and fit a signed 32-bit integer", 0)
        end
        length = length < 0 and math.ceil(length) or math.floor(length)
        if length < -2147483648 or length > 2147483647 then
            error("Cannot serialise table: external array length must be finite and fit a signed 32-bit integer", 0)
        end
        return math.max(0, length)
    end

    local function classify_table(value)
        local mt = raw_metatable(value)
        local hint = TABLE_TYPE_HINT[value]
        if rawequal(mt, _M.array_mt) then return "array", raw_length(value), true end
        local method = external_length_method(value, mt)
        if method ~= nil then return "array", external_array_length(value, method), false, true end
        if rawequal(mt, _M.empty_array_mt) and hint ~= "array" then
            -- Native empty_array_mt first checks ordinary sparse policy, then
            -- forces an array even when non-numeric/hash keys were present.
            local kind, length = classify_plain_table(value)
            if kind == "array" then return kind, length end
            return "array", raw_length(value), true
        end
        if hint == "object" then return "object" end
        if hint == "array" then
            -- Materialization preserves empty-array identity, but later ordinary
            -- table edits must still pass the same sparse policy as other tables.
            if next(value) == nil then return "array", 0 end
            return classify_plain_table(value)
        end
        return classify_plain_table(value)
    end

    local _ENCODE_NUMBER_PRECISION = 14
    local _ENCODE_NUMBER_FMT = "%.14g"

    function codec.encode_number_precision(...)
        settings.arity(select("#", ...), 1)
        _ENCODE_NUMBER_PRECISION = settings.integer((...), _ENCODE_NUMBER_PRECISION, 1, 16, 1)
        _ENCODE_NUMBER_FMT = "%." .. _ENCODE_NUMBER_PRECISION .. "g"
        return _ENCODE_NUMBER_PRECISION
    end

    -- Escape lookup table: byte value → escape sequence string (or nil if safe).
    local ESCAPES = {
        [0x22] = '\\"',
        [0x5C] = '\\\\',
        [0x0A] = '\\n',
        [0x0D] = '\\r',
        [0x09] = '\\t',
        [0x08] = '\\b',
        [0x0C] = '\\f',
        [0x7F] = '\\u007f',
    }
    for byte = 0, 0x1F do
        if not ESCAPES[byte] then ESCAPES[byte] = string_format('\\u%04x', byte) end
    end

    local function escape_byte(byte, escape_slash)
        if byte == 0x2F then return escape_slash and '\\/' or nil end
        return ESCAPES[byte]
    end

    -- JSON string escaper with bulk-copy fast path.
    -- Scans for bytes that need escaping; copies clean segments via s:sub.
    -- For strings with no escapes, returns '"' .. s .. '"' with zero table allocations.
    local function encode_string(s)
        local n = #s
        local last, i = 1, 1
        local out = nil   -- lazily create table only when escapes found
        while i <= n do
            local b = string_byte(s, i)
            local esc = escape_byte(b, ENCODE_ESCAPE_FORWARD_SLASH)
            if esc then
                if not out then out = {'"'} end
                if i > last then out[#out + 1] = s:sub(last, i - 1) end
                out[#out + 1] = esc
                last = i + 1
            end
            i = i + 1
        end
        if not out then return '"' .. s .. '"' end
        if last <= n then out[#out + 1] = s:sub(last, n) end
        out[#out + 1] = '"'
        return table.concat(out)
    end

    local function encode_number(n, fmt, invalid_mode)
        if n ~= n or n == math.huge or n == -math.huge then
            if invalid_mode == nil then invalid_mode = ENCODE_INVALID_NUMBERS end
            if invalid_mode == "null" then return "null" end
            if invalid_mode then
                if n ~= n then return "NaN" end
                return n < 0 and "-Infinity" or "Infinity"
            end
            error("Cannot serialise number: must not be NaN or Infinity", 0)
        end
        return string_format(fmt or _ENCODE_NUMBER_FMT, n)
    end

    local function encode_key(key, fmt, invalid_mode)
        local kind = type(key)
        if kind == "string" then return key end
        if kind == "number" then return encode_number(key, fmt, invalid_mode) end
        -- Standalone sentinels are private Lua tables, but their public native
        -- key diagnostic retains the lightuserdata type used by cjson.
        if rawequal(key, _M.null) or rawequal(key, _M.empty_array) then kind = "userdata" end
        error("Cannot serialise " .. kind .. ": table key must be a number or string", 0)
    end

    codec.key = function(key) return encode_key(key) end

    local function encode_cdata(v)
        if ffi.istype(int64_ct, v) or ffi.istype(uint64_ct, v) then
            local s = tostring(v):gsub("[UuLl]+$", "")
            return s
        end
        error("Cannot serialise cdata: type not supported", 0)
    end

    local ENCODE_MAX_DEPTH = 1000
    local ENCODE_SPARSE_CONVERT = false
    local ENCODE_SPARSE_RATIO = 2
    local ENCODE_SPARSE_SAFE = 10
    local function depth_error(depth) error("Cannot serialise, excessive nesting (" .. depth .. ")", 0) end
    function codec.encode_max_depth(...)
        settings.arity(select("#", ...), 1)
        ENCODE_MAX_DEPTH = settings.integer((...), ENCODE_MAX_DEPTH, 1, 2147483647, 1)
        return ENCODE_MAX_DEPTH
    end

    function codec.encode_sparse_array(convert, ratio, safe, ...)
        settings.arity(3 + select("#", ...), 3)
        local new_convert = settings.boolean(convert, ENCODE_SPARSE_CONVERT, 1)
        local new_ratio = settings.integer(ratio, ENCODE_SPARSE_RATIO, 0, 2147483647, 2)
        local new_safe = settings.integer(safe, ENCODE_SPARSE_SAFE, 0, 2147483647, 3)

        ENCODE_SPARSE_CONVERT = new_convert
        ENCODE_SPARSE_RATIO = new_ratio
        ENCODE_SPARSE_SAFE = new_safe

        return ENCODE_SPARSE_CONVERT, ENCODE_SPARSE_RATIO, ENCODE_SPARSE_SAFE
    end

    local function encode_proxy(value, depth)
        local reader = codec._new_reader(value, nil, depth)
        local parts = {}
        while true do
            local chunk, err = reader:next()
            if err then error(err, 0) end
            if chunk == nil then break end
            parts[#parts + 1] = chunk
        end
        return table.concat(parts)
    end

    classify_plain_table = function(t)
        local count = 0
        local max = 0
        local all_positive_integer_keys = true
        local saw_key = false
        for k in pairs(t) do
            saw_key = true
            count = count + 1
            if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                all_positive_integer_keys = false
            elseif k > max then
                max = k
            end
        end
        if not saw_key then return ENCODE_EMPTY_AS_OBJECT and "object" or "array", 0 end
        if not all_positive_integer_keys then
            return "object"
        end
        if ENCODE_SPARSE_RATIO > 0
            and max > ENCODE_SPARSE_SAFE
            and max > count * ENCODE_SPARSE_RATIO
        then
            if ENCODE_SPARSE_CONVERT then
                return "object"
            end
            error("Cannot serialise table: excessively sparse array", 0)
        end
        return "array", max
    end

    local function origin_fully_matches(value, origin, depth, ancestors)
        local stack, active = { { value = value, origin = origin, depth = depth } }, {}
        while #stack > 0 do
            local frame = stack[#stack]
            if frame.iterator then
                local key, child = frame.iterator(frame.value, frame.previous)
                frame.previous = key
                if key == nil then active[frame.value] = nil; stack[#stack] = nil
                else
                    local record = frame.origin.records[key]
                    if not record then return false end
                    if record.tag == "string" then
                        if type(child) ~= "string" or child ~= record.value then return false end
                    elseif record.tag == "table" then
                        if type(child) ~= "table" or TABLE_ORIGIN[child] ~= record.origin then return false end
                        stack[#stack + 1] = { value = child, origin = record.origin, depth = frame.depth + 1 }
                    else return false end
                end
            else
                local t, o = frame.value, frame.origin
                if active[t] or ancestors[t] and t ~= value then depth_error(ENCODE_MAX_DEPTH + 1) end
                if frame.depth > ENCODE_MAX_DEPTH then depth_error(frame.depth) end
                if not o.complete or o.had_duplicates then return false end
                -- Recognition alone invalidates provenance. Calling __len here
                -- would repeat callbacks when the ordinary traversal follows.
                if external_length_method(t) ~= nil then return false end
                local kind, length = classify_table(t)
                if kind ~= o.kind or kind == "array" and length ~= o.len then return false end
                for _, key in ipairs(o.keys) do if rawget(t, key) == nil then return false end end
                active[t] = true
                frame.iterator = next
            end
        end
        return true
    end

    -- Explicit traversal keeps the public upper depth range real on LuaJIT.
    -- Complete encoding already owns its output, but never recurses on Lua's
    -- call stack or constructs a second snapshot of an ordinary table.
    local function encode_iterative(value)
        local parts, active, stack = {}, {}, { { value = value, depth = 1 } }
        local function emit(text) parts[#parts + 1] = text end
        local function newline(depth)
            if ENCODE_INDENT ~= "" then emit("\n"); emit(string.rep(ENCODE_INDENT, depth)) end
        end
        local function skip(v)
            if not ENCODE_SKIP_UNSUPPORTED then return false end
            if proxy.is_proxy(v) then
                local node = proxy.node(v)
                return unsupported(node.kind, node.value)
            end
            return not rawequal(v, _M.null) and not rawequal(v, _M.empty_array)
                and unsupported(type(v), v)
        end
        while #stack > 0 do
            local frame = stack[#stack]
            if frame.iterator then
                local key, child = frame.iterator()
                if key == nil then
                    if frame.has_items then newline(frame.depth - 1) end
                    emit(frame.kind == "array" and "]" or "}")
                    active[frame.value] = nil; stack[#stack] = nil
                else
                    frame.has_items = true
                    -- Native validates object keys even when the value will be skipped.
                    local name = frame.kind == "object" and codec.key(key)
                    if not skip(child) then
                        if frame.count > 0 then emit(",") end
                        newline(frame.depth)
                        frame.count = frame.count + 1
                        if name then emit(encode_string(name)); emit(ENCODE_INDENT ~= "" and ": " or ":") end
                        local record = frame.origin and frame.origin.records[key]
                        if record and record.tag == "string" and type(child) == "string" and child == record.value then emit(record.raw)
                        else stack[#stack + 1] = { value = child, depth = frame.depth + 1 } end
                    end
                end
            else
                local v, depth = frame.value, frame.depth
                local tv = type(v)
                if rawequal(v, _M.null) or tv == "nil" then emit("null"); stack[#stack] = nil
                elseif rawequal(v, _M.empty_array) then emit("[]"); stack[#stack] = nil
                elseif tv == "string" then emit(encode_string(v)); stack[#stack] = nil
                elseif tv == "number" then emit(encode_number(v)); stack[#stack] = nil
                elseif tv == "boolean" then emit(v and "true" or "false"); stack[#stack] = nil
                elseif proxy.is_proxy(v) then emit(encode_proxy(v, depth)); stack[#stack] = nil
                elseif skip(v) then stack[#stack] = nil
                elseif tv == "cdata" then emit(encode_cdata(v)); stack[#stack] = nil
                elseif tv ~= "table" then error("Cannot serialise " .. tv .. ": type not supported", 0)
                else
                    if active[v] then depth_error(ENCODE_MAX_DEPTH + 1) end
                    if depth > ENCODE_MAX_DEPTH then depth_error(depth) end
                    local kind, length, raw, external = classify_table(v)
                    local origin = not external and TABLE_ORIGIN[v]
                    if origin and origin.kind ~= kind then origin = nil end
                    if ENCODE_INDENT == "" and origin and origin_fully_matches(v, origin, depth, active) then
                        emit(read_all(origin.backend, origin.bs, origin.be)); stack[#stack] = nil
                    else
                        active[v] = true
                        frame.kind, frame.count, frame.origin = kind, 0, origin
                        if kind == "array" then
                            local index = 0
                            frame.iterator = function()
                                index = index + 1
                                if index <= length then
                                    if raw then return index, rawget(v, index) end
                                    return index, v[index]
                                end
                            end
                        elseif origin then
                            local index, previous, emitted = 0, nil, {}
                            frame.iterator = function()
                                while index < #origin.keys do
                                    index = index + 1
                                    local key = origin.keys[index]
                                    local child = rawget(v, key)
                                    if child ~= nil then emitted[key] = true; return key, child end
                                end
                                while true do
                                    local key, child = next(v, previous); previous = key
                                    if key == nil or not emitted[key] then return key, child end
                                end
                            end
                        else
                            local previous
                            frame.iterator = function() local key, child = next(v, previous); previous = key; return key, child end
                        end
                        emit(kind == "array" and "[" or "{")
                    end
                end
            end
        end
        return table.concat(parts)
    end

    function codec._new_reader(value, options, depth)
        local fmt = _ENCODE_NUMBER_FMT
        local invalid_mode = ENCODE_INVALID_NUMBERS
        local escape_slash = ENCODE_ESCAPE_FORWARD_SLASH
        local skip_unsupported = ENCODE_SKIP_UNSUPPORTED
        return bounded_reader.new(value, options, {
            number = function(n) return encode_number(n, fmt, invalid_mode) end,
            key = function(key) return encode_key(key, fmt, invalid_mode) end,
            escape = function(byte) return escape_byte(byte, escape_slash) end,
            cdata = encode_cdata,
            classify = classify_table,
            indent = ENCODE_INDENT,
            skip = function(node) return skip_unsupported and unsupported(node.kind, node.value) end,
            depth = depth, max_depth = ENCODE_MAX_DEPTH,
        })
    end

    function codec.reader(value, options) return codec._new_reader(value, options, 1) end

    codec.encode = function(...)
        if select("#", ...) ~= 1 then error("bad argument #1 to '?' (expected 1 argument)", 0) end
        return encode_iterative((...))
    end


    codec.classify = classify_table
    codec.tostring = function(value) return encode_proxy(value, 1) end
    codec.decode = function(...)
        local count = select("#", ...)
        if count < 1 or count > 2 then error("bad argument #1 to '?' (expected 1 argument)", 0) end
        local raw, opts = ...
        if type(raw) == "number" then raw = tostring(raw) end
        if type(raw) ~= "string" then error("bad argument #1 to '?' (string expected, got " .. type(raw) .. ")", 0) end
        return decode(raw, opts, codec)
    end
    codec.decode_file = function(filename, opts) return require("leanjson.source").decode_file(filename, opts, codec) end
    codec.new_decoder = function(opts) return require("leanjson.source").new_decoder(opts, codec) end
    codec.fork = function(value) return proxy.fork(value, codec) end
    codec.type = function(value) return proxy.type(value, classify_table) end
    codec.get = function(value, path) return require("leanjson.path").get(value, path, codec) end
    codec.ref = function(...) return require("leanjson.query").ref(codec, ...) end
    codec.len = function(...) return require("leanjson.query").len(codec, ...) end
    codec.exists = function(...) return require("leanjson.query").exists(codec, ...) end
    codec.is_empty = function(...) return require("leanjson.query").is_empty(codec, ...) end
    return codec
end

local default = new_codec()
local public_methods = { "encode", "decode", "decode_file", "new_decoder", "reader",
    "encode_number_precision", "encode_sparse_array", "encode_empty_table_as_object",
    "encode_indent", "encode_skip_unsupported_value_types", "encode_keep_buffer",
    "decode_array_with_array_mt", "decode_invalid_numbers", "decode_validate_utf8", "decode_allow_comment",
    "encode_invalid_numbers", "encode_escape_forward_slash", "decode_max_depth", "encode_max_depth", "fork", "type", "get", "ref", "len", "exists", "is_empty" }
local function methods(codec)
    local out = {}
    for _, key in ipairs(public_methods) do out[key] = codec[key] end
    return out
end
for key, value in pairs(methods(default)) do _M[key] = value end
_M.new = function() return methods(new_codec()) end
_M._new_reader = default._new_reader
proxy.configure({ null = _M.null, empty_array = _M.empty_array, array_mt = _M.array_mt,
    empty_array_mt = _M.empty_array_mt, classify = default.classify, key = default.key,
    tostring = default.tostring })

-- Debug convenience: tostring(lazy_view) returns the original JSON bytes.
-- Not the canonical encoder — callers should still use leanjson.encode for output.
LazyObject.__tostring = function(t) return proxy.codec(t).tostring(t) end
LazyArray.__tostring  = function(t) return proxy.codec(t).tostring(t) end
proxy.MarkedArray.__tostring = LazyArray.__tostring

-- Test-only exports for metatable identity checks.
_M._LazyObject = LazyObject
_M._LazyArray  = LazyArray

return _M
