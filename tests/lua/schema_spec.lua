local json = require('leanjson')
local schema = require('leanjson.schema')

describe('compiled native schemas', function()
    it('compiles reusable opaque plans and rejects unsupported assertions', function()
        local plan = schema.compile({type='object', required={'n'}, properties={n={type='integer'}}}, json)
        assert.are.equal(plan, schema.compile(plan, json))
        assert.is_not_nil(schema.pointer(plan))
        assert.has_error(function() schema.compile({unevaluatedProperties=false}, json) end)
        assert.has_error(function() schema.compile({['x-gateway-image-size']={}}, json) end)
        assert.has_error(function() schema.compile({format='custom'}, json) end)
        assert.is_nil(schema.pointer({}))
        assert.is_not_nil(schema.compile(false, json))
        assert.is_not_nil(schema.compile({}, json))
    end)
end)

describe('compiled schema lifecycle and schema serialization', function()
    it('keeps an attached plan alive after callers collect its wrapper', function()
        local decoder
        do
            local plan = json.compile_schema({type='object', properties={n={type='integer', minimum=2}}})
            decoder = json.new_decoder({schema=plan})
        end
        collectgarbage('collect'); collectgarbage('collect')
        assert.is_true(decoder:feed('{"n":'))
        assert.is_true(decoder:feed('3}'))
        local root, err = decoder:finish()
        assert.is_nil(err)
        assert.are.equal(3, root.n)
        json.close(root); decoder:close()
    end)

    it('reuses a plan across rejected and accepted documents', function()
        local plan = json.compile_schema({type='integer', minimum=2})
        for _ = 1, 5 do
            assert.has_error(function() json.decode('1', {schema=plan}) end)
            assert.are.equal(3, json.decode('3', {schema=plan}))
        end
        assert.has_error(function() json.decode('{}', {schema=json.compile_schema(false)}) end)
        assert.is_false(schema.is_compiled(newproxy(true)))
        assert.has_error(function() json.decode('{}', {schema=newproxy(true)}) end)
    end)

    it('serializes assertions independently of application encoder settings', function()
        local codec = json.new()
        codec.encode_number_precision(1)
        codec.encode_skip_unsupported_value_types(true)
        local plan = codec.compile_schema({maximum=9007199254740992})
        assert.has_error(function() codec.decode('9007199254740993', {schema=plan}) end)
        assert.are.equal(9007199254740992, codec.decode('9007199254740992', {schema=plan}))
        local tenths = codec.compile_schema({multipleOf=0.1})
        assert.are.equal(0.3, codec.decode('0.3', {schema=tenths}))
        assert.has_error(function() codec.decode('0.30000000000000001', {schema=tenths}) end)
        assert.has_error(function() codec.compile_schema({minimum=function() end}) end)
        local recursive = {}; recursive.properties={x=recursive}
        assert.has_error(function() codec.compile_schema(recursive) end)
    end)

    it('closes and removes spool files after schema rejection', function()
        local io_source = require('leanjson.source_io')
        local old_spool, old_close = io_source.spool, io_source.close
        local created, closed = {}, {}
        io_source.spool = function(...)
            local fd, path = old_spool(...)
            if fd then created[path] = true end
            return fd, path
        end
        io_source.close = function(fd, path)
            if path and created[path] then closed[path] = true end
            return old_close(fd, path)
        end
        local ok, err = pcall(function()
            for _ = 1, 3 do
                local decoder = json.new_decoder({schema=false})
                assert.is_true(decoder:feed('{}'))
                local root, failure = decoder:finish()
                assert.is_nil(root)
                assert.is_not_nil(failure)
                decoder:close()
            end
            for path in pairs(created) do
                assert.is_true(closed[path])
                local file = io.open(path, 'rb')
                if file then file:close() end
                assert.is_nil(file)
            end
        end)
        io_source.spool, io_source.close = old_spool, old_close
        assert(ok, err)
    end)
end)

describe('schema object keys', function()
    it('rejects invalid UTF-8 instead of aliasing the empty property name', function()
        local raw = '{"' .. string.char(255) .. '":1}'
        local plain = json.decode(raw)
        assert.are.equal(1, plain[string.char(255)])
        json.close(plain)
        local plan = json.compile_schema({type='object', additionalProperties=false, properties={['']={const=1}}})
        assert.has_error(function() json.decode(raw, {schema=plan}) end)
    end)
end)

describe('schema literal object identity', function()
    it('keeps serde-private-looking keys as ordinary legal data', function()
        local plan=json.compile_schema({const={['$serde_json::private::Number']='123'}})
        assert.has_error(function() json.decode('123',{schema=plan}) end)
        local value=json.decode('{"$serde_json::private::Number":"123"}',{schema=plan})
        assert.are.equal('123',value['$serde_json::private::Number'])
        json.close(value)
    end)
end)
