package.loaded.cjson = nil
package.preload.cjson = function() error("cjson deliberately unavailable") end
local json = require("leanjson")
assert(json.encode(json.decode('[]', { lazyload = false })) == '{}')
json.decode_array_with_array_mt(true)
local value = json.decode('{"a":[false,null,[],{}],"x":1}', { lazyload = false })
assert(rawget(value, "a") and rawget(value.a, 1) == false and rawget(value.a, 2) == json.null)
assert(json.encode(value.a[3]) == "[]" and json.encode(value.a[4]) == "{}")
local input = json.new_decoder({ lazyload = false })
assert(input:feed('{"a":[[],false]}'))
local first = assert(input:finish())
first.a[1][1] = 9
local second = assert(input:finish())
assert(json.encode(second.a[1]) == "[]" and second.a[2] == false)
input:close()
local selected = json.decode('{"a":{"b":"x"},"n":9007199254740993}', {
    preload_paths = { "$['a'].b", "$.n" }, index_depth = 0, index_array_limit = 0, index_budget_bytes = 0,
})
assert(selected.a.b == "x")
selected.x = true
assert(json.encode(selected):find('"n":9007199254740993', 1, true))
json.close(selected)
