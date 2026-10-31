local cjson = require "cjson"
local lfs = require "lfs"
local function read_status()
    local file = assert(io.open("/proc/self/status", "r"))
    local status = file:read("*a")
    file:close()
    return tonumber(status:match("VmRSS:%s+(%d+)")), tonumber(status:match("VmHWM:%s+(%d+)"))
end
if ngx.var.arg_gc == "1" then collectgarbage("collect") end
local rss, hwm = read_status()
local io_file = assert(io.open("/proc/self/io", "r"))
local io_stats = {}
for key, value in io_file:read("*a"):gmatch("([%w_]+):%s+(%d+)") do io_stats[key] = tonumber(value) end
io_file:close()
local fd_count = 0
for name in lfs.dir("/proc/self/fd") do if name ~= "." and name ~= ".." then fd_count = fd_count + 1 end end
ngx.header.content_type = "application/json"
ngx.say(cjson.encode { pid = ngx.worker.pid(), rss_kib = rss, hwm_kib = hwm,
    lua_kib = collectgarbage("count"), fd_count = fd_count, cpu_s = os.clock(), io = io_stats })
