local hash = assert(require("resty.sha256"):new())
local input = assert(ngx.req.socket())
local length = assert(tonumber(ngx.var.content_length))
local received = 0
while received < length do
    local chunk, err = input:receive(math.min(65536, length - received))
    if not chunk then ngx.status = 400; ngx.say(err); return end
    hash:update(chunk)
    received = received + #chunk
end
ngx.header.content_type = "application/json"
ngx.say(require("cjson").encode { bytes = received,
    sha256 = require("resty.string").to_hex(hash:final()) })
