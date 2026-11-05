local json = require("leanjson")

describe("CJSON-derived complete-memory scanner", function()
    local roots
    before_each(function() roots = {} end)
    after_each(function() for _, root in ipairs(roots) do json.close(root) end end)
    local function decode(raw, opts, codec)
        local root = (codec or json).decode(raw, opts)
        if type(root) == "table" or type(root) == "userdata" and root ~= json.null then roots[#roots + 1] = root end
        return root
    end

    it("rejects invalid scanner options instead of silently ignoring them", function()
        for _, value in ipairs({false, true, 1, "unknown", {}}) do
            assert.has_error(function() json.decode('{}', {scanner = value}) end)
            assert.has_error(function() json.new_decoder({scanner = value}) end)
        end
    end)

    it("keeps key hashes, escaping flags and duplicate replacement at every split", function()
        local raw = '{"long-key":"first","a/b":"slash/\127","long-key":"last",' ..
            '"unicode":"\\u4e2d\\ud83d\\ude00","escaped":"quote\\\" slash\\\\ tab\\t"}'
        local expected = { ["long-key"] = "last", ["a/b"] = "slash/\127", unicode = "中😀", escaped = 'quote" slash\\ tab\t' }
        for _, scanner in ipairs({"cjson", "legacy"}) do
            for chunk = 1, #raw do
                local root = decode(raw, {chunk_size = chunk, scanner = scanner})
                assert.same(expected, json.materialize(root))
                assert.same(expected, json.materialize(decode(json.encode(root))))
                assert.is_true(json.source_stats(root).index_bytes <= 1048576)
            end
        end
    end)

    it("loads explicit paths beyond all automatic metadata limits", function()
        local raw = '{"ignored":"' .. string.rep("z", 131072) .. '","a":[0,1,2,{"b":{"prompt":"selected/中"}}]}'
        local root = decode(raw, {scanner = "cjson", chunk_size = 17, index_depth = 0,
            index_array_limit = 0, index_budget_bytes = 0, preload_paths = {"$.a[3].b.prompt"}})
        assert.are.equal(0, json.source_stats(root).index_bytes)
        assert.is_true(json.source_stats(root).preloaded_payload_bytes > 0)
        assert.are.equal("selected/中", root.a[4].b.prompt)
        assert.are.equal(131072, json.len(root, "$.ignored"))
    end)

    it("uses the same bounded event stream for eager values and schemas", function()
        local schema = json.compile_schema({type = "object", required = {"text", "n"}, properties = {
            text = {type = "string", minLength = 3, maxLength = 6}, n = {type = "integer", minimum = 2},
        }})
        for _, scanner in ipairs({"cjson", "legacy"}) do
            for _, lazyload in ipairs({false, true}) do
                for _, chunk in ipairs({1, 2, 7, 65536}) do
                    local root = decode('{"text":"中/\\u4e2d","n":1,"n":3}', {
                        scanner = scanner, chunk_size = chunk, lazyload = lazyload, schema = schema})
                    assert.same({text = "中/中", n = 3}, json.materialize(root))
                    assert.has_error(function() decode('{"text":"abc","n":3,"n":1}', {
                        scanner = scanner, chunk_size = chunk, lazyload = lazyload, schema = schema}) end)
                end
            end
        end
    end)

    it("preserves native error messages and independent strict policies", function()
        local codec = json.new()
        codec.decode_allow_comment(true)
        codec.decode_validate_utf8(true)
        codec.decode_invalid_numbers(false)
        for _, raw in ipairs({'[1,]', '{"x":1,,}', '{}/*Unclosed', '[tru/*x*/e]', '[1/*x*/0]',
            '[1e+]', '"\\uD800"', '"\255"', '\0\0', '', '"unfinished'}) do
            local legacy_ok, legacy = pcall(codec.decode, raw, {scanner = "legacy", chunk_size = 3})
            local fast_ok, fast = pcall(codec.decode, raw, {scanner = "cjson", chunk_size = 1})
            assert.is_false(legacy_ok)
            assert.is_false(fast_ok)
            assert.are.equal(legacy, fast)
        end
        codec.decode_validate_utf8(false)
        local root = decode('{"raw":"\255"}', {scanner = "cjson"}, codec)
        assert.are.equal("\255", root.raw)
    end)

    it("preserves file and incremental values, preload and schemas at chunk boundaries", function()
        local raw = '{"model":"old","prompt":"' .. string.rep("normal/", 4096) .. '中","model":"new"}'
        local plan = json.compile_schema({type = "object", required = {"model", "prompt"}, properties = {
            model = {const = "new"}, prompt = {type = "string", minLength = 28000},
        }})
        local filename = os.tmpname()
        local file = assert(io.open(filename, "wb")); assert(file:write(raw)); assert(file:close())
        local ok, err = pcall(function()
            for _, scanner in ipairs({"cjson", "legacy"}) do
                for _, chunk in ipairs({1, 7, 65536}) do
                    local opts = {scanner = scanner, chunk_size = chunk, index_budget_bytes = 0,
                        preload_paths = {"$.model"}, schema = plan, file_in_memory = false}
                    local body = json.decode_file(filename, opts); roots[#roots + 1] = body
                    assert.are.equal("new", body.model)
                    assert.are.equal(28675, json.len(body, "$.prompt"))
                    local decoder = json.new_decoder(opts)
                    for first = 1, #raw, chunk do assert(decoder:feed(raw:sub(first, first + chunk - 1))) end
                    local streamed = assert(decoder:finish()); decoder:close(); roots[#roots + 1] = streamed
                    assert.are.equal("new", streamed.model)
                    assert.are.equal(28675, json.len(streamed, "$.prompt"))
                end
            end
        end)
        os.remove(filename)
        assert(ok, err)
    end)

    it("keeps source references and edits valid after the scan", function()
        local a = decode('{"prompt":"' .. string.rep("q", 131072) .. '/"}', {scanner = "cjson"})
        local b = decode('{"messages":null,"model":"old"}', {scanner = "cjson"})
        b.messages = json.ref(a, "$.prompt")
        b.model = "new"
        assert.are.equal(131073, json.len(b, "$.messages"))
        local encoded = json.encode(b)
        local result = decode(encoded)
        assert.are.equal("new", result.model)
        assert.are.equal(string.rep("q", 131072) .. "/", result.messages)
    end)
end)
