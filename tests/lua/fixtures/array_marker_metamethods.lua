local c = require("leanjson").new()
local function output(value)
    local reader, chunks = c.reader(value, { chunk_size = 1 }), {}
    while true do
        local chunk, err = reader:next(); assert(err == nil)
        if not chunk then return table.concat(chunks) end
        chunks[#chunks + 1] = chunk
    end
end
if arg[1] == "raw" then
    local marker = c.array_mt
    marker.__len = function() error("explicit array marker length was invoked") end
    marker.__index = function() return "synthetic" end
    marker.__metatable = "protected marker"
    local value = setmetatable({ 1, 2, hash = "ignored" }, marker)
    assert(c.encode(value) == "[1,2]")
    assert(output(value) == "[1,2]")
    local raw = '["' .. string.rep("x",90) .. '"]'
    local source = c.decode(raw)
    local plain = c.materialize(source, { keep_origin = true })
    setmetatable(plain, marker)
    assert(c.encode(plain) == raw)
    c.close(source)
elseif arg[1] == "equality" then
    local equality = { __eq = function() return true end }
    setmetatable(c.array_mt, equality)
    local fake = setmetatable({}, equality)
    local unrelated = setmetatable({ hash = 1 }, fake)
    assert(not rawequal(fake, c.array_mt))
    assert(c.encode(unrelated) == '{"hash":1}')
    assert(output(unrelated) == '{"hash":1}')
elseif arg[1] == "empty" then
    c.empty_array_mt.__index = function(_, k) if k == 2 then return "synthetic" end end
    local holes = setmetatable({ 1, 2, 3, 4 }, c.empty_array_mt); holes[2] = nil
    assert(c.encode(holes) == '[1,"synthetic",3,4]')
    assert(output(holes) == '[1,"synthetic",3,4]')
else error("unknown marker fixture") end
