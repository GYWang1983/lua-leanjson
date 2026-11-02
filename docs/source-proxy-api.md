# Mutable JSON views and bounded output

`leanjson.decode(string)` keeps the validated JSON source and decodes fields on demand. Memory, file and incremental input share the sparse native source path; the legacy `leanjson.parse` ABI remains separate. Objects and arrays remain proxies after writes. Use `leanjson.type(value)` to distinguish `"object"`, `"array"`, `"null"`, and scalar types; proxy metatables are not array markers. Use `leanjson.pairs`, `leanjson.ipairs`, and `leanjson.len` on LuaJIT builds without Lua 5.2 compatibility. Direct `next`, `rawget`, `rawset`, and metatable replacement bypass the proxy API.

The source options `index_depth`, `index_array_limit`, and `index_budget_bytes` default to `3`, `3`, and `1048576`. Each accepts an integer from 0 through 4294967295; negative, fractional, nonfinite, nonnumeric and overflowing values are rejected before FFI conversion. Zero disables the corresponding optional preindexing/cache allocation. Root is depth 0, so `a.b.c` is the default retained frontier. Every array retains at most the configured prefix while its length remains exact. `max_depth` independently limits actual nesting; all input is eagerly validated even beyond the retained frontier.

The byte budget covers native rebuildable index capacities per immutable source, shared by its forks. It applies throughout the source lifetime: later scans do not build another retained sibling tree. A root span and the validation stack, active traversal/string/duplicate workspace, mutation payloads, live public views and explicitly requested strings or output are separate storage. This is a metadata limit, not a process RSS guarantee. Missing or discarded indexes fall back to source scans. Held views/readers use immutable spans and remain valid after index removal.

Targeted field/index reads avoid expanding every Lua sibling. Object writes retain sparse patches; array insertion/removal retain ranges over the original array plus edited values. Iteration streams members. Child identity links are weak when the caller drops its public views; live held views and durable edits keep their required logical links. Full materialization is explicit and releases rebuildable source indexes after conversion.

```lua
local leanjson = require("leanjson")
local body = leanjson.decode(raw)
local first, second = leanjson.fork(body), leanjson.fork(body)
first.model = "first"
second.model = "second"
first.unwanted = nil
first.optional = leanjson.null
```

A fork captures the current logical value. Later writes to the original or either fork are independent. The immutable source and untouched structural nodes are shared; large sibling strings are not decoded by a write or a fork.

Proxy assignment captures a snapshot too. Assigning a plain Lua table or another proxy copies its logical ownership, so later external edits do not change the assigned value. Repeated reads of a particular attached child still return the same proxy. Replacing or deleting the parent field detaches an already returned child: edits through that old reference affect the old value only. A cyclic plain table cannot be snapshotted.

Source callbacks can yield during mutation preparation. If another coroutine changes the same proxy or a linked ancestor before publication, the suspended mutation raises `leanjson: stale proxy mutation` without changing nodes, moving/detaching children or invalidating the source. The completed writer remains visible and the caller can retry the rejected operation against the current value. Disjoint keys on the same branch can conflict through a shared ancestor; independent forks do not conflict. Close cancels the initiating holder's preparation and releases its temporary dependencies immediately.

```lua
local plain = { x = 1 }
body.settings = plain
plain.x = 2                 -- body.settings.x stays 1
body.copy = body.settings
body.copy.x = 3            -- body.settings.x stays 1
```

`nil` deletes a property; `leanjson.null` is a JSON value. Empty source arrays retain their array type, including after writes. `leanjson.array_insert(array, index, value)` inserts before a one-based index; `index = leanjson.len(array) + 1` appends. `leanjson.array_remove(array, index)` shifts later elements and returns the detached removed value. The helpers preserve proxy child identity when elements move. `array[i] = nil` does not shift elements. Interior `nil` writes and writes beyond the next tail index are rejected before changing the array. A trailing `nil` removes the tail without shifting other slots. Use explicit removal for sequence deletion. `array_insert`/`array_remove` require a dense array. The sparse-array encoder options continue to apply to ordinary Lua tables; explicitly materialize a proxy to use sparse Lua-table operations. Array iteration rejects writes during the iteration; object iteration observes the membership snapshot taken when iteration starts.

