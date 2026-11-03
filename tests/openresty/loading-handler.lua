local json = require "leanjson"
local adapter = require "leanjson.openresty"
local cjson = require "cjson"
local eager = ngx.var.arg_eager == "1"
local calls, value, session, child, items = 0
local opts = { chunk_size = 4096, temp_dir = os.getenv("LEANJSON_TEST_PREFIX") .. "/decoder",
    decode = { lazyload = not eager, proxy_mode = ngx.var.arg_proxy_mode or "table",
        index_depth = 0, index_array_limit = 0, index_budget_bytes = 0,
        preload_paths = { "$.a.b.c.d.e", "$.items[5].x", "$.n", "$.big" } },
    on_chunk = function() calls = calls + 1; ngx.sleep(0) end }
if ngx.var.arg_invalid == "1" then opts.decode.preload_paths = { "$..invalid" } end
local ok, result = pcall(function()
    local err, info
    if ngx.var.uri == "/loading/incremental" then
        session, err, info = adapter.start_body(opts)
        assert(session, err)
        value, err = session:finish()
    else value, err, info = adapter.read_body(opts) end
    assert(not err, err)
    if ngx.var.arg_scalar == "1" then return { value = value, mode = info.mode, kind = json.type(value) } end
    local after_scan = calls
    child, items = value.a, value.items
    for _ = 1, 3 do
        assert(value.a.b.c.d.e == "selected")
        assert(value.items[6].x == false)
        assert(value.n == json.null)
    end
    local out = { mode = info.mode, fallback = info.fallback, before = after_scan, after = calls,
        lua_type = type(value), child_lua_type = type(child), array_lua_type = type(items),
        rawget_rejected = not pcall(rawget, value, "a"),
        ordinary = eager and rawget(value, "a") ~= nil or false,
        encoded = json.encode(value) }
    if not eager then
        out.stats = json.source_stats(value)
        assert(value.ignored:sub(1, 1) == "p")
    end
    if session then
        value.a.b.c.d.e = "edited"
        local repeated = assert(session:finish())
        local current, status = session:get("a.b.c.d.e")
        out.session_observes_edits = repeated.a.b.c.d.e == "edited" and current == "edited" and status == "READY"
    end
    return out
end)
json.close(child); json.close(items)
json.close(value)
if session then session:close() end
ngx.header.content_type = "application/json"
if not ok then ngx.status = 400; result = { error = tostring(result) } end
ngx.say(cjson.encode(result))
