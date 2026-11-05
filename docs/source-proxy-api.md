# Mutable JSON views and bounded output

`leanjson.decode(string)` keeps the validated JSON source and decodes fields on demand. Memory, file and incremental input share the sparse native source path; the legacy `leanjson.parse` ABI remains separate. Objects and arrays remain proxies after writes. Use `leanjson.type(value)` to distinguish `"object"`, `"array"`, `"null"`, and scalar types. With `decode_array_with_array_mt(true)`, array views expose the public `array_mt` marker through a private metatable; their proxy mechanics remain active. Use `leanjson.pairs`, `leanjson.ipairs`, and `leanjson.len` on LuaJIT builds without Lua 5.2 compatibility.

The per-decode `scanner` option accepts `"cjson"` (default) or `"legacy"`.
It applies to memory, file and incremental inputs, including the OpenResty
request adapter, eager loading and `preload_paths`. The native block loop handles
complete string escapes within Rust and retains
the CJSON-derived C helper for long ordinary spans; dense short spans stay inside
the Rust loop. Only unfinished escape/UTF-8 state crosses input blocks. The same
choice applies to scalar string readers and internal walkers. Rust continues to
validate syntax, numbers, escapes and strict UTF-8 and produce the same bounded
indexes. Unselected values emit no decoded bytes; selected/Schema data uses a
bounded native batch, and scalar output keeps at most three remainder bytes.
Complete-memory input generates native-compatible diagnostics by replaying the
original input only on error. Streaming sources keep incremental diagnostics,
with the same plain-string batching. Schema validation receives the same
logical decoded bytes in batches; it is never skipped. Neither setting changes
metadata budgets or the input storage policy. `"legacy"` remains available for
controlled comparisons and rollback. This is not a runtime dependency on
lua-cjson and does not materialize a full Lua tree unless eager mode requests it.

The per-decode `proxy_mode` option accepts `"table"` (default) or `"userdata"`.
It applies to `decode`, `decode_file`, and `new_decoder`, including normal/safe
modules and independent codecs. Lazy object/array roots, nested and preloaded
containers, decoder get/finish views, detached children and array-remove results
use the selected carrier. Native `type()` really returns `"userdata"` in strict
mode; `leanjson.type()` still returns the logical object/array kind. Scalars,
null and empty-array sentinels retain their existing contracts. Invalid mode
values throw before I/O, including safe calls and eager decoding. A runtime
without `newproxy` rejects strict mode rather than falling back to table proxies.

Direct `next`, `rawget`, `rawset`, metatable replacement and `table.getn` do not
observe logical proxy data. On the table carrier they operate on raw empty
storage; on userdata they reject the type, as do table-only operations such as
`table.insert`, `table.remove`, `table.sort` and `table.concat`. No Lua builtin is
patched. Use the helpers and dense-array edits below, or materialize at an
interface requiring ordinary tables. Third-party libraries may reject, skip or
otherwise handle userdata according to their own rules.

`lazyload` defaults to `true`. Set `lazyload=false` to build the complete value
as ordinary Lua tables/scalars during validation, without proxy descendants or
hidden source ownership. Native `pairs`, `ipairs`, `next`, `rawget` and ordinary
table edits then work directly. Null is `leanjson.null`, numbers are Lua numbers,
decoded duplicate keys use the final whole value. Eager arrays are unmarked by
default, matching cjson: an empty array normally re-encodes as `{}`. Enable
`decode_array_with_array_mt(true)` before decoding to retain explicit array
identity. The policy is snapshotted per input, including incremental get/finish
rebuilds. This mode works without the optional `cjson`
module. The separate `lazy` option controls validation and remains unsupported
for these fully validated source APIs. Lua defaults accept native nonstandard
numbers and raw byte strings. `decode_invalid_numbers(false)` enables RFC
number grammar; `decode_validate_utf8(true)` additionally requires valid UTF-8.
Unicode escapes remain validated in both policies. Settings are fixed per
source, including late child access and eager get/finish rebuilds.
`decode_allow_comment(true)` optionally accepts native comment trivia; it is
also fixed per source. Output rebuilds comment-bearing containers through bounded
iterators, so actual comments never survive encode/reader or keep_origin reuse.
Unaffected child spans and string contents retain their existing semantics.

