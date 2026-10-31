# File and incremental JSON sources

`qjson.decode_file(path, opts)` validates a complete file using bounded windows and returns the same scalar/proxy values as `qjson.decode`. It raises on invalid JSON, options or I/O. It never reads or concatenates the complete file into a Lua string. The original file must remain immutable while values/readers use it; the library never unlinks that path.

```lua
local body = qjson.decode_file(path, { chunk_size = 65536 })
local branch = qjson.fork(body)
branch.model = "replacement"
local reader = qjson.reader(branch, { normalize_duplicates = true })
local length, err = reader:length()
if err then error(err) end
-- Send length and consume reader:next(), preserving any returned error.
reader:close()
qjson.close(branch)
qjson.close(body)
```

These functions are independent of `ngx`. File I/O is synchronous. Smaller windows bound each operation's working buffers; they do not make disk I/O asynchronous or guarantee constant total memory. Structural metadata, keys, overlays and explicitly read scalar values still occupy memory.

## Options and callbacks

`decode(raw, opts)`, `decode_file` and `new_decoder` validate the same parsing options. Calling `decode(raw)` without options retains its default eager behavior; the legacy `parse` API keeps its separate option contract. File/spool controls are validated in all modes but apply only where specified below:

| Option | Default | Behavior |
| --- | --- | --- |
| `chunk_size` | `65536` | Positive uint32 integer; bounds file reads, feed steps and native scalar windows. |
| `max_depth` | `1024` | Nonnegative uint32 integer; zero selects the default, values above 4096 are clamped. |
| `lazy` | `false` | Source v1 supports eager validation only; `true` is rejected. |
| `temp_dir` | `$TMPDIR` or `/tmp` | Existing directory for owned decoder spools; memory and original-file decoding do not create spools. |
| `on_chunk(bytes_sofar)` | absent | Runs between bounded file/feed source steps and may yield; not invoked by memory decoding. The argument is the received/scanned byte total and stays fixed during later value reads. |

No Lua callback runs inside Rust. Every native output pointer is copied before the callback. A callback error propagates as a source failure and releases the failing operation's resources. The caller should close its holders on cancellation. The OpenResty adapter handles request cleanup separately.

If a mutation yields and another coroutine changes its proxy or a linked ancestor, it raises the nonterminal `qjson: stale proxy mutation` before publication. It preserves the completed writer, dense array positions and held child links. Retry against the current value if needed; independent forks do not conflict. See [mutable view semantics](source-proxy-api.md).

## Incremental input

```lua
local decoder = qjson.new_decoder({ temp_dir = "/var/tmp/qjson", chunk_size = 65536 })
local ok, err = decoder:feed(chunk)
if err then error(err) end
local pending, status, query_error = decoder:get("messages[0].role")
-- status is NEED_INPUT until finish confirms EOF and complete validation.
local body, finish_error = decoder:finish()
if finish_error then error(finish_error) end -- false and qjson.null are valid roots
decoder:close() -- body remains usable
qjson.close(body)
```

`new_decoder(opts)` validates its options and creates an exclusive owner-only (0600) spool with `mkstemp` in the configured directory. Construction errors raise. `feed(chunk)` accepts a Lua string and returns `true` or `nil, error`; even a large caller chunk is processed through bounded feed/write steps. No borrowed input pointer survives a native call.

`finish()` confirms EOF and returns `value` or `nil, error`. Strings, numbers, booleans, null and containers all require successful completion. Repeated successful `finish()` calls create views of the same immutable source. Feeding after completion is rejected without invalidating completed values.

`feed()` and `finish()` reject overlapping calls with `nil, error` while an earlier input/completion operation is suspended in a callback. Rejection does not abort the source or accept any bytes from the overlapping call. Resume/complete the current operation before feeding or finishing again; `close()` and `abort()` remain available for cancellation.

`get(path)` returns one of:

| Result | Meaning |
| --- | --- |
| `value, "READY"` | A complete final value; `false` and `qjson.null` are values. |
| `nil, "NEED_INPUT"` | EOF/full validation has not completed. |
| `nil, "ABSENT"` | The completed object/array has no such field/index. |
| `nil, "ERROR", error` | Invalid query, malformed input, abort, I/O failure or closed decoder. |

The native `NEED_READ` status is handled internally through bounded file windows. Source v1 deliberately exposes no provisional values: a closing root before EOF does not establish final duplicate-key or absence results. Completed decoder queries refer to its immutable source; proxy edits do not rewrite that source.

`abort(reason)` invalidates unfinished input and releases its spool ownership. After successful finish it returns `nil, error` and leaves completed values valid. `close()` is idempotent, drops decoder ownership and makes later decoder queries return `ERROR`. It leaves independently returned proxies/readers/forks valid.

## Paths, proxies and explicit reads

`qjson.get(value, path)` follows the existing Doc path grammar: dot keys and zero-based uint32 bracket indexes, such as `messages[0].role`. Proxy array indexing remains one-based. Invalid paths and type mismatches raise; an absent value returns nil. Returned container proxies remain linked to their live ancestors just like ordinary indexing, until a parent path is replaced/deleted/closed. Path and ordinary indexing share canonical private cells, including across array insert/remove; repeated attached-child reads return the same live proxy. The accessor creates no hidden intermediate public proxies or leases.

File/incremental proxies use the same overlays, duplicate-key last-wins lookup, snapshots, array helpers and reader as memory proxies. Untouched scalar output preserves its raw numeric/string spelling, including integers above the Lua exact-number range. Explicit scalar access can materialize one entire string or numeric token; numeric access converts to a Lua number and rejects nonfinite results. Explicit `qjson.encode` and `qjson.materialize` can allocate complete outputs/trees.

`qjson.materialize(file_value)` returns independent ordinary values. `keep_origin=true` is explicitly unsupported for any value referencing a file/incremental backend, including mixed overlays. Memory-source provenance remains supported. This prevents ordinary tables from acquiring hidden file ownership: `qjson.close` is a no-op for ordinary tables and scalars.

All native source offsets are uint64. Before Lua file I/O or span arithmetic, offsets must fit the exact integer range through `2^53-1`; larger coordinates are rejected rather than rounded/truncated.

## Closing and cancellation

`qjson.close(proxy)` closes that proxy idempotently. Later proxy access raises. A held child, fork or reader owns independent leases and remains usable. Closing a cached child detaches its cache entry; accessing that unchanged parent field again returns a fresh usable proxy. Closing does not edit JSON.

Each holder retains every backend referenced by its logical value. Replacing a node acquires its new dependencies before releasing old ones. Dependency collection stops at immutable raw subtrees and walks only synthetic overlay nodes; it does not read/materialize source descendants. Removing the last source dependency can close a file while a fully synthetic proxy remains usable.

Active backend operations belong to the initiating public holder's cancellation scope, including through private path ancestors. Explicit holder close cancels only its own operations and releases their leases immediately, even if its coroutine remains suspended/killed and GC is stopped. True source I/O errors invalidate all consumers of that source and remain errors rather than normal EOF. GC finalizers are fallback resource cleanup for omitted closes and avoid weak-table key/value cycles. Collecting a public wrapper releases its leases without changing canonical logical links needed by a live root and descendant; explicit close retains its detach semantics.

The final lease closes the descriptor and unlinks an owned spool deterministically. An original `decode_file` path is never unlinked. Reader EOF, error and close release only that reader's scope; other holders remain valid.

Reader construction freezes the logical snapshot and acquires leases without source I/O. `length()` performs and caches full length/encoding validation; `next()` performs that validation first if needed, before returning any output. Both operations can yield through source callbacks. Close wins over a late suspended result, while a previously successful length stays available after close.
