local json = require("leanjson")

local function collect(c, value, size)
    local r, parts = c.reader(value, { chunk_size = size or 1 }), {}
    local length, err = r:length(); assert.is_nil(err)
    while true do
        local chunk, failure = r:next(); assert.is_nil(failure)
        if not chunk then break end
        assert.is_true(#chunk <= (size or 1)); parts[#parts + 1] = chunk
    end
    local raw = table.concat(parts); assert.equal(#raw, length)
    return raw
end

describe("source number and byte-string compatibility", function()
    local files, held
    before_each(function() files, held = {}, {} end)
    after_each(function()
        for _, item in ipairs(held) do item[1].close(item[2]) end
        for _, path in ipairs(files) do os.remove(path) end
    end)
    local function hold(c, value)
        if type(value) == "table" or type(value) == "userdata" then held[#held + 1] = {c, value} end
        return value
    end
    local function load(c, source, raw, opts)
        opts = opts or {}
        opts.chunk_size = 3
        opts.index_depth, opts.index_array_limit, opts.index_budget_bytes = 0, 0, 0
        if source == "memory" then return hold(c, c.decode(raw, opts)) end
        if source == "file" then
            local path = os.tmpname(); files[#files + 1] = path
            local f = assert(io.open(path, "wb")); assert(f:write(raw)); f:close()
            return hold(c, c.decode_file(path, opts))
        end
        local d = c.new_decoder(opts)
        local ok, value = pcall(function()
            for i = 1, #raw do assert(d:feed(raw:sub(i,i))) end
            return assert(d:finish())
        end)
        d:close(); if not ok then error(value, 0) end
        return hold(c, value)
    end

    for _, source in ipairs({"memory", "file", "feed"}) do
      for _, mode in ipairs({"lazy", "eager", "preload"}) do
        it("uses native numbers and byte strings in " .. source .. "/" .. mode, function()
            local c = json.new()
            local opts = { lazyload = mode ~= "eager" }
            if mode == "preload" then opts.preload_paths = {"$.selected"} end
            local bytes = string.char(128,255)
            local raw = '{"selected":0x6.ffp1,"late":{"n":-Infinity,"nan":NaN,"raw":"' .. bytes .. '"},"' .. bytes .. '":"value"}'
            local body = load(c, source, raw, opts)
            assert.equal(13.9921875, body.selected)
            local late = hold(c, body.late)
            assert.equal(-math.huge, late.n)
            assert.is_true(late.nan ~= late.nan)
            assert.equal(bytes, late.raw)
            assert.equal("value", body[bytes])
            assert.is_function(c.encode_invalid_numbers)
            c.encode_invalid_numbers("null")
            local encoded = collect(c, body)
            local strict = json.new()
            local output = hold(strict, strict.decode(encoded, { lazyload = false }))
            assert.equal(json.null, output.late.n)
            assert.equal(json.null, output.late.nan)
            assert.equal(bytes, output.late.raw)
            c.decode_invalid_numbers(false)
            assert.has_error(function() load(c, source, raw, opts) end)
            c.decode_invalid_numbers(true); c.decode_validate_utf8(true)
            assert.has_error(function() load(c, source, raw, opts) end)
        end)
      end
    end

    it("snapshots decoder policy across late reads and repeated eager rebuilds", function()
        for _, eager in ipairs({false,true}) do
            local c = json.new()
            assert.is_function(c.decode_validate_utf8)
            local d = c.new_decoder({lazyload=not eager,chunk_size=1,index_depth=0})
            c.decode_invalid_numbers(false); c.decode_validate_utf8(true)
            assert(d:feed('{"n":NaN,"s":"'..string.char(255)..'"}'))
            for _ = 1, 2 do
                local value = hold(c, assert(d:finish()))
                assert.is_true(value.n ~= value.n); assert.equal(string.char(255),value.s)
                local n, state = d:get("n"); assert.equal("READY",state); assert.is_true(n ~= n)
            end
            d:close()
        end
    end)

    it("applies F09 to source numbers hidden in unchanged containers", function()
        local c = json.new()
        assert.is_function(c.encode_invalid_numbers)
        for _, raw in ipairs({'{"nested":[NaN]}','{"nested":[1e9999]}','{"nested":[-Infinity]}'}) do
            local root = hold(c, c.decode(raw))
            assert.has_error(function() c.encode(root) end)
            local r = c.reader(root); local n, err = r:length(); assert.is_nil(n); assert.is_string(err); r:close()
            c.encode_invalid_numbers("null")
            assert.equal('{"nested":[null]}',c.encode(root))
            assert.equal('{"nested":[null]}',collect(c,root))
            c.encode_invalid_numbers(false)
        end
    end)

    it("escapes source strings and keys through bounded output", function()
        local c = json.new()
        local raw = '{"a/b":"' .. string.rep("x",100000) .. '/\127","nested":["\\u002f"]}'
        local root = hold(c,c.decode(raw))
        local expected = '{"a\\/b":"' .. string.rep("x",100000) .. '\\/\\u007f","nested":["\\/"]}'
        assert.equal(expected,c.encode(root)); assert.equal(expected,collect(c,root,7))
        c.encode_escape_forward_slash(false)
        expected = '{"a/b":"'..string.rep("x",100000)..'/\\u007f","nested":["/"]}'
        assert.equal(expected,collect(c,root,7))
        local plain = c.materialize(root,{keep_origin=true})
        assert.equal(expected,c.encode(plain))
    end)

    it("matches native integer saturation and NaN payload conversion", function()
        for _, mode in ipairs({"lazy", "eager", "preload"}) do
            local c = json.new()
            local raw = '[9223372036854775808,-9223372036854775809,' .. string.rep("9",400) .. ',nan(payload_12),1e9999,-.5,+.5,-0,-000,-0.0]'
            local value = load(c,"feed",raw,{lazyload=mode~="eager",preload_paths=mode=="preload" and {"$[*]"} or nil})
            assert.equal(9223372036854775807,value[1]); assert.equal(-9223372036854775808,value[2])
            assert.equal(9223372036854775807,value[3]); assert.is_true(value[4]~=value[4])
            assert.equal(math.huge,value[5]); assert.equal(-0.5,value[6]); assert.equal(0.5,value[7])
            assert.equal(math.huge,1/value[8]); assert.equal(math.huge,1/value[9])
            assert.equal(-math.huge,1/value[10])
        end
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
      for _, mode in ipairs({ "lazy", "eager", "preload" }) do
        for _, carrier in ipairs({ "table", "userdata" }) do
            it("preserves native signed zero in " .. source .. "/" .. mode .. "/" .. carrier, function()
                local c = json.new()
                local value = load(c, source, '[-0,-000,-0.0,-0e0,-0x0p0,-1e-9999,0.0,1e-9999]', {
                    lazyload = mode ~= "eager", proxy_mode = carrier,
                    preload_paths = mode == "preload" and { "$[*]" } or nil,
                })
                for _, index in ipairs({ 1, 2, 7, 8 }) do assert.equal(math.huge, 1 / value[index]) end
                for _, index in ipairs({ 3, 4, 5, 6 }) do assert.equal(-math.huge, 1 / value[index]) end
                c.decode_invalid_numbers(false)
                assert.has_error(function() load(c, source, '[-0x0p0]', { lazyload = false }) end)
                local strict = load(c, source, '[-0.0,-0e0,-1e-9999]', { lazyload = false })
                for index = 1, 3 do assert.equal(-math.huge, 1 / strict[index]) end
            end)
        end
      end
    end

    it("rejects malformed Unicode escapes and control bytes even in byte mode", function()
        for _, source in ipairs({"memory","file","feed"}) do
            for _, mode in ipairs({"lazy","eager","preload"}) do
                for _, raw in ipairs({'{"x":"\\uD800"}','{"x":"\\uDC00"}','{"x":"\\uZZZZ"}','{"x":"'..string.char(0)..'"}'}) do
                    assert.has_error(function()
                        load(json.new(),source,raw,{lazyload=mode~="eager",preload_paths=mode=="preload" and {"$.unselected"} or nil})
                    end)
                end
            end
        end
    end)

    it("uses byte-exact duplicate keys and safe conversions across all input modes", function()
        local key = string.char(128,255)
        for _, source in ipairs({"memory","file","feed"}) do
            for _, mode in ipairs({"lazy","eager","preload"}) do
                local c = require("leanjson.safe").new()
                c.encode_invalid_numbers("null")
                local opts={lazyload=mode~="eager",preload_paths=mode=="preload" and {"$.*"} or nil}
                local body=load(c,source,'{"'..key..'":0,"'..key..'":Infinity}',opts)
                assert.equal(math.huge,body[key])
                assert.equal('{"'..key..'":null}',collect(c,body))
            end
        end
    end)

    it("cancels a suspended decoded-string stream and discards late bytes", function()
        for _, during in ipairs({"length","next"}) do
            local c=json.new()
            local backend, handle=require("leanjson.source_memory").open('{"s":"a/b"}',nil,c)
            local value=hold(c,require("leanjson.proxy").from_backend(backend,handle,c))
            local r=c.reader(value,{chunk_size=1})
            if during=="next" then assert.equal(#'{"s":"a\\/b"}',r:length()) end
            local original=backend.read
            function backend:read(offset,length)
                if offset >= 6 then coroutine.yield("stream pending") end
                return original(self,offset,length)
            end
            local co=coroutine.create(function()
                if during == "length" then return r:length() end
                while true do
                    local chunk,err=r:next()
                    if chunk==nil then return chunk,err end
                end
            end)
            local ok,pending=coroutine.resume(co); assert.is_true(ok); assert.equal("stream pending",pending)
            r:close()
            local resumed,chunk,err=coroutine.resume(co)
            assert.is_true(resumed); assert.is_nil(chunk); assert.equal("leanjson.reader: closed",err)
        end
    end)
end)
