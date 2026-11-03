-- Lazy JSON views, explicit materialization and the compatible full encoder.
local ffi = require("ffi")
local proxy = require("leanjson.proxy")
local bounded_reader = require("leanjson.reader")
local leases = require("leanjson.leases")
local settings = require("leanjson.settings")
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

local materialize_node
materialize_node = function(node, keep_origin, scope, backends)
    if node.backend then backends[node.backend] = true end
    if node.kind ~= "array" and node.kind ~= "object" then return proxy.scalar(node, scope) end
    local out, records, keys = {}, {}, {}
    local complete = true
    keep_origin = keep_origin and node.backend ~= nil
    local n = 0
    for key, child in proxy.iter(node, scope, true) do
        n = n + 1
        if keep_origin then keys[n] = key end
        local value = materialize_node(child, keep_origin, scope, backends)
        out[key] = value
        if keep_origin then
            local backend, first, last = proxy.span(child)
            local record
            if backend and child.kind == "string" and last - first > 24
                and not string_needs_escape_policy(value) then
                record = { tag = "string", value = value, raw = read_all(backend, first, last, scope) }
            elseif backend and (child.kind == "object" or child.kind == "array") then
                local origin = TABLE_ORIGIN[value]
                if origin and origin.complete and last - first > 64 then
                    record = { tag = "table", origin = origin }
                end
            end
            records[key] = record
            if not record or string_needs_escape_policy(key) then complete = false end
        end
    end
    if node.kind == "array" then
        if proxy.array_marked(node) then setmetatable(out, _M.array_mt)
        elseif n == 0 then setmetatable(out, _M.empty_array_mt) end
    end
    TABLE_TYPE_HINT[out] = node.kind
    if keep_origin then
        local backend, first, last = proxy.span(node)
        TABLE_ORIGIN[out] = { kind = node.kind, complete = complete, backend = backend,
            bs = first, be = last, keys = keys, len = n, records = records,
            had_duplicates = node.kind == "object" and node.backend.lexical_length
                and node.backend:lexical_length(node.handle) ~= n or false }
    end
    return out
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
        return leases.guard(proxy.scope(value), node, function()
            local backends = {}
            local plain = materialize_node(node, keep == true, proxy.scope(value), backends)
            -- Explicit full values no longer need duplicate source indexes.
            for backend in pairs(backends) do if backend.clear_indexes then backend:clear_indexes() end end
            return plain
        end)
    end
    return value
end

