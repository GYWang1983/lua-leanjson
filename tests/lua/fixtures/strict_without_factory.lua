-- A fresh VM models a runtime without LuaJIT's userdata factory.
_G.newproxy = nil
local json = require("leanjson")
local safe = require("leanjson.safe")
for _, api in ipairs({ json, json.new(), safe, safe.new() }) do
    for _, eager in ipairs({ false, true }) do
        local opts = { proxy_mode = "userdata", lazyload = not eager }
        for _, call in ipairs({ function() api.decode("{}", opts) end,
            function() api.decode_file("/missing/f18-input", opts) end,
            function() api.new_decoder(opts) end }) do
            local ok, err = pcall(call)
            assert(not ok and tostring(err):find("newproxy", 1, true), tostring(err))
        end
    end
    local value = api.decode('{"a":1}', { proxy_mode = "table" })
    assert(type(value) == "table" and value.a == 1)
    json.close(value)
end
