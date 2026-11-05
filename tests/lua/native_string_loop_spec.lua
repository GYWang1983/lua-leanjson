local json = require "leanjson"

describe("native block string loop", function()
    local roots
    before_each(function() roots = {} end)
    after_each(function() for _, root in ipairs(roots) do json.close(root) end end)
    local function load(raw, opts, source)
        local body
        if source == "memory" then body = json.decode(raw, opts)
        else
            local decoder = json.new_decoder(opts)
            for first = 1, #raw, opts.chunk_size do assert(decoder:feed(raw:sub(first, first+opts.chunk_size-1))) end
            body = assert(decoder:finish()); decoder:close()
        end
        roots[#roots+1] = body
        return body
    end

    it("keeps escaped duplicate keys and selected strings correct for every input boundary", function()
        local raw = '{"model":"old","m\\u006fdel":"new","prompt":"quote\\\" slash\\\\\\n\\u4e2d\\ud83d\\ude00\\u002f\\u007f"}'
        local expected = {model="new", prompt='quote" slash\\\n中😀/\127'}
        for _, source in ipairs({"memory", "feed"}) do
            for _, scanner in ipairs({"cjson", "legacy"}) do
                for chunk = 1, #raw do
                    local body = load(raw, {scanner=scanner, chunk_size=chunk, index_budget_bytes=0,
                        preload_paths={"$.model", "$.prompt"}}, source)
                    assert.same(expected, json.materialize(body))
                end
            end
        end
    end)

    it("sends decoded UTF-8 and escape batches to schemas in lazy, eager and preload modes", function()
        local text = string.rep('quote"\\\n中😀/', 600)
        local raw = '{"prompt":' .. json.encode(text) .. '}'
        local plan = json.compile_schema({type="object", required={"prompt"}, properties={
            prompt={type="string", const=text},
        }})
        for _, source in ipairs({"memory", "feed"}) do
            for _, mode in ipairs({"lazy", "eager", "preload"}) do
                for _, chunk in ipairs({1,7,4093,65536}) do
                    local body = load(raw, {chunk_size=chunk, schema=plan, lazyload=mode~="eager",
                        preload_paths=mode=="preload" and {"$.prompt"} or nil}, source)
                    assert.are.equal(text, body.prompt)
                end
            end
        end
    end)

    it("normalizes referenced escaped spans through bounded readers", function()
        local text = string.rep('quote"\\\n中😀/\127', 2000)
        local a = load('{"prompt":' .. json.encode(text) .. '}', {chunk_size=65536}, "memory")
        local b = load('{"messages":null}', {chunk_size=17}, "memory")
        b.messages = json.ref(a,"$.prompt")
        for _, chunk in ipairs({1,3,65536}) do
            local reader = json.reader(b, {chunk_size=chunk})
            local parts = {}
            while true do
                local part = reader:next()
                if not part then break end
                assert.is_true(#part <= chunk)
                parts[#parts+1] = part
            end
            json.close(reader)
            local decoded = load(table.concat(parts), {chunk_size=31}, "memory")
            assert.are.equal(text, decoded.messages)
        end
    end)
end)
