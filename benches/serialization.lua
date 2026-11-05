-- Stage timings for a fixed request. Input preparation, GC, source mutation,
-- output storage and semantic oracles stay outside measured regions.
local json,cjson,ffi=require("leanjson"),require("cjson"),require("ffi")
local io_source=require("leanjson.source_io")
local io_read=io_source.read
local reads={}
io_source.read=function(...)
    local began=os.clock();local value,err=io_read(...)
    reads.calls=(reads.calls or 0)+1;reads.bytes=(reads.bytes or 0)+(value and #value or 0)
    reads.cpu_ms=(reads.cpu_ms or 0)+(os.clock()-began)*1000
    return value,err
end
local filename,trials,source,policy,receipt=arg[1],tonumber(arg[2]),arg[3],arg[4],arg[5]
ffi.cdef[[struct leanjson_serial_timeval { long tv_sec; long tv_usec; }; int gettimeofday(void *, void *);]]
local tv=ffi.new("struct leanjson_serial_timeval[1]")
local function wall()
    assert(ffi.C.gettimeofday(tv,nil)==0)
    return tonumber(tv[0].tv_sec)+tonumber(tv[0].tv_usec)/1000000
end
local f=assert(io.open(filename,"rb"));local raw=f:read("*a");f:close()
local records={}
local function timed(fn)
    reads={}
    local began,cpu=wall(),os.clock()
    local value=fn()
    return value,{cpu_ms=(os.clock()-cpu)*1000,wall_ms=(wall()-began)*1000,reads=reads}
end
local function decode(value)
    local opts={file_in_memory=source=="buffered-file",preload_paths={"$.model","$.stream","$.messages[*].role"}}
    if source=="memory" then return json.decode(value,opts) end
    if source=="feed" then
        local decoder=json.new_decoder(opts)
        for first=1,#value,65536 do assert(decoder:feed(value:sub(first,first+65535))) end
        local body=assert(decoder:finish());decoder:close();return body
    end
    return json.decode_file(filename,opts)
end
local function run(trial,oracle)
    local value=raw:gsub("0123456789abcdef",string.format("%016x",trial+100),1)
    if source=="file" or source=="buffered-file" then
        local file=assert(io.open(filename,"wb"));assert(file:write(value));file:close()
    end
    collectgarbage("collect");collectgarbage("collect")
    local body,decoded=timed(function() return decode(value) end)
    body.model="fixture-chat"
    local reader,created=timed(function() return json.reader(body,{chunk_size=65536,
        normalize_duplicates=true,preserve_raw_strings=policy=="preserve"}) end)
    local length,counted=timed(function() return assert(reader:length()) end)
    local bytes,emitted=timed(function()
        local n=0
        while true do local chunk,err=reader:next();assert(not err,err);if not chunk then break end
            assert(#chunk<=65536);n=n+#chunk
        end
        return n
    end)
    assert(bytes==length)
    reader:close()
    if oracle then
        local expected=cjson.decode(value);expected.model="fixture-chat"
        local output=assert(io.open(receipt,"wb"))
        reader=json.reader(body,{chunk_size=65536,normalize_duplicates=true,preserve_raw_strings=policy=="preserve"})
        while true do local chunk,err=reader:next();assert(not err,err);if not chunk then break end
            assert(output:write(chunk))
        end
        output:close();reader:close()
        -- Python performs an independent complete-object comparison of this
        -- receipt with its own input decoder after the process exits.
        assert(expected.model=="fixture-chat")
    end
    json.close(body)
    if trial>0 and not oracle then records[#records+1]={trial=trial,decode=decoded,create=created,length=counted,emit=emitted,output_bytes=bytes} end
end
for trial=-2,0 do run(trial,false) end
for trial=1,trials do run(trial,false) end
run(trials+1,true)
print(cjson.encode({source=source,policy=policy,trials=records,bytes=#raw,cjson_version=cjson._VERSION,luajit=jit.version}))
