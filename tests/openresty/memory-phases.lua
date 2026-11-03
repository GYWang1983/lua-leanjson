-- One fresh native process per method/input/mode. Input construction and the
-- complete semantic oracle run elsewhere, never in this measured process.
local method, source, input, output = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
assert(method == "leanjson" or method == "cjson")
local json = method == "leanjson" and require("leanjson") or nil
local cjson = require "cjson"
local metrics = require "metrics"
if method == "cjson" then
    assert(not package.loaded.leanjson and not package.loaded["leanjson.lib"] and not package.loaded["leanjson.openresty"],
        "cjson benchmark requires a fresh process without LeanJSON")
end
local access = arg[5] or "model"
local options = { chunk_size = 65536, proxy_mode = arg[10] or "table" }
assert(options.proxy_mode == "table" or options.proxy_mode == "userdata")
if arg[6] then options.index_budget_bytes = assert(tonumber(arg[6])) end
local branches_count = tonumber(arg[7]) or 0
if arg[8] then options.index_depth = assert(tonumber(arg[8])) end
if arg[9] then options.index_array_limit = assert(tonumber(arg[9])) end
assert(source == "memory" or source == "file" or source == "feed")
local phases = {}
local body, raw
local function sample(name)
    local row = metrics.sample()
    row.stage = name
    if method == "leanjson" and body and json.source_stats then
        row.index = json.source_stats(body)
        assert(row.index.index_bytes <= row.index.budget_bytes, "index budget exceeded")
    end
    phases[#phases + 1] = row
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end
collectgarbage("collect")
sample("baseline")
local file = assert(io.open(input, "rb"))
local source_bytes = assert(file:seek("end"))
assert(file:seek("set", 0))
if method == "cjson" or source == "memory" then
    raw = assert(file:read("*a"))
    body = method == "cjson" and cjson.decode(raw) or json.decode(raw, options)
elseif source == "file" then body = json.decode_file(input, options)
else
    local decoder = json.new_decoder(options)
    while true do
        local chunk = file:read(options.chunk_size)
        if not chunk then break end
        assert(decoder:feed(chunk))
    end
    body = assert(decoder:finish())
    decoder:close()
end
assert(file:close())
local carrier_type = type(body)
if json then assert(carrier_type == options.proxy_mode, "requested proxy carrier was not used") end
sample("parsed")
assert(body.model == "original")
local visited = 0
if access == "scan" or access == "scan-auto" then
    for _, value in (method == "cjson" and pairs or json.pairs)(body) do
        local kind = json and json.type(value) or type(value)
        if kind == "table" or kind == "object" or kind == "array" then
            local id = value.id
            assert(type(id) == "number")
            if method == "leanjson" and access == "scan" then json.close(value) end
            visited = visited + 1
        end
    end
elseif access == "far" then
    local items = body.items
    local n = method == "cjson" and #items or json.len(items)
    for _, i in ipairs({n, 1, math.max(1, math.floor(n / 2)), n}) do
        local item = items[i]
        assert(item.id == i)
        if method == "leanjson" then json.close(item) end
        visited = visited + 1
    end
    if method == "leanjson" then json.close(items) end
else assert(access == "model") end
sample("read")
local branches = {}
if branches_count == 0 then
    body.model = "rewritten-1"
    branches[1] = body
else
    for i = 1, branches_count do
        local branch = method == "cjson" and copy(body) or json.fork(body)
        branch.model = "rewritten-" .. i
        branches[i] = branch
    end
end
sample("modified")
local sink = assert(io.open(output, "wb"))
local output_bytes, max_chunk
max_chunk = 0
local reader, encoded
if method == "leanjson" then
    reader = json.reader(branches[1], { chunk_size = options.chunk_size, normalize_duplicates = true })
    output_bytes = assert(reader:length())
else encoded = cjson.encode(branches[1]); output_bytes = #encoded end
sample("length")
if reader then
    local written = 0
    while true do
        local chunk, err = reader:next()
        assert(not err, err)
        if chunk == nil then break end
        assert(sink:write(chunk))
        written, max_chunk = written + #chunk, math.max(max_chunk, #chunk)
    end
    assert(written == output_bytes and max_chunk <= options.chunk_size)
else assert(sink:write(encoded)); max_chunk = #encoded end
assert(sink:close())
sample("output")
if method == "leanjson" then
    reader:close()
    for _, branch in ipairs(branches) do json.close(branch) end
    json.close(body)
end
-- Explicitly drop all caller-owned values before the close-phase sample.
body, branches, raw, reader, encoded = nil, nil, nil, nil, nil -- luacheck: ignore 311
sample("closed")
local peak, lua_peak = 0, 0
for _, row in ipairs(phases) do peak = math.max(peak, row.hwm_kib); lua_peak = math.max(lua_peak, row.lua_kib) end
print(cjson.encode({method=method,source=source,access=access,visited=visited,branches=branches_count,
    proxy_mode=options.proxy_mode,lua_type=carrier_type,
    source_bytes=source_bytes,output_bytes=output_bytes,max_chunk=max_chunk,
    index_budget_bytes=options.index_budget_bytes or 1048576,
    index_depth=options.index_depth or 3,index_array_limit=options.index_array_limit or 3,
    worker_hwm_kib=peak,lua_heap_sample_max_kib=lua_peak,phases=phases,
    elapsed_cpu_s=phases[#phases].cpu_s-phases[1].cpu_s,
    methodology="fresh process; no forced GC during measured phases; input generation and oracle external"}))
