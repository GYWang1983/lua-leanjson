local scenario, size, path = assert(arg[1]), assert(tonumber(arg[2])), assert(arg[3])
local file = assert(io.open(path, "wb"))
assert(file:write(require("benchmark-fixtures").build(scenario, size)))
assert(file:close())
