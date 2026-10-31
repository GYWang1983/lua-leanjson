# Mutable JSON views and bounded output

`qjson.decode(string)` keeps the validated JSON source and decodes fields on demand. Objects and arrays remain proxies after writes. Use `qjson.type(value)` to distinguish `"object"`, `"array"`, `"null"`, and scalar types; proxy metatables are not array markers. Use `qjson.pairs`, `qjson.ipairs`, and `qjson.len` on LuaJIT builds without Lua 5.2 compatibility. Direct `next`, `rawget`, `rawset`, and metatable replacement bypass the proxy API.

```lua
local qjson = require("qjson")
local body = qjson.decode(raw)
local first, second = qjson.fork(body), qjson.fork(body)
first.model = "first"
second.model = "second"
first.unwanted = nil
first.optional = qjson.null
```

A fork captures the current logical value. Later writes to the original or either fork are independent. The immutable source and untouched structural nodes are shared; large sibling strings are not decoded by a write or a fork.

Proxy assignment captures a snapshot too. Assigning a plain Lua table or another proxy copies its logical ownership, so later external edits do not change the assigned value. Repeated reads of a particular attached child still return the same proxy. Replacing or deleting the parent field detaches an already returned child: edits through that old reference affect the old value only. A cyclic plain table cannot be snapshotted.

```lua
local plain = { x = 1 }
body.settings = plain
plain.x = 2                 -- body.settings.x stays 1
body.copy = body.settings
body.copy.x = 3            -- body.settings.x stays 1
```

`nil` deletes a property; `qjson.null` is a JSON value. Empty source arrays retain their array type, including after writes. `qjson.array_insert(array, index, value)` inserts before a one-based index; `index = qjson.len(array) + 1` appends. `qjson.array_remove(array, index)` shifts later elements and returns the detached removed value. The helpers preserve proxy child identity when elements move. `array[i] = nil` does not shift elements. Interior `nil` writes and writes beyond the next tail index are rejected before changing the array. A trailing `nil` removes the tail without shifting other slots. Use explicit removal for sequence deletion. `array_insert`/`array_remove` require a dense array. The sparse-array encoder options continue to apply to ordinary Lua tables; explicitly materialize a proxy to use sparse Lua-table operations. Array iteration rejects writes during the iteration; object iteration observes the membership snapshot taken when iteration starts.

Object getters use the last occurrence of a duplicate key. For compatibility, iteration of an untouched source object still yields lexical occurrences, and ordinary output can retain untouched source bytes. Editing an object collapses its duplicate keys, keeping first-appearance order and the last logical value; deleting a key removes every occurrence. `normalize_duplicates = true` collapses duplicates recursively for forwarding.

Untouched scalar tokens remain source spans even if their parent changes. Merely reading a large integer does not alter its output token. Assigning the decoded Lua number back is an explicit replacement and may round or normalize it under the existing numeric encoder settings.

```lua
local body = qjson.decode('{"n":9007199254740993,"x":0}')
local n = body.n            -- Lua double access may round
body.x = 1                 -- output still contains 9007199254740993
body.n = n                 -- replacement now uses Lua number encoding
```

`qjson.materialize(value, { keep_origin = true })` remains an explicit full tree conversion with optional provenance reuse. `qjson.encode(value)` remains the convenience API that allocates a complete output string.

```lua
local reader = qjson.reader(body, {
    chunk_size = 65536,
    normalize_duplicates = true,
})
local length, err = reader:length()
if not length then error(err) end
while true do
    local chunk, read_err = reader:next()
    if read_err then error(read_err) end
    if chunk == nil then break end
    send(chunk)
end
reader:close()
```

Reader construction freezes proxy and ordinary Lua values, including mixed trees. `length()` counts the actual encoded bytes without building output or advancing the output cursor. Each nonempty chunk is at most `chunk_size` bytes. Original spans and newly assigned Lua strings are emitted with bounded buffers, including JSON escapes. The reader does not call the complete encoder for scalar strings or documents.

A successfully computed length remains available after EOF or `close()` without keeping the source alive. Construction/counting failures release snapshot references immediately; `length()` and the first `next()` report the original error.

Normal EOF is `nil, nil`. Encoding/source failures are `nil, error`; preserve this error when adapting a reader to an HTTP body iterator. EOF, failure, and explicit `close()` are terminal; later `next()` returns a closed error. `close()` is idempotent and drops only the reader's references. A fork, proxy, or other reader continues to keep shared source resources alive. A new reader is needed for another traversal.

These APIs are independent of `ngx`. This phase retains the complete input string and its structural index; it reduces extra decoding/output allocations but does not implement file or incremental input.
