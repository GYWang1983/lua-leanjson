-- Native byte processing with call-owned scratch. GC finalizers/debug hooks can
-- reenter encoding during Lua allocations; no writable state is shared.
local ffi = require("ffi")
local C = require("leanjson.lib")
local M = {}
local LIMIT = 65536
local function check(code)
    if code ~= 0 then error("leanjson: " .. ffi.string(C.leanjson_strerror(code)), 0) end
end
function M.length(value, slash)
    local count = ffi.new("size_t[1]")
    check(C.leanjson_encode_string_length(value,#value,slash and 1 or 0,count))
    return tonumber(count[0])+2
end
function M.cursor(value, slash)
    return {value=value, flags=slash and 1 or 0, state=ffi.new("leanjson_encode_cursor[1]")}
end
function M.next(cursor, room)
    local remaining = #cursor.value-tonumber(cursor.state[0].offset)
    if remaining == 0 then return nil end
    local size=math.min(room,LIMIT,remaining*6)
    local output,count=ffi.new("uint8_t[?]",size),ffi.new("size_t[1]")
    check(C.leanjson_encode_string_chunk(cursor.value,#cursor.value,cursor.flags,cursor.state,output,size,count))
    return ffi.string(output,count[0])
end
function M.encode(value, slash)
    local size=M.length(value,slash)
    if size==#value+2 then return '"'..value..'"' end
    local bytes=ffi.new("uint8_t[?]",size)
    local cursor,count=ffi.new("leanjson_encode_cursor[1]"),ffi.new("size_t[1]")
    bytes[0],bytes[size-1]=34,34
    check(C.leanjson_encode_string_chunk(value,#value,slash and 1 or 0,cursor,bytes+1,size-2,count))
    return ffi.string(bytes,size)
end
function M.depth_state(depth, maximum)
    return ffi.new("leanjson_encode_depth_state[1]",{{depth,maximum,0,0}})
end
function M.depth(state, bytes)
    return tonumber(C.leanjson_encode_depth_chunk(bytes,#bytes,state))
end
return M
