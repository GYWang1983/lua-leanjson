local leanjson = require "leanjson"
local root = "tests/vendor/JSONTestSuite/test_parsing"
local listing = assert(io.popen("ls -1 " .. root, "r"))
local names = {}
for name in listing:lines() do if name:match("^[yni]_.+%.json$") then names[#names + 1] = name end end
assert(listing:close())
assert(#names == 318, "pinned JSONTestSuite missing or changed: " .. #names .. " cases")
table.sort(names)
local counts = { y = 0, n = 0, i = 0, i_accept = 0, i_reject = 0 }
for _, name in ipairs(names) do
    local path = root .. "/" .. name
    local classification = name:sub(1, 1)
    local file_ok, file_value = pcall(leanjson.decode_file, path, { chunk_size = 17 })
    if file_ok then leanjson.close(file_value) end
    for _, size in ipairs { 17, 65536 } do
        local decoder = leanjson.new_decoder { chunk_size = size }
        local file = assert(io.open(path, "rb"))
        local stream_error
        while true do
            local chunk = file:read(size)
            if not chunk then break end
            local ok, err = decoder:feed(chunk)
            if not ok then stream_error = err; break end
        end
        file:close()
        local value
        if not stream_error then value, stream_error = decoder:finish() end
        decoder:close()
        if not stream_error then leanjson.close(value) end
        local stream_ok = stream_error == nil
        assert(stream_ok == file_ok, name .. " file/stream verdict differs at chunk " .. size)
        if classification == "y" then assert(stream_ok, name .. ": " .. tostring(stream_error)) end
        if classification == "n" then assert(not stream_ok, name .. " was incorrectly accepted") end
    end
    counts[classification] = counts[classification] + 1
    if classification == "i" then
        local verdict = file_ok and "i_accept" or "i_reject"
        counts[verdict] = counts[verdict] + 1
    end
end
print("source JSONTestSuite: " .. counts.y .. " valid, " .. counts.n .. " invalid, " .. counts.i ..
    " implementation-defined (" .. counts.i_accept .. " accept/" .. counts.i_reject .. " reject); file + 17/65536-byte feeds")
