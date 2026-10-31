# OpenResty JSON Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver lazy mutable JSON proxies, independent snapshots, bounded serialization, file sources, and incremental input in the independent lua-qjson fork, verified under native OpenResty.

**Architecture:** Preserve the upstream Rust parser and public ABI. Add a source-backed node boundary for proxies, versioned incremental scanning where complete borrowed buffers cannot work, and explicit Lua I/O adapters. Never acquire the whole file or assemble the complete output implicitly.

**Tech Stack:** Rust, LuaJIT FFI, Busted, OpenResty, lua-resty-http, Python HTTP acceptance runner, Docker.

**Spec:** `docs/design/openresty-json-source.md` (approved scope; OpenResty only).

## Global Constraints

- Keep Apache-2.0 attribution and upstream history; original Rust FFI layouts and symbols remain compatible.
- Core JSON operations must run without `ngx`; only OpenResty adapters use it.
- Large untouched siblings must not be decoded on mutation; branches share immutable source and indexes.
- `qjson.encode` deliberately returns a complete string; `qjson.reader` never constructs complete output.
- Preserve null versus absent, array versus object, Unicode validity, and eager validation defaults.
- Object lookup is last-wins; expose duplicate normalization for forwarding.
- Root code owns reviews and publication; implementers never push or create PRs and stage only their files.
- All implementation remains in this independent fork. No Kong/Gateway/Controller integration.
- File reads are bounded synchronous I/O unless explicitly backed by an asynchronous adapter; report worker latency honestly.
- Incremental lookup returns final values only: wait until the enclosing object has closed, avoiding provisional last-wins decisions. Input failure is never absence.

## Review Focus

1. Decoding `{"_doc":1,"_parent":2}` and reading then writing array entries must not bypass proxy state.
2. Replacing a parent detaches held child proxies; cross-branch assignments and readers freeze logical snapshots.
3. A giant escaped string spanning windows must validate without accumulating its full decoded value.
4. Duplicate keys and Unicode/surrogate boundaries must agree across memory, file, and incremental paths.
5. Error/cancel/EOF cleanup must neither leak owned files nor close sources still held by another branch/reader.

## Task 1: Mutable proxies, forks, bounded reader

**Files:** `lua/qjson/table.lua`, `lua/qjson.lua`, new focused `lua/qjson/*` modules as needed; `tests/lua/source_proxy_spec.lua`, `tests/lua/reader_spec.lua`; module API documentation.

**Interfaces:** Existing `decode/encode/materialize/pairs/ipairs/len` remain supported. Add `qjson.fork(value)`, `qjson.type(value)`, `qjson.array_insert(array,index,value)`, `qjson.array_remove(array,index)`, and `qjson.reader(value, {chunk_size=65536, normalize_duplicates=false})`. Reader has `length()`, `next()` returning chunk or nil/error, and idempotent `close()`. Source/proxy backend seam must permit Task 2 to supply opaque nodes, types, scalar decode, child iteration, and bounded original spans without a contiguous input string; document its concrete internal API in the report.

- [ ] Write and run failing tests for same-level huge siblings on writes, metadata collisions, read-then-write arrays, parent detach, null/empty arrays, independent branch snapshots and table-assignment ownership.
- [ ] Implement private proxy metadata, field overlays, structural sharing and explicit array operations. Preserve original API regression behavior except intentional documented snapshot assignment and last-wins corrections.
- [ ] Write failing reader tests for chunk bounds, full-string-allocation avoidance, escaping, nested edits, actual length, duplicate normalization, snapshot freezing, mixed Lua/proxy values, closed/error states.
- [ ] Implement a bounded reader; numeric/string scalar output must not invoke whole-document encode. Capture source/encoding errors explicitly and release only owned references.
- [ ] Run full upstream Lua suite plus deterministic property/mutation tests; record failing baseline versus introduced regressions accurately. Run Rust baseline when shared environment becomes available.
- [ ] Commit only this task's implementation, tests and API docs; report exact commands/results and backend seam.

## Task 2: Window-fed Rust source and file/incremental Lua adapters

**Files:** new `src/source.rs`/focused submodules, new versioned FFI module if useful, `src/lib.rs`, `include/qjson.h`, `lua/qjson/lib.lua`, `lua/qjson/source.lua`, `lua/qjson.lua`, backend seam from Task 1, `tests/source_*.rs`, `tests/lua/source_file_spec.lua`, `tests/lua/source_feed_spec.lua`.

