local json = require("leanjson")
local source_io = require("leanjson.source_io")

describe("source index and scan-time schema options", function()
    local filenames, roots
    before_each(function() filenames, roots = {}, {} end)
    after_each(function()
        for _, root in ipairs(roots) do json.close(root) end
        for _, filename in ipairs(filenames) do os.remove(filename) end
    end)

    local function decode(mode, raw, opts)
        local root
        if mode == "memory" then root = json.decode(raw, opts)
        elseif mode == "file" then
            local filename = os.tmpname()
            filenames[#filenames + 1] = filename
            local file = assert(io.open(filename, "wb"))
            assert(file:write(raw)); assert(file:close())
            root = json.decode_file(filename, opts)
        else
            local decoder = json.new_decoder(opts)
            local ok, value = pcall(function()
                for first = 1, #raw, 17 do assert(decoder:feed(raw:sub(first, first + 16))) end
                local value, err = decoder:finish()
                assert(not err, err)
                return value
            end)
            decoder:close()
            assert(ok, value)
            root = value
        end
        roots[#roots + 1] = root
        return root
    end

    for _, mode in ipairs({ "memory", "file", "feed" }) do
        it("can disable structural metadata without changing " .. mode .. " results", function()
            local raw = '{"a":{"text":"' .. string.rep("x", 4096) .. '","n":7},"a":{"n":9,"text":"last"}}'
            local enabled = decode(mode, raw, { chunk_size = 19 })
            local disabled = decode(mode, raw, { structural_index = false, chunk_size = 19 })
            assert.is_true(json.source_stats(enabled).structural_index_bytes > 0)
            assert.are.equal(0, json.source_stats(disabled).structural_index_bytes)
            assert.are.equal(9, enabled.a.n)
            assert.are.equal(9, disabled.a.n)
            assert.are.equal("last", disabled.a.text)
        end)

        it("validates a reusable schema before publishing " .. mode .. " values", function()
            local plan = json.compile_schema({type = "object", required = {"a"}, properties = {
                a = {type = "object", required = {"n"}, properties = {n = {type = "integer", minimum = 2}}},
            }})
            local accepted = decode(mode, '{"a":{"n":1},"a":{"n":3}}', {schema = plan, structural_index = false})
            assert.are.equal(3, accepted.a.n)
            local ok, err = pcall(decode, mode, '{"a":{"n":3},"a":{"n":1}}', {schema = plan})
            assert.is_false(ok)
            assert.is_true(tostring(err):lower():find("schema", 1, true) ~= nil)
            assert.has_error(function() decode(mode, '{}', {schema = false}) end)
            local permissive = decode(mode, '{}', {schema = true})
            assert.are.equal("object", json.type(permissive))
        end)
    end

    it("rejects a non-boolean structural option", function()
        assert.has_error(function() json.decode('{}', {structural_index = "false"}) end)
        assert.has_error(function() json.new_decoder({structural_index = 1}) end)
        local safe = require("leanjson.safe")
        assert.has_error(function() safe.decode('{}', {structural_index = "true"}) end)
    end)

    it("reuses complete path and absent-key results across source forks", function()
        local raw = '{"unused":"' .. string.rep("x", 131072) .. '","a":{"b":{"value":1}}}'
        local root = decode("file", raw, {file_in_memory = false, structural_index = false, index_depth = 0,
            index_array_limit = 0, index_budget_bytes = 65536, chunk_size = 4096})
        local original_read, bytes = source_io.read, 0
        source_io.read = function(...)
            local value, err = original_read(...)
            if value then bytes = bytes + #value end
            return value, err
        end
        local ok, err = pcall(function()
            assert.is_false(json.exists(root, "a.b.absent"))
            local first = bytes
            assert.is_true(first > 0)
            assert.is_false(json.exists(root, "a.b.absent"))
            assert.are.equal(first, bytes)
            local fork = json.fork(root); roots[#roots + 1] = fork
            assert.is_false(json.exists(fork, "a.b.absent"))
            assert.are.equal(first, bytes)
            local a = fork.a; local b = a.b
            b.absent = true
            json.close(b); json.close(a)
            assert.is_true(json.exists(fork, "a.b.absent"))
            assert.is_false(json.exists(root, "a.b.absent"))
            local stats = json.source_stats(root)
            assert.is_true(stats.lookup_cache_bytes > 0)
            assert.is_true(stats.lookup_cache_hits > 0)
            assert.is_true(stats.index_bytes <= stats.budget_bytes)
        end)
        source_io.read = original_read
        assert(ok, err)
    end)

    it("exposes schema compilation on independent and protected codecs", function()
        for _, codec in ipairs({json.new(), require("leanjson.safe").new()}) do
            local plan = codec.compile_schema({type = "integer", minimum = 4})
            assert.are.equal(7, codec.decode('7', {schema = plan}))
            local ok, value = pcall(codec.decode, '3', {schema = plan})
            assert.is_true(not ok or value == nil)
        end
    end)

    it("retains native validation after the Lua plan wrapper is collected", function()
        local weak = setmetatable({}, {__mode = "v"})
        local decoder
        do
            local plan = json.compile_schema({type = "integer", minimum = 4})
            weak[1] = plan
            decoder = json.new_decoder({schema = plan})
        end
        collectgarbage("collect"); collectgarbage("collect")
        local released = weak[1] == nil
        local fed, feed_error = decoder:feed('3')
        local value, failure = decoder:finish()
        decoder:close()
        assert.is_true(released, "decoder unnecessarily pinned the Lua schema wrapper")
        assert.is_true(fed, feed_error)
        assert.is_nil(value)
        assert.is_not_nil(failure)
    end)
end)
