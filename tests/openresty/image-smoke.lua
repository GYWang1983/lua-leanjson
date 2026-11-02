-- Runs inside the runtime image, loading only its installed Lua/native files.
local leanjson = require "leanjson"
local cjson = require "cjson"
local http = require "resty.http"
local sha256 = require "resty.sha256"
local hex = require("resty.string").to_hex
assert(type(leanjson.decode_file) == "function" and type(leanjson.new_decoder) == "function")
assert(type(require("leanjson.openresty").request) == "function")
local count = 0
for _, size in ipairs { 5, 200000 } do
    local prompt = ("p"):rep(size)
    local raw = '{"model":"original","prompt":"' .. prompt .. '"}'
    local expected = '{"model":"example-model","prompt":"' .. prompt .. '"}'
    local hash = assert(sha256:new())
    hash:update(expected)
    local digest = hex(hash:final())
    for _, path in ipairs { "/", "/incremental" } do
        local result, err = http.new():request_uri("http://127.0.0.1:8080" .. path,
            { method = "POST", body = raw, keepalive = false })
        assert(result, err)
        assert(result.status == 200, result.body)
        local decoded = cjson.decode(result.body)
        assert(decoded.bytes == #expected and decoded.sha256 == digest)
        local mode = path == "/incremental" and "incremental" or (size > 65536 and "completed-file" or "completed-memory")
        assert(result.headers["X-LEANJSON-Input-Mode"] == mode)
        count = count + 1
    end
end
local invalid = assert(http.new():request_uri("http://127.0.0.1:8080/",
    { method = "POST", body = '{"model":"valid"} trailing', keepalive = false }))
assert(invalid.status == 400)
print("runtime image: " .. count .. " memory/file/incremental length+SHA checks; malformed input rejected")
