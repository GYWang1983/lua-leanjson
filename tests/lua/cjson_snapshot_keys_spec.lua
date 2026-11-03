local json=require("leanjson")
local function drain(reader)
    local parts={}
    while true do
        local chunk,err=reader:next(); assert.is_nil(err)
        if not chunk then return table.concat(parts) end
        parts[#parts+1]=chunk
    end
end
describe("formatted object key snapshots",function()
    it("preserves distinct Lua keys that format to the same JSON name",function()
        local c=json.new();c.encode_number_precision(3);c.encode_invalid_numbers(true)
        for _,value in ipairs({{[-1.231]=1,[-1.232]=2},{[-math.huge]=1,["-Infinity"]=2},{[1]=1,["1"]=2}}) do
            assert.equal(c.encode(value),drain(c.reader(value,{chunk_size=1})))
        end
    end)
    it("retains both source-backed children when formatted names collide",function()
        local c=json.new();c.encode_number_precision(3)
        local paths={os.tmpname(),os.tmpname()}
        for i,name in ipairs({"first","second"}) do
            local f=assert(io.open(paths[i],"wb"));assert(f:write('{"value":"'..name..'"}'));f:close()
        end
        local a,b=c.decode_file(paths[1]),c.decode_file(paths[2])
        local value={[-1.231]=a,[-1.232]=b}
        local expected=c.encode(value)
        local reader=c.reader(value,{chunk_size=1})
        c.close(a);c.close(b)
        local ok,output=pcall(drain,reader)
        reader:close()
        for _,path in ipairs(paths) do os.remove(path) end
        assert.is_true(ok,output)
        assert.equal(expected,output)
    end)
end)