```lua
local plain = leanjson.decode(raw, { lazyload = false })
local body = leanjson.decode(raw, {
    preload_paths = { "$.model", "$.stream", "$.messages[*].role" },
    index_depth = 0,
    index_array_limit = 0,
    index_budget_bytes = 0,
})
```

`preload_paths` is an optional dense array of JSONPath strings. `$` selects the
whole value; `.name` and `["quoted.key"]` / `['quoted.key']` select members;
`[0]` selects the first array element. Dot names accept letters, digits, `_`, `-`
and non-ASCII UTF-8 names. Quoted names accept JSON escapes and Unicode surrogate
pairs; single-quoted names also accept `\'`. `.*` and `[*]` match immediate object
members or array elements. Recursive descent, filters, slices, unions, negative
indexes and malformed expressions raise before file/spool creation. A missing
path or incompatible input type has no match. Empty, duplicate and overlapping
path arrays are harmless. The compiled selection is immutable even if the
caller's path array changes. `lazyload=false` loads everything while still
validating any supplied paths.

Selection shares path prefixes during the native scan under the chosen policy; unselected data
is fully validated without building its Lua values or an unrestricted metadata
tree. Selecting an object/array loads its complete subtree. Required path spans
and selected decoded values are independent of all three automatic index bounds,
including zero. Repeated selected lookups and selected-subtree iteration reuse
immutable decoded nodes without source reads or scalar decoding. Unselected
fields remain readable lazily, and encoding retains the complete JSON.
Preloading is source data rather than an edit: untouched spans preserve lexical
tokens (including large integers), while writes, forks, held children and
duplicate snapshots keep the usual proxy semantics.

## Explicit immutable references

`leanjson.ref(value[, path])` uses the inspection path grammar, including optional
`$` roots and zero-based bracket indexes. Omitted/nil/empty paths select the
whole value. Missing/nil and non-container intermediates return nil; JSON null,
false and every other present value create an independently owned handle.

```lua
local prompt = leanjson.ref(a, "$.prompt")
b.messages = prompt
leanjson.close(prompt)
leanjson.close(a)                  -- b owns the captured source independently
local reader = leanjson.reader(b, { chunk_size = 65536 })
leanjson.close(b)
-- Consume reader chunks without concatenating the complete body.
```

The handle captures the immutable logical node at creation. Lazy strings remain
source spans; preloaded/edited strings use their existing immutable Lua value.
A plain/eager table is snapshotted by the existing assignment mechanism, while
its existing strings remain shared. Capturing a proxy never materializes its
whole subtree. Subsequent writes to the source, target, or derived mutable views
are independent. Referencing a root/ancestor into a descendant captures the old
finite snapshot; encoder depth checks still apply.

Handles reject normal field access/writes and array mutations. They use userdata
where `newproxy` is available, otherwise a protected private table carrier.
The table fallback cannot intercept raw Lua primitives such as `rawset`; those
raw fields are unrelated to the captured JSON node and ignored by serialization.
Userdata carriers also reject raw table operations.
They remain opaque; no raw offset/pointer is exposed. `leanjson.type(ref)` reports the
logical kind, `len(ref)` counts a string's decoded bytes in bounded chunks or a
container's size, and `exists`/`is_empty` inspect the logical value. In raw Lua,
a handle is always truthy even when it represents false. Unsupported values and
invalid scalar lengths follow the existing encoder/query rules.

Assigning a handle to a proxy or inserting it into a proxy array captures its
node and leases. An ordinary Lua table merely stores the handle: keep it open
until `encode` finishes or a proxy assignment, `fork`, or `reader` has captured
the table. A reader that captures its input successfully owns that snapshot
independently; capture errors follow the usual `next`/`length` error convention.
`encode`, `reader`, `materialize`,
`source_stats` and `close` accept it through the private holder registry. Reading
a mapped target field uses normal getters, so a scalar read can materialize a
string; merely mapping or streaming does not. A source cannot be freed while a
handle, assigned target, derived view, or reader still owns it. Explicit `close`
is idempotent, GC cleans abandoned holders, and failed/cancelled construction
releases newly acquired resources immediately.

`fork(ref)` preserves scalar references and returns a normal independently
mutable proxy for containers, retaining their carrier. Children returned by
`get`/iteration over a container reference are detached mutable views; editing
them leaves the reference unchanged. An empty `get` path retains its usual
root-value behavior; use `materialize(ref)` for explicit full Lua values.

