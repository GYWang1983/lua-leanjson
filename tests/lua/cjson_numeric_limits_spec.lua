local json=require("leanjson")
describe("native numeric conversion limits",function()
    it("converts huge decimal and hexadecimal exponents in all loading modes",function()
        local cases={{"1e99999999",math.huge},{"0e9999999999999999999999",0},
            {"1e-9999999999999999999999",0},{"-1e-9999999999999999999999",-1/math.huge},
            {"0x1p99999999999999999999",math.huge},{"0x1p-99999999999999999999",0},
            {"0x0p99999999999999999999",0}}
        for _,mode in ipairs({"lazy","eager","preload"}) do
            for _,case in ipairs(cases) do
                local c=json.new()
                local value=c.decode('['..case[1]..']',{lazyload=mode~="eager",preload_paths=mode=="preload" and {"$[*]"} or nil})
                assert.equal(case[2],value[1])
                if case[2]==0 then assert.equal(1/case[2],1/value[1]) end
                c.close(value)
            end
        end
    end)

    it("never concatenates a long NaN payload or saturated integer during bounded output",function()
        for _,token in ipairs({'nan('..string.rep('x',1048576)..')',string.rep('9',1048576)}) do
            local raw='{"n":'..token..',"marker":0}'
            local c=json.new();c.encode_invalid_numbers("null")
            local body=c.decode(raw,{chunk_size=4096,index_depth=0,index_array_limit=0,index_budget_bytes=0})
            body.marker=1
            local concat=table.concat
            rawset(table,"concat",function(parts,sep,first,last)
                local bytes=0
                for i=first or 1,last or #parts do bytes=bytes+#parts[i] end
                assert.is_true(bytes<=65536,"bounded numeric output concatenated "..bytes.." bytes")
                return concat(parts,sep,first,last)
            end)
            local ok,err=pcall(function()
                local r=c.reader(body,{chunk_size=128})
                local expected=token:sub(1,1)=='n' and '{"n":null,"marker":1}' or '{"n":'..token..',"marker":1}'
                local length,failure=r:length();assert.is_nil(failure);assert.equal(#expected,length)
                local position=1
                while true do
                    local chunk,e=r:next();assert.is_nil(e)
                    if not chunk then break end
                    assert.equal(expected:sub(position,position+#chunk-1),chunk)
                    position=position+#chunk
                end
                assert.equal(#expected+1,position)
            end)
            rawset(table,"concat",concat);c.close(body)
            assert.is_true(ok,err)
        end
    end)
end)
