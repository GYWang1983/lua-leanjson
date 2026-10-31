-- Versioned file/window source. Rust owns only metadata; Lua owns the fd and
-- one lease for every independent consumer. No original file is ever unlinked.
local ffi = require("ffi")
local C = require("qjson.lib")
local io_source = require("qjson.source_io")
local path = require("qjson.path")
local proxy = require("qjson.proxy")
local leases = require("qjson.leases")
local M = {}
local Backend = {}; Backend.__index = Backend
local Decoder = {}; Decoder.__index = Decoder
local READY, DONE, NEED_INPUT, NEED_READ, ERROR = 0, 1, 2, 3, 5
local MAX_EXACT = 9007199254740991
local kinds = { [0] = "null", "boolean", "number", "string", "array", "object" }
local U64_MAX = ffi.cast("uint64_t", -1)
local details = { "source I/O error", "source aborted", "source closed", "invalid source window",
    "invalid source offset", "invalid source options" }

local function integer(value, name, default, minimum, maximum)
    if value == nil then return default end
    if type(value) ~= "number" or value < minimum or value > maximum or value ~= math.floor(value) then
        error("qjson: " .. name .. " must be an integer between " .. minimum .. " and " .. maximum, 0)
    end
    return value
end

local function options(opts)
    if opts == nil then opts = {} end
    if type(opts) ~= "table" then error("qjson: source opts must be a table", 0) end
    if opts.lazy ~= nil and type(opts.lazy) ~= "boolean" then error("qjson: opts.lazy must be a boolean", 0) end
    if opts.lazy then error("qjson: source v1 supports eager validation only", 0) end
    if opts.on_chunk ~= nil and type(opts.on_chunk) ~= "function" then error("qjson: opts.on_chunk must be a function", 0) end
    if opts.temp_dir ~= nil and (type(opts.temp_dir) ~= "string" or opts.temp_dir == "" or opts.temp_dir:find("\0", 1, true)) then
        error("qjson: opts.temp_dir must be a nonempty path", 0)
    end
    return {
        chunk_size = integer(opts.chunk_size, "chunk_size", 65536, 1, 4294967295),
        max_depth = integer(opts.max_depth, "max_depth", 0, 0, 4294967295),
        on_chunk = opts.on_chunk,
        temp_dir = opts.temp_dir or os.getenv("TMPDIR") or "/tmp",
    }
end

local function exact(value)
    if value > MAX_EXACT then error("qjson: source offset exceeds Lua exact integer range", 0) end
    return tonumber(value)
end

local function result_error(result)
    local r = result[0]
    local message
    if r.detail ~= 0 then message = details[tonumber(r.detail)] or "source error"
    else message = ffi.string(C.qjson_strerror(r.code)) end
    if r.offset ~= U64_MAX then message = message .. " at byte " .. tostring(exact(r.offset)) end
    return "qjson: " .. message
end

local function require_status(status, expected, result)
    if status ~= expected then
        if status == ERROR then error(result_error(result), 0) end
        error("qjson: unexpected source status " .. status, 0)
    end
end

local function close_state(state)
    if state.fd ~= nil then
        io_source.close(state.fd, state.path)
        state.fd, state.path = nil, nil
    end
    if state.source ~= nil then
        C.qjson_source_v1_release(state.source)
        state.source = nil
    end
end

local function drop(state)
    state.leases = state.leases - 1
    if state.leases == 0 then close_state(state) end
end

function Backend:retain()
    self:check_open()
    local state = self.state
    state.leases = state.leases + 1
    -- The finalizer closes over resource state only, never this token, backend,
    -- proxy or weak-table key. An explicit release removes the fallback first.
    return ffi.gc(ffi.new("uint8_t[1]"), function() drop(state) end)
end

function Backend:release(token)
    if token then ffi.gc(token, nil); drop(self.state) end
end

function Backend:check_open()
    if self.state.fd == nil then error("qjson: source closed", 0) end
    if self.failure then error(self.failure, 0) end