local string_byte = string.byte
local string_format = string.format
local int64_ct = ffi.typeof("int64_t")
local uint64_ct = ffi.typeof("uint64_t")
-- Each codec owns its mutable settings and closures. Proxy/loading sentinels
-- and origin/type metadata remain shared so values cross codec boundaries.
local function new_codec()
    local codec = {}
    local classify_plain_table
    local ENCODE_EMPTY_AS_OBJECT = true
    local DECODE_ARRAY_WITH_MT = false
    local DECODE_INVALID_NUMBERS = true
    local DECODE_VALIDATE_UTF8 = false
    local ENCODE_INVALID_NUMBERS = false
    local ENCODE_ESCAPE_FORWARD_SLASH = true

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

    local function classify_table(value)
        local mt = raw_metatable(value)
        local hint = TABLE_TYPE_HINT[value]
        if rawequal(mt, _M.array_mt) then return "array", raw_length(value), true end
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
            error("leanjson.encode: cannot encode non-finite number")
        end
        return string_format(fmt or _ENCODE_NUMBER_FMT, n)
    end

    local function encode_key(key, fmt, invalid_mode)
        local kind = type(key)
        if kind == "string" then return key end
        if kind == "number" then return encode_number(key, fmt, invalid_mode) end
        error("leanjson.encode: object key must be a string or number, got " .. kind)
    end

    codec.key = function(key) return encode_key(key) end

    local function encode_cdata(v)
        if ffi.istype(int64_ct, v) or ffi.istype(uint64_ct, v) then
            local s = tostring(v):gsub("[UuLl]+$", "")
            return s
        end
        error("leanjson.encode: unsupported value type: cdata")
    end

    -- Forward declaration so encode_lazy_object_walking, encode_lazy_array_walking,
    -- and encode_array/encode_object can reference encode before its definition is
    -- complete (Lua resolves upvalues at call time, but the slot must be declared first).
    local encode

    local ENCODE_MAX_DEPTH = 1000
    local ENCODE_SPARSE_CONVERT = false
    local ENCODE_SPARSE_RATIO = 2
    local ENCODE_SPARSE_SAFE = 10
    local ENCODE_DEPTH_ERROR = "leanjson.encode: max depth exceeded"
    local ENCODE_CYCLE_ERROR = "leanjson.encode: circular reference"

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
            error("Cannot serialise table: excessively sparse array")
        end
        return "array", max
    end

    local function encode_array(t, depth, active, n, raw)
        if depth > ENCODE_MAX_DEPTH then
            error(ENCODE_DEPTH_ERROR)
        end
        local parts = {}
        n = n or #t
        for i = 1, n do
            local value
            if raw then value = rawget(t, i) else value = t[i] end
            parts[i] = encode(value, depth + 1, active)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local function encode_object(t, depth, active)
        if depth > ENCODE_MAX_DEPTH then
            error(ENCODE_DEPTH_ERROR)
        end
        local parts = {}
        for k, v in pairs(t) do
            parts[#parts+1] = encode_string(codec.key(k)) .. ":" .. encode(v, depth + 1, active)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    local origin_object_fully_matches
    local origin_array_fully_matches

    local function origin_record_matches(record, value, depth, active)
        if record == nil then
            return false
        end
        local tag = record.tag
        if tag == "string" then
            return type(value) == "string" and value == record.value
        elseif tag == "table" then
            if type(value) ~= "table" then
                return false
            end
            if active[value] then
                error(ENCODE_CYCLE_ERROR)
            end
            local origin = TABLE_ORIGIN[value]
            if origin == nil or origin ~= record.origin then
                return false
            end
            if classify_table(value) ~= origin.kind then
                return false
            end
            if depth > ENCODE_MAX_DEPTH then
                error(ENCODE_DEPTH_ERROR)
            end
            active[value] = true
            local ok
            if origin.kind == "object" then
                ok = origin_object_fully_matches(value, origin, depth, active)
            elseif origin.kind == "array" then
                ok = origin_array_fully_matches(value, origin, depth, active)
            else
                ok = false
            end
            active[value] = nil
            return ok
        end
        return false
    end

    local function origin_table_slice(origin)
        return read_all(origin.backend, origin.bs, origin.be)
    end

    origin_object_fully_matches = function(t, origin, depth, active)
        if origin.complete ~= true then
            return false
        end
        if origin.had_duplicates then
            return false
        end
        if depth > ENCODE_MAX_DEPTH then
            error(ENCODE_DEPTH_ERROR)
        end
        for k, v in pairs(t) do
            local record = origin.records[k]
            if not origin_record_matches(record, v, depth + 1, active) then
                return false
            end
        end
        for _, k in ipairs(origin.keys) do
            if rawget(t, k) == nil then
                return false
            end
        end
        return true
    end

    origin_array_fully_matches = function(t, origin, depth, active)
        if origin.complete ~= true then
            return false
        end
        if depth > ENCODE_MAX_DEPTH then
            error(ENCODE_DEPTH_ERROR)
        end
        local kind, length = classify_table(t)
        if kind ~= "array" or length ~= origin.len then
            return false
        end
        for i = 1, origin.len do
            if not origin_record_matches(origin.records[i], rawget(t, i), depth + 1, active) then
                return false
            end
        end
        for k, _ in pairs(t) do
            if type(k) ~= "number"
                or k ~= math.floor(k)
                or k < 1
                or k > origin.len
            then
                return false
            end
        end
        return true
    end

    local function encode_origin_child(value, depth, active, record)
        if record ~= nil then
            if record.tag == "string"
                and type(value) == "string"
                and value == record.value
            then
                return record.raw
            end
        end
        -- Small scalars and incomplete child tables are re-encoded.
        return encode(value, depth + 1, active)
    end

    local function encode_object_with_origin(t, depth, active, origin)
        if depth > ENCODE_MAX_DEPTH then
            error(ENCODE_DEPTH_ERROR)
        end
        if origin.complete == true and origin_object_fully_matches(t, origin, depth, active) then
            return origin_table_slice(origin)
        end

        local parts = {}
        local emitted = {}
        local records = origin.records

        for _, key in ipairs(origin.keys) do
            local value = rawget(t, key)
            if value ~= nil then
                emitted[key] = true
                parts[#parts + 1] = encode_string(key) .. ":" .. encode_origin_child(value, depth, active, records[key])
            end
        end

        for key, value in pairs(t) do
            if not emitted[key] then
                parts[#parts + 1] = encode_string(codec.key(key)) .. ":" .. encode(value, depth + 1, active)
            end
        end

        return "{" .. table.concat(parts, ",") .. "}"
    end

    local function encode_array_with_origin(t, depth, active, origin)
        if depth > ENCODE_MAX_DEPTH then
            error(ENCODE_DEPTH_ERROR)
        end
        if origin.complete == true and origin_array_fully_matches(t, origin, depth, active) then
            return origin_table_slice(origin)
        end
        local kind, max, raw = classify_table(t)
        if kind == "array" then
            return encode_array(t, depth, active, max, raw)
        end
        return encode_object(t, depth, active)
    end

    -- Dispatch for plain (non-lazy) tables. Separated from the main encode
    -- function to keep the lazy-proxy fast path narrow for LuaJIT traces.
    local function encode_plain_table(v, depth, active)
        local kind, max, raw = classify_table(v)
        local origin = TABLE_ORIGIN[v]
        if origin ~= nil and origin.kind == kind then
            if origin.kind == "object" then
                return encode_object_with_origin(v, depth, active, origin)
            end
            if origin.kind == "array" then
                return encode_array_with_origin(v, depth, active, origin)
            end
        end

        if kind == "array" then
            return encode_array(v, depth, active, max, raw)
        end
        return encode_object(v, depth, active)
    end

    encode = function(v, depth, active)
        if rawequal(v, _M.null) then
            return "null"
        end
        if rawequal(v, _M.empty_array) then return "[]" end
        local tv = type(v)
        if tv == "string" then
            return encode_string(v)
        elseif tv == "number" then
            return encode_number(v)
        elseif tv == "boolean" then
            return v and "true" or "false"
        elseif tv == "nil" then
            return "null"
        elseif tv == "cdata" then
            return encode_cdata(v)
        elseif tv == "table" then
            if active[v] then
                error(ENCODE_CYCLE_ERROR)
            end
            active[v] = true
            local encoded
            if proxy.is_proxy(v) then
                encoded = encode_proxy(v, depth, active)
            else
                encoded = encode_plain_table(v, depth, active)
            end
            active[v] = nil
            return encoded
        end
        error("leanjson.encode: unsupported value type: " .. tv)
    end

    function codec._new_reader(value, options, depth)
        local fmt = _ENCODE_NUMBER_FMT
        local invalid_mode = ENCODE_INVALID_NUMBERS
        local escape_slash = ENCODE_ESCAPE_FORWARD_SLASH
        return bounded_reader.new(value, options, {
            number = function(n) return encode_number(n, fmt, invalid_mode) end,
            key = function(key) return encode_key(key, fmt, invalid_mode) end,
            escape = function(byte) return escape_byte(byte, escape_slash) end,
            cdata = encode_cdata,
            classify = classify_table,
            depth = depth,
        })
    end

    function codec.reader(value, options) return codec._new_reader(value, options, 1) end

    codec.encode = function(v)
        return encode(v, 1, {})
    end


    codec.classify = classify_table
    codec.tostring = function(value) return encode_proxy(value, 1) end
    codec.decode = function(raw, opts) return decode(raw, opts, codec) end
    codec.decode_file = function(filename, opts) return require("leanjson.source").decode_file(filename, opts, codec) end
    codec.new_decoder = function(opts) return require("leanjson.source").new_decoder(opts, codec) end
    codec.fork = function(value) return proxy.fork(value, codec) end
    codec.type = function(value) return proxy.type(value, classify_table) end
    codec.get = function(value, path) return require("leanjson.path").get(value, path, codec) end
    return codec
end

local default = new_codec()
local public_methods = { "encode", "decode", "decode_file", "new_decoder", "reader",
    "encode_number_precision", "encode_sparse_array", "encode_empty_table_as_object",
    "decode_array_with_array_mt", "decode_invalid_numbers", "decode_validate_utf8",
    "encode_invalid_numbers", "encode_escape_forward_slash", "fork", "type", "get" }
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
