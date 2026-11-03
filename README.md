# LeanJSON

**Memory-conscious JSON processing for LuaJIT and OpenResty.**

LeanJSON is a Rust-backed JSON library for applications that receive large
payloads but inspect or change only a few fields. It exposes mutable Lua proxies
while keeping untouched content in its original source. File-backed input and
chunked output let applications avoid assembling the entire request, object
tree and rewritten body in Lua memory.

This project is a fork of **[api7/lua-qjson](https://github.com/api7/lua-qjson)**.
It builds on qjson's Rust structural scanners, offset indexes, lazy field access
and LuaJIT FFI integration. The fork adds source-backed mutation, independent
snapshots, bounded output, file/incremental sources and native OpenResty body
adapters. It is distributed under its own name, **`lua-leanjson`**, with the Lua
module **`leanjson`**. Credit for the original implementation belongs to the
qjson authors; the project retains the [Apache-2.0 license](LICENSE).

## Why LeanJSON?

A gateway may need only `model`, `stream` or a few routing parameters from a
request containing megabytes of messages, prompts or inline media. Decoding all
that content into Lua values and building another complete JSON string can
consume substantially more memory than the fields being changed require.

LeanJSON keeps source spans for untouched values. Reading a selected value
decodes it on demand; writing a field records a replacement. A reader then
combines original spans and modifications into bounded chunks.

This is most useful when:

- Large strings or subtrees pass through unchanged.
- Only a small part of the document is inspected or modified.
- Several independent variants share the same input.
- Input can stay in a file and output can be consumed incrementally.

Memory use still includes structural indexes, keys, modifications and any
values explicitly read. A long string becomes a complete Lua string when
accessed. In-memory input retains its original string. LeanJSON does **not**
promise constant memory or lower memory use for every JSON shape.

The source APIs validate the entire input but retain only a bounded optional
index. By default they index to depth **3** and retain the first **3** entries
of each indexed array, within a shared **1 MiB** metadata budget. Reads outside
that index scan the original source on demand. Array lengths remain exact;
these limits never hide fields or truncate a document.
Explicit `preload_paths` selections bypass all three index limits, including
zero: selected values and the paths needed to reach them have separate storage.

## What this fork adds

| Capability | What it enables |
| --- | --- |
| Mutable JSON proxies | Read and assign fields without decoding untouched sibling values. |
| Copy-on-write forks | Create independent request variants that share immutable source data. |
| Bounded JSON reader | Emit original spans and changed values in chunks, and calculate the encoded length without building a complete output string. |
| File-backed decoding | Validate and access a file through bounded windows instead of reading the whole file into Lua. |
| Incremental input | Feed incoming chunks into a parser and owned disk spool. Final values become available after complete validation. |
| Bounded metadata | Configure indexing depth, array prefix and a per-source index budget; access deferred content without retaining a complete node tree. |
| Explicit path preloading | Load routing fields during scanning while preserving lazy access to the rest of the document and complete output. |
| Eager decoding | Set `lazyload=false` to return ordinary Lua tables and scalars for consumers that need them. |
| Native OpenResty adapter | Receive memory/file/request-socket input and send readers through lua-resty-http, with explicit cancellation and error handling. |
| Explicit resource ownership | Close holders deterministically; independently held children, forks and readers keep their source alive. |

The JSON core does not depend on `ngx`. OpenResty integration is isolated in
`leanjson.openresty`.

## Install from source

The renamed package has **not yet been published to LuaRocks**. From a checkout
of this fork, install the checked-out revision with the command below. Pin the
commit you have validated; published branches may not yet include the runtime
described in the latest local verification report.

```sh
luarocks --lua-version=5.1 make rockspec/lua-leanjson-scm-1.rockspec
```

Building requires Rust/Cargo and LuaRocks configured for LuaJIT's Lua 5.1 ABI.
The pinned verification environment uses Rust 1.90 and OpenResty LuaJIT.
Standard PUC Lua is not supported: the library requires LuaJIT FFI.

Rust is a **build-time dependency only**. Runtime deployments need LuaJIT,
`leanjson.so` and the installed `leanjson.lua` / `leanjson/` modules. The supplied
[OpenResty Docker example](examples/openresty/README.md) builds and copies the
native library and Lua modules into a runtime image without Rust.

If using a raw Cargo build rather than a LuaRocks installation, make
`libleanjson.so` (Linux) or `libleanjson.dylib` (macOS) discoverable by the FFI
loader. For example, Linux development uses `LD_LIBRARY_PATH=target/release`.

## Read, change and fork a document

```lua
local json = require "leanjson"

local body = json.decode([[{
  "model": "public-model",
  "stream": true,
  "messages": [{"role": "user", "content": "Hello"}]
}]])

print(body.model)                  -- public-model
local variant = json.fork(body)
variant.model = "provider-model"  -- body.model stays public-model
variant.stream = false

local encoded = json.encode(variant)
json.close(variant)
json.close(body)
print(encoded)
```

`encode()` is convenient for small results but allocates the complete output
string. For large results, consume a reader instead. `materialize()` explicitly
creates ordinary Lua values; reserve it for consumers that require them.

## Choose what to load

By default, `decode()` returns lazy proxies. Use `preload_paths` to have selected
fields ready when decoding finishes:

```lua
local body = json.decode(raw, {
    preload_paths = { "$.model", "$.stream", "$.messages[*].role" },
    index_depth = 0,
    index_array_limit = 0,
    index_budget_bytes = 0,
})

print(body.model)              -- already loaded, despite all index limits being 0
print(body.messages[1].role)   -- JSONPath indexes are 0-based; Lua indexes are 1-based
body.model = "provider-model"
local rewritten = json.encode(body)  -- includes unselected fields too
json.close(body)
```

This is preloading, not projection. Unselected values stay available on demand,
and all input is validated before a result is returned. Selecting an object or
array loads its entire subtree; selecting a long string loads that complete
string. Preloads are immutable source data, so merely reading them preserves
original output bytes and number spellings. Explicit selected data is outside
the automatic index budget; selecting `$` can use substantial memory.

The supported JSONPath subset includes `$`, dot member names, quoted bracket
member names, zero-based array indexes, and immediate `.*` / `[*]` wildcards.
Missing fields do not match. Recursive descent, filters, slices, unions and
negative indexes are rejected. This is not a JSON Schema API.

For eager decoding, choose ordinary Lua values instead:

```lua
local value = json.decode(raw, { lazyload = false })
for key, child in pairs(value) do print(key, child) end
value.model = "provider-model"
local encoded = json.encode(value)
```

This mode supports native `pairs`, `ipairs`, `next`, `rawget` and table writes;
it does not retain proxies or require closing the returned values. Null uses
`json.null`, numbers use Lua numbers, and duplicate object keys keep their final
value. It fully loads the document even if `preload_paths` is also supplied.
Use it when consumers need ordinary tables, with the corresponding full-value
memory cost. It does not promise cjson's speed, allocation behavior or permissive
handling of invalid JSON, and it works without cjson installed.
Use `encode` for these ordinary values. A `reader` also accepts them, but takes
an immutable snapshot of the table tree; this has additional memory cost compared
with reading a source-backed lazy proxy.

Both options apply to `decode`, `decode_file`, `new_decoder`, and OpenResty
adapters via `opts.decode`. `lazyload` controls value loading; the older `lazy`
option concerns validation and does not disable source validation. See the
[source API](docs/file-source-api.md) for ownership and decoder lifecycle details.

## Independent codec instances

`leanjson.new()` returns an independent encoder/decoder API table, like
`cjson.new()`. It creates a codec, not a JSON document. Each call starts with
library defaults, including calls to an instance's `new()`; it does not copy
the parent's current settings. Call its functions with `.` just like the module.

```lua
local json = require "leanjson"
local a, b = json.new(), json.new()
a.encode_number_precision(3)
a.encode_sparse_array(true)
assert(a.encode(1 / 3) == "0.333")
assert(b.encode_number_precision() == 14)
assert(json.encode_number_precision() == 14)

local body = a.decode('{"model":"old","messages":[]}', {
    preload_paths = { "$.model" },
})
body.model = "new"
local output = a.encode(body)
a.close(body)
```

Instances retain `decode`, `decode_file`, `new_decoder`, lazy/eager/preload
options and the existing helpers. `new_decoder()` still creates an incremental
input decoder; it is distinct from `new()`.

- Numeric, byte validation, escaping and array settings are isolated between
  the default module and every normal/safe instance. Each setter returns its current/new setting.
- `codec.encode(value)` and `codec.reader(value)` use the called codec, including
  when `value` was created by another instance. A reader snapshots numeric
  formatting, nonfinite-number policy, escaping and table contents when created.
  Unaffected source spans retain original bytes, including finite numeric
  spellings. Nonfinite numbers and strings/keys containing slash or DEL follow
  the called codec's encoding policy even inside unchanged source containers.
- Lazy views, child views and incremental decoder results retain their creating
  codec for `tostring` and for classifying plain tables assigned into them.
  Later settings on that codec affect future operations; sibling instances do
  not. A table assigned to a lazy view is snapshotted at assignment, so changing
  sparse-array settings later does not reshape an existing snapshot.
- `codec.fork(value)` adopts the called codec for the new view without changing
  the original. Eager tables remain ordinary Lua values and use the codec chosen
  when encoding. Null/array markers and immutable source data can be shared
  safely across instances. A codec itself needs no `close()`; file/feed views
  and readers retain their existing cleanup requirements.

## Depth limits and diagnostics

`decode_max_depth([value])` and `encode_max_depth([value])` default to `1000`.
They use independent codec settings, accept `1` through `2147483647`, and return
the current/new value. Numeric strings and fractional values follow the same
integer coercion as the other cjson-shaped settings. Only nested containers
count; scalar children do not add depth. Cyclic tables fail with an excessive
nesting error. The explicit `empty_array` sentinel follows native cjson's
scalar-token exception; real source arrays and Lua tables still count.

Decode limits are frozen when a source or incremental decoder is created.
A nonzero per-call `max_depth` overrides that codec default; `0` inherits it.
`index_depth` and the other metadata bounds never change legal nesting.
High-level source v2 accepts configured depths above 4096; legacy `parse` and
source v1 retain their separate native limits. Large limits still require
memory for the active validation/traversal stack and any requested full values.

Encoding checks ordinary tables, edits and unchanged source spans at their
actual output depth. Readers freeze the encode limit when constructed; their
`length()` validates it before raw output. A source whose accepted limit fits
uses that bound directly; otherwise raw spans receive a bounded byte scan.
Deep ordinary encoding, snapshots and materialization use explicit stacks.

Public syntax, Unicode and depth errors use native cjson wording and byte-based
`character` positions, including across feed boundaries. The companion native
tokenizer retains fixed token payloads and a nesting stack, not a decoded tree.
The additive C formatter leaves internal result code/detail/offset available.
Strict-number/UTF-8 extensions, stricter embedded-NUL handling and unsupported
features keep their documented boundaries; this is not complete cjson parity.

## Precision, sparse arrays and array markers

`encode_number_precision([value])` defaults to 14 and accepts 1–16. Setting it
returns the **new** value. Numeric strings and fractional values use native
integer coercion/truncation within the declared bounds. It applies to newly
encoded numbers, including integer-valued doubles and negative zero. Unchanged
source tokens keep their bytes; readers freeze formatting when constructed.

`encode_sparse_array([convert[, ratio[, safe]]])` returns all three settings.
`convert` accepts booleans or exactly `on`/`off`; ratio/safe accept truncated
integers from 0 through 2147483647. Defaults are false, 2, 10. All arguments are
validated before any change is published. Nonfinite/out-of-range values are
rejected; native integer overflow/wrap and partial-update accidents are not
reproduced.

```lua
local codec = require("leanjson").new()
codec.encode_number_precision(16)
assert(codec.encode(2^53) == "9007199254740992")
assert(codec.encode(codec.empty_array) == "[]")
assert(codec.encode(setmetatable({1, 2, tag = "ignored"}, codec.array_mt)) == "[1,2]")
codec.decode_array_with_array_mt(true)
local value = codec.decode('{"array":[]}', { lazyload = false })
assert(getmetatable(value.array) == codec.array_mt)
assert(codec.encode(value.array) == "[]")
```

`array_mt` and `empty_array_mt` are distinct shared markers. `array_mt` uses raw
Lua table length/values, fills holes inside that length with null and ignores
hash entries. `empty_array_mt` first applies ordinary sparse policy, then forces
an array if ordinary classification would choose an object. Its ordinary array
path honors indexed reads (`__index`); its forced fallback uses raw values. The
shared `empty_array` sentinel always encodes as `[]`.

`encode_empty_table_as_object` defaults to true; false makes an ordinary empty
table encode as `[]`. `decode_array_with_array_mt` defaults to false. Both accept
booleans and `on`/`off`, and reject excess arguments. With eager decoding, an
unmarked empty JSON array becomes a plain empty Lua table and normally re-encodes
as `{}`. **Migration:** enable `decode_array_with_array_mt(true)` to retain eager
array identity; earlier LeanJSON versions retained it implicitly.

Lazy/preload views retain source container identity and, with compact encoding,
unchanged bytes.
With marking enabled, `getmetatable(array_view) == codec.array_mt` is observable
without replacing proxy behavior. Decode settings are snapshotted when memory,
file or incremental input starts; later children and repeated decoder results
keep that policy. Lazy array edits still use the existing dense-array rules.
Explicit `materialize` retains its shape-preserving helper contract and sparse
reclassification after edits; `array_mt` explicitly overrides that shape.

## Numbers and byte strings

Decode defaults follow the pinned OpenResty lua-cjson: native nonstandard
numbers (including hex floats, leading zeroes, Inf/Infinity and NaN) and raw
non-UTF8 bytes in strings/keys are accepted. Unicode escapes and surrogate pairs
are always validated; arbitrary raw control characters remain invalid.

```lua
local codec = require("leanjson").new()
codec.decode_invalid_numbers(false) -- opt into RFC number grammar
codec.decode_validate_utf8(true)    -- also require valid UTF-8 raw string bytes
codec.encode_invalid_numbers("null") -- false: reject; true: NaN/Infinity tokens
codec.encode_escape_forward_slash(false) -- default true: / becomes \/
```

These settings are isolated on normal/safe instances and support getters and
boolean or exact `on`/`off` values; only `encode_invalid_numbers` also accepts
`"null"`. Encoding rejects nonfinite numbers by default. True mode emits `NaN`,
`Infinity` and `-Infinity`; null mode emits `null`. DEL always encodes as
`\u007f`. All other high bytes remain byte-exact, without replacement characters.

Decode settings are fixed when each memory/file/incremental source starts;
readers fix encoding settings when created. Source strings needing escaping are
decoded and encoded in bounded chunks. Native conversion preserves signed-64
saturation for plain decimal integers and the native distinction between `-0`
(integer zero) and `-0.0` (negative floating zero). A private C numeric locale
handles exponent ranges beyond LuaJIT's converter without changing process
locale. Unchanged finite source tokens retain their original spelling, so
encoding is not a general JSON canonicalizer. The legacy low-level `parse` ABI
and zero-mode C source constructors retain their strict defaults.

## Indentation and unsupported values

```lua
local codec = require("leanjson").new()
codec.encode_indent("  ") -- default "": compact output
codec.encode_skip_unsupported_value_types(true) -- default false: raise
print(codec.encode({ 1, function() end, { n = 2 } }))
-- [
--   1,
--   {
--     "n": 2
--   }
-- ]
```

`encode_indent([value])` returns the current indentation string; nil leaves it
unchanged. Numbers convert to strings, and the first NUL byte terminates the
setting, matching native cjson. Non-whitespace indentation such as `"abc"` is
accepted, so the resulting output need not be valid JSON. An empty string
disables indentation. LeanJSON safely returns `""` for the empty/default getter;
the pinned native cjson getter crashes in that state.

`encode_skip_unsupported_value_types([value])` accepts booleans or native
`"on"`/`"off"` options, including their NUL-terminated forms. When enabled,
functions, threads, userdata and unsupported cdata disappear from object members
and compact out of arrays; an unsupported root encodes as `""`. The existing
numeric `int64_t`/`uint64_t` cdata support remains available. Nil and `null` still
encode as `null`. Invalid keys, nonfinite-number policy, sparse arrays, cycles
and depth limits keep their usual validation. Empty containers stay `{}`/`[]`;
with indentation, a nonempty container whose values were all skipped still has
a newline before its closing delimiter.

Both settings are independent on ordinary and safe codecs and fresh `new()`
instances. Readers freeze them at construction. Nonempty indentation rebuilds
every source container, including unchanged proxies and `keep_origin` tables,
through iterative traversal; readers retain bounded source reads and output
chunks without materializing the source. Eligible source scalar tokens keep
their original spelling. Indented untouched source objects retain lexical
duplicate occurrences unless the reader uses `normalize_duplicates=true`.

## Optional JSON comments

`decode_allow_comment([value])` defaults to `false`. Use `true` or `"on"` to
accept `//` line comments and non-nested `/* ... */` block comments between JSON
tokens. A line comment ends at LF or EOF; CR alone does not end it. Comment-like
text inside strings/keys stays literal. Comments cannot join number or keyword
fragments: `1/*x*/0` is still invalid.

```lua
local codec = require("leanjson").new()
codec.decode_allow_comment(true)
local body = codec.decode('/* input */ {"model": /* route */ "seedance"}')
assert(body.model == "seedance")
assert(codec.encode(body) == '{"model":"seedance"}')
codec.close(body)
```

The setting is independent per normal/safe instance and frozen when each source
or incremental decoder starts, including later reads, preload and eager rebuild.
Disabling it afterwards does not invalidate an already accepted source. Encoding
always removes actual comments, including through `reader`, forks, edits and
`materialize(..., {keep_origin=true})`. Affected containers stream through bounded
member iterators; unaffected child spans can retain their original spelling.
There is no full-document materialization just to strip comments, and no comment
body is retained in parser metadata. Strings containing `//` or `/* */` keep
their content, subject to the normal string escape policy. Legacy `parse` and
zero-mode C source APIs remain strict.

## Safe conversions

`require "leanjson.safe"` provides a separate codec whose conversion failures
return `nil, err`. `safe.new()` creates another independent safe codec at library
defaults; settings do not leak into normal codecs or sibling safe instances.

```lua
local safe = require "leanjson.safe"
local body, err = safe.decode('{"model":"seedance"}', {
    preload_paths = { "$.model" },
})
if body == nil then error(err) end
body.model = "provider-model"
local output, encode_err = safe.encode(body)
safe.close(body)
if output == nil then error(encode_err) end
```

- Successful conversions return exactly one value. JSON `false` is a valid
  result; JSON null is `safe.null`. Test for `value == nil`, not `not value`.
- `encode(value)` requires exactly one argument: `encode(nil)` returns `"null"`,
  but `encode()` throws. `decode(raw[, opts])` and `decode_file(path[, opts])`
  require one or two arguments; `new_decoder([opts])` takes zero or one.
- Wrong argument counts, invalid loading options and configuration setter
  errors throw. JSON syntax/value errors and decode input-type errors return
  exactly `nil, err`. Like cjson, safe decode accepts numeric input by converting
  it to a string. Existing parser restrictions still apply.
- `decode_file` and `new_decoder` return `nil, err` on source/construction
  failures. Failed file scans and incremental input release their descriptors
  and spool ownership through the existing source implementation.
- Lazy/eager/preload and all input sources remain available. Helpers, lazy
  property access, and reader/decoder methods retain their existing contracts:
  late property errors may throw, `reader:next()` returns `nil, err` on failure,
  and `decoder:get()` uses its status return. Safe conversion does not make
  these later operations protected or remove the need for `close()`.

This Lua adapter does not reproduce the native C wrapper's separate
`LUA_ERRMEM` classification; VM allocation failures are not a verified
compatibility guarantee. Exact cjson error wording remains tracked separately.

## Rewrite a file without assembling the output

This example keeps the original file as its source, changes `model`, and writes
chunks of at most 64 KiB to standard output. Cleanup covers ordinary errors as
well as successful completion.

```lua
local json = require "leanjson"
local body, variant, reader

local ok, err = pcall(function()
    body = json.decode_file("request.json", {
        chunk_size = 65536,
        index_depth = 3,
        index_array_limit = 3,
        index_budget_bytes = 1048576,
    })
    variant = json.fork(body)
    variant.model = "provider-model"
    json.close(body)
    body = nil

    reader = json.reader(variant, {
        chunk_size = 65536,
        normalize_duplicates = true,
    })
    json.close(variant)             -- the reader owns its snapshot
    variant = nil

    while true do
        local chunk, read_err = reader:next()
        if read_err then error(read_err) end
        if chunk == nil then break end
        assert(io.write(chunk))
    end
end)

if reader then reader:close() end
json.close(variant)
json.close(body)
if not ok then error(err) end
```

`reader:length()` returns the actual encoded byte count or `nil, error`, without
advancing output. `next()` returns `nil, nil` at EOF and `nil, error` on failure.
It completes validation/counting before returning its first chunk. Do not turn
reader errors into ordinary EOF when integrating with an HTTP client.

The input file must stay immutable while holders use it. LeanJSON closes its
file descriptor when the final holder releases it; it never deletes an
original input file. Incremental decoder spools are owned by LeanJSON and are
removed after their final holder closes.

The three index settings above are defaults and also apply to `decode()`,
`new_decoder()` and the OpenResty input adapters. Zero disables the respective
optional index work; it does not disable validation. The root is depth 0, so
`a.b.c` is at the default depth frontier. `max_depth` separately controls the
allowed JSON nesting depth.

The index budget covers rebuildable retained metadata shared by forks, not the
whole process. Input strings, explicit preloads/materialization, user-held values,
mutation payloads, active parser/iterator state and output buffers have their
own storage. Lower budgets trade memory for rescanning. Wide-object duplicate
normalization can spill its exact key index to temporary storage; choose a
writable disk-backed `temp_dir` when that storage must not consume RAM. A
memory-backed filesystem and the OS page cache still count toward system or
container memory even when process RSS stays low.

## Native OpenResty integration

```lua
local input = require "leanjson.openresty"
```

- `input.read_body(opts)` waits for Nginx to receive the body, then uses its
  memory buffer or temporary file.
- `input.start_body(opts)` can receive and scan chunks while a fixed-length
  HTTP/1.1 upload is arriving. HTTP/2 and chunked uploads use the completed-body
  fallback. The current decoder publishes final query values only after EOF
  and full validation; this is not early forwarding of an incomplete JSON body.
- `input.request(httpc, request, value, opts)` sends bounded JSON chunks through
  lua-resty-http, sets the encoded Content-Length, and preserves reader errors.
  It makes one attempt and does not retry automatically.

The [complete handler](examples/openresty/handler.lua) covers client aborts,
source errors, holder cleanup and connection cleanup. Configure
`lua_check_client_abort on`, register cleanup before operations that may yield,
and close each independently owned container view, fork and reader. Closing
only the root intentionally leaves independently held children alive.

Run the reproducible example from a committed checkout:

```sh
scripts/build-openresty-image.sh HEAD lua-leanjson-openresty:local
scripts/verify-openresty-image.sh lua-leanjson-openresty:local
docker run --rm -p 8080:8080 -v leanjson-body:/tmp/leanjson-body lua-leanjson-openresty:local
```

Then, from another terminal:

```sh
curl --data-binary '{"model":"public-model","prompt":"hello"}' http://localhost:8080/
```

The example forwards to a local test sink. See the [deployment instructions](examples/openresty/README.md)
for buffering, disk storage, upstream settings and cancellation behavior.

## Measured advantages and current limits

The bounded-metadata runtime passed **63/63** paired native-process memory
checks against a pure-cjson baseline across memory/file/feed sources, defaults, zero/tiny budgets, traversal
and forks. The following rows use 32,768 entries, completed-file input,
direct mutation and no forced GC during measured phases:

| Shape | lua-cjson peak RSS | LeanJSON peak RSS |
| --- | ---: | ---: |
| 32,768 short array objects | 18.68 MiB | 13.70 MiB |
| 32,768 small-object fields | 23.18 MiB | 15.07 MiB |
| 32,768 scalar fields | 15.88 MiB | 14.87 MiB |

**The memory reduction has a CPU/I/O cost.** In the paired local HTTP run with
two concurrent clients, the wide-object case used 17.18 MiB versus cjson's
43.00 MiB, but p50 latency was **1,413 ms versus 26 ms**. Wide exact-key
normalization currently uses many synchronous disk operations. This is not a
speed improvement or a production latency guarantee.

The [bounded-metadata report](docs/verification/bounded-metadata.md) records
exact revisions, fingerprints, all process modes, CPU/HTTP results, raw data and
validation boundaries. These finite tests fix the measured small-object
regression; they do not prove lower RSS for every JSON shape or caller behavior.
Earlier [historical measurements](docs/verification/openresty-json-source.md)
and their original qjson labels remain available for traceability.

The [loading-mode report](docs/verification/decode-loading-modes.md) separately
records eager and explicit-preload results. In its 4.28 MiB completed-file case,
selected fields plus bounded output peaked at **14.50 MiB**, compared with cjson's
**36.45 MiB**. Eager ordinary values plus full encoding of 32,768 small-object
fields used **36.11 MiB versus 24.31 MiB**. Both modes took more CPU than cjson in
these runs. Disabling lazy loading is a compatibility option, not a promise of
cjson's memory or speed.

Additional boundaries:

- File I/O is synchronous. Bounded buffers and yields do not make disk access
  asynchronous; storage latency can still delay an OpenResty worker.
- This is not a transparent drop-in replacement for lua-cjson. Use
  `leanjson.encode` for proxies, or explicitly materialize for other encoders.
- In lazy mode, native `next`, `rawget` and `rawset` bypass proxy behavior. Use
  `json.pairs`, `json.ipairs` and `json.len`; these also work on stock LuaJIT
  without Lua 5.2 compatibility support.
- Proxy arrays stay dense. Use `array_insert` / `array_remove` for structural
  changes. `nil` deletes a field; `json.null` represents JSON null.
- Concurrent mutations on the same branch may report a stale-mutation conflict
  across a yield. Use independent forks or handle the conflict explicitly.
- Lua decode validates the entire input under the chosen number/byte policy;
  native-compatible permissive defaults are described above. The inherited
  low-level `parse` API remains strict by default and has a separate opt-in
  lazy-validation mode.

## Compatibility and migration

The [complete pinned upstream cjson matrix](docs/verification/upstream-cjson-compatibility.md)
has been executed for lazy, `lazyload=false`, and preload modes across memory,
file, and incremental input. It **does not establish full cjson compatibility**:
missing configuration APIs, exact error differences, lazy container semantics, and
foreign array-proxy encoding remain gaps. Eager loading returns ordinary Lua
values; it does not implement every cjson API. The report separates unsupported
setup dependencies from actual value/output differences and links the raw evidence.
The [F01/F02/F05 report](docs/verification/f01-f02-f05-config-arrays.md) records
the repaired settings, current array rules, and the remaining lazy differences.

All current public names use the new namespace:

| Surface | LeanJSON name |
| --- | --- |
| Repository / LuaRocks package | `lua-leanjson` |
| Lua module / OpenResty adapter | `leanjson` / `leanjson.openresty` |
| Rust crate / native library | `leanjson` / `libleanjson` |
| C header / exported symbols | `include/leanjson.h` / `leanjson_*` |
| Environment variables | `LEANJSON_*` |

There is no `qjson` compatibility alias. Applications using this fork's old
name must update imports and build/package references; C callers must use the
new header and rebuild against the new library. Upstream qjson remains a
separate project and package.

## Verification and contributing

The canonical full gate builds Rust modes, checks Clippy/Lua lint, runs the Lua
suite and extended properties, replays JSON corpora, and exercises real native
OpenResty HTTP paths including cancellation and resource cleanup:

```sh
git submodule update --init --recursive
make openresty-dev-image
make openresty-docker-test
```

`make help` lists focused build, test and benchmark commands. CI additionally
checks Linux/macOS, multiple OpenResty versions, installed packaging, fuzz
corpus replay and memory tooling. Test results describe their recorded revision;
see the [CI runs](https://github.com/GYWang1983/lua-leanjson/actions/workflows/ci.yml)
for the current branch.

After building the Linux library in the Docker verification environment, run
`make openresty-memory-gate` on the Docker host for fresh-process comparisons
against native cjson. The gate defaults to direct mutation without forks;
`scripts/verify-memory.py --help` exposes source modes, budgets and fork counts.

- [Proxy, mutation and reader API](docs/source-proxy-api.md)
- [File/incremental input and ownership](docs/file-source-api.md)
- [OpenResty APIs, verification and benchmarks](docs/verification/openresty-json-source.md)
- [Migrating from lua-cjson](docs/migrating-from-cjson.md)
- [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md) · [License](LICENSE)