Normal/new/safe codecs export `ref`. Construction is an inspection operation
and throws on malformed paths, closed sources and I/O errors. Referenced
numbers, strings and containers obey the calling/destination encoder's settings,
duplicate normalization, depth and escape policies. When raw token reuse is
ineligible, the existing bounded decoder/encoder transforms the content without
building a complete string.

## Path length, presence and Lua falsiness

`leanjson.len(value[, path])`, `leanjson.exists(value[, path])` and
`leanjson.is_empty(value[, path])` resolve lazy nodes directly and preserve
source leases without exposing child proxies or materializing string contents.

```lua
local bytes = leanjson.len(body, "$.prompt")
local elements = leanjson.len(body, "messages")
if leanjson.exists(body, "$.model") then
    -- The field exists, even if its value is false or JSON null.
end
if leanjson.is_empty(body, "$.stream") then
    -- Equivalent to Lua `not` on the logical value: missing/nil or false.
end
```

| Resolved value | `exists` | `is_empty` |
| --- | --- | --- |
| Missing / nil | false | true |
| false | true | true |
| JSON null sentinel | true | false |
| Empty string, array or object | true | false |
| Zero, whitespace or any other truthy value | true | false |

Paths use the existing `get` grammar (dot-separated keys and zero-based uint32
bracket indexes), additionally accepting `$`, `$.key` and `$[0]`. Empty string
selects the root; omitted/nil paths also select the root. There are no wildcard
or quoted-key selectors. A literal `$` key is accessible as `.$`; `$field`
remains a literal key. Existing `get` parsing is unchanged. A missing member or
non-container intermediate is unresolved; malformed paths and operational
errors raise. In particular, a closed/I/O-failing source is never reported as
a missing value.

Path-based length counts decoded string bytes (not Unicode code points), array
elements, or distinct object keys after last-key-wins and current edits. An
unresolved path returns nil; a resolved null, boolean or number raises a type
error. The existing one-argument `len(value)` behavior is retained, including
Lua's ordinary-table length; an explicit root path requests logical key/element
counting for ordinary/eager values too.

Preloaded, edited and plain Lua strings use `#value`. Other source strings use
the bounded native scalar decoder and add chunk byte counts without concatenating
the payload. Object counts may scan/de-duplicate keys; no member values are
decoded. `exists` and `is_empty` never decode strings or inspect string contents;
only a source boolean may need a small value read for its truthiness. No new
per-field metadata or cache is retained. Queries capture the immutable logical
snapshot and release temporary operations on success, error and cancellation.

Normal/new/safe codecs export all three helpers. They throw on inspection
errors, like `get`, and do not change safe conversion error handling. Use the
path argument rather than `len(body.prompt)` / `is_empty(body.prompt)`, which
would evaluate the ordinary getter first.

The source options `index_depth`, `index_array_limit`, and `index_budget_bytes` default to `3`, `3`, and `1048576`. Each accepts an integer from 0 through 4294967295; negative, fractional, nonfinite, nonnumeric and overflowing values are rejected before FFI conversion. Zero disables the corresponding optional preindexing/cache allocation. Root is depth 0, so `a.b.c` is the default retained frontier. Every array retains at most the configured prefix while its length remains exact. `max_depth` independently limits actual nesting; zero/absent inherits the creating codec's `decode_max_depth()` (default 1000), and a nonzero value overrides it. This policy is frozen per source, and applies beyond the retained frontier. `encode_max_depth()` independently checks actual output nesting, including unchanged spans; readers freeze it at construction. See [depth settings](../README.md#depth-limits-and-diagnostics).

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

A fork captures the current logical value and preserves a proxy's carrier, even when called through another codec. Forking an ordinary table uses the default table carrier. Later writes to the original or either fork are independent. The immutable source and untouched structural nodes are shared; large sibling strings are not decoded by a write or a fork.

Proxy assignment captures a snapshot too. Assigning a plain Lua table or another proxy copies its logical ownership, so later external edits do not change the assigned value. Assignment and array insertion expose containers with the destination parent's carrier, independent of the source carrier. Repeated reads of a particular attached child still return the same proxy. Replacing or deleting the parent field detaches an already returned child: edits through that old reference affect the old value only. A cyclic plain table cannot be snapshotted.

