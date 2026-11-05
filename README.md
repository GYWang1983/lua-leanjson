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
qjson authors; the project retains the [Apache-2.0 license](LICENSE). The
CJSON-derived string scanning kernel retains its [MIT notice](LICENSES/lua-cjson.txt);
see [NOTICE](NOTICE) for provenance.

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
| File input | Retain source chunks in memory by default; opt into bounded disk windows with `file_in_memory=false`. |
| Incremental input | Scan and retain incoming chunks in memory by default, with an optional owned disk spool. Final values require complete validation. |
| Bounded metadata | Configure indexing depth, array prefix and a per-source index budget; access deferred content without retaining a complete node tree. |
| Explicit path preloading | Load routing fields during scanning while preserving lazy access to the rest of the document and complete output. |
| Eager decoding | Set `lazyload=false` to return ordinary Lua tables and scalars for consumers that need them. |
| Optional strict proxies | Set `proxy_mode="userdata"` to reject native raw/table-only operations while retaining lazy access, snapshots and bounded output. |
| Native OpenResty adapter | Receive memory/file/request-socket input and send readers through lua-resty-http, with explicit cancellation and error handling. |
| Explicit resource ownership | Close holders deterministically; independently held children, forks and readers keep their source alive. |

The JSON core does not depend on `ngx`. OpenResty integration is isolated in
`leanjson.openresty`.

The module exposes `_NAME = "leanjson"` and `_VERSION = "0.1.0"`, matching
the package version in `Cargo.toml`. Independent codecs from `new()`,
`leanjson.safe` and its instances expose the same identity. These fields identify
LeanJSON, rather than the reference lua-cjson implementation; the LuaRocks
`scm-1` value describes the development rock revision.

## Install

```sh
luarocks --lua-version=5.1 install lua-leanjson 0.1.0-1
```

Version 0.1.0 provides a source rock and Linux x86_64/amd64 and ARM64/aarch64
binary rocks targeting glibc 2.35. Binary installation requires no Rust
compiler. Configure LuaRocks for the LuaJIT/OpenResty Lua 5.1 module tree;
PUC Lua and musl/Alpine binaries are not supported by this release.

Release notes: [English](docs/releases/0.1.0.en.md) /
[简体中文](docs/releases/0.1.0.zh-CN.md).

### Install from a source checkout

From a checkout of this fork, install the checked-out revision with the
command below. Use the `v0.1.0` tag for the release or pin the development
commit you have validated.

```sh
luarocks --lua-version=5.1 make rockspec/lua-leanjson-scm-1.rockspec
```

Building requires Rust/Cargo and LuaRocks configured for LuaJIT's Lua 5.1 ABI.
Source builds also require a C99 compiler for the statically linked scanning
kernel; they do not require a runtime lua-cjson dependency.

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

`decode`, `decode_file` and `new_decoder` accept `structural_index` (default
`true`). Set it to `false` to disable the optional validated string-boundary
index. This preserves validation and lazy access; automatic prefix indexes and
the shared demand cache remain controlled by the existing index settings.
All three retained metadata stores share `index_budget_bytes`.

To validate a request while it is scanned, compile its Schema once and pass the
plan as `schema`:

```lua
local plan = json.compile_schema {
    type = "object",
    required = { "model", "messages" },
    properties = {
        model = { type = "string" },
        messages = { type = "array", minItems = 1, items = {
            type = "object", required = { "role", "content" },
            properties = { role = { type = "string" }, content = { type = "string" } },
        } },
    },
}
local body = json.decode_file("request.json", {
    schema = plan,
    structural_index = true, -- false disables boundary retention, not validation
})
json.close(body)
```

The same native scan performs JSON and Schema checks before returning a value.
Type/length-only strings do not become full Lua strings. See
[scan-time Schema validation](docs/schema-validation.md) for the executable
subset, compilation errors, numeric semantics and memory costs.

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