end

function Backend:fail(message, detail)
    if not self.failure then
        self.failure = tostring(message)
        if self.state.source ~= nil then C.qjson_source_v1_abort(self.state.source, detail or 1, nil) end
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
        or offset > MAX_EXACT - length then error("qjson: invalid source read range", 0) end
    local lease = self:retain()
    local record = leases.track(scope, function() self:release(lease) end)
    local ok, chunk = pcall(function()
        local read_ok, value, err = pcall(io_source.read, self.state.fd, offset, length)
        leases.check(scope)
        if not read_ok then error(self:fail(value), 0) end
        if type(value) ~= "string" then error(self:fail(err or "qjson: source read failed"), 0) end
        if #value == 0 then error(self:fail("qjson: unexpected source EOF"), 0) end
        if #value > length then error(self:fail("qjson: source exceeded read bound"), 0) end
        self:notify(scope)
        return value
    end)
    leases.finish(scope, record)
    if not ok then error(chunk, 0) end
    return chunk
end

local function info(self, handle)
    self:check_open()
    local out, result = ffi.new("qjson_source_v1_node_info[1]"), ffi.new("qjson_source_v1_result[1]")
    require_status(C.qjson_source_v1_node_get_info(handle, out, result), READY, result)
    return out[0]
end

function Backend:type(handle) return kinds[tonumber(info(self, handle).kind)] end
function Backend:span(handle)
    local value = info(self, handle)
    return exact(value.raw_start), exact(value.raw_end)
end

