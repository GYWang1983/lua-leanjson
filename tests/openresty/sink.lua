-- This process never assembles a request body. Optional disk captures are read by
-- the separate test client only after the measured transfer has completed.
local cjson = require "cjson"
local sha256 = require "resty.sha256"
local hex = require("resty.string").to_hex
local state = ngx.shared.sink_state
if ngx.var.uri == "/stats" then
    ngx.say(cjson.encode { requests = state:get("requests") or 0,
        bytes = state:get("bytes") or 0 })
    return
end
state:incr("requests", 1, 0)
if ngx.var.uri == "/disconnect" then
    return ngx.exit(444)
end
local input = assert(ngx.req.socket())
local length = assert(tonumber(ngx.var.content_length), "sink requires Content-Length")
local hash = assert(sha256:new())
local bytes, max_chunk = 0, 0
local output, capture
local id = ngx.req.get_headers()["x-capture-id"]
if id and id:match("^[a-zA-Z0-9_-]+$") then
    capture = os.getenv("QJSON_TEST_PREFIX") .. "/capture-" .. id .. ".json"
    output = assert(io.open(capture, "wb"))
end
local started = ngx.now()
local first_byte
while bytes < length do
    local chunk, err = input:receive(math.min(16384, length - bytes))
    if not chunk then
        if output then output:close() end
        ngx.status = 400
        ngx.say(cjson.encode { error = err, bytes = bytes })
        return
    end
    first_byte = first_byte or ngx.now()
    bytes = bytes + #chunk
    max_chunk = math.max(max_chunk, #chunk)
    hash:update(chunk)
    if output then assert(output:write(chunk)) end
end
if output then assert(output:close()) end
state:incr("bytes", bytes, 0)
ngx.header.content_type = "application/json"
ngx.say(cjson.encode { bytes = bytes, length = length, sha256 = hex(hash:final()),
    max_chunk = max_chunk, capture = capture, first_byte_at = first_byte,
    transfer_encoding = ngx.var.http_transfer_encoding,
    first_byte_ms = ((first_byte or started) - started) * 1000 })