To reject accidental native raw access, select the optional userdata carrier:

```lua
local body = json.decode(raw, { proxy_mode = "userdata" })
assert(type(body) == "userdata") -- object/array roots and all nested views
assert(json.type(body) == "object")
body.model = "provider-model"
local plain = json.materialize(body) -- ordinary Lua tables at table-only interfaces
json.close(body)
```

`proxy_mode` defaults to `"table"`; the only other accepted value is `"userdata"`.
It applies per decode, independently of codec configuration. Strict mode requires
LuaJIT's `newproxy` factory and errors clearly if it is unavailable. `new()` and
options remain ordinary tables; scalar/null/sentinel contracts stay the same.
`lazyload=false` and `materialize()` return ordinary values. Forks preserve the
source carrier across codecs; assignment and insertion snapshot the source value
and expose descendants using the destination parent's carrier. Held children and
removed array values retain their carrier after their parent closes.

These options apply to `decode`, `decode_file`, `new_decoder`, and OpenResty
adapters via `opts.decode`. `lazyload` controls value loading; the older `lazy`
option concerns validation and does not disable source validation. See the
[source API](docs/file-source-api.md) for ownership and decoder lifecycle details.

`scanner="cjson"` (default) uses a native block string loop: complete escapes
are handled inside Rust, with the CJSON-derived C helper retained for long plain
spans. Only incomplete sequences resume byte state across input blocks. This
retains LeanJSON's grammar, validation and bounded indexes.
`scanner="legacy"` selects the previous byte-wise path for comparisons or
rollback. Both work with lazy/eager/preload and Schema validation. Complete
memory input runs compatibility diagnostics only after an error; file-backed
and incremental sources retain resumable diagnostics and batch their string
scans. The option does not call `cjson.decode` or build a cjson tree.

## Inspect fields without loading their contents

Use optional paths to query lazy values directly:

```lua
local json = require "leanjson"
local body = json.decode_file("/tmp/request.json")
local bytes = json.len(body, "$.prompt")       -- decoded string bytes
local count = json.len(body, "$.messages")    -- array elements / object keys
local present = json.exists(body, "$.prompt")
local falsy = json.is_empty(body, "$.prompt")
json.close(body)
```

`exists` tests presence: JSON null and boolean false both exist. `is_empty`
uses **Lua truthiness**, as requested by this API's contract: only missing/nil
and false are empty. Empty strings/containers, zero, whitespace and the
`json.null` sentinel are truthy. It does not trim strings or count contents.

`len(value, path)` returns decoded string byte length, array size or distinct
logical object-key count. Preloaded, edited and ordinary Lua strings use their
existing length; other strings are counted in bounded decoded chunks, without
constructing a complete string. Sparse paths may require source scans. Paths
use `get`'s dot and zero-based array-index syntax, with an optional `$` root
prefix; `$` or `""` selects the root. Wildcard/quoted-key selectors are not
supported. Missing/non-traversable paths return nil for `len`, false for
`exists`, and true for `is_empty`. Resolved number/bool/null values have no
length and raise; invalid paths, closed sources and I/O errors also raise.

`len(value)` retains its existing behavior, including ordinary Lua table
length. Supplying `path` is essential for long strings: `len(body.prompt)`
evaluates and loads `body.prompt` before calling the helper. The query family
is also available on independent and safe codecs; inspection errors are
thrown rather than protected conversion results.

## Map values with explicit source references

`ref(value[, path])` captures an immutable logical value without reading a lazy
string into Lua. It accepts the same optional paths as the inspection helpers:

```lua
local json = require "leanjson"
local a = json.decode_file("/tmp/input.json")
local b = json.decode('{}')
b.messages = json.ref(a, "$.prompt")
```

Assigning to a proxy copies the captured value's ownership, sharing its source nodes.
It preserves the JSON type: a referenced string becomes a string at `b.messages`.
For a chat message array, construct the small wrapper around the reference:

