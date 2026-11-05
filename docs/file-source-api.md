# File and incremental JSON sources

`leanjson.decode_file(path, opts)` validates a complete file once through bounded
reads and returns lazy scalar/proxy values, or ordinary Lua values with
`lazyload=false`. It raises on invalid JSON, options or I/O. By default,
`file_in_memory=true` retains immutable input chunks in memory and closes the
input fd before returning, including for lazy values. Later getters, forks and
readers use those chunks; modifying/removing the original after decode does not
change the snapshot. There is no whole-input concat or second parse.

Set `file_in_memory=false` to retain the original bounded fd/window behavior.
That file must remain immutable while any holder uses it. LeanJSON never unlinks
an original path. Eager results own no descriptors after file decode completes.

```lua
local body = leanjson.decode_file(path, { chunk_size = 65536 })
local branch = leanjson.fork(body)
branch.model = "replacement"
local reader = leanjson.reader(branch, { normalize_duplicates = true }) -- raw strings preserved by default
local length, err = reader:length()
if err then error(err) end
-- Send length and consume reader:next(), preserving any returned error.
reader:close()
leanjson.close(branch)
leanjson.close(body)
```

These functions are independent of `ngx`. File I/O is synchronous. Smaller windows bound each operation's working buffers; they do not make disk I/O asynchronous or guarantee constant total memory. Retained native indexes obey the source metadata budget. Validation/traversal workspace, live public views, durable overlays and explicitly read scalar values still occupy memory.

## Options and callbacks

`decode(raw, opts)`, `decode_file` and `new_decoder` validate the same parsing options. Calling `decode(raw)` without options retains eager validation with the native-compatible numeric/byte policy and lazy value loading; the legacy `parse` API keeps its separate option contract. File/spool controls are validated in all modes but apply only where specified below:

| Option | Default | Behavior |
| --- | --- | --- |
| `file_in_memory` | `true` | Boolean; retain file/feed bytes in memory. False keeps an original source fd or creates an owned incremental spool. Independent of lazy/eager/preload loading. |
| `chunk_size` | `65536` | Positive uint32 integer; bounds file reads, feed steps and native scalar windows. |
| `max_depth` | codec `decode_max_depth()` (`1000`) | Nonnegative uint32 integer; zero inherits the codec default, nonzero overrides it. Source v2 does not clamp at 4096; the legacy parse/v1 limits remain separate. |
| `index_depth` | `3` | Nonnegative uint32 integer; root depth is 0 and `a.b.c` is the default span frontier. Zero retains no optional children. |
| `index_array_limit` | `3` | Nonnegative uint32 integer; optional retained prefix per array, with exact full length and scanning for farther elements. Zero disables the prefix. |
| `index_budget_bytes` | `1048576` | Nonnegative uint32 integer; shared native index-capacity budget per source across parse and later operations. Zero disables optional cached indexes. |
| `structural_index` | `true` | Boolean; retain optional validated value-string boundaries to skip bodies during later member walks. False disables this store only; JSON/Schema validation, prefix indexing and demand caching remain correct. |
| `schema` | absent | A reusable `compile_schema` plan or boolean/table Schema; validate during the original scan before returning values. See [Schema assertions and costs](schema-validation.md). |
| `lazy` | `false` | High-level sources support eager validation only; `true` is rejected. |
| `lazyload` | `true` | Boolean. `false` builds complete ordinary tables/scalars during the scan, without proxy descendants or hidden source ownership. |
| `preload_paths` | absent | Dense array of JSONPath-subset strings. Selected values/subtrees and their required route metadata load during scanning independently of every index bound. All remaining fields remain lazy/readable. Syntax is checked even when `lazyload=false`. |
| `temp_dir` | `$TMPDIR` or `/tmp` | Existing directory for decoder input spools when file_in_memory=false and active duplicate-normalization spill storage. Default memory-backed input creates no source spool; wide normalized operations may create an unlinked spill file. |
| `on_chunk(bytes_sofar)` | absent | Runs between bounded file/feed source steps and may yield; not invoked by direct string decoding. Memory-backed file/feed input still invokes it. The argument is the received/scanned byte total and stays fixed during later value reads. |

The same loading options and bounds propagate through OpenResty `read_body`/`start_body` in `opts.decode`; HTTP chunk/callback overrides preserve them. The HTTP adapter also accepts top-level `file_in_memory`, which overrides `opts.decode.file_in_memory`; invalid nested options are still rejected before input is consumed. Metadata bounds do not weaken full eager JSON validation or the independent nesting limit. See [loading modes and selector syntax](source-proxy-api.md) for wildcards, escaping, duplicates and the separate selected-data diagnostic units. Preloading never produces a projection; unmodified semantic values remain available. With `decode_allow_comment(true)`, source/decoder creation freezes comment acceptance, and all output paths omit actual comments while preserving eligible clean child spans. The codec setter is independent of the loading options and defaults to false.

