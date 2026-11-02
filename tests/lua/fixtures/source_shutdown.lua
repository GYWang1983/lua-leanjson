-- Executed in an independent LuaJIT VM: finalizers at lua_close have no ordering
-- guarantee, even when the corresponding values remain reachable until exit.
package.path = "./lua/?.lua;" .. package.path
local json = require("leanjson")
local proxy = require("leanjson.proxy")
local memory = require("leanjson.source_memory")
local mode, directory = arg[1], arg[2]
local pending = {}
for i = 1, 96 do
    local backend, root = memory.open('{"a":1,"b":2}')
    local iterator = backend:children(root)
    assert(iterator() == "a")
    pending[#pending + 1] = iterator

    local scalar, handle = memory.open('"\\u0041"')
    function scalar:read() coroutine.yield("scalar pending"); return "A" end
    local worker = coroutine.create(function() scalar:scalar(handle) end)
    assert(select(2, coroutine.resume(worker)) == "scalar pending")
    pending[#pending + 1] = worker

    local input = json.new_decoder({ temp_dir = directory, chunk_size = 3 })
    assert(input:feed('{"a":1,"b":2}'))
    local value = assert(input:finish())
    local node = proxy.node(value)
    local file_iterator = node.backend:children(node.handle)
    assert(file_iterator() == "a")
    pending[#pending + 1] = file_iterator
    local reader = json.reader(value, { chunk_size = 1 })
    assert(reader:next() == "{")
    pending[#pending + 1] = reader
    input:close()
    json.close(value)
    if mode == "closed" then
        reader:close()
        local aborted = json.new_decoder({ temp_dir = directory })
        assert(aborted:feed('{"open":'))
        assert(aborted:abort("cancelled"))
        aborted:close()
    end
end
_G.pending_source_operations = pending
if mode == "collect" then
    pending = nil
    _G.pending_source_operations = pending
    collectgarbage("collect")
    collectgarbage("collect")
end
