local leanjson = require "leanjson"
local adapter = require "leanjson.openresty"
local opts = { temp_dir = os.getenv("LEANJSON_TEST_PREFIX") .. "/decoder", decode = {} }
local invalid = { nan = 0 / 0, infinity = math.huge, string = "invalid", boolean = true, table = {} }
if ngx.var.arg_depth then opts.decode.max_depth = tonumber(ngx.var.arg_depth) or invalid[ngx.var.arg_depth] end
if ngx.var.arg_lazy then opts.decode.lazy = ngx.var.arg_lazy == "true" and true or "invalid" end
if ngx.var.arg_options == "false" then opts = false
elseif ngx.var.arg_options == "decode-false" then opts.decode = false
elseif ngx.var.arg_options == "chunk-false" then opts.chunk_size = false
elseif ngx.var.arg_options == "hook-false" then opts.on_chunk = false
elseif ngx.var.arg_options == "temp-false" then opts.temp_dir = false end
if ngx.var.arg_file_in_memory == "false" then opts.file_in_memory = false end
if ngx.var.uri == "/loading/completed" or ngx.var.uri == "/policy/completed" then ngx.req.read_body() end
local value, session, info
local ran, err = pcall(function()
    local failure
    if ngx.var.uri == "/policy/incremental" then
        session, failure, info = adapter.start_body(opts)
        assert(session, failure)
        value, failure = session:finish()
    else value, failure, info = adapter.read_body(opts) end
    assert(not failure, failure)
end)
leanjson.close(value)
if session then session:close() end
ngx.header.content_type = "application/json"
ngx.say(require("cjson").encode { accepted = ran, error = not ran and tostring(err) or nil,
    mode = info and info.mode, fallback = info and info.fallback })
