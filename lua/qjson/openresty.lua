-- Native OpenResty I/O only. The JSON core never waits for a socket or yields
-- through an FFI call. Completed file reads remain synchronous, bounded reads.
local qjson = require "qjson"
local ngx = ngx
local _M = {}
local Session = {}
Session.__index = Session
local OWNER = "qjson.openresty.input"
local ABORT = "qjson.openresty.abort"

local function options(opts)
    opts = opts or {}
    local size = opts.chunk_size or 65536
    assert(type(size) == "number" and size >= 1 and size == math.floor(size), "chunk_size must be a positive integer")
    local json = {}
    for key, value in pairs(opts.decode or {}) do json[key] = value end
    assert(not json.lazy, "OpenResty input requires full JSON validation")
    json.chunk_size = size
    json.on_chunk = opts.on_chunk or function() ngx.sleep(0) end
    if opts.temp_dir then json.temp_dir = opts.temp_dir end
    return opts, json, size
end

local function release(value)
    if value ~= nil then qjson.close(value) end
end

-- ngx.on_abort accepts one callback per request. All resources owned by this
-- adapter join that callback; completed operations unregister their resources.
local function on_abort(callback)
    local callbacks = ngx.ctx[ABORT]
    if not callbacks then
        callbacks = { next_id = 0, active = {} }
        local ok, err = ngx.on_abort(function()
            for id = 1, callbacks.next_id do
                local fn = callbacks.active[id]
                if fn then
                    local ran, callback_err = pcall(fn)
                    if not ran then ngx.log(ngx.ERR, "qjson abort cleanup failed: ", tostring(callback_err)) end
                end
            end
        end)
        if not ok then return nil, "qjson.openresty: ngx.on_abort: " .. tostring(err) end
        ngx.ctx[ABORT] = callbacks
    end
    callbacks.next_id = callbacks.next_id + 1
    local id = callbacks.next_id
    callbacks.active[id] = callback
    return function() callbacks.active[id] = nil end
end
_M.on_abort = on_abort

local function completed(opts, json)
    if ngx.ctx[OWNER] then return nil, "request body already owned by qjson.openresty" end
    ngx.ctx[OWNER] = "completed"
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    local file = data == nil and ngx.req.get_body_file() or nil
    local info = { mode = file and "completed-file" or "completed-memory", source = file and "file" or "memory" }
    local ok, value
    if file then
        -- decode_file keeps an open fd; the Nginx-owned pathname is never removed
        -- or read into a full Lua string by this adapter.
        ok, value = pcall(qjson.decode_file, file, json)
    else
        ok, value = pcall(qjson.decode, data or "", json)
    end
    if not ok then return nil, value, info end
    local unregister, err = on_abort(function() release(value) end)
    if not unregister then release(value); return nil, err, info end
    -- read_body transfers normal-path ownership to its caller. The abort hook
    -- is a fallback for cancellation and remains idempotent after caller close.
    return value, nil, info
end

function _M.read_body(opts)
    local normalized, json = options(opts)
    return completed(normalized, json)
end

function Session:_signal()
    if self.waiters > 0 then self.ready:post(self.waiters) end
end

function Session:_fail(reason)
    if self.done then return end
    self.error = reason or "input aborted"
    self.done = true
    self.decoder:abort(self.error)
    self.decoder:close()
    self:_signal()
end

function Session:abort(reason)
    if self.done then return true end
    self:_fail(reason)
    if self.producer then ngx.thread.kill(self.producer) end
    return true
end

function Session:_wait()
    self.waiters = self.waiters + 1
    local ok, err = self.ready:wait(self.wait_timeout)
    self.waiters = self.waiters - 1
    if not ok then self:abort("input wait: " .. tostring(err)); return nil, self.error end
    return true
end

function Session:get(path)
    if self.closed then return nil, "ERROR", "input session closed" end
    while true do
        if self.error then return nil, "ERROR", self.error end
        if self.done then
            local ok, value = pcall(qjson.get, self.value, path)
            if not ok then return nil, "ERROR", value end
            if value == nil then return nil, "ABSENT" end
            return value, "READY"
        end
        local value, status, err = self.decoder:get(path)
        if status ~= "NEED_INPUT" then return value, status, err end
        if not self:_wait() then return nil, "ERROR", self.error end
    end
end

function Session:finish()
    if self.closed then return nil, "input session closed" end
    while not self.done do
        if not self:_wait() then return nil, self.error end
    end
    if self.error then return nil, self.error end
    return self.value
end

function Session:close()
    if self.closed then return true end
    if not self.done then self:abort("input session closed") end
    self.closed = true
    if self.unregister then self.unregister() end
    if self.decoder then self.decoder:close() end
    release(self.value)
    self.value = nil
    return true
end