```lua
local prompt = json.ref(a, "$.prompt")
b.messages = { { role = "user", content = prompt } }
json.close(prompt)       -- b now holds its own source lease
json.close(a)
local reader = json.reader(b, { chunk_size = 65536 }) -- preserves unchanged string tokens
json.close(b)            -- the reader independently owns its snapshot
-- Consume reader:next() chunks; close the reader on an early exit/error.
```

References capture the **current** value, including edits and preloads; later
source writes do not change them. Source-backed strings/subtrees stay shared.
Existing Lua strings are shared, while ordinary/eager Lua containers are
snapshotted under the normal assignment rules. `ref` does not make already
eager input lazy. A retained reference/target/reader can extend the lifetime of
the entire original buffer or source file. Close retained handles explicitly;
unretained temporary handles also release their leases through GC.

A reference is an opaque handle: normal field access and mutation are rejected.
It uses userdata when available and a protected table otherwise. The fallback
cannot intercept Lua raw operations such as `rawset`; added raw fields are not
part of its captured JSON value. Use `json.type`, `json.len`, `json.exists`,
`json.is_empty`, `json.encode`, `json.reader`, `json.materialize` and `json.close`
for inspection/output. `materialize` explicitly loads the logical value.
`fork(ref)` returns an independent mutable proxy for a container; scalar refs
remain references so forking a long string does not decode it. Container views
returned by `get`/iteration are detached and cannot mutate the captured handle.
Ordinary target getters still return their normal values and may load strings.

An ordinary Lua table only stores the reference handle; its assignment has no
snapshot hook. Keep that handle open until encoding finishes or until a proxy
assignment, `fork`, or `reader` has captured it. For example,
`local reader = json.reader({ content = prompt })` captures ownership when
the reader is created, so `prompt` can then be closed.

A missing/nil or non-traversable path returns nil, so ordinary nil-assignment
rules apply. JSON null and false produce valid handles. The handle itself is
truthy in Lua; query helpers inspect the captured logical value (`is_empty` is
true for a false-valued reference). Invalid paths, closed sources and I/O errors
raise, including on safe codecs. Destination encoder policies and depth checks
continue to apply; references do not bypass validation or escaping.

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
  spellings. Nonfinite numbers always follow the called codec's encoding policy.
  Readers default to `preserve_raw_strings=true`: unchanged source strings keep
  their original JSON spelling, including slash, Unicode and DEL spellings.
  Use `reader(value, {preserve_raw_strings=false})` for the previous string
  formatting policy. `encode()` and `tostring()` keep that previous policy;
  new/modified Lua strings and reconstructed keys always use the calling codec.
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

`encode_keep_buffer([value])` is a compatibility-only setting for migrating
cjson code. It defaults to true, accepts booleans or `on`/`off`, and returns the
current setting when called without a value (or with nil). A setter returns the
new value; invalid or extra arguments raise errors, including on safe codecs.
Module, normal/safe `new()` instances each own their setting. **It does not
change allocation or buffer retention:** LeanJSON has no reusable whole-output
buffer retained between encoding calls. `encode()` still allocates a complete
result string; `reader()` generates chunks under its existing lifecycle. Reader steps use call-owned staging buffers of at most 64 KiB; no writable
encoder scratch is retained across calls.

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
hash entries, taking precedence over `__len` and `__index`. Without a `__len`
method, `empty_array_mt` first applies ordinary sparse policy, then forces an
array if ordinary classification would choose an object. Its ordinary array
path honors indexed reads (`__index`); its forced fallback uses raw values. The
shared `empty_array` sentinel always encodes as `[]`.

Other Lua tables with a raw `__len` field in their real metatable encode as
external arrays. Protected metatables and callable length values work; inherited
or fabricated public metadata does not select an array. The length callback
receives the table once per occurrence. Hash keys and ordinary sparse settings
are ignored, and positions `1..length` use ordinary indexing, including
`__index`. Missing values encode as null.