External Lua arrays are also accepted by `encode`, `reader`, `fork` and proxy
assignment/insertion. Except for the raw `array_mt` marker, a raw `__len` field
on the real metatable selects this behavior, including protected metatables and
callable values. Inherited/public replacement metadata is ignored. The method
receives the table once per occurrence; its result uses native number/string
conversion and truncates toward zero. Nonnumeric/nil/boolean/table/cdata results
mean zero, and finite negatives produce an empty array. Nonfinite or truncated
lengths outside `-2147483648..2147483647` fail with `Cannot serialise table:
external array length must be finite and fit a signed 32-bit integer`. This is
an explicit boundary around nonportable native C conversions, without a smaller
length cap. External arrays ignore hash keys and sparse settings, read each
selected index through ordinary `__index` behavior and encode holes as null.

Snapshots evaluate external callbacks during construction and retain the
captured values; later length/count/output operations never call them again.
Source proxies returned by callbacks are pinned immediately, before another
callback can close or collect their public holders. Successful construction
transfers source ownership to the reader/fork/assigned value; errors and
initiating-holder cancellation release temporary pins. Capturing a proxy never
closes its public holder on behalf of the caller. LeanJSON's own proxies bypass
external classification, preserving source tokens, bounded reads and normal
lease ownership. External callbacks override materialized `keep_origin` spans,
including when nested inside an otherwise reusable parent. Encoding preserves
callback error objects; the reader's established errors are strings.
Reader failures release owned leases and snapshot references before invoking
error-object formatting. A throwing or non-string `__tostring` result becomes
`leanjson.reader: error message unavailable` without a secondary exception.

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

`encode_keep_buffer([value])` is retained solely for cjson migration. It defaults
to true and accepts booleans or native `on`/`off` options (C-string prefix before
the first NUL). No argument or nil reads the current value; a setter returns its
new value. Invalid/extra arguments throw without changing state, also on safe
codecs. Each normal/safe module or `new()` instance owns independent state, and
new instances always start at true. This setting does **not** alter allocation,
GC or resource lifetimes: neither value creates or retains a cross-call encoding
buffer. A complete `encode()` result and reader chunks still require memory.

`encode_indent([value])` defaults to `""`; nonempty indentation rebuilds all
containers, including unchanged source spans and `keep_origin` tables, without
materializing source values. Raw scalar spellings can remain unchanged. Numbers
coerce to strings; the first NUL terminates the indentation. Arbitrary
non-whitespace strings are accepted. The empty/default getter safely returns
`""` despite a null-pointer bug in the pinned native getter.

`encode_skip_unsupported_value_types([value])` defaults to false and accepts
booleans and native on/off options. True omits unsupported values, compacts
arrays and emits an empty string for an unsupported root. Nil/null and supported
64-bit integer cdata remain encodable. LeanJSON's own userdata proxies remain
encodable at the root or inside mixed trees; foreign userdata remains unsupported.
Invalid keys, numeric policy, sparse
arrays, cycles and depth limits still apply. A container with only skipped
values retains the native closing newline when indentation is enabled, while
truly empty containers have no newline. These settings belong to the calling
normal/safe codec and are frozen by each reader. Indented untouched source
objects retain lexical duplicates unless `normalize_duplicates=true`; existing
compact-output reuse and normalization behavior remains unchanged.

