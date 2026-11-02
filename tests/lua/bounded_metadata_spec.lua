local json = require("leanjson")
local proxy = require("leanjson.proxy")

local function drain(reader)
    local out = {}
    while true do
        local chunk, err = reader:next()
        assert.is_nil(err)
        if not chunk then break end
        out[#out + 1] = chunk
    end
    return table.concat(out)
end

describe("bounded source metadata", function()
    it("rejects invalid metadata options before conversion", function()
        for _, name in ipairs({ "index_depth", "index_array_limit", "index_budget_bytes" }) do
            for _, value in ipairs({ -1, 0.5, math.huge, -math.huge, 0 / 0, "3", false, 4294967296 }) do
                assert.has_error(function() json.decode('{}', { [name] = value }) end)
            end
        end
    end)

    it("does not expand all Lua members for targeted reads or normalized length", function()
        local body = json.decode('{"a":{"b":{"c":{"d":7}}},"tail":[1,2,3,4,5]}',
            { index_budget_bytes = 0 })
        assert.are.equal(7, body.a.b.c.d)
        assert.are.equal(5, body.tail[5])
        assert.is_nil(proxy.node(body).values)
        local reader = json.reader(body, { normalize_duplicates = true, chunk_size = 3 })
        assert.are.equal(44, reader:length())
        assert.is_nil(proxy.node(body).values)
        reader:close()
        json.close(body)
    end)

    it("preserves linked children, forks and reader snapshots with zero cache", function()
        local body = json.decode('{"a":[{"x":1},{"x":2},{"x":3}],"d":0,"d":null}',
            { index_depth = 0, index_array_limit = 0, index_budget_bytes = 0 })
        local held, branch = body.a[3], json.fork(body)
        local reader = json.reader(body, { normalize_duplicates = true, chunk_size = 2 })
        json.array_insert(body.a, 1, false)
        held.x = 9
        assert.are.equal(9, body.a[4].x)
        assert.are.equal(3, branch.a[3].x)
        assert.are.equal('{"a":[{"x":1},{"x":2},{"x":3}],"d":null}', drain(reader))
        assert.are.equal('{"a":[false,{"x":1},{"x":2},{"x":9}],"d":null}',
            drain(json.reader(body, { normalize_duplicates = true, chunk_size = 1 })))
        json.close(body); json.close(branch); json.close(held)
    end)

    it("normalizes decoded duplicates and replaces entire subtrees in streamed tails", function()
        local body = json.decode('{"a":{"old":1},"a":false,"deep":{"x":{"z":1,"z":2}},"\\u0061":null}',
            { index_depth = 1, index_array_limit = 1, index_budget_bytes = 64 })
        assert.are.equal(json.null, body.a)
        local expected = '{"a":null,"deep":{"x":{"z":2}}}'
        local reader = json.reader(body, { normalize_duplicates = true, chunk_size = 1 })
        assert.are.equal(#expected, reader:length())
        assert.are.equal(expected, drain(reader))
        body.new = false
        assert.is_nil(proxy.node(body).values)
        json.close(body)
    end)
    it("serves the configured array prefix from native metadata without rereading values", function()
        local io_source = require("leanjson.source_io")
        local filename = os.tmpname()
        local output = assert(io.open(filename, "wb"))
        output:write('[{"x":1},{"x":2},{"x":3},{"x":4}]')
        output:close()
        local body = json.decode_file(filename)
        local original, reads = io_source.read, 0
        io_source.read = function(...) reads = reads + 1; return original(...) end
        local ok, err = pcall(function()
            local first = body[1]
            assert.are.equal(0, reads)
            assert.are.equal(1, first.x)
            reads = 0
            local fourth = body[4]
            assert.is_true(reads > 0)
            assert.are.equal(4, fourth.x)
            json.close(first); json.close(fourth)
        end)
        io_source.read = original
        json.close(body)
        os.remove(filename)
        assert.is_true(ok, err)
    end)

    it("does not retain traversed child cells after the caller drops its views", function()
        local body
        do
            local pieces = {}
            for i = 1, 8192 do pieces[i] = '{"x":' .. i .. '}' end
            body = json.decode('[' .. table.concat(pieces, ',') .. ']', { index_budget_bytes = 0 })
        end
        collectgarbage("collect")
        local before = collectgarbage("count")
        for pass = 1, 2 do
            local sum = 0
            for _, child in json.ipairs(body) do sum = sum + child.x end
            assert.are.equal(33558528, sum)
            collectgarbage("collect"); collectgarbage("collect")
            assert.is_true(collectgarbage("count") - before < 512, "discarded views left a full sibling cache")
            assert.are.equal(0, json.source_stats(body).index_bytes)
        end
        json.close(body)
    end)

    it("preserves held children, forks and readers after materialization discards native indexes", function()
        local body = json.decode('[{"x":1},{"x":2},{"x":3},{"x":4}]')
        local held, branch = body[3], json.fork(body)
        local reader = json.reader(body, { normalize_duplicates = true, chunk_size = 1 })
        assert.is_true(json.source_stats(body).index_bytes > 0)
        assert.are.same({ { x = 1 }, { x = 2 }, { x = 3 }, { x = 4 } }, json.materialize(body))
        assert.are.equal(0, json.source_stats(body).index_bytes)
        json.array_remove(body, 1)
        held.x = 9
        assert.are.equal(9, body[2].x)
        assert.are.equal(3, branch[3].x)
        assert.are.equal('[{"x":1},{"x":2},{"x":3},{"x":4}]', drain(reader))
        json.close(body); json.close(branch); json.close(held)
    end)

    it("normalizes wide escaped duplicates across one-byte feed windows without expanding Lua members", function()
        local pieces, expected = {}, {}
        for i = 1, 96 do
            pieces[i] = '"k' .. i .. '":{"x":1,"x":2}'
            expected[i] = '"k' .. i .. '":' .. (i == 7 and 'false' or '{"x":2}')
        end
        local raw = '{' .. table.concat(pieces, ',') .. ',"\\u006b7":false}'
        expected = '{' .. table.concat(expected, ',') .. '}'
        for _, budget in ipairs({ 0, 64, 192 }) do
            local input = json.new_decoder({ chunk_size = 1, index_depth = 1, index_array_limit = 1, index_budget_bytes = budget })
            for i = 1, #raw do assert.is_true(input:feed(raw:sub(i, i))) end
            local body = assert(input:finish())
            input:close()
            assert.is_false(body.k7)
            local reader = json.reader(body, { normalize_duplicates = true, chunk_size = 1 })
            assert.are.equal(#expected, reader:length())
            assert.are.equal(expected, drain(reader))
            assert.is_true(json.source_stats(body).index_bytes <= budget)
            assert.is_nil(proxy.node(body).values)
            json.close(body)
        end
    end)

end)
