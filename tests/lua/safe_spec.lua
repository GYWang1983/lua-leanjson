local json = require("leanjson")
local proxy = require("leanjson.proxy")
local io_source = require("leanjson.source_io")
local function pack(...) return { n = select("#", ...), ... } end
local function safe()
    local ok, module = pcall(require, "leanjson.safe")
    assert.is_true(ok, tostring(module))
    return module.new()
end
local function error_pair(...)
    local result = pack(...)
    assert.equal(2, result.n)
    assert.is_nil(result[1])
    assert.is_string(result[2])
    return result[2]
end

describe("safe codec", function()
    local files, opened, original
    local function fixture(raw)
        local path = os.tmpname()
        files[#files + 1] = path
        local f = assert(io.open(path, "wb"))
        assert(f:write(raw)); assert(f:close())
        return path
    end
    local function load(codec, source, raw, opts)
        if source == "memory" then return codec.decode(raw, opts) end
        if source == "file" then return codec.decode_file(fixture(raw), opts) end
        local decoder, err = codec.new_decoder(opts)
        assert.is_nil(err)
        for i = 1, #raw, 3 do
            local ok, feed_error = decoder:feed(raw:sub(i, i + 2))
            if not ok then decoder:close(); return nil, feed_error end
        end
        local value, finish_error = decoder:finish()
        decoder:close()
        if finish_error then return nil, finish_error end
        return value
    end
    before_each(function()
        files, opened, original = {}, {}, {}
        for _, key in ipairs({ "open", "spool", "close" }) do original[key] = io_source[key] end
        for _, key in ipairs({ "open", "spool" }) do
            io_source[key] = function(...)
                local fd, extra = original[key](...)
                if fd then opened[fd] = key == "spool" and extra or true end
                return fd, extra
            end
        end
        io_source.close = function(fd, path)
            opened[fd] = nil
            return original.close(fd, path)
        end
    end)
    after_each(function()
        local leaked = next(opened) ~= nil
        for fd, path in pairs(opened) do original.close(fd, type(path) == "string" and path or nil) end
        for key, fn in pairs(original) do io_source[key] = fn end
        for _, path in ipairs(files) do os.remove(path) end
        assert.is_false(leaked, "source descriptors must close without forcing GC")
    end)

    it("preserves single success results including false and null", function()
        local s = safe()
        for _, row in ipairs({ { "false", false }, { "true", true }, { "null", json.null }, { "123", 123 } }) do
            local result = pack(s.decode(row[1]))
            assert.equal(1, result.n)
            assert.equal(row[2], result[1])
            local encoded = pack(s.encode(result[1]))
            assert.equal(1, encoded.n)
            assert.equal(row[1], encoded[1])
        end
        assert.equal(123, s.decode(123))
        assert.equal("null", s.encode(nil))
    end)

    it("returns exactly two values for conversion and input type failures", function()
        local s = safe()
        error_pair(s.decode("Oops"))
        error_pair(s.decode(nil))
        error_pair(s.decode(false))
        error_pair(s.decode({}))
        error_pair(s.encode(function() end))
        error_pair(s.encode(math.huge))
        local circular = {}; circular.self = circular
        error_pair(s.encode(circular))
        error_pair(s.encode({ [100] = true }))
        assert.equal("true", s.encode(true))
        assert.has_error(function() json.decode("Oops") end)
        assert.has_error(function() json.encode(function() end) end)
    end)

    it("throws arity and configuration errors rather than returning them", function()
        local s = safe()
        for _, call in ipairs({
            function() s.encode() end,
            function() s.encode(true, nil) end,
            function() s.decode() end,
            function() s.decode("1", nil, nil) end,
            function() s.decode_file() end,
            function() s.decode_file("file", nil, nil) end,
            function() s.new_decoder(nil, nil) end,
            function() s.encode_number_precision(0) end,
            function() s.encode_sparse_array(false, -1) end,
        }) do assert.has_error(call) end
        assert.equal(14, s.encode_number_precision())
        assert.same({ false, 2, 10 }, { s.encode_sparse_array() })
        assert.equal(1, s.decode("1", nil))
    end)

    it("validates options before opening any source", function()
        local s = safe()
        local path = fixture("true")
        for _, opts in ipairs({ false, { lazyload = "no" }, { chunk_size = 0 }, { preload_paths = { "$..bad" } } }) do
            assert.has_error(function() s.decode("true", opts) end)
            assert.has_error(function() s.decode_file(path, opts) end)
            assert.has_error(function() s.new_decoder(opts) end)
            assert.is_nil(next(opened))
        end
    end)

    it("isolates safe default, safe instances and ordinary codecs", function()
        local a, b = safe(), safe()
        local default = require("leanjson.safe")
        local previous = default.encode_number_precision()
        default.encode_number_precision(4)
        a.encode_number_precision(3)
        a.encode_sparse_array(true)
        local ordinary = json.new()
        local child = a.new("ignored")
        assert.equal(14, b.encode_number_precision())
        assert.equal(14, ordinary.encode_number_precision())
        assert.equal(14, child.encode_number_precision())
        assert.equal("0.3333", default.encode(1 / 3))
        assert.equal("0.333", a.encode(1 / 3))
        error_pair(child.encode({ [100] = 1 }))
        error_pair(b.decode("Oops"))
        assert.is_true(rawequal(a.null, ordinary.null))
        assert.is_true(rawequal(a.empty_array_mt, ordinary.empty_array_mt))
        assert.equal("[]", child.encode(setmetatable({}, a.empty_array_mt)))
        default.encode_number_precision(previous)
    end)

    it("returns construction failures and releases failed files and spools", function()
        local s = safe()
        local missing = fixture("true") .. "/absent"
        error_pair(s.decode_file(missing))
        error_pair(s.new_decoder({ temp_dir = missing }))
        error_pair(s.decode_file(fixture("{bad")))
        error_pair(s.decode_file(fixture("true"), { on_chunk = function() error("callback failed") end }))
        local d = assert(s.new_decoder())
        local spool = opened[d.backend.state.fd]
        error_pair(d:feed("{bad"))
        assert.is_nil(io.open(spool, "rb"))
        assert.is_nil(next(opened))
        d = assert(s.new_decoder())
        assert(d:feed('{"unfinished":'))
        error_pair(d:finish())
        assert.is_nil(next(opened))
        d = assert(s.new_decoder({ on_chunk = function() error("feed callback failed") end }))
        error_pair(d:feed("true"))
        assert.is_nil(next(opened))
    end)

    it("keeps incremental statuses and explicit cleanup after valid null and false", function()
        local s = safe()
        for _, raw in ipairs({ "false", "null" }) do
            local d = assert(s.new_decoder())
            local value, state = d:get("$")
            assert.is_nil(value); assert.equal("NEED_INPUT", state)
            assert(d:feed(raw))
            local result = pack(d:finish())
            assert.equal(1, result.n)
            if raw == "false" then assert.is_false(result[1])
            else assert.equal(s.null, result[1]) end
            d:close()
        end
    end)

    it("protects encode failures without changing delayed proxy and reader errors", function()
        local s = safe()
        local path = fixture('{"text":"read later"}')
        local value = assert(s.decode_file(path))
        local f = assert(io.open(path, "wb")); f:close()
        assert.has_error(function() return value.text end)
        error_pair(s.encode(value))
        local reader = s.reader(value)
        error_pair(reader:next())
        s.close(value)
        assert.is_nil(next(opened))
    end)

    for _, source in ipairs({ "memory", "file", "feed" }) do
        for _, mode in ipairs({ "lazy", "eager", "preload" }) do
            it("preserves safe " .. source .. "/" .. mode .. " conversions and resource ownership", function()
                local s = safe()
                s.encode_number_precision(3)
                local opts = { lazyload = mode ~= "eager" }
                if mode == "preload" then
                    opts.preload_paths = { "$.child.n" }
                    opts.index_depth, opts.index_array_limit, opts.index_budget_bytes = 0, 0, 0
                end
                local value = assert(load(s, source, '{"child":{"n":0},"keep":"raw"}', opts))
                assert.equal(mode ~= "eager", proxy.is_proxy(value))
                value.child.n = 1 / 3
                assert.equal("raw", value.keep)
                assert.equal("0.333", s.encode(value):match('"n":([^,}]+)'))
                local fork = s.fork(value)
                local reader = s.reader(fork, { chunk_size = 4 })
                s.close(fork); s.close(value.child); s.close(value)
                local chunks = {}
                while true do
                    local chunk, err = reader:next()
                    assert.is_nil(err)
                    if not chunk then break end
                    chunks[#chunks + 1] = chunk
                end
                assert.matches('"keep":"raw"', table.concat(chunks), 1, true)
                error_pair(load(s, source, '{"bad":', opts))
                assert.is_nil(next(opened))
            end)
        end
    end
end)
