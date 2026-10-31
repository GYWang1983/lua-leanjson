local cjson = require "cjson"
local lfs = require "lfs"
local function read_status()
    local file = assert(io.open("/proc/self/status", "r"))
    local status = file:read("*a")
    file:close()
    return tonumber(status:match("VmRSS:%s+(%d+)")), tonumber(status:match("VmHWM:%s+(%d+)"))
end
collectgarbage("collect")
local rss, hwm = read_status()
local fd_count = 0
for name in lfs.dir("/proc/self/fd") do if name ~= "." and name ~= ".." then fd_count = fd_count + 1 end end
ngx.header.content_type = "application/json"
ngx.say(cjson.encode { pid = ngx.worker.pid(), rss_kib = rss, hwm_kib = hwm,
    lua_kib = collectgarbage("count"), fd_count = fd_count })
