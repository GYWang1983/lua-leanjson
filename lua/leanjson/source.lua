-- Versioned input source. Rust owns metadata; Lua owns retained memory chunks
-- or a source fd, with one lease per consumer. Original files are never unlinked.
local ffi = require("ffi")
local C = require("leanjson.lib")
local io_source = require("leanjson.source_io")
local path = require("leanjson.path")
local proxy = require("leanjson.proxy")
local leases = require("leanjson.leases")
local options = require("leanjson.options").for_codec
local M = {}
local Backend = {}; Backend.__index = Backend
local Decoder = {}; Decoder.__index = Decoder
local READY, NEED_INPUT = 0, 2
local MAX_EXACT = 9007199254740991
local shared = require("leanjson.source_backend")
local loading = require("leanjson.loading")
local buffer = require("leanjson.source_buffer")
local exact, result_error, require_status = shared.exact, shared.result_error, shared.require_status
local native_options = shared.native_options
for _, name in ipairs({ "type", "span", "scalar", "scalar_chunks", "flags", "children", "lookup", "length", "identity", "clean", "stats", "lexical_length", "clear_indexes" }) do
    Backend[name] = shared[name]
end

local function close_state(state)
    if state.buffer then state.buffer:close() end
    if state.preloaded then
        for identity in pairs(state.preloaded) do state.preloaded[identity] = nil end
        state.preloaded = nil
    end
    if state.fd ~= nil then
        io_source.close(state.fd, state.path)
        state.fd, state.path = nil, nil
    end
    if state.source ~= nil then
        C.leanjson_source_v1_release(state.source)
        state.source = nil
    end
end

local function drop(state)
    state.leases = state.leases - 1
    if state.leases == 0 then close_state(state) end
end

local function release_lease(lease)
    if lease.released then return end
    lease.released = true
    drop(lease.state)
end
function Backend:retain()
    self:check_open()
    local state = self.state
    state.leases = state.leases + 1
    local lease = { state = state }
    -- Both explicit release and VM shutdown enter the same idempotent owner.
    -- The finalizer captures no token, backend, proxy or weak-table key.
    local token = ffi.gc(ffi.new("uint8_t[1]"), function() release_lease(lease) end)
    return { token = token, lease = lease }
end
function Backend:release(owner)
    if owner then ffi.gc(owner.token, nil); release_lease(owner.lease) end
end

function Backend:check_open()
    if self.state.source == nil then error("leanjson: source closed", 0) end
    if self.failure then error(self.failure, 0) end
end

function Backend:fail(message, detail)
    if not self.failure then
        self.failure = tostring(message)
        if self.state.source ~= nil then C.leanjson_source_v1_abort(self.state.source, detail or 1, nil) end
    end
    return self.failure
end

function Backend:notify(scope)
    if self.opts.on_chunk then
        local ok, err = pcall(self.opts.on_chunk, self.total)
        leases.check(scope)
        if not ok then error(self:fail(err, 2), 0) end
    end
end

function Backend:read(offset, length, scope)
    self:check_open()
    offset = exact(offset)
    length = math.min(length, self.opts.chunk_size)
    if offset < 0 or offset ~= math.floor(offset) or length < 1 or length ~= math.floor(length)
        or offset > MAX_EXACT - length then error("leanjson: invalid source read range", 0) end
    local lease = self:retain()
    local record = leases.track(scope, function() self:release(lease) end)
    local ok, chunk = pcall(function()
        local read_ok, value, err
        if self.buffered then read_ok, value = pcall(self.state.buffer.read, self.state.buffer, offset, length)
        else read_ok, value, err = pcall(io_source.read, self.state.fd, offset, length) end
        leases.check(scope)
        if not read_ok then error(self:fail(value), 0) end
        if type(value) ~= "string" then error(self:fail(err or "leanjson: source read failed"), 0) end
        if #value == 0 then error(self:fail("leanjson: unexpected source EOF"), 0) end
        if #value > length then error(self:fail("leanjson: source exceeded read bound"), 0) end
        self:notify(scope)
        return value
    end)
    leases.finish(scope, record)
    if not ok then error(chunk, 0) end
    return chunk
end

local function backend_new(fd, spool_path, opts, codec)
    local result = ffi.new("leanjson_source_v1_result[1]")
    local source = C.leanjson_source_v2_new(native_options(opts), result)
    if source == nil then
        if fd ~= nil then io_source.close(fd, spool_path) end
        error(result_error(result), 0)
    end
    local backend = setmetatable({ state = { fd = fd, path = spool_path, source = source, leases = 0 },
        total = 0, opts = opts, buffered = opts.file_in_memory }, Backend)
    if backend.buffered then backend.state.buffer = buffer.new() end
    local owner = backend:retain()
    local ok, builder = pcall(function()
        shared.configure_source(backend, codec)
        return loading.new(backend)
    end)
    if not ok then backend:release(owner); error(builder, 0) end
    backend.loading = builder
    return backend, owner
end

