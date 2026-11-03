-- Thin execution adapter. Test expressions and helper bodies remain upstream Lua.
-- Native cjson is never a target decode/encode/configuration fallback.
local config = dofile(assert(arg[1]))
local unpack = unpack
local function pack(...) return { n = select("#", ...), ... } end
local array_mt = {}
local function array(t) return setmetatable(t or {}, array_mt) end
local function escape(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        return ("\\u%04x"):format(c:byte())
    end) .. '"'
end
local function encode_json(value)
    local kind = type(value)
    if kind == "string" then return escape(value) end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "nil" then return "null" end
    assert(kind == "table", "invalid report type " .. kind)
    local pieces = {}
    local mt = getmetatable(value)
    if mt == array_mt or mt and mt.__json_array then
        for i = 1, #value do pieces[i] = encode_json(value[i]) end
        return "[" .. table.concat(pieces, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    for i, key in ipairs(keys) do pieces[i] = escape(key) .. ":" .. encode_json(value[key]) end
    return "{" .. table.concat(pieces, ",") .. "}"
end

local report = assert(io.open(config.output, "wb"))
local function emit(record) report:write(encode_json(record), "\n"); report:flush() end
local ffi = require("ffi")
ffi.cdef[[unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);]]
local crypto = ffi.load("libcrypto.so.3")
local digest_buffer = ffi.new("unsigned char[32]")
local function hex(s) return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function sha256(s)
    crypto.SHA256(s, #s, digest_buffer)
    return hex(ffi.string(digest_buffer, 32))
end
local function blob(s)
    local hash = sha256(s)
    local filename = config.blobs .. "/" .. hash .. ".bin"
    local existing = io.open(filename, "rb")
    if existing then existing:close()
    else
        local output = assert(io.open(filename, "wb"))
        assert(output:write(s)); assert(output:close())
    end
    return hash, filename
end
local function string_value(s, always_blob)
    local out = { type = "string", bytes = #s, sha256 = sha256(s) }
    if #s <= 2048 then out.hex = hex(s)
    else out.first_64_bytes_hex, out.last_64_bytes_hex = hex(s:sub(1, 64)), hex(s:sub(-64)) end
    if #s > 2048 or always_blob then local _, filename = blob(s); out.artifact = filename end
    return out
end

package.path = config.root .. "/lua/?.lua;" .. config.native .. "/lua/?.lua;" .. config.native .. "/?.lua;" .. package.path
local lean, lean_safe, proxy, native, native_safe
if config.implementation == "target" then
    assert(package.loaded.cjson == nil, "native cjson was already loaded in target process")
    package.preload.cjson = function()
        package.loaded.cjson = nil -- Lua 5.1 otherwise retains its failed-load sentinel.
        error("native cjson denied during target bootstrap", 0)
    end
    package.preload["cjson.safe"] = function()
        package.loaded["cjson.safe"] = nil
        error("native cjson.safe denied during target bootstrap", 0)
    end
    lean = require("leanjson")
    lean_safe = require("leanjson.safe")
    proxy = require("leanjson.proxy")
    assert(package.loaded.cjson == nil, "target bootstrap loaded native cjson")
    assert(package.loaded["cjson.safe"] == nil, "target bootstrap loaded native cjson.safe")
else
    local function load_native(symbol)
        return assert(package.loadlib(config.native .. "/cjson.so", symbol))()
    end
    native, native_safe = load_native("luaopen_cjson"), load_native("luaopen_cjson_safe")
end

local current, resources, resource_set, temp_files, decode_observations
local failed_settings, failed_helpers, configuration = {}, {}, {}
local expected_one_of = setmetatable({}, { __mode = "k" })
local known_functions = {}
local null = lean and lean.null or native.null
local function track(value)
    if lean and proxy.is_proxy(value) and not resource_set[value] then
        resource_set[value] = true
        resources[#resources + 1] = value
    end
    return value
end
local function iteration(value)
    if lean and proxy.is_proxy(value) then return lean.pairs(value) end
    return pairs(value)
end
local function describe(value, seen, depth, input, shape_array_mt)
    local kind = type(value)
    if rawequal(value, null) then return { type = "json_null", lua_type = kind } end
    if kind == "nil" then return { type = "nil" } end
    if kind == "string" then return string_value(value) end
    if kind == "boolean" then return { type = "boolean", value = value } end
    if kind == "number" then
        local repr
        if value ~= value then repr = "NaN"
        elseif value == math.huge then repr = "+Infinity"
        elseif value == -math.huge then repr = "-Infinity"
        elseif value == 0 and 1 / value < 0 then repr = "-0"
        else repr = ("%.17g"):format(value) end
        return { type = "number", repr = repr }
    end
    local own_proxy = lean and proxy.is_proxy(value)
    if kind ~= "table" and not own_proxy then return { type = kind } end
    seen, depth = seen or {}, depth or 0
    if seen[value] then return { type = kind .. "_reference", lua_type = kind, ref = seen[value] } end
    if input and depth >= 48 then return { type = kind, input_depth_summary = true } end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    seen[value] = count + 1
    track(value)
    local out = { type = kind, lua_type = kind, entries = array(), storage = own_proxy and "proxy" or "plain" }
    if own_proxy then out.container = lean.type(value)
    elseif shape_array_mt then out.container = getmetatable(value) == shape_array_mt and "array" or "object"
    elseif expected_one_of[value] then out.container = "one_of"
    else out.container = "Lua table (empty shape ambiguous upstream)" end
    local keys = {}
    for key, child in iteration(value) do
        track(child)
        keys[#keys + 1] = { key = key, value = child }
    end
    table.sort(keys, function(a, b)
        if type(a.key) ~= type(b.key) then return type(a.key) < type(b.key) end
        if type(a.key) == "number" or type(a.key) == "string" then return a.key < b.key end
        return tostring(a.key) < tostring(b.key)
    end)
    for i, entry in ipairs(keys) do
        out.entries[i] = { key = describe(entry.key, seen, depth + 1, input, shape_array_mt),
                           value = describe(entry.value, seen, depth + 1, input, shape_array_mt) }
    end
    return out
end
local function describe_pack(values, start, shape_array_mt)
    start = start or 1
    local out = { arity = values.n - start + 1, values = array() }
    for i = start, values.n do out.values[#out.values + 1] = describe(values[i], nil, nil, nil, shape_array_mt) end
    return out
end

local function append_unique(list, value)
    for _, existing in ipairs(list) do if existing == value then return end end
    list[#list + 1] = value
end
local function api_called(name)
    if current then current.called_apis[#current.called_apis + 1] = name end
end
local function unavailable(name, operation)
    if current then
        current.unsupported[#current.unsupported + 1] = { symbol = name, operation = operation or "call" }
    end
end
local function dependencies(domain, setting)
    if not current then return end
    for name, id in pairs(failed_settings) do
        if (setting and name == setting or not setting and name:match("^" .. domain .. "_")) or name == "new" then
            append_unique(current.dependencies, id .. " (" .. name .. ")")
        end
    end
    for _, id in ipairs(failed_helpers) do append_unique(current.dependencies, id) end
end

local function options(raw)
    local out = { chunk_size = config.feed_one_byte and 1 or 16384, proxy_mode = config.proxy_mode or "table" }
    if config.mode == "eager" then out.lazyload = false end
    if config.mode == "preload" or config.mode == "selective" then
        out.index_depth, out.index_array_limit, out.index_budget_bytes = 0, 0, 0
        out.preload_paths = { "$" }
        if config.mode == "selective" then
            out.preload_paths = assert(current.selected_paths, "selective paths missing")
        end
    end
    return out
end
local function decode(raw, reference_function, upstream_api, codec, safe)
    api_called(upstream_api or "leanjson.decode")
    dependencies("decode")
    local event = { requested_source = config.source, upstream_api = upstream_api or "selective replay of decode input",
                    input = string_value(raw, true), configuration = {}, options = {},
                    safe = not not safe, decode_settings = {},
                    codec_scope = codec and codec ~= lean and codec ~= lean_safe and codec ~= native and codec ~= native_safe and "instance" or "module" }
    for key, value in pairs(configuration) do event.configuration[key] = value end
    -- Capture the actual codec, including settings changed inside an upstream
    -- test function or on a new/safe instance. Declared APIs are not a snapshot.
    for _, key in ipairs({ "decode_invalid_numbers", "decode_max_depth", "decode_allow_comment", "decode_array_with_array_mt" }) do
        event.decode_settings[key] = (codec or lean or native)[key]()
    end
    local result
    if config.implementation == "reference" then
        event.actual_path = safe and "source-built cjson.safe.decode" or "source-built cjson.decode"
        result = pack(pcall(reference_function, raw))
    else
        codec = codec or lean
        local api_prefix = safe and "leanjson.safe." or "leanjson."
        local opts = options(raw)
        for key, value in pairs(opts) do event.options[key] = type(value) == "table" and array({ unpack(value) }) or value end
        if config.source == "memory" then
            event.actual_path = api_prefix .. "decode"
            result = pack(pcall(codec.decode, raw, opts))
        elseif config.source == "file" then
            event.actual_path = api_prefix .. "decode_file"
            local filename = os.tmpname()
            local output = assert(io.open(filename, "wb"))
            assert(output:write(raw)); assert(output:close())
            temp_files[#temp_files + 1] = filename
            result = pack(pcall(codec.decode_file, filename, opts))
        elseif config.source == "feed" then
            event.actual_path = api_prefix .. "new_decoder:feed:finish"
            event.feed_chunks, event.max_chunk_bytes = 0, 0
            result = pack(pcall(function()
                local function failed(err)
                    if safe then return nil, err end
                    error(err, 0)
                end
                local decoder, construction_error = codec.new_decoder(opts)
                if not decoder then return failed(construction_error) end
                local decoded_result = pack(pcall(function()
                    local widths, position, index = { 1, 2, 3, 5, 8, 13, 64, 256, 1024, 4096, 16384 }, 1, 1
                    while position <= #raw do
                        local width = config.feed_one_byte and 1 or widths[index]
                        local chunk = raw:sub(position, position + width - 1)
                        event.feed_chunks = event.feed_chunks + 1
                        event.max_chunk_bytes = math.max(event.max_chunk_bytes, #chunk)
                        local fed, err = decoder:feed(chunk)
                        if not fed then return failed(err) end
                        position = position + #chunk
                        index = index % #widths + 1
                    end
                    local decoded, err = decoder:finish()
                    if err ~= nil then return failed(err) end
                    return decoded
                end))
                decoder:close()
                event.decoder_closed = true
                if not decoded_result[1] then error(decoded_result[2], 0) end
                return unpack(decoded_result, 2, decoded_result.n)
            end))
        else error("unknown decode source") end
        if result[1] then
            track(result[2])
            if config.fault_return then result[2] = 2 end
            if proxy.is_proxy(result[2]) then
                -- Statistics do not traverse or materialize any user value.
                event.initial_source_stats = lean.source_stats(result[2])
            end
        end
    end
    event.success = result[1]
    if config.implementation == "reference" then
        event.reference_result = describe_pack(result, 2)
        decode_observations[#decode_observations + 1] = function()
            -- A separate native codec preserves JSON container kinds for the
            -- allowance guard; never alter the actual upstream test's codec.
            local shape_codec = native.new()
            for key, value in pairs(event.decode_settings) do shape_codec[key](value) end
            shape_codec.decode_array_with_array_mt(true)
            local shaped = pack(pcall(shape_codec.decode, raw))
            event.reference_shape_result = describe_pack(shaped, 2, shape_codec.array_mt)
        end
    end
    if lean and current.suite == "decode-cycle" then
        -- Observe after the unmodified upstream comparator has run, so a
        -- userdata-type mismatch cannot conceal a separate content regression.
        decode_observations[#decode_observations + 1] = function()
            event.decoded_result = describe_pack(result, 2)
        end
    end
    current.dispatch[#current.dispatch + 1] = event
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end

local function missing_function(name)
    return function()
        api_called(name); unavailable(name)
        error("UPSTREAM_CJSON_UNSUPPORTED: " .. name, 0)
    end
end
local config_names = {
    decode_max_depth = true, encode_max_depth = true, decode_invalid_numbers = true,
    encode_invalid_numbers = true, encode_sparse_array = true, decode_allow_comment = true,
    encode_indent = true, encode_keep_buffer = true, encode_number_precision = true,
    encode_empty_table_as_object = true, decode_array_with_array_mt = true,
    encode_escape_forward_slash = true, encode_skip_unsupported_value_types = true,
}
local function facade(module, prefix, safe)
    local result = {}
    local cache = {}
    return setmetatable(result, { __index = function(_, key)
        if cache[key] ~= nil then return cache[key] end
        local name = prefix .. "." .. key
        local value = module and module[key]
        if safe and config.implementation == "target" and config.fault_missing_safe then
            unavailable("cjson.safe", "module use")
            if key == "encode" or key == "decode" or key == "new" or config_names[key] then value = missing_function(name)
            else unavailable(name, "read"); value = nil end
        elseif key == "decode" then
            value = function(...)
                local raw = ...
                -- Arity and non-string inputs exercise the real API directly:
                -- they cannot be represented as a file/feed JSON byte source.
                if select("#", ...) ~= 1 or type(raw) ~= "string" then
                    api_called(name)
                    return module.decode(...)
                end
                return decode(raw, module and module.decode, name, module, safe)
            end
        elseif key == "new" and type(value) == "function" then
            value = function(...)
                api_called(name)
                return facade(module.new(...), prefix, safe)
            end
        elseif type(value) == "function" then
            known_functions[value] = name
        elseif value == nil then
            if config_names[key] or key == "new" then value = missing_function(name)
            else unavailable(name, "read") end
        end
        if value ~= nil then cache[key] = value end
        return value
    end })
end
local json = facade(lean or native, "cjson")
local json_safe = facade(lean_safe or native_safe, "cjson.safe", true)
package.loaded.cjson, package.loaded["cjson.safe"] = nil, nil
package.preload.cjson = function() return json end
package.preload["cjson.safe"] = function()
    if lean and config.fault_missing_safe then unavailable("cjson.safe", "module require") end
    return json_safe
end

local util = require("cjson.util")
local original_compare, original_one_of = util.compare_values, util.one_of
util.one_of = function(value)
    expected_one_of[value] = true
    return original_one_of(value)
end
local function logical_equal(a, b)
    if expected_one_of[b] then
        for _, option in ipairs(b) do if logical_equal(a, option) then return true end end
        return false
    end
    if rawequal(a, null) or rawequal(b, null) then return rawequal(a, b) end
    local a_container = type(a) == "table" or lean and proxy.is_proxy(a)
    local b_container = type(b) == "table" or lean and proxy.is_proxy(b)
    if a_container ~= b_container then return false end
    if not a_container and type(a) ~= type(b) then return false end
    if type(a) == "number" and a ~= a and b ~= b then return true end
    if not a_container then return a == b end
    track(a); track(b)
    local checked = {}
    for key, value in iteration(a) do
        track(value)
        checked[key] = true
        if not logical_equal(value, b[key]) then return false end
    end
    for key, value in iteration(b) do
        track(value)
        if not checked[key] then return false end
    end
    return true
end

local raw_print = print
local printed = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    printed[#printed + 1] = table.concat(parts, "\t") .. "\n"
end
local real_setlocale = os.setlocale
local locale_unavailable = false
os.setlocale = function(locale, ...)
    local value = real_setlocale(locale, ...)
    if current then
        current.locale_calls = current.locale_calls or array()
        current.locale_calls[#current.locale_calls + 1] = { requested = locale, returned = value or false }
        if locale == "cs_CZ" then
            locale_unavailable = value == nil
            if locale_unavailable then current.environment_inapplicable = "cs_CZ locale unavailable; upstream ignores os.setlocale return" end
        elseif locale == "C" then locale_unavailable = false end
    end
    return value
end

local row_index, passes, total = 0, 0, 0
local function begin_case(meta, name)
    resources, resource_set, temp_files, decode_observations = {}, {}, {}, {}
    current = { record_type = "case", id = meta.id, suite = meta.suite, line = meta.line,
                source_location = meta.source, name = name or meta.name, category = meta.category,
                cell = config.cell, implementation = config.implementation, mode = config.mode, requested_source = config.source,
                proxy_mode = config.proxy_mode or "table",
                declared_apis = array(meta.declared_apis or {}), called_apis = array(), dispatch = array(),
                required_modules = array(meta.required_modules or {}),
                unsupported = array(), dependencies = array(), helper = meta.category == "helper" }
    if locale_unavailable and (current.name:find("under comma locale", 1, true)) then
        current.environment_inapplicable = "cs_CZ locale setup unavailable"
    end
    debug.sethook(function()
        local info = debug.getinfo(2, "f")
        local name = info and known_functions[info.func]
        if name then
            api_called(name)
            if name:match("%.encode$") then dependencies("encode") end
            local setting = name:match("^cjson%.([_%w]+)$")
            if setting and config_names[setting] then dependencies(setting:match("^([^_]+)_"), setting) end
        end
    end, "c")
end
local function finish_case()
    debug.sethook()
    for _, observe in ipairs(decode_observations) do observe() end
    local closed, errors = 0, array()
    if lean then
        for i = #resources, 1, -1 do
            local ok, err = pcall(lean.close, resources[i])
            if ok then closed = closed + 1 else errors[#errors + 1] = tostring(err) end
        end
    end
    for _, filename in ipairs(temp_files) do
        if not os.remove(filename) then errors[#errors + 1] = "cannot remove " .. filename end
    end
    current.cleanup = { proxies_closed = closed, files_removed = #temp_files, errors = errors }
    if #errors > 0 then error("case cleanup failure: " .. table.concat(errors, "; ")) end
    emit(current)
    current = nil
    resources, resource_set, temp_files, decode_observations = nil, nil, nil, nil
    collectgarbage("collect")
end
local function run_case(meta, name, func, input, expected_success, expected_output)
    begin_case(meta, name)
    for _, api in ipairs(meta.declared_apis or {}) do
        local key = api:match("^cjson%.([_%w]+)$")
        if key and not (lean or native)[key] and not config_names[key] and key ~= "new" then unavailable(api, "read during definition") end
    end
    input = input or {}
    current.input = describe(input, nil, nil, true)
    -- Input diagnostics above do not touch any decode result. Exact upstream
    -- comparison is performed BEFORE the logical observation traverses proxies.
    local result = pack(pcall(func, unpack(input)))
    current.success = result[1]
    local upstream_result = {}
    for i = 2, result.n do upstream_result[i - 1] = result[i] end
    if current.helper then
        current.setup_outcome = result[1] and "success" or "failure"
        if not result[1] and not current.environment_inapplicable then failed_helpers[#failed_helpers + 1] = meta.id end
    else
        local compared = pack(pcall(original_compare, upstream_result, expected_output))
        current.upstream_exact_pass = result[1] == expected_success and compared[1] and compared[2] == true
        if not compared[1] then current.upstream_comparison_error = string_value(tostring(compared[2])) end
        local logical = pack(pcall(logical_equal, upstream_result, expected_output))
        current.logical_pass = result[1] == expected_success and logical[1] and logical[2] == true
        if not logical[1] then current.logical_comparison_error = string_value(tostring(logical[2])) end
        current.expected_success = expected_success
        current.expected = describe(expected_output)
        total = total + 1
        if current.upstream_exact_pass then passes = passes + 1 end
    end
    current.result = describe_pack(result, 2)
    for _, api in ipairs(meta.declared_apis or {}) do
        local key = api:match("^cjson%.([_%w]+)$")
        if key and (config_names[key] or key == "new") then
            if (expected_success == true or current.helper) and not result[1] then failed_settings[key] = meta.id
            elseif result[1] then
                failed_settings[key] = nil
                if key == "new" then failed_settings, failed_helpers, configuration = {}, {}, {} end
                configuration[key] = describe(input, nil, nil, true)
            end
        end
    end
    finish_case()
    return true, upstream_result
end

util.run_test_group = function(rows)
    emit({ record_type = "setup", id = "test.lua:load_testdata", outcome = "completed before run_test_group",
           fixture_generation = "upstream gen_raw_octets and gen_utf16_escaped unmodified" })
    for _, row in ipairs(rows) do
        row_index = row_index + 1
        local meta = assert(config.cases[row_index], "unexpected upstream row")
        if meta.suite == "test.lua" then assert(meta.name == row[1], "inventory label mismatch at " .. meta.id) end
        run_case(meta, unpack(row))
    end
end
util.run_test = function(name, func, input, expected_success, output)
    row_index = row_index + 1
    return run_case(assert(config.cases[row_index], "unexpected decode cycle"), name, func, input, expected_success, output)
end
util.run_test_summary = function() return passes, total end

local maps = assert(io.open("/proc/self/maps", "rb"))
local mapped = maps:read("*a"); maps:close()
local libraries = array()
for line in mapped:gmatch("[^\n]+") do
    if line:find("cjson", 1, true) or line:find("leanjson", 1, true) then libraries[#libraries + 1] = line end
end
if lean then assert(not mapped:match("/[^\n]*cjson%.so"), "native cjson mapped into target process") end
emit({ record_type = "runtime", implementation = config.implementation, cell = config.cell,
       proxy_mode = config.proxy_mode or "table",
       lua_version = _VERSION, jit_version = jit.version, mapped_libraries = libraries,
       native_module_version = native and native._VERSION or nil, native_module_name = native and native._NAME or nil,
       native_library_requested = native and config.native .. "/cjson.so" or nil,
       target_dependency_mode = lean and "standalone sentinels; cjson denied during bootstrap" or nil,
       unsupported_modules = lean and array({ "cjson.safe" }) or array(),
       target_native_cjson_loaded = config.implementation == "reference",
       target_decode_source = lean and debug.getinfo(lean.decode, "S").source or nil,
       target_encode_source = lean and debug.getinfo(lean.encode, "S").source or nil,
       helper_module_source = debug.getinfo(util.file_load, "S").source })

local function execute()
    if config.kind == "test" then
        local env = setmetatable({ arg = {}, os = setmetatable({ exit = function(status)
            emit({ record_type = "upstream_summary", requested_exit = status, passes = passes, total = total })
        end }, { __index = os }) }, { __index = _G })
        for _, case in ipairs(config.cases) do if case.fixture then env.arg[#env.arg + 1] = case.fixture end end
        local chunk = assert(loadfile(config.native .. "/tests/test-driver.lua"))
        setfenv(chunk, env)
        chunk()
    elseif config.kind == "control" then
        local chunk = assert(loadstring(config.code, "@negative-control"))
        setfenv(chunk, setmetatable({ json = json, util = util, CONTROL_TARGET = lean ~= nil }, { __index = _G }))
        chunk()
    elseif config.kind == "agent" then
        local meta = config.cases[1]
        begin_case(meta)
        local chunk = assert(loadstring(config.code, "@vendor/lua-cjson/tests/agentzh.t:L" .. meta.line))
        local result = pack(pcall(chunk))
        local stdout = table.concat(printed)
        current.success = result[1]
        current.stdout, current.expected_stdout = string_value(stdout), string_value(config.expected_stdout)
        current.expected_exit_code, current.observed_exit_code = 0, result[1] and 0 or 1
        current.upstream_exact_pass = result[1] and stdout == config.expected_stdout
        current.logical_pass = current.upstream_exact_pass
        current.result = describe_pack(result, 2)
        if config.block_number == 24 then
            local minor = tonumber(_VERSION:match("Lua 5%.([0-9]+)"))
            current.conditional_branch = minor >= 3 and "Lua 5.3+ integer assertions" or "canned output; no cjson use"
            if minor < 3 then current.environment_inapplicable = "upstream canned output branch on LuaJIT; no Lua 5.3 integer behavior tested" end
        elseif config.block_number == 15 then
            current.conditional_branch = jit.version:find("LuaJIT 2.1.0", 1, true) and "table.new" or "ordinary table"
        end
        finish_case()
    elseif config.kind == "replay" then
        for _, meta in ipairs(config.cases) do
            begin_case(meta)
            current.selected_paths = array(meta.selected_paths)
            current.selection_reason = meta.selection_reason
            local file = assert(io.open(meta.input_blob, "rb"))
            local raw = file:read("*a"); file:close()
            local codec = (meta.reference_safe and lean_safe or lean).new()
            for key, value in pairs(assert(meta.reference_decode_settings, "reference decode settings missing")) do
                codec[key](value)
            end
            local result = pack(pcall(decode, raw, nil, meta.reference_api, codec, meta.reference_safe))
            current.success = result[1]
            if result[1] then
                if meta.unselected_key ~= nil then
                    current.unselected_key = describe(meta.unselected_key)
                    local accessed = pack(pcall(function() return track(result[2][meta.unselected_key]) end))
                    current.unselected_access_success = accessed[1]
                    if accessed[1] then current.unselected_value = describe(accessed[2])
                    else current.unselected_access_error = describe(accessed[2]) end
                end
                local complete = pack(pcall(function()
                    local encoded = codec.encode(result[2])
                    current.encoded_output = string_value(encoded)
                    current.encoded_validation_path = "replay codec.decode(encoded_output, {lazyload=false}) after replay operations"
                    local decoded = codec.decode(encoded, { lazyload = false })
                    return logical_equal(decoded, result[2])
                end))
                current.encoded_roundtrip_complete = complete[1] and complete[2] == true
                if not complete[1] then current.encoded_roundtrip_error = describe(complete[2]) end
            end
            current.result = describe_pack(result, 2)
            current.logical_pass = false -- controller compares typed observation to the reference decode call
            current.origin_id = meta.origin_id
            current.reference_configuration = meta.reference_configuration
            finish_case()
        end
    else error("unrecognized worker kind") end
end
local ok, err = xpcall(execute, debug.traceback)
if not ok then
    debug.sethook()
    emit({ record_type = "harness_failure", message = tostring(err) })
    report:close()
    io.stderr:write(tostring(err), "\n")
    os.exit(2)
end
emit({ record_type = "worker_complete", rows = row_index, kind = config.kind })
report:close()
raw_print("worker completed: " .. config.implementation .. " " .. config.mode .. " " .. config.source .. " " .. config.kind)