```lua
local virtual = setmetatable({}, {
    __len = function() return 3 end,
    __index = { "foo", "bar", "baz" },
})
assert(codec.encode(virtual) == '["foo","bar","baz"]')
```

Length results use native Lua number/string conversion and truncate fractions
toward zero. Nonnumeric results, nil, booleans, tables and cdata mean zero;
finite negative lengths produce `[]`. LeanJSON rejects nonfinite or truncated
out-of-signed-32-bit lengths with `Cannot serialise table: external array length
must be finite and fit a signed 32-bit integer`, rather than reproducing
nonportable native C conversions. No smaller length cap applies.

Readers, forks and proxy assignments capture external callbacks and values when
constructed, so later edits do not change the snapshot. Readers do not repeat
these callbacks in `length()` or `next()`. External array semantics override
`keep_origin` reuse. LeanJSON's own JSON proxies retain their source semantics
and do not invoke external length callbacks. Normal/safe codecs and `new()`
instances share these rules; normal/safe encoding preserves callback error
objects, while readers retain their existing `nil, string_error` interface.
Readers release owned resources before formatting errors. If an error object's
`__tostring` throws or returns a non-string value, the reader reports
`leanjson.reader: error message unavailable`.

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
        file_in_memory = false, -- keep this example file-backed
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

The example explicitly selects `file_in_memory=false`, so the input file must
stay immutable while holders use it. LeanJSON closes its
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

Successful lazy lookups can add final per-key/index results, including confirmed
absence and path ancestors, even outside the automatic prefix/depth bounds.
They remain subject to the byte budget. Repeated lookups and forks share this
immutable-source cache; branch edits take precedence. Partial automatic indexes
never certify an earlier duplicate as the final value. `source_stats()` reports
`structural_index_bytes`, `lookup_cache_bytes`, `lookup_cache_hits` and
`lookup_cache_misses`; `index_bytes` includes all retained optional metadata and
may change after reads. Structural storage retains selected validated value-string
spans with 64-bit coordinates, rather than a full member tree or all punctuation.

## Native OpenResty integration

```lua
local input = require "leanjson.openresty"
```

- `input.read_body(opts)` automatically receives/scans an unread fixed-length
  HTTP/1.1 body through `ngx.req.socket()`, waits for validated EOF and returns
  the owned value. HTTP/2, chunked and already-buffered bodies use the completed
  Nginx body path.
- `input.start_body(opts)` can receive and scan chunks while a fixed-length
  HTTP/1.1 upload is arriving. HTTP/2 and chunked uploads use the completed-body
  fallback. The current decoder publishes final query values only after EOF
  and full validation; this is not early forwarding of an incomplete JSON body.
- `input.request(httpc, request, value, opts)` sends bounded JSON chunks through
  lua-resty-http, sets the encoded Content-Length, and preserves reader errors.
  It makes one attempt and does not retry automatically.

File/incremental source storage defaults to memory, independently of lazy field
loading. `file_in_memory=false` selects the original fd/window or decoder spool
mode. This option is accepted by `decode_file`/`new_decoder`, HTTP `opts.decode`
and as a top-level HTTP override. A completed Nginx temporary file is read once,
retained as memory chunks and closed before returning by default. Later reads and
output do not reread that source file; no whole-body concat/reparse is needed.
`info.storage` reports `memory` or `file`; `info.mode` reports the input path.
Internal duplicate-key workspace can still spill, and memory storage grows with
input size and the number of independently retained sources.

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

At revision `33d00b5`, the fresh Linux ARM64 run passed **66/66 default
paired memory checks**: 33 cases for each of the table and userdata carriers,
across memory/file/feed inputs. Each comparison used separate native OpenResty
processes, direct mutation and no forced GC during measured phases.