```lua
local reader = leanjson.reader(body, {
    chunk_size = 65536,
    normalize_duplicates = true,
    preserve_raw_strings = true, -- default; false restores prior string formatting
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

`preserve_raw_strings` is a boolean, default `true`. Unmodified source string
values and eligible source containers retain their original validated JSON bytes,
including `/`, `\/`, `\uXXXX` and DEL spellings. Their string length is obtained
from source offsets and output copies bounded raw windows without decoding the
string. Reconstructed object keys and new/modified Lua values still use the codec.
Comments are removed and requested duplicate normalization still applies.
`preserve_raw_strings=false` restores the previous reader string formatting;
`encode()` and `tostring()` select this behavior internally. JSON values are
unchanged, but byte hashes/signatures may differ between the two reader modes.

String encoded-length calculation and escaping for both reader output and full
encode, including keys, run in Rust. Tiny output windows may split an escape;
only its bounded cursor is retained. The raw-container output depth check also
runs in Rust across windows. Lua schedules nodes/chunks and concatenates only
when the API explicitly returns a complete output string. Reader steps use call-owned staging buffers of at most 64 KiB, never a complete
decoded source string. Full encode may allocate its explicitly requested complete
encoded string. Scratch is not shared across reentrant calls.

Reader construction freezes proxy and ordinary Lua values, including mixed trees. It evaluates external array callbacks; acquiring captured proxy leases itself performs no source I/O. `length()` validates/counts the actual encoded bytes without building output or advancing the output cursor. `next()` ensures that complete validation/count first when needed. Each nonempty chunk is at most `chunk_size` bytes. Original spans and newly assigned Lua strings are emitted with bounded buffers, including JSON escapes. The reader does not call the complete encoder for scalar strings or documents.

A successfully computed length remains available after EOF or `close()` without keeping the source alive. Construction/counting failures release snapshot references immediately; `length()` and the first `next()` report the original error.

Normal EOF is `nil, nil`. Encoding/source failures are `nil, error`; preserve this error when adapting a reader to an HTTP body iterator. EOF, failure, and explicit `close()` are terminal; later `next()` returns a closed error. `close()` is idempotent and drops only the reader's references. A fork, proxy, or other reader continues to keep shared source resources alive. A new reader is needed for another traversal.

`leanjson.close(proxy)` drops that proxy's source leases, detaches its cache slot and rejects later access. Held children, forks and readers remain independently usable. These APIs are independent of `ngx`. Direct memory input retains its source string; [file and incremental sources](file-source-api.md) retain bounded immutable chunks in memory by default. `file_in_memory=false` selects fd/spool windows. Both source modes retain explicit ownership and cancellation; lazy loading is independent of this storage choice.

`leanjson.source_stats(proxy)` returns `budget_bytes`, `index_bytes`, `indexed_nodes`, `indexed_depth`, `index_depth`, and `index_array_limit` for a source-backed root or overlay. `index_bytes` counts native index vector capacities, excluding the mandatory root record. The additional `spill_file_bytes`, `spill_live_regions` and `spill_free_regions` describe the current shared temporary workspace's file length and allocated/free region counts; all three are zero when no spilled map is active. These disk diagnostics are separate from the index budget. The diagnostic does not count the Lua allocator, weak live-view identity maps, holder state, input/output strings, patches or active operation workspace memory. It is useful for verifying the configured cache bound, and is not total native heap or RSS. An entirely synthetic value has no source diagnostic.

Loading diagnostics are separate from `index_bytes`:

| Field | Unit |
| --- | --- |
| `preloaded_nodes` | Retained selected scalar/container node count, including retained lexical duplicate occurrences inside selected subtrees. |
| `preload_path_nodes` | Retained route-only node count needed to reach selected descendants; excludes complete selected nodes. |
| `preloaded_payload_bytes` | Logical scalar payload: decoded string bytes (including accepted raw high bytes), 8 bytes per Lua number, 1 per boolean and 0 per null. |
| `preloaded_key_bytes` | Sum of decoded key byte lengths for retained cache occurrences; route-only nodes count their final matched members. |

These counts are zero without preloading. They describe immutable selected
source data, so branch edits do not change them. Payload/key byte counts exclude
Lua tables, string headers, allocator capacities, possible string interning and
native selector/event workspace. They are neither allocation measurements nor a
total-memory estimate. Eager ordinary values have no `source_stats` diagnostic.

Exact duplicate normalization keeps at most eight short decoded keys (4096 key bytes) per active object in memory, then uses an on-disk hash index with exact byte comparison on fingerprint collisions. All spilled maps for one source share one unlinked temporary backing file while active, including parent reader iterators and nested duplicate detection. Its virtual regions grow with bounded-buffer relocation. Released regions are coalesced and reused, trailing free space is truncated, and the final active map closes the descriptor. Repeated traversals do not retain a region for every historical operation while an older reader stays open. Wide/deep normalization trades extra scanning and temporary disk I/O for limited retained memory. The current decoded key, an explicitly accessed scalar, or a caller-retained key/value can still be large; those are separate from optional retained indexes. Temporary storage must be available in `temp_dir`; I/O failures remain errors and clean up owned resources.
