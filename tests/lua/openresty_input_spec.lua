local json = require("leanjson")
local io_source = require("leanjson.source_io")
local proxy = require("leanjson.proxy")

describe("socket-first OpenResty input", function()
    local saved_ngx, saved_adapter, saved_semaphore, original_spool, adapter, fake, raw, calls, filename, held
    before_each(function()
        saved_ngx, saved_adapter, saved_semaphore = rawget(_G, "ngx"), package.loaded["leanjson.openresty"], package.loaded["ngx.semaphore"]
        original_spool, held = io_source.spool, {}
        raw, calls = '{"prompt":"hello\\nworld","model":"public"}', {socket = 0, completed = 0, read = 0}
        fake = {ctx = {}, version = 1.1, headers = {}, buffered = false}
        fake.req = {
            get_headers = function() return fake.headers end,
            http_version = function() return fake.version end,
            read_body = function() calls.completed = calls.completed + 1; fake.buffered = true end,
            get_body_data = function() if fake.buffered and not filename then return raw end end,
            get_body_file = function() if fake.buffered then return filename end end,
            socket = function()
                calls.socket = calls.socket + 1
                local first = 1
                return {
                    settimeout = function() end,
                    receive = function(_, size)
                        calls.read = calls.read + 1
                        if fake.receive_error then return nil, "client closed" end
                        local bytes = raw:sub(first, first + size - 1); first = first + #bytes
                        return bytes
                    end,
                }
            end,
        }
        fake.on_abort = function(fn) fake.abort = fn; return true end
        fake.sleep = function() end
        fake.log = function() end
        fake.thread = {
            spawn = function(fn)
                local co = coroutine.create(fn); assert(coroutine.resume(co)); return co
            end,
            kill = function() return true end,
        }
        package.loaded["ngx.semaphore"] = {new = function() return {post = function() end, wait = function() error("producer not finished") end} end}
        rawset(_G, "ngx", fake)
        package.loaded["leanjson.openresty"] = nil
        adapter = require("leanjson.openresty")
    end)
    after_each(function()
        for _, value in ipairs(held) do json.close(value) end
        io_source.spool = original_spool
        rawset(_G, "ngx", saved_ngx)
        package.loaded["leanjson.openresty"], package.loaded["ngx.semaphore"] = saved_adapter, saved_semaphore
        if filename then os.remove(filename); filename = nil end
    end)
    local function receive(opts)
        fake.headers["content-length"] = tostring(#raw)
        local body, err, info = adapter.read_body(opts)
        if body ~= nil then held[#held + 1] = body end
        return body, err, info
    end
    it("makes read_body scan socket chunks without completed buffering or a source spool", function()
        io_source.spool = function() error("socket memory input created a spool") end
        local body, err, info = receive({chunk_size = 2})
        assert.is_nil(err); assert.are.equal("hello\nworld", body.prompt)
        assert.are.equal("incremental", info.mode); assert.are.equal("memory", info.storage)
        assert.are.equal(1, calls.socket); assert.are.equal(0, calls.completed)
        assert.is_true(calls.read > 1)
        local second, failure = adapter.read_body()
        assert.is_nil(second); assert.matches("already owned", failure, 1, true)
    end)
    for _, fallback in ipairs({"http-version", "transfer-encoding", "content-length", "body-buffered"}) do
        it("falls back safely for " .. fallback, function()
            fake.headers["content-length"] = tostring(#raw)
            if fallback == "http-version" then fake.version = 2
            elseif fallback == "transfer-encoding" then fake.headers["transfer-encoding"] = "chunked"
            elseif fallback == "content-length" then fake.headers["content-length"] = nil
            else fake.buffered = true end
            local body, err, info = adapter.read_body()
            if body then held[#held + 1] = body end
            assert.is_nil(err); assert.are.equal("public", body.model)
            assert.are.equal(fallback, info.fallback)
            assert.are.equal("completed-memory", info.mode); assert.are.equal("memory", info.storage)
            assert.are.equal(0, calls.socket)
        end)
    end
    it("loads a completed file into memory and honors a top-level file override", function()
        filename = os.tmpname()
        local output = assert(io.open(filename, "wb")); assert(output:write(raw)); assert(output:close())
        fake.buffered = true
        local body, err, info = receive({file_in_memory = true, decode = {file_in_memory = false}})
        assert.is_nil(err); assert.are.equal("completed-file", info.mode)
        assert.are.equal("memory", info.storage)
        local input = assert(io.open(filename, "wb")); input:close()
        assert.are.equal("hello\nworld", body.prompt)
    end)
    it("creates an explicit disk spool and returns an independently owned body", function()
        local creates = 0
        io_source.spool = function(...) creates = creates + 1; return original_spool(...) end
        local body, err, info = receive({file_in_memory = false})
        assert.is_nil(err); assert.are.equal(1, creates); assert.are.equal("file", info.storage)
        local backend = proxy.node(body).backend
        assert.is_true(backend.state.fd ~= nil)
        assert.are.equal("hello\nworld", body.prompt)
        fake.abort()
        assert.has_error(function() return body.prompt end)
        assert.is_nil(backend.state.fd)
    end)
    it("does not replay a failed socket receive through completed input", function()
        fake.receive_error = true
        local body, err = receive()
        assert.is_nil(body); assert.matches("client closed", err, 1, true)
        assert.are.equal(1, calls.socket); assert.are.equal(0, calls.completed)
    end)
    it("reports JSON errors and valid false roots distinctly", function()
        raw = '{"broken":'
        local body, err = receive()
        assert.is_nil(body); assert.is_string(err); assert.are.equal(0, calls.completed)
        fake.ctx, raw = {}, 'false'
        body, err = receive()
        assert.is_nil(err); assert.is_false(body)
    end)
    it("validates file storage options before consuming the body", function()
        assert.has_error(function() receive({file_in_memory = "yes"}) end)
        assert.has_error(function() receive({decode = {file_in_memory = 1}, file_in_memory = true}) end)
        assert.are.equal(0, calls.socket); assert.are.equal(0, calls.completed)
    end)
end)