The following completed-file cases contain 32,768 entries. Values are peak
process RSS; each carrier has its own independently measured cjson baseline.

| Shape | cjson / table carrier | LeanJSON table | cjson / userdata carrier | LeanJSON userdata |
| --- | ---: | ---: | ---: | ---: |
| Short array objects | 18.64 MiB | 13.96 MiB | 18.61 MiB | 13.93 MiB |
| Small-object fields | 23.17 MiB | 15.14 MiB | 23.12 MiB | 15.05 MiB |
| Scalar fields | 15.87 MiB | 15.03 MiB | 15.80 MiB | 15.11 MiB |

These are finite observations, not a universal memory bound. The closest
userdata comparison, wide scalars from memory, had only **16 KiB** of headroom.
Eager loading can use more memory than cjson, and lower RSS can come with
substantial CPU and synchronous I/O costs. This run does not establish a
production throughput or latency improvement.

The [current verification report](docs/verification/full-verification.md)
contains the complete memory/loading results, compatibility matrix, original
failures, tool identities, reproducible commands and evidence archives. Its
results replace the earlier measurements formerly stored in this directory;
those reports remain in Git history.

Additional boundaries:

- File I/O is synchronous. Bounded buffers and yields do not make disk access
  asynchronous; storage latency can still delay an OpenResty worker.
- This is not a transparent drop-in replacement for lua-cjson. Use
  `leanjson.encode` for proxies, or explicitly materialize for other encoders.
- With the default table carrier, native `next`, `rawget` and `rawset` bypass
  proxy behavior and `table.getn` sees raw empty storage. With the userdata carrier,
  these operations and native table-only functions reject the type. Use
  `json.pairs`, `json.ipairs` and `json.len`; these also work on stock LuaJIT
  without Lua 5.2 compatibility support.
- Third-party libraries may reject or skip userdata, or apply their own policy.
  Use eager decoding or `materialize()` where a library requires ordinary tables.
- Proxy arrays stay dense. Use `array_insert` / `array_remove` for structural
  changes. `nil` deletes a field; `json.null` represents JSON null.
- Concurrent mutations on the same branch may report a stale-mutation conflict
  across a yield. Use independent forks or handle the conflict explicitly.
- Lua decode validates the entire input under the chosen number/byte policy;
  native-compatible permissive defaults are described above. The inherited
  low-level `parse` API remains strict by default and has a separate opt-in
  lazy-validation mode.

## Compatibility and migration

The [current upstream cjson matrix](docs/verification/full-verification.md)
was run on OpenResty 1.29 ARM64 with Lua 5.2 compatibility enabled. It
covers lazy, `lazyload=false` and preload modes across memory, file and
incremental input, for both proxy carriers. Each cell retains all 164 upstream
records. Eager cells pass 159 assertions and differ only on the intentionally
separate module identity; three records are setup helpers and one conditional
record does not apply in this environment.

Lazy and preload cells also retain intentional proxy-array differences. The
userdata carrier adds observable Lua type differences, so an upstream comparator
that requires tables rejects those containers. Native table operations do not
become transparent. Use the proxy API, or eager loading / `materialize()` when
ordinary Lua values are required. The report preserves exact upstream verdicts
separately from semantic diagnostics and does not claim complete cjson
compatibility. The strict project gate records module identity, lazy-array
semantics and userdata carriers as declared differences. It reports
`accepted=true, compatible=false` when only those differences remain; unexpected
errors or content/container-kind changes still fail. A separate Ubuntu distro
LuaJIT beta3 run without Lua 5.2
compatibility still has **7 failed and 3 pending tests**; its Valgrind run also
reports failures and memory-check errors. See the report for exact runtime
boundaries and the blocked OpenResty 1.27 / x86_64 ASan checks.

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
- [Complete verification report and evidence](docs/verification/full-verification.md)
- [Migrating from lua-cjson](docs/migrating-from-cjson.md)
- [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md) · [License](LICENSE)
