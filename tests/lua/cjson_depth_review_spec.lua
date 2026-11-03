local json = require('leanjson')
local proxy = require('leanjson.proxy')
local function nested(depth)
    local root = {}
    local current = root
    for _ = 2, depth do current[1] = {}; current = current[1] end
    current[1] = 0
    return root
end
local function collect(reader)
    local parts = {}
    while true do
        local chunk, err = reader:next()
        assert.is_nil(err)
        if chunk == nil then return table.concat(parts) end
        parts[#parts + 1] = chunk
    end
end

describe('depth review regressions', function()
    it('propagates the calling codec snapshot limit through fork, including safe codecs', function()
        local value, raw = nested(5000), string.rep('[',5000) .. '0' .. string.rep(']',5000)
        for _, c in ipairs({json.new(), require('leanjson.safe').new()}) do
            c.encode_max_depth(6000)
            local branch = c.fork(value)
            assert.equal(raw, c.encode(branch))
            local low = json.new(); low.encode_max_depth(2)
            local low_branch = low.fork(branch)
            assert.has_error(function() low.encode(low_branch) end, 'Cannot serialise, excessive nesting (3)')
            c.close(low_branch); c.close(branch)
        end
    end)

    it('enforces low fork limits while accepting exact container boundaries', function()
        local c = json.new(); c.encode_max_depth(2)
        local branch = c.fork(nested(2))
        assert.equal('[[0]]', c.encode(branch)); c.close(branch)
        assert.has_error(function() c.fork(nested(3)) end, 'Cannot serialise, excessive nesting (3)')
    end)

    it('preserves the empty_array sentinel exception through reader, fork and overlay snapshots', function()
        local c = json.new(); c.encode_max_depth(1)
        local value = {c.empty_array}
        assert.equal('[[]]', c.encode(value))
        local reader = c.reader(value, {chunk_size=1})
        assert.equal(4, reader:length()); assert.equal('[[]]', collect(reader))
        local branch = c.fork(value)
        assert.equal('[[]]', c.encode(branch)); c.close(branch)
        local body = c.decode('[0]')
        body[1] = c.empty_array
        assert.equal('[[]]', c.encode(body))
        assert.equal('[[]]', collect(c.reader(body, {chunk_size=1})))
        local held = body[1]
        local holder = {held}
        assert.equal('[[]]', c.encode(holder))
        held[1] = 0
        assert.has_error(function() c.encode(body) end, 'Cannot serialise, excessive nesting (2)')
        c.close(held); c.close(body)
    end)

    it('continues counting actual source arrays and actual Lua tables as containers', function()
        local c = json.new(); c.encode_max_depth(1)
        local source = c.decode('[]')
        for _, child in ipairs({source, {}, setmetatable({},c.array_mt)}) do
            local reader = c.reader({child})
            local length, err = reader:length()
            assert.is_nil(length); assert.equal('Cannot serialise, excessive nesting (2)', err)
            reader:close()
        end
        c.close(source)
    end)

    it('stops a raw-depth scan immediately when a yielding read is closed', function()
        for _, method in ipairs({'next','length'}) do
            local c = json.new(); c.encode_max_depth(3)
            local backend, root = require('leanjson.source_memory').open('{"x":[]}')
            local original, reads = backend.read, 0
            function backend:read(offset, length, scope)
                reads = reads + 1
                coroutine.yield('scan read pending')
                return original(self, offset, length, scope)
            end
            local body = proxy.from_backend(backend, root)
            local reader = c.reader(body, {chunk_size=1})
            local co = coroutine.create(function() return reader[method](reader) end)
            local ok, pending = coroutine.resume(co)
            assert.is_true(ok); assert.equal('scan read pending', pending)
            assert.equal(1, reads)
            reader:close()
            local resumed, result, err = coroutine.resume(co)
            assert.is_true(resumed); assert.is_nil(result)
            assert.equal('leanjson.reader: closed', err)
            assert.equal(1, reads)
            assert.equal('dead', coroutine.status(co))
            c.close(body)
        end
    end)

    it('renders standalone sentinel key errors as native userdata without cjson', function()
        local interpreter = os.getenv('LUAJIT_BIN') or os.getenv('LUAJIT')
            or (arg and type(arg[-1]) == 'string' and not arg[-1]:match('^%-') and arg[-1]) or 'luajit'
        local quoted = "'" .. interpreter:gsub("'", "'\\''") .. "'"
        local status = os.execute(quoted .. ' tests/lua/fixtures/sentinel_key_errors.lua')
        assert.is_true(status == 0 or status == true, 'standalone sentinel key diagnostic mismatch')
    end)
end)