local function feed_bytes(backend, chunk, store, scope)
    if type(chunk) ~= "string" then error("leanjson: feed chunk must be a string", 0) end
    if #chunk > MAX_EXACT - backend.total then error("leanjson: source offset exceeds Lua exact integer range", 0) end
    local result, position = ffi.new("leanjson_source_v1_result[1]"), 0
    while position < #chunk do
        leases.check(scope)
        local count = math.min(#chunk - position, backend.opts.chunk_size)
        if store then
            if backend.buffered then backend.state.buffer:append(chunk, position, count)
            else
                local written, err = io_source.write(backend.state.fd, backend.total, chunk, position, count)
                if not written then error(backend:fail(err), 0) end
            end
        end
        require_status(C.leanjson_source_v1_feed(backend.state.source, backend.total,
            ffi.cast("const uint8_t *", chunk) + position, count, result), NEED_INPUT, result, backend.state.source)
        if backend.loading then backend.loading:drain() end
        backend.total, position = backend.total + count, position + count
        backend:notify(scope)
    end
end

local function finish_backend(backend)
    local result, root = ffi.new("leanjson_source_v1_result[1]"), ffi.new("leanjson_source_v2_node[1]")
    require_status(C.leanjson_source_v1_finish(backend.state.source, backend.total, result), READY, result, backend.state.source)
    if backend.loading then backend.loading:finish() end
    require_status(C.leanjson_source_v2_root(backend.state.source, root, result), READY, result)
    return require("leanjson.nodes").raw(backend, ffi.new("leanjson_source_v2_node", root[0]))
end

function M.decode_file(filename, opts, codec)
    opts = options(opts, codec)
    if type(filename) ~= "string" or filename:find("\0", 1, true) then error("leanjson: file path must be a string without NUL", 0) end
    local fd, open_error = io_source.open(filename)
    if fd == nil then error(open_error, 0) end
    local backend, owner = backend_new(fd, nil, opts, codec)
    local ok, value = pcall(function()
        while true do
            local chunk, err = io_source.read(fd, backend.total, opts.chunk_size)
            if type(chunk) ~= "string" then error(err or "leanjson: source read failed", 0) end
            if #chunk > opts.chunk_size then error("leanjson: source exceeded read bound", 0) end
            if #chunk == 0 then break end
            feed_bytes(backend, chunk, backend.buffered)
        end
        if backend.buffered then io_source.close(fd); backend.state.fd = nil end
        local node = finish_backend(backend)
        if not opts.lazyload then return backend.loading:take() end
        return proxy.from_backend(backend, node.handle, codec)
    end)
    backend:release(owner)
    if not ok then error(value, 0) end
    return value
end

function M.new_decoder(opts, codec)
    opts = options(opts, codec)
    local fd, spool_path
    if not opts.file_in_memory then
        fd, spool_path = io_source.spool(opts.temp_dir)
        if fd == nil then error(spool_path, 0) end
    end
    local backend, owner = backend_new(fd, spool_path, opts, codec)
    local scope = leases.acquire()
    scope.entries = { { backend, owner } }
    return setmetatable({ backend = backend, scope = scope, codec = codec }, Decoder)
end

function Decoder:close()
    leases.release(self.scope)
    self.closed, self.node = true, nil
    self.backend.loading = nil
end

function Decoder:fail(message)
    self.failure = self.failure or tostring(message)
    if not self.closed then self.backend:fail(self.failure, 2) end
    self:close()
    return nil, self.failure
end

function Decoder:feed(chunk)
    if self.failure then return nil, self.failure end
    if self.closed then return nil, "leanjson.decoder: closed for input" end
    if self.input_busy then return nil, "leanjson.decoder: input operation in progress" end
    if self.finished then return nil, "leanjson.decoder: closed for input" end
    local lease = self.backend:retain()
    local record = leases.track(self.scope, function() self.backend:release(lease) end)
    self.input_busy = true
    local ok, err = pcall(feed_bytes, self.backend, chunk, true, self.scope)
    self.input_busy = nil
    leases.finish(self.scope, record)
    if not ok then return self:fail(err) end
    return true
end

function Decoder:finish()
    if self.failure then return nil, self.failure end
    if self.closed then return nil, "leanjson.decoder: closed" end
    if self.input_busy then return nil, "leanjson.decoder: input operation in progress" end
    self.input_busy = true
    local ok, value = pcall(function()
        leases.check(self.scope)
        local was_finished = self.finished
        if not was_finished then self.node = finish_backend(self.backend) end
        local completed
        if self.backend.opts.lazyload then completed = path.from_node(self.node, {}, self.scope, self.codec, self.backend.opts.proxy_mode)
        elseif was_finished then completed = loading.rebuild(self.backend, self.node.handle, self.scope)
        else completed = self.backend.loading:take() end
        self.finished = true
        return completed
    end)
    self.input_busy = nil
    if not ok then return self:fail(value) end
    return value
end

function Decoder:get(query)
    if self.failure then return nil, "ERROR", self.failure end
    if self.closed then return nil, "ERROR", "leanjson.decoder: closed" end
    local ok, segments = pcall(path.parse, query)
    if not ok then return nil, "ERROR", tostring(segments) end
    local usable, source_error = pcall(leases.check, self.scope)
    if not usable then return nil, "ERROR", tostring(source_error) end
    if not self.finished then return nil, "NEED_INPUT" end
    local found, value = pcall(function()
        if self.backend.opts.lazyload then
            return path.from_node(self.node, segments, self.scope, self.codec, self.backend.opts.proxy_mode)
        end
        local node = self.node
        for _, segment in ipairs(segments) do
            if node.kind ~= segment.kind then error("leanjson.get: type mismatch", 0) end
            node = proxy.lookup(node, segment.key, self.scope)
            if node == nil then return nil end
        end
        if node.kind ~= "array" and node.kind ~= "object" then return proxy.scalar(node, self.scope) end
        return loading.rebuild(self.backend, node.handle, self.scope)
    end)
    if not found then return nil, "ERROR", tostring(value) end
    if type(value) == "nil" then return nil, "ABSENT" end
    return value, "READY"
end

function Decoder:abort(reason)
    if self.finished then return nil, "leanjson.decoder: cannot abort a finished decoder" end
    if self.closed then return nil, self.failure or "leanjson.decoder: closed" end
    self:fail(reason or "leanjson.decoder: aborted")
    return true
end

return M
