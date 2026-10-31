# Migrating from lua-cjson

`qjson` has a cjson-shaped Lua API for incremental migrations, but it is not a
table-building decoder internally. `qjson.decode` returns a lazy proxy over the
original JSON document, and `qjson.encode` knows how to encode that proxy without
materializing unchanged subtrees.

Use this guide when replacing `lua-cjson` in existing LuaJIT or OpenResty code.

## API mapping

| lua-cjson | qjson | Notes |
| --- | --- | --- |
| `cjson.decode(json)` | `qjson.decode(json)` | Returns a lazy object or array proxy, not a plain Lua table. |
| `cjson.decode(json)` when a plain table is required | `qjson.materialize(qjson.decode(json))` | Use before passing decoded data to libraries that use raw table access or C encoders. |
| `cjson.encode(value)` | `qjson.encode(value)` | Encodes lazy proxies, plain Lua tables, and mixed trees. |
| `cjson.encode_number_precision(precision)` | `qjson.encode_number_precision(precision)` | Shared module-level encode setting in the Lua VM. qjson accepts integers from 1 to 14 and returns the previous setting when updated. |
| `cjson.null` | `qjson.null` | Aliases `cjson.null` when lua-cjson is available; otherwise qjson provides its own sentinel. |
| `cjson.empty_array_mt` | `qjson.empty_array_mt` | Aliases lua-cjson's empty-array metatable when available. |
| `pairs(t)` / `ipairs(t)` on decoded data | `qjson.pairs(t)` / `qjson.ipairs(t)` | Works on all LuaJIT builds. Plain `pairs` / `ipairs` need LuaJIT 5.2-compat support. |
| `next(t)` on decoded data | No direct lazy-proxy equivalent | Use `qjson.pairs`, `qjson.ipairs`, or `qjson.len`; materialize first if a library requires native `next`. |
| `#t` on decoded data | `qjson.len(t)` | Works on all LuaJIT builds. Plain `#t` needs LuaJIT 5.2-compat support. |
| Field reads after decode | `t.key`, `t[1]`, or `qjson.parse(json):get_*("path")` | Use `qjson.parse` and cursors for parse-once, extract-a-few-fields hot paths. |

## Pick the migration path

For code that already does `decode -> read or mutate -> encode`, start with the
lazy table API:

```lua
local qjson = require("qjson")

local body = qjson.decode(payload)
local model = body.model
body.seen = true

return qjson.encode(body)
```

For code that only needs a few fields, skip the table-shaped API and use the
cursor API directly:

```lua
local qjson = require("qjson")

local doc = qjson.parse(payload)
local model = doc:get_str("body.model")

local usage = doc:open("usage")
local input_tokens = usage and usage:get_i64("input_tokens")
```

Typed integer getters are lossless. `get_i64` returns LuaJIT `int64_t` cdata,
and `get_u64` returns `uint64_t` cdata for unsigned IDs such as Snowflakes or
database `unsigned bigint` values. This avoids LuaJIT's double precision limit
for JSON integers above 2^53. Use `get_f64(path)` for the Lua-number behavior,
or wrap `tonumber(doc:get_i64(path))` only when the value is known to fit.

For code that passes decoded data to a third-party encoder, validator, or helper
that expects an ordinary Lua table, materialize first:

```lua
local qjson = require("qjson")

local proxy = qjson.decode(payload)
third_party_library.accept_table(qjson.materialize(proxy))
```

Do not pass a qjson lazy proxy directly to `cjson.encode`. lua-cjson is written
in C and does not honor the metamethods qjson uses for lazy reads.

`qjson.encode` also accepts LuaJIT `int64_t` and `uint64_t` cdata values and
emits them as decimal JSON integers without `LL` or `ULL` suffixes.

## Behavior differences

### Decoded values are lazy proxies

`qjson.decode` returns a lazy object or array proxy. Field and index reads decode
only the requested value. Nested containers are also proxies and keep stable Lua
identity when read repeatedly.

Writes keep objects and arrays as proxies and copy structural references along
the modified path without decoding sibling scalars. `qjson.type(value)` reports
`"array"`, `"object"`, `"null"`, or the scalar type; an array proxy does not use
`qjson.empty_array_mt`. `qjson.decode` returns ordinary scalar values for scalar
JSON roots.

`qjson.fork(value)` freezes the current logical value into an independent branch.
Proxy assignment snapshots ordinary Lua tables and other proxies too; it does
not create a shared mutable alias. Replacing/deleting a field detaches an already
returned child proxy. This differs from assigning references between ordinary
Lua tables. Cyclic plain tables are rejected when snapshotting.

Object getters use the last duplicate key even before a write. Untouched source
objects may retain duplicate lexical entries in iteration and output. Modified
objects collapse duplicates in first-appearance order with the last value;
`qjson.reader(value, { normalize_duplicates = true })` normalizes recursively.

Untouched scalar spans retain their original spelling when a sibling changes.
Merely reading `9007199254740993` through the Lua-number getter does not round the
output token. Explicitly assigning that Lua number back applies the configured
numeric encoder and may round it. To deliberately normalize a number, replace
that field with the decoded value.