The index byte budget covers automatic prefixes, structural spans and confirmed
demand results, including unused allocation capacity. Reading a path can retain
its ancestors and a final positive or negative result, beyond automatic depth or
array-prefix bounds. It does not index every scanned sibling. A confirmed result
is usable without a complete object index; unconfirmed prefix occurrences still
require scanning for later duplicates. Saturation falls back to correct reads,
and admission can release rebuildable prefix/structural metadata. Shared source
identities preserve results across forks while each branch's patches take
precedence. Diagnostic counters are lifetime cumulative; `index_bytes` can grow
or shrink after reads. `source_stats` additionally exposes
`structural_index_bytes`, `lookup_cache_bytes`, `lookup_cache_hits` and
`lookup_cache_misses` without changing the existing C stats layout.

Synchronous file reads reuse one worker-local buffer up to 64 KiB. Larger
caller-selected windows are not retained in that pool. Returned Lua strings are
copies; this bounds reusable I/O storage without changing pointer lifetimes or
making a full-request memory guarantee.

No Lua callback runs inside Rust. Every native output pointer is copied before the callback. A callback error propagates as a source failure and releases the failing operation's resources. The caller should close its holders on cancellation. The OpenResty adapter handles request cleanup separately.

If a mutation yields and another coroutine changes its proxy or a linked ancestor, it raises the nonterminal `leanjson: stale proxy mutation` before publication. It preserves the completed writer, dense array positions and held child links. Retry against the current value if needed; independent forks do not conflict. See [mutable view semantics](source-proxy-api.md).

## Incremental input

```lua
local decoder = leanjson.new_decoder({ temp_dir = "/var/tmp/leanjson", chunk_size = 65536 })
local ok, err = decoder:feed(chunk)
if err then error(err) end
local pending, status, query_error = decoder:get("messages[0].role")
-- status is NEED_INPUT until finish confirms EOF and complete validation.
local body, finish_error = decoder:finish()
if finish_error then error(finish_error) end -- false and leanjson.null are valid roots
decoder:close() -- body remains usable
leanjson.close(body)
```

`new_decoder(opts)` validates its options and retains bounded immutable Lua chunks in memory by default, without a source spool. With `file_in_memory=false`, it creates an exclusive owner-only (0600) spool with `mkstemp`. Construction errors raise. `feed(chunk)` returns `true` or `nil, error`; large chunks are processed through bounded feed steps. No borrowed input pointer survives a native call.

`finish()` confirms EOF and returns `value` or `nil, error`. Strings, numbers, booleans, null and containers all require successful completion. Repeated successful `finish()` calls create independent views of the same immutable source. With `lazyload=false`, the first finish transfers its ordinary value; later finish calls rebuild independent ordinary values from bounded source windows, so caller edits cannot affect subsequent results. The decoder retains its input chunks or spool until close, without retaining a second full Lua value. Feeding after completion is rejected without invalidating completed values.

`feed()` and `finish()` reject overlapping calls with `nil, error` while an earlier input/completion operation is suspended in a callback. Rejection does not abort the source or accept any bytes from the overlapping call. Resume/complete the current operation before feeding or finishing again; `close()` and `abort()` remain available for cancellation.

`get(path)` returns one of:

| Result | Meaning |
| --- | --- |
| `value, "READY"` | A complete final value; `false` and `leanjson.null` are values. |
| `nil, "NEED_INPUT"` | EOF/full validation has not completed. |
| `nil, "ABSENT"` | The completed object/array has no such field/index. |
| `nil, "ERROR", error` | Invalid query, malformed input, abort, I/O failure or closed decoder. |

The native `NEED_READ` status is handled internally through bounded memory or file windows. The source APIs deliberately expose no provisional values: a closing root before EOF does not establish final duplicate-key or absence results. Completed decoder queries refer to its immutable source; proxy edits do not rewrite that source.

Eager `get` results are independent ordinary values too; a later eager container
query reconstructs only its requested source subtree. Those repeated eager
queries can read retained chunks (or perform I/O in file mode) and run `on_chunk`. This Decoder contract is
separate from the OpenResty Session contract: a Session owns one completed value,
and its later `get`/`finish` calls observe edits to that value in either loading
mode, including completed-body fallback sessions.

`abort(reason)` invalidates unfinished input and releases its input storage ownership. After successful finish it returns `nil, error` and leaves completed values valid. `close()` is idempotent, drops decoder ownership and makes later decoder queries return `ERROR`. It leaves independently returned proxies/readers/forks valid.

## Paths, proxies and explicit reads

`leanjson.get(value, path)` follows the existing Doc path grammar: dot keys and zero-based uint32 bracket indexes, such as `messages[0].role`. Proxy array indexing remains one-based. Invalid paths and type mismatches raise; an absent value returns nil. Returned container proxies remain linked to their live ancestors just like ordinary indexing, until a parent path is replaced/deleted/closed. Path and ordinary indexing share canonical private cells, including across array insert/remove; repeated attached-child reads return the same live proxy. The accessor creates no hidden intermediate public proxies or leases.

File/incremental proxies use the same overlays, duplicate-key last-wins lookup, snapshots, array helpers and reader as memory proxies. Untouched scalar output preserves its raw numeric/string spelling, including integers above the Lua exact-number range. Explicit scalar access can materialize one entire string or numeric token; numeric access converts to a Lua number and rejects nonfinite results. Explicit `leanjson.encode` and `leanjson.materialize` can allocate complete outputs/trees.