**Interfaces:** Add `qjson.decode_file(path, {chunk_size=65536,...})` and `qjson.new_decoder(opts)`. Decoder supports `feed(chunk)`, `finish()` returning proxy, `abort(reason)`, `get(path)` returning value/status/error, and `close()`. Status vocabulary is `READY`, `NEED_INPUT`, `NEED_READ`, `ABSENT`, `ERROR`. Lua adapters own file descriptors; Rust retains absolute offsets/index/validation state, never a borrowed Lua window across FFI return. Input spool is owned by decoder/source, deletable only when all users release it. Existing input files are never deleted.

- [ ] Write failing Rust tests for every-byte chunking, strings/UTF-8/escapes/numbers across boundaries, depth, malformed EOF, duplicate keys and offsets above u32 where supported (otherwise explicit rejection).
- [ ] Implement a versioned bounded incremental scanner with source positions, complete JSON validation, node lookup metadata and NEED_READ/resume support. Preserve panic barriers; no complete-file buffer or full decoded long-string storage.
- [ ] Write failing Lua file/source lifetime tests, including early EOF/read errors, readers surviving other references, file ownership, detached children and two forks.
- [ ] Implement file-backed raw access with bounded windows and on-demand scalar materialization. Integrate through Task 1 backend; never `read('*a')` or aggregate source chunks into a complete string.
- [ ] Implement incremental spool/feed/finish/abort and final-value lookup semantics. Pending lookups are explicit until complete enough for final last-wins results; malformed/aborted inputs propagate errors.
- [ ] Run full Rust default/scalar/test-panic matrices, Clippy and Lua suite; extend property/corpus tests to new source mode.
- [ ] Commit task files and document resource ownership, synchronous I/O and explicit materialization boundaries.

## Task 3: Native OpenResty adapter and reproducible verification

**Files:** `lua/qjson/openresty.lua`, `examples/openresty/*`, `tests/openresty/*`, `scripts/*` verification helpers, `Makefile`, CI workflow, documentation/build metadata.

**Interfaces:** `qjson.openresty.read_body(opts)` selects memory/file after `ngx.req.read_body()`. `qjson.openresty.start_body(opts)` starts a sole input reader for supported Content-Length HTTP/1.1 requests; its `get(path)` may yield and `finish()` waits for final validation. HTTP/2/chunked use the completed-body path, with a reported mode. HTTP iterator wrapper preserves reader errors, updates Content-Length, closes on error, never auto-retries. Exact Lua API names may be refined once Task 2 public contract is implemented, with documentation/tests updated together.

- [ ] Build a reproducible tool/runtime image pinned to a known native OpenResty image digest and Rust toolchain; run upstream baseline before declaring regressions.
- [ ] Add HTTP acceptance tests for memory/file selection, huge siblings, branch independence, mixed modifications, actual length/digest, invalid JSON, upstream disconnect, request abort, file cleanup and worker liveness.
- [ ] Implement complete-body and incremental adapters without Kong. Use a single reader owner and shared decoder status; only issue upstream side effects after finish/validation.
- [ ] Exercise HTTP/1.1 fixed length, HTTP/1.1 chunked fallback, HTTP/2 fallback and slow/aborted uploads; verify no input socket/read_body mixing.
- [ ] Add deterministic benchmarks comparing cjson and qjson with identical payloads/concurrency; record process RSS, Lua heap, source/index/materialized/output bytes where available, CPU/time, cold file worker lag, first upstream byte. Separate explicit full-value access from lazy cases.
- [ ] Run all library gates and native HTTP suite, pinned JSONTestSuite/corpus, mutation properties and bounded fuzz/stress runs. Record commands, versions and measured results in `docs/verification/openresty-json-source.md`.
- [ ] Update README/CHANGELOG/package module lists and CI to reproduce new gates; commit only task paths.

## Task 4: Independent final review and publication

**Files:** fixes/tests in owned component areas; verification report.

- [ ] Review full branch versus upstream baseline for spec compliance, FFI safety, mutation semantics, memory complexity and source cancellation. Obtain independent review and resolve important findings with regression tests.
- [ ] Re-run affected gates after fixes; run final full gate bundle on exact candidate commit. Distinguish tested architecture, disk I/O limits and unsupported HTTP live-input modes.
- [ ] Verify clean worktree, explicit commit manifest, correct fork remote and no credentials/artifacts. Push `feat/openresty-json-source` to `GYWang1983/lua-qjson`, verify remote SHA, and inspect GitHub CI when available. Do not change upstream or overwrite main.
- [ ] Return GitHub branch/commit link, implementation scope, measured results and any remaining limitations.