Object getters use the last occurrence of a duplicate key. For compatibility, iteration of an untouched source object still yields lexical occurrences, and ordinary output can retain untouched source bytes. Editing an object collapses its duplicate keys, keeping first-appearance order and the last logical value; deleting a key removes every occurrence. `normalize_duplicates = true` collapses duplicates recursively for forwarding. Keys compare by decoded bytes, so `"a"` and `"\u0061"` are equal. Unchanged subtrees proven free of duplicates can pass through as raw spans; unknown status is scanned. Normalized output can therefore retain whitespace or lexical spellings inside such clean spans.

Unique and final duplicate container occurrences from `leanjson.pairs` share the current attached child returned by a direct read. Earlier duplicate occurrences and values replaced since iteration began remain snapshots. Untouched source object iteration makes one initial pass into the bounded/spilled exact-key workspace before replaying lexical members; it does not rescan the parent for each child or retain a full Lua sibling index. `leanjson.ipairs` returns no members for an object, including numeric-looking string keys.

Untouched scalar tokens remain source spans even if their parent changes. Merely reading a large integer does not alter its output token. Assigning the decoded Lua number back is an explicit replacement and may round or normalize it under the existing numeric encoder settings.

```lua
local body = leanjson.decode('{"n":9007199254740993,"x":0}')
local n = body.n            -- Lua double access may round
body.x = 1                 -- output still contains 9007199254740993
body.n = n                 -- replacement now uses Lua number encoding
```

`leanjson.materialize(value, { keep_origin = true })` remains an explicit full tree conversion with optional memory-source provenance reuse. File/incremental sources reject `keep_origin=true`; default materialization returns independent ordinary values. `leanjson.encode(value)` remains the convenience API that allocates a complete output string.

```lua
local reader = leanjson.reader(body, {
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

Reader construction freezes proxy and ordinary Lua values, including mixed trees, and acquires source leases without source I/O. `length()` validates/counts the actual encoded bytes without building output or advancing the output cursor. `next()` ensures that complete validation/count first when needed. Each nonempty chunk is at most `chunk_size` bytes. Original spans and newly assigned Lua strings are emitted with bounded buffers, including JSON escapes. The reader does not call the complete encoder for scalar strings or documents.

A successfully computed length remains available after EOF or `close()` without keeping the source alive. Construction/counting failures release snapshot references immediately; `length()` and the first `next()` report the original error.

Normal EOF is `nil, nil`. Encoding/source failures are `nil, error`; preserve this error when adapting a reader to an HTTP body iterator. EOF, failure, and explicit `close()` are terminal; later `next()` returns a closed error. `close()` is idempotent and drops only the reader's references. A fork, proxy, or other reader continues to keep shared source resources alive. A new reader is needed for another traversal.

`leanjson.close(proxy)` drops that proxy's source leases, detaches its cache slot and rejects later access. Held children, forks and readers remain independently usable. These APIs are independent of `ngx`. Memory input retains the complete source string; [file and incremental sources](file-source-api.md) use bounded disk windows with explicit ownership and cancellation.

`leanjson.source_stats(proxy)` returns `budget_bytes`, `index_bytes`, `indexed_nodes`, `indexed_depth`, `index_depth`, and `index_array_limit` for a source-backed root or overlay. `index_bytes` counts native index vector capacities, excluding the mandatory root record. The additional `spill_file_bytes`, `spill_live_regions` and `spill_free_regions` describe the current shared temporary workspace's file length and allocated/free region counts; all three are zero when no spilled map is active. These disk diagnostics are separate from the index budget. The diagnostic does not count the Lua allocator, weak live-view identity maps, holder state, input/output strings, patches or active operation workspace memory. It is useful for verifying the configured cache bound, and is not total native heap or RSS. An entirely synthetic value has no source diagnostic.

Exact duplicate normalization keeps at most eight short decoded keys (4096 key bytes) per active object in memory, then uses an on-disk hash index with exact byte comparison on fingerprint collisions. All spilled maps for one source share one unlinked temporary backing file while active, including parent reader iterators and nested duplicate detection. Its virtual regions grow with bounded-buffer relocation. Released regions are coalesced and reused, trailing free space is truncated, and the final active map closes the descriptor. Repeated traversals do not retain a region for every historical operation while an older reader stays open. Wide/deep normalization trades extra scanning and temporary disk I/O for limited retained memory. The current decoded key, an explicitly accessed scalar, or a caller-retained key/value can still be large; those are separate from optional retained indexes. Temporary storage must be available in `temp_dir`; I/O failures remain errors and clean up owned resources.