`leanjson.materialize(file_value)` returns independent ordinary values. `keep_origin=true` is explicitly unsupported for any value referencing a file/incremental backend, including mixed overlays. Memory-source provenance remains supported. This prevents ordinary tables from acquiring hidden file ownership: `leanjson.close` is a no-op for ordinary tables and scalars.

All native source offsets are uint64. Before Lua file I/O or span arithmetic, offsets must fit the exact integer range through `2^53-1`; larger coordinates are rejected rather than rounded/truncated.

## Closing and cancellation

`leanjson.close(proxy)` closes that proxy idempotently. Later proxy access raises. A held child, fork or reader owns independent leases and remains usable. Closing a cached child detaches its cache entry; accessing that unchanged parent field again returns a fresh usable proxy. Closing does not edit JSON.

Each holder retains every backend referenced by its logical value. Replacing a node acquires its new dependencies before releasing old ones. Dependency collection stops at immutable raw subtrees and walks only synthetic overlay nodes; it does not read/materialize source descendants. Removing the last source dependency can close a file while a fully synthetic proxy remains usable.

Active backend operations belong to the initiating public holder's cancellation scope, including through private path ancestors. Explicit holder close cancels only its own operations and releases their leases immediately, even if its coroutine remains suspended/killed and GC is stopped. True source I/O errors invalidate all consumers of that source and remain errors rather than normal EOF. GC finalizers are fallback resource cleanup for omitted closes and avoid weak-table key/value cycles. Collecting a public wrapper releases its leases without changing canonical logical links needed by a live root and descendant; explicit close retains its detach semantics.

The final lease closes the descriptor, releases selected caches and unlinks an owned spool deterministically. An original `decode_file` path is never unlinked. Reader EOF, error and close release only that reader's scope; other holders remain valid. Close/failure drops incomplete loading builders; independently returned selected child/fork values keep their cache and file leases until their own final close.

Reader construction freezes the logical snapshot and acquires leases without source I/O. `length()` performs and caches full length/encoding validation; `next()` performs that validation first if needed, before returning any output. Both operations can yield through source callbacks. Close wins over a late suspended result, while a previously successful length stays available after close.

The additive sparse C ABI is version 2 (`leanjson_source_v2_*`), documented in `include/leanjson.h`. It uses immutable span handles and resumable targeted lookup/iteration with bounded `NEED_READ` windows. Loading adds immutable selector compilation/configuration and drainable BEGIN/DATA/END scan events, copied between bounded feed steps; no event may be published before successful final validation. Feed/finish/abort/source retain/release and scalar operation pumping reuse the unchanged v1 functions. Existing v1/v2 struct layouts and the contiguous `parse` API remain unchanged. Use v1 metadata/node/iteration functions with v1-created sources and v2 span/iteration functions with v2-created sources. The Lua loader requires sparse/loading exports and rejects an older native library with a missing-symbol diagnostic. See [source diagnostics and duplicate workspace](source-proxy-api.md) for the accounting boundary.

## Socket-first OpenResty input

`require("leanjson.openresty").read_body(opts)` automatically uses
`ngx.req.socket()` for an unread fixed-length HTTP/1.1 body. It scans while
receiving, retains source chunks in memory by default, waits for EOF/full
validation, and transfers an independently owned value to its caller.
`start_body(opts)` exposes the same producer as an explicit Session; its final
values/absence results still require complete validation.

HTTP/2, Transfer-Encoding/chunked input, missing/invalid Content-Length, empty
bodies and already-buffered Nginx bodies use the completed-body fallback. A
Nginx temporary file is copied into retained chunks during its one decode pass
and closed before returning. Socket read/parse errors are terminal: input is
never replayed through fallback after socket consumption begins. Other modules
must not concurrently consume the same body.

```lua
local input = require "leanjson.openresty"
local body, err, info = input.read_body({
    chunk_size = 65536,
    file_in_memory = true, -- default; false selects fd/spool source storage
    decode = { preload_paths = { "$.model", "$.stream" } },
})
if err then error(err) end
-- info.mode: incremental, completed-memory or completed-file (input origin).
-- info.storage: memory or file (retained source storage).
leanjson.close(body)
```

Memory storage occupies O(input bytes) plus chunk metadata and is shared by
independent holders. The final close clears those retained chunks; cancellation
releases unfinished input. This option removes source-file rereads, not all
possible disk I/O: exact duplicate-key workspace may still spill in `temp_dir`.
It is separate from loading fields into ordinary Lua objects and does not make
initial file reads asynchronous.

## Output string preservation

Readers preserve unmodified source string tokens by default, including original
escape spellings. Length uses the raw span and output reads bounded source
windows. `preserve_raw_strings=false` applies the previous codec string policy;
`encode()` keeps that policy. New/modified strings are encoded in Rust with
bounded reader output. This choice is independent of `file_in_memory`, lazy
loading and preload selection; it changes JSON spelling, not the decoded value.