Proxy arrays support replacement and tail append. `arr[i] = nil` deletes only a
tail slot; interior holes and noncontiguous writes raise an error before changing
the array. Use `qjson.array_insert(arr, index, value)` and
`qjson.array_remove(arr, index)` for dense sequence changes. Explicitly
materialize before using arbitrary sparse Lua-table operations; their encoding
continues to honor `qjson.encode_sparse_array`.

See [mutable views and bounded output](source-proxy-api.md) for the complete
reader, ownership and lifecycle contract.

### Iteration and length helpers

OpenResty LuaJIT enables Lua 5.2 compatibility, so plain `pairs`, `ipairs`, and
`#` dispatch to the proxy metamethods there. Stock LuaJIT 5.1 often does not.
Portable code should use:

```lua
for k, v in qjson.pairs(obj) do
    -- object fields in source order
end

for i, v in qjson.ipairs(arr) do
    -- array elements in order
end

local n = qjson.len(obj_or_arr)
```

`qjson.materialize` converts proxies into plain Lua tables. Duplicate object keys
collapse to the last value during materialization, matching the table shape that
lua-cjson callers usually observe.

### Native `next` is not supported on proxies

Lua's native `next(t)` walks the raw table storage directly; it does not call
`__pairs`, `__ipairs`, `__index`, or any qjson helper. On a qjson lazy proxy,
that raw storage is empty, not the decoded JSON object or array. Private state
and child caches are stored outside the proxy table. This means `next(proxy)` is
not a valid way to iterate JSON fields, fetch the first entry, or test whether a
decoded object is empty.

Replace common `next` patterns with proxy-aware helpers:

```lua
-- Before, with cjson-decoded plain tables:
if next(obj) == nil then
    -- empty object
end

-- After, with qjson lazy proxies:
if qjson.len(obj) == 0 then
    -- empty object or array
end

for k, v in qjson.pairs(obj) do
    -- object fields in source order
end

for i, v in qjson.ipairs(arr) do
    -- array elements in order
end
```

If code you do not control calls `next`, `rawget`, `rawset`, or otherwise expects
ordinary table storage, pass `qjson.materialize(proxy)` instead of the proxy.

### Validation mode

`qjson.decode(json)` uses qjson's default eager parsing path. Eager mode validates
structure, trailing content, number syntax, string content, and UTF-8 at parse
time.

`qjson.parse(json, { lazy = true })` is available for code that wants value-level
errors to surface only when the offending field is accessed. This is the parser
validation mode, not the same thing as the `qjson.decode` lazy table proxy.

### Nulls and empty arrays

When lua-cjson is installed, qjson reuses `cjson.null` and `cjson.empty_array_mt`
so existing sentinel comparisons can keep working:

```lua
local cjson = require("cjson")
local qjson = require("qjson")

assert(qjson.null == cjson.null)
assert(qjson.empty_array_mt == cjson.empty_array_mt)
```

When lua-cjson is not installed, qjson provides compatible sentinel values for
its own encoder and materializer.

## Unsupported lua-cjson APIs

qjson intentionally does not implement every lua-cjson configuration API.

| lua-cjson API | qjson status |
| --- | --- |
| `cjson.new()` | No equivalent. qjson has module-level functions and no isolated per-instance encoder/decoder state. |

If your application depends on an unsupported lua-cjson knob, keep lua-cjson for
that path or isolate the migration to call sites that use decode/encode without
per-instance configuration.

## Supported sparse-array configuration

qjson now supports lua-cjson-style sparse-array controls via
`qjson.encode_sparse_array(convert, ratio, safe)`.

- Getter mode (`qjson.encode_sparse_array()`) returns the current triplet.
- Setter mode updates only arguments that are non-`nil`, and still returns the
  full updated triplet.
- Defaults match lua-cjson/OpenResty lua-cjson: `false, 2, 10`.
- Excessive sparsity triggers only when
  `ratio > 0 and max_index > safe and max_index > key_count * ratio`; setting
  `ratio = 0` disables the excessive-sparse check.

`qjson.encode_sparse_array` is module-level global state, just like other qjson
module settings. There is no `cjson.new()`-style isolated instance, so in
OpenResty the setting persists for the lifetime of each worker process and can
affect subsequent requests handled by the same worker.

## Incremental checklist

1. Replace `local cjson = require("cjson")` with `local qjson = require("qjson")`
   in one read-heavy path.
2. Replace `cjson.decode` / `cjson.encode` with `qjson.decode` / `qjson.encode`.
3. Replace `pairs`, `ipairs`, and `#` on decoded values with `qjson.pairs`,
   `qjson.ipairs`, and `qjson.len` for LuaJIT portability.
4. Add `qjson.materialize(value)` before sending decoded values to third-party
   encoders or helpers that require plain Lua tables.
5. In hot paths that only read a few fields, consider `qjson.parse` plus
   `doc:get_*` or cursor getters instead of `qjson.decode`.
6. Leave call sites that depend on `cjson.new` on lua-cjson until they can be
   redesigned.