local function scalar_bytes(self, handle, base, scope)
    leases.check(scope)
    local lease = self:retain()
    local out, result = ffi.new("qjson_source_v1_op *[1]"), ffi.new("qjson_source_v1_result[1]")
    local status = C.qjson_source_v1_node_scalar_begin(handle, out, result)
    if status == ERROR then self:release(lease); error(result_error(result), 0) end
    local operation = ffi.gc(out[0], C.qjson_source_v1_op_release)
    local record = leases.track(scope, function()
        if operation then ffi.gc(operation, nil); C.qjson_source_v1_op_release(operation); operation = nil end
        self:release(lease)
    end)
    local ok, value = pcall(function()
        local parts, ptr, size = {}, ffi.new("const uint8_t *[1]"), ffi.new("size_t[1]")
        while status ~= DONE do
            leases.check(scope)
            if not operation then error("qjson: source operation closed", 0) end
            if status == NEED_READ then
                local offset, length = exact(result[0].offset), exact(result[0].length)
                local chunk = self:read((base or 0) + offset, length, scope)
                leases.check(scope)
                require_status(C.qjson_source_v1_provide_window(operation, offset, chunk, #chunk, result), READY, result)
            elseif status == READY then
                -- Copy before another operation step can invalidate the pointer.
                parts[#parts + 1] = ffi.string(ptr[0], size[0])
                self:notify(scope)
            else error(result_error(result), 0) end
            status = C.qjson_source_v1_op_step(operation, ptr, size, result)
        end
        return table.concat(parts)
    end)
    leases.finish(scope, record)
    if not ok then error(value, 0) end
    return value
end

function Backend:scalar(handle, scope)
    local ok, value = pcall(function()
        local kind = self:type(handle)
        local raw = scalar_bytes(self, handle, nil, scope)
        if kind == "string" then return raw end
        if kind == "boolean" then return raw == "true" end
        if kind == "null" then return nil end
        local number = tonumber(raw)
        if number == nil or number == math.huge or number == -math.huge then error("qjson: number out of range", 0) end
        return number
    end)
    if not ok then error(value, 0) end
    return value
end

local function native_options(opts)
    return ffi.new("qjson_source_v1_options[1]", { { 1, 0, opts.max_depth, opts.chunk_size } })
end

local function key_string(self, first, last, scope)
    -- Keys have spans rather than value-node handles. A temporary bounded
    -- source reuses the same Rust string validator/decoder without aggregating
    -- a raw quoted key or maintaining a second Lua escape implementation.
    local result = ffi.new("qjson_source_v1_result[1]")
    local source = C.qjson_source_v1_new(native_options(self.opts), result)
    if source == nil then error(result_error(result), 0) end
    source = ffi.gc(source, C.qjson_source_v1_release)
    local record = leases.track(scope, function()
        if source then ffi.gc(source, nil); C.qjson_source_v1_release(source); source = nil end
    end)
    local ok, value = pcall(function()
        local position = first
        while position < last do
            local chunk = self:read(position, math.min(last - position, self.opts.chunk_size), scope)
            leases.check(scope)
            require_status(C.qjson_source_v1_feed(source, position - first, chunk, #chunk, result), NEED_INPUT, result)
            position = position + #chunk
        end
        require_status(C.qjson_source_v1_finish(source, last - first, result), READY, result)
        local root = ffi.new("qjson_source_v1_node[1]")
        require_status(C.qjson_source_v1_root(source, root, result), READY, result)
        return scalar_bytes(self, root[0], first, scope)
    end)
    leases.finish(scope, record)
    if not ok then error(value, 0) end
    return value
end

function Backend:children(handle, scope)
    local kind = self:type(handle)
    local lease = self:retain()
    local out, result = ffi.new("qjson_source_v1_iter *[1]"), ffi.new("qjson_source_v1_result[1]")
    local status = C.qjson_source_v1_iter_begin(handle, out, result)
    if status ~= READY then self:release(lease); error(result_error(result), 0) end
    local iterator = ffi.gc(out[0], C.qjson_source_v1_iter_release)
    local record = leases.track(scope, function()
        if iterator then ffi.gc(iterator, nil); C.qjson_source_v1_iter_release(iterator); iterator = nil end
        if lease then self:release(lease); lease = nil end
    end)
    local fallback = leases.fallback(scope, record)
    return function()
        leases.check(scope)
        if not fallback or not iterator then return nil end
        local ok, key, child = pcall(function()
            local member = ffi.new("qjson_source_v1_member[1]")
            local rc = C.qjson_source_v1_iter_next(iterator, member, result)
            if rc == DONE then return nil end
            require_status(rc, READY, result)
            local value = member[0]
            local name = kind == "array" and (exact(value.ordinal) + 1)
                or key_string(self, exact(value.key_start), exact(value.key_end), scope)
            if kind == "array" then self:notify(scope) end
            return name, ffi.new("qjson_source_v1_node", value.value)
        end)
        if not ok then leases.finish(scope, record); fallback = nil; error(key, 0) end
        if key == nil then leases.finish(scope, record); fallback = nil end
        return key, child
    end
end

local function backend_new(fd, spool_path, opts)
    local result = ffi.new("qjson_source_v1_result[1]")
    local source = C.qjson_source_v1_new(native_options(opts), result)
    if source == nil then io_source.close(fd, spool_path); error(result_error(result), 0) end
    local backend = setmetatable({ state = { fd = fd, path = spool_path, source = source, leases = 0 },
        total = 0, opts = opts }, Backend)
    return backend, backend:retain()
end

local function feed_bytes(backend, chunk, spool, scope)
    if type(chunk) ~= "string" then error("qjson: feed chunk must be a string", 0) end
    if #chunk > MAX_EXACT - backend.total then error("qjson: source offset exceeds Lua exact integer range", 0) end
    local result, position = ffi.new("qjson_source_v1_result[1]"), 0
    while position < #chunk do
        leases.check(scope)
        local count = math.min(#chunk - position, backend.opts.chunk_size)
        if spool then
            local written, err = io_source.write(backend.state.fd, backend.total, chunk, position, count)
            if not written then error(backend:fail(err), 0) end
        end
        require_status(C.qjson_source_v1_feed(backend.state.source, backend.total,
            ffi.cast("const uint8_t *", chunk) + position, count, result), NEED_INPUT, result)
        backend.total, position = backend.total + count, position + count
        backend:notify(scope)
    end
end

local function finish_backend(backend)
    local result, root = ffi.new("qjson_source_v1_result[1]"), ffi.new("qjson_source_v1_node[1]")
    require_status(C.qjson_source_v1_finish(backend.state.source, backend.total, result), READY, result)
    require_status(C.qjson_source_v1_root(backend.state.source, root, result), READY, result)
    return { backend = backend, handle = ffi.new("qjson_source_v1_node", root[0]), kind = backend:type(root[0]) }
end

function M.decode_file(filename, opts)
    opts = options(opts)
    if type(filename) ~= "string" or filename:find("\0", 1, true) then error("qjson: file path must be a string without NUL", 0) end
    local fd, open_error = io_source.open(filename)
    if fd == nil then error(open_error, 0) end
    local backend, owner = backend_new(fd, nil, opts)
    local ok, value = pcall(function()
        while true do
            local chunk, err = io_source.read(fd, backend.total, opts.chunk_size)
            if type(chunk) ~= "string" then error(err or "qjson: source read failed", 0) end
            if #chunk > opts.chunk_size then error("qjson: source exceeded read bound", 0) end
            if #chunk == 0 then break end
            feed_bytes(backend, chunk, false)
        end
        return proxy.from_node(finish_backend(backend))
    end)
    backend:release(owner)
    if not ok then error(value, 0) end
    return value
end

function M.new_decoder(opts)
    opts = options(opts)
    local fd, spool_path = io_source.spool(opts.temp_dir)
    if fd == nil then error(spool_path, 0) end
    local backend, owner = backend_new(fd, spool_path, opts)
    local scope = leases.acquire()
    scope.entries = { { backend, owner } }
    return setmetatable({ backend = backend, scope = scope }, Decoder)
end

function Decoder:close()
    leases.release(self.scope)
    self.closed, self.node = true, nil
end

function Decoder:fail(message)
    self.failure = self.failure or tostring(message)
    if not self.closed then self.backend:fail(self.failure, 2) end
    self:close()
    return nil, self.failure
end

function Decoder:feed(chunk)
    if self.failure then return nil, self.failure end
    if self.closed then return nil, "qjson.decoder: closed for input" end
    if self.input_busy then return nil, "qjson.decoder: input operation in progress" end
    if self.finished then return nil, "qjson.decoder: closed for input" end
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
    if self.closed then return nil, "qjson.decoder: closed" end
    if self.input_busy then return nil, "qjson.decoder: input operation in progress" end
    self.input_busy = true
    local ok, value = pcall(function()
        leases.check(self.scope)
        if not self.finished then self.node = finish_backend(self.backend) end
        local completed = path.from_node(self.node, {}, self.scope)
        self.finished = true
        return completed
    end)
    self.input_busy = nil
    if not ok then return self:fail(value) end
    return value
end

function Decoder:get(query)
    if self.failure then return nil, "ERROR", self.failure end
    if self.closed then return nil, "ERROR", "qjson.decoder: closed" end
    local ok, segments = pcall(path.parse, query)
    if not ok then return nil, "ERROR", tostring(segments) end
    local usable, source_error = pcall(leases.check, self.scope)
    if not usable then return nil, "ERROR", tostring(source_error) end
    if not self.finished then return nil, "NEED_INPUT" end
    local found, value = pcall(path.from_node, self.node, segments, self.scope)
    if not found then return nil, "ERROR", tostring(value) end
    if type(value) == "nil" then return nil, "ABSENT" end
    return value, "READY"
end

function Decoder:abort(reason)
    if self.finished then return nil, "qjson.decoder: cannot abort a finished decoder" end
    if self.closed then return nil, self.failure or "qjson.decoder: closed" end
    self:fail(reason or "qjson.decoder: aborted")
    return true
end

return M