function _M.start_body(opts)
    local normalized, json, size = options(opts)
    local headers = ngx.req.get_headers()
    local length = headers["content-length"]
    local version = ngx.req.http_version()
    local reason
    if version ~= 1.1 then reason = "http-version"
    elseif headers["transfer-encoding"] then reason = "transfer-encoding"
    elseif type(length) ~= "string" or not length:match("^%d+$") then reason = "content-length"
    end
    if reason then
        local value, err, info = completed(normalized, json)
        if info then info.fallback = reason end
        if err then return nil, err, info end
        local session = setmetatable({ done = true, value = value, waiters = 0 }, Session)
        return session, nil, info
    end
    if ngx.ctx[OWNER] then return nil, "request body already owned by qjson.openresty" end
    local ok, decoder = pcall(qjson.new_decoder, json)
    if not ok then return nil, decoder end
    ngx.ctx[OWNER] = "socket"
    local input, err = ngx.req.socket()
    if not input then decoder:close(); return nil, err end
    input:settimeout(normalized.read_timeout or 30000)
    local semaphore = require "ngx.semaphore"
    local session = setmetatable({ decoder = decoder, ready = semaphore.new(), waiters = 0,
        wait_timeout = normalized.wait_timeout or 30 }, Session)
    session.unregister, err = on_abort(function() session:abort("client aborted"); session:close() end)
    if not session.unregister then decoder:close(); return nil, err end
    local function produce()
        local remaining = tonumber(length)
        while remaining > 0 and not session.done do
            local chunk, read_err = input:receive(math.min(size, remaining))
            if not chunk then session:_fail("request body read: " .. tostring(read_err)); return end
            local fed, feed_err = decoder:feed(chunk)
            if not fed then session:_fail(feed_err); return end
            remaining = remaining - #chunk
            session:_signal()
            -- Yield only in Lua, after the core has consumed the borrowed chunk.
            ngx.sleep(0)
        end
        if session.done then return end
        local value, finish_err = decoder:finish()
        if finish_err then session:_fail(finish_err); return end
        session.value = value
        session.done = true
        session:_signal()
    end
    session.producer = ngx.thread.spawn(function()
        local ran, producer_err = pcall(produce)
        if not ran then session:_fail(producer_err) end
    end)
    return session, nil, { mode = "incremental", source = "decoder" }
end

-- The client must be connected already. This method sends once, and leaves a
-- successful response body to the caller. Failed sends always close the client.
function _M.request(httpc, params, value, opts)
    opts = opts or {}
    local size = opts.chunk_size or 65536
    local state = { attempts = 0, delivered_bytes = 0, max_chunk = 0,
        headers_may_have_been_sent = false, reader_closed = false, stage = "prepare" }
    local ok, reader = pcall(qjson.reader, value, { chunk_size = size, normalize_duplicates = true })
    if not ok then httpc:close(); return nil, reader, state end
    local function close_reader()
        if not state.reader_closed then reader:close(); state.reader_closed = true end
    end
    local function fail(err, stage)
        state.stage = stage
        close_reader()
        httpc:close()
        return nil, err, state
    end
    local length, err = reader:length()
    if length == nil then state.reader_error = err; return fail(err, "length") end
    state.length = length
    local request = {}
    for key, item in pairs(params) do request[key] = item end
    local headers = {}
    for key, item in pairs(params.headers or {}) do
        local lower = string.lower(key)
        if lower ~= "content-length" and lower ~= "transfer-encoding" and lower ~= "expect" then headers[key] = item end
    end
    headers["Content-Length"] = tostring(length)
    request.headers = headers
    request.body = function()
        if state.reader_error then return nil, state.reader_error end
        if opts.cancelled and opts.cancelled() then
            state.reader_error = "request cancelled"
            close_reader()
            return nil, state.reader_error
        end
        local next_ok, chunk, next_err = pcall(reader.next, reader)
        if not next_ok then next_err = chunk; chunk = nil end
        if chunk and (#chunk > size or state.delivered_bytes + #chunk > length) then
            chunk, next_err = nil, "reader exceeded declared output bounds"
        elseif chunk == nil and next_err == nil and state.delivered_bytes ~= length then
            next_err = "reader ended before declared Content-Length"
        end
        if next_err then
            state.reader_error = next_err
            close_reader()
            return nil, next_err
        end
        if chunk then
            -- Bytes delivered to lua-resty-http, not proof of peer receipt.
            state.delivered_bytes = state.delivered_bytes + #chunk
            state.max_chunk = math.max(state.max_chunk, #chunk)
        else
            close_reader()
        end
        return chunk
    end
    local unregister
    unregister, err = on_abort(function()
        state.reader_error = "client aborted"
        close_reader()
        httpc:close()
    end)
    if not unregister then return fail(err, "prepare") end
    state.attempts = 1
    state.headers_may_have_been_sent = true
    state.stage = "send"
    local sent
    sent, ok, err = pcall(httpc.send_request, httpc, request)
    if not sent then err = ok; ok = nil end
    if not ok or state.reader_error then
        unregister()
        return fail(state.reader_error or err, state.reader_error and "reader" or "send")
    end
    close_reader()
    state.stage = "response"
    local response
    local read
    read, response, err = pcall(httpc.read_response, httpc, request)
    if not read then err = response; response = nil end
    unregister()
    if not response then return fail(err, "response") end
    state.stage = "complete"
    return response, nil, state
end

return _M
