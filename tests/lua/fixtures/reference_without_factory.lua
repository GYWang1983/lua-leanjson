_G.newproxy = nil
local json = require("leanjson")
local a = json.decode('{"prompt":"value"}')
local reference = json.ref(a, "$.prompt")
assert(type(reference) == "table")
assert(json.type(reference) == "string")
assert(json.len(reference) == 5)
assert(not pcall(function() reference.x = 1 end))
assert(not pcall(function() return reference.x end))
-- Table carriers cannot intercept raw Lua primitives. They still protect the
-- captured logical node from those unrelated raw fields.
rawset(reference, "x", 123)
assert(reference.x == 123)
assert(json.encode(reference) == '"value"')
local b = json.decode('{}')
b.messages = reference
json.close(a); json.close(reference)
assert(json.encode(b) == '{"messages":"value"}')
json.close(b)
