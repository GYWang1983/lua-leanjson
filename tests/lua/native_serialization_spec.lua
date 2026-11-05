local json = require("leanjson")
local cjson = require("cjson")
local function drain(reader, size)
    local parts = {}
    while true do
        local chunk, err = reader:next()
        assert.is_nil(err)
        if not chunk then break end
        assert.is_true(#chunk > 0 and #chunk <= size)
        parts[#parts+1] = chunk
    end
    return table.concat(parts)
end
local function output(value, options)
    local reader = json.reader(value, options)
    local length = assert(reader:length())
    local raw = drain(reader, options.chunk_size)
    assert.are.equal(#raw, length)
    return raw
end

describe("native string serialization", function()
    it("preserves original string tokens while encoding modified fields", function()
        local value = json.decode('{"model":"old","prompt":"a/b\\u0061\\u007f"}')
        value.model = "new/route"
        local expected = '{"model":"new\\/route","prompt":"a/b\\u0061\\u007f"}'
        for _,size in ipairs {1,2,3,5,7,65536} do
            assert.are.equal(expected, output(value, {chunk_size=size}))
        end
        assert.are.equal('{"model":"new\\/route","prompt":"a\\/ba\\u007f"}', json.encode(value))
        assert.are.equal('{"model":"new\\/route","prompt":"a\\/ba\\u007f"}',
            output(value, {chunk_size=3,preserve_raw_strings=false}))
        json.close(value)
    end)

    it("preserves source strings across sources preload and independent references", function()
        local raw = '{"model":"old","prompt":"a/b\\u0061"}'
        local filename = os.tmpname()
        local file = assert(io.open(filename,"wb"));file:write(raw);file:close()
        for _,source in ipairs {"memory","file","feed"} do
            for _,preload in ipairs {false,true} do
                local opts={file_in_memory=false,preload_paths=preload and {"$.prompt"} or nil}
                local value
                if source=="memory" then value=json.decode(raw,opts)
                elseif source=="file" then value=json.decode_file(filename,opts)
                else
                    local decoder=json.new_decoder(opts)
                    for i=1,#raw,3 do assert(decoder:feed(raw:sub(i,i+2))) end
                    value=assert(decoder:finish());decoder:close()
                end
                local target=json.decode('{}')
                target.messages=json.ref(value,"$.prompt")
                json.close(value)
                assert.are.equal('{"messages":"a/b\\u0061"}',output(target,{chunk_size=2}))
                target.messages='changed/'
                assert.are.equal('{"messages":"changed\\/"}',output(target,{chunk_size=1}))
                json.close(target)
            end
        end
        os.remove(filename)
    end)

    it("keeps duplicate normalization and comment removal while reusing string values",function()
        local codec=json.new();codec.decode_allow_comment(true)
        local value=codec.decode('{/*comment*/"a":0,"a":1,"s":"a/b\\u0061"}')
        local reader=codec.reader(value,{chunk_size=3,normalize_duplicates=true})
        local expected='{"a":1,"s":"a/b\\u0061"}'
        assert.are.equal(#expected,reader:length());assert.are.equal(expected,drain(reader,3))
        codec.close(value)
    end)

    it("encodes ordinary strings keys and every byte like cjson with bounded chunks",function()
        local bytes={};for i=0,255 do bytes[#bytes+1]=string.char(i) end
        local value=table.concat(bytes)
        for _,slash in ipairs {false,true} do
            local codec=json.new();local reference=cjson.new()
            codec.encode_escape_forward_slash(slash);reference.encode_escape_forward_slash(slash)
            local expected=reference.encode(value)
            assert.are.equal(expected,codec.encode(value))
            for _,size in ipairs {1,2,3,5,7,65536} do
                local reader=codec.reader(value,{chunk_size=size})
                assert.are.equal(#expected,reader:length());assert.are.equal(expected,drain(reader,size))
                reader=codec.reader({[value]=value},{chunk_size=size})
                local expected_object=reference.encode({[value]=value})
                assert.are.equal(#expected_object,reader:length())
                assert.are.equal(expected_object,drain(reader,size))
            end
        end
    end)

    it("rejects invalid preservation options",function()
        for _,option in ipairs {0,"true",{}} do
            assert.has_error(function() json.reader({}, {preserve_raw_strings=option}) end)
        end
    end)

    it("checks raw depth across tiny windows with native lexical state",function()
        local codec=json.new();codec.encode_max_depth(2)
        local value=codec.decode('{"a":["braces{}[] and quote\\\" and slash\\\\"]}')
        for _,size in ipairs {1,2,3,7} do
            local reader=codec.reader(value,{chunk_size=size})
            local n=assert(reader:length());assert.are.equal(n,#drain(reader,size))
        end
        codec.encode_max_depth(1)
        local reader=codec.reader(value,{chunk_size=1})
        local n,err=reader:length();assert.is_nil(n);assert.matches('excessive nesting',err,1,true)
        codec.close(value)
    end)

    it("performs payload byte work in native code rather than Lua instruction loops",function()
        local text=('a/b\n"\\'):rep(131072)
        local codec=json.new()
        local value=codec.decode('{"s":"'..('a/b'):rep(262144)..'"}')
        local raw_depth=codec.decode('{"s":"'..('x'):rep(786432)..'"}')
        codec.encode_max_depth(10)
        local was_on=jit.status();jit.off()
        local ticks=0
        debug.sethook(function() ticks=ticks+1 end,"",1000)
        local ok,err=pcall(function()
            local ordinary=codec.encode({[text]=text})
            assert.is_true(#ordinary > #text)
            local reader=codec.reader(value,{chunk_size=65536,preserve_raw_strings=false})
            local n=assert(reader:length());local bytes=0
            while true do local chunk,e=reader:next();assert.is_nil(e);if not chunk then break end;bytes=bytes+#chunk end
            assert.are.equal(n,bytes)
            reader=codec.reader(raw_depth,{chunk_size=65536})
            n=assert(reader:length());bytes=0
            while true do local chunk,e=reader:next();assert.is_nil(e);if not chunk then break end;bytes=bytes+#chunk end
            assert.are.equal(n,bytes)
        end)
        debug.sethook();if was_on then jit.on() end
        codec.close(value);codec.close(raw_depth)
        if not ok then error(err,0) end
        assert.is_true(ticks<500,"JSON payload work exceeded 500000 Lua VM instructions: "..ticks)
    end)
    local function reentrant(fn)
        local native=require("leanjson.encode")
        local old_hook,old_mask,old_count=debug.gethook()
        local entered,calls=false,0
        debug.sethook(function()
            local f=debug.getinfo(2,"f").func
            if not entered and (f==native.length or f==native.next or f==native.encode) then
                entered=true;calls=calls+1
                json.encode("inner/\n")
                entered=false
            end
        end,"l")
        local ok,result=pcall(fn)
        debug.sethook(old_hook,old_mask,old_count)
        if not ok then error(result,0) end
        assert.is_true(calls>0)
        return result
    end

    it("keeps complete encoding stable when debug callbacks reenter the codec",function()
        local value=('outer/\n"\0'):rep(40)
        local expected=cjson.encode(value)
        assert.are.equal(expected,reentrant(function() return json.encode(value) end))
    end)

    it("keeps reader length and bytes stable when callbacks reenter native helpers",function()
        local value=('outer/\n"\0'):rep(40)
        local expected=cjson.encode(value)
        assert.are.equal(expected,reentrant(function()
            local reader=json.reader(value,{chunk_size=64})
            assert.are.equal(#expected,reader:length())
            return drain(reader,64)
        end))
    end)

end)
