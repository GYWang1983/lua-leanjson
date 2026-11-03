package.loaded.cjson = nil
package.preload.cjson = function() error('cjson deliberately unavailable', 0) end
local json = require('leanjson')
local safe = require('leanjson.safe')
local expected = 'Cannot serialise userdata: table key must be a number or string'
for _, sentinel in ipairs({json.null, json.empty_array}) do
    assert(type(sentinel) == 'table')
    local value = {[sentinel]=1}
    local ok, err = pcall(json.encode, value)
    assert(not ok and err == expected, tostring(err))
    local result, safe_error = safe.encode(value)
    assert(result == nil and safe_error == expected, tostring(safe_error))
    local reader = json.reader(value)
    local length, reader_error = reader:length()
    assert(length == nil and reader_error == expected, tostring(reader_error))
    reader:close()
    local body = json.decode('{}')
    local assigned, assign_error = pcall(function() body.x = value end)
    assert(not assigned and assign_error == expected, tostring(assign_error))
    json.close(body)
end
