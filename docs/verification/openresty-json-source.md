# Native OpenResty sources: API and verification

The OpenResty layer is `require("qjson.openresty")`. Pure JSON, fork, source, and reader operations remain independent of `ngx`. The example and acceptance tests run native OpenResty; they have no Kong or Gateway dependency.

## Receiving a completed body

```lua
local qjson = require "qjson"
local input = require "qjson.openresty"
local value, err, info = input.read_body { chunk_size = 65536 }
if err then return fail(err) end
-- info.mode is completed-memory or completed-file.
local branch = qjson.fork(value)
branch.model = "rewritten"
qjson.close(value) -- branch retains the source independently
```

`read_body(opts)` calls `ngx.req.read_body` once, then selects `get_body_data` or `get_body_file`. It catches the core's decode/I/O errors and returns `nil, error, info`. JSON false and null are successful values. File input uses `qjson.decode_file`, never a complete-body `read("*a")`. Nginx owns its file; qjson owns an open descriptor lease and does not unlink the Nginx pathname. Close each returned proxy explicitly; children, forks, and readers retain their own leases.

`opts.chunk_size` defaults to 65536. `opts.decode` supplies core decode options. Lazy validation is rejected for HTTP input. `opts.on_chunk(bytes_sofar)` runs in Lua between bounded file/parser steps and may yield; the default yields with `ngx.sleep(0)`. Reads remain synchronous disk I/O. This API does not promise constant memory for every JSON shape: structural indexes, selected long values, and overlays consume memory.

## Incremental input

```lua
local session, err, info = input.start_body {
    chunk_size = 65536,
    temp_dir = "/disk/qjson-spool",
    read_timeout = 30000, -- socket milliseconds
    wait_timeout = 30,  -- semaphore seconds
}
if err then return fail(err) end
local model, status, get_err = session:get("model") -- can yield
if status == "ERROR" then session:close(); return fail(get_err) end
local value, finish_err = session:finish()
if finish_err then session:close(); return fail(finish_err) end
local branch = qjson.fork(value)
session:close() -- closes the session's root; branch remains usable
-- Only now may the application create external side effects.
```

`start_body` returns `session, nil, info` or `nil, error, info`. Live socket mode is restricted to HTTP/1.1 with a valid Content-Length and no Transfer-Encoding. Other inputs take `read_body`; `info.fallback` reports `http-version`, `transfer-encoding`, or `content-length`. `info.mode` reports `incremental`, `completed-memory`, or `completed-file`.

One producer owns the input socket. Every waiter shares one decoder and semaphore notifications. `get(path)` returns `value, "READY"`, `nil, "ABSENT"`, or `nil, "ERROR", error`; it waits through NEED_INPUT. Paths use the core's dot/zero-based-bracket syntax. Last-wins field values are not final until their object closes; the current eager source decoder publishes values at finish. The adapter does not promise early values.

`finish()` waits for one producer-owned decoder finish and full validation. `abort(reason)` stops unfinished input and wakes waiters. `close()` is idempotent, closes session ownership, and preserves independently held forks/children/readers. `temp_dir` is passed to the owned decoder spool and must be writable; cleanup occurs at the final lease. The producer never yields through Rust FFI or mixes `ngx.req.socket` with `read_body`/`discard_body`. Configure `lua_check_client_abort on`; the adapter coordinates one `ngx.on_abort` hook per request.

Register cleanup for application-owned forks with `local unregister, err = input.on_abort(function() qjson.close(branch) end)`. This joins the adapter's single abort callback and returns an unregister function for normal completion. Closing the input root or session alone intentionally preserves those forks; their owner must close them too. Callbacks must not yield.

## Sending a reader once

```lua
-- httpc is a connected lua-resty-http 0.17.2 client.
local res, err, transfer = input.request(httpc, {
    method = "POST", path = "/sink", headers = { ["Content-Type"] = "application/json" },
}, branch, { chunk_size = 65536 })
qjson.close(branch)
if err then return fail(err) end
-- Read/stream res.body_reader and then close httpc.
```

The helper freezes a qjson reader, normalizes duplicate keys recursively, calculates actual encoded length, strips stale Content-Length/Transfer-Encoding/Expect, and sets the new Content-Length. It uses `send_request`/`read_response` once. A reader error is stored separately and returned as failure, never ordinary EOF. Failure or cancellation closes the reader and client connection. The caller owns a successful response body and connection.

The returned transfer record includes `stage`, `attempts`, `headers_may_have_been_sent`, `delivered_bytes`, `length`, `max_chunk`, `reader_error`, and `reader_closed`. `delivered_bytes` counts bytes handed to lua-resty-http, not bytes received by the peer. Header-send state is conservative; even zero delivered body bytes does not imply a safe retry. No automatic retry is performed. Optional `opts.cancelled()` cancels output at the next chunk boundary.

## Reproducible gates

```sh
git submodule update --init --recursive
make openresty-dev-image
make openresty-docker-test
# Focused HTTP tests in an existing dev container:
make openresty-test
# Extended deterministic properties are included in openresty-verify:
QJSON_PROP_CASES=2000 QJSON_MUT_PROP_CASES=1000 QJSON_MUT_PROP_STEPS=100 make openresty-verify
```

The dev image is based on native `openresty/openresty:1.29.2.4-0-jammy@sha256:0a887716d1bc7a3d38e6a765e4c9df31a4b4e27473fc30def6601511330c7f2f` and `rust:1.90.0-slim-bookworm@sha256:64232e656c058f4468e8d024e990acff04f0fd5a5c0a88a574dc37773d7325c9`. Direct and transitive Lua rock versions are pinned in the Dockerfile. Runtime FFI and Lua modules are built from the same exact fork revision by `scripts/build-openresty-image.sh`.

`openresty-verify` runs Rust release/default, scalar, and panic-barrier modes; Clippy with warnings denied; the full Lua suite; Lua lint; seeded encode/mutation properties; 500 valid plus 500 byte-mutated source/contiguous differential stress cases; pinned JSONTestSuite/third-party corpus tests; and real worker HTTP tests. CI runs this native source gate independently of existing runtime compatibility jobs. The submodule gitlinks pin JSONTestSuite (`1ef36fa01286573e846ac449e8683f8833c5b26a`), cJSON (`fb16e5cf358798aabb049655975cde8427101056`), and simdjson (`43766fc7efdedc87111c48bda55f758ca212335b`).

The native harness starts a dedicated qjson worker and a separate upstream worker. The sink only reads bounded chunks, counts bytes, hashes them, and optionally writes a disk capture. A separate test client parses those captures after the transfer for semantic comparison. This separates the oracle's full parsing from the measured process and sink.

Acceptance covers memory/file selection; large siblings; independent branches and mixed changes; exact output length and bounded chunks; malformed input without upstream side effects; one-attempt disconnects; final duplicate values with multiple waiters; false/null; one input owner; chunked/HTTP2 completed fallbacks; slow and aborted uploads; real source truncation and unlink; output cancellation; descriptor/temp-file cleanup; and worker liveness. Set `QJSON_KEEP_TEST_OUTPUT=1` to keep logs/captures. Set `QJSON_TEST_PORT`/`QJSON_SINK_PORT` to change the default 19841/19842 ports.

Bounded libFuzzer sessions are a separate nightly gate:

```sh
rustup toolchain install nightly --profile minimal
cargo +nightly install cargo-fuzz --version 0.13.2 --locked
QJSON_FUZZ_SECONDS=30 make bounded-fuzz
```

The first five libFuzzer targets exercise the legacy contiguous core. `fuzz_source_windows` exercises the new window-fed source separately. Seeded Lua source stress also checks valid/mutated stream verdicts, chunked output, and final lease release; it is distinct from coverage-guided libFuzzer.

## Benchmark protocol

```sh
# Run inside the dev container, saving JSONL on the mounted checkout if desired.
QJSON_BENCH_BYTES=8388608 QJSON_BENCH_CONCURRENCY=2 QJSON_BENCH_REQUESTS=3 make openresty-bench
# A quick pair:
QJSON_BENCH_CASES=prompt QJSON_BENCH_BYTES=1048576 make openresty-bench
# Larger context pair, with four concurrent clients and two branches:
QJSON_BENCH_CASES='prompt messages' QJSON_BENCH_BYTES=8388608 QJSON_BENCH_CONCURRENCY=4 QJSON_BENCH_BRANCHES=2 make openresty-bench
```

Each method/scenario uses a fresh qjson worker so process RSS high water never carries over from its pair. Both methods receive identical payloads, make the same branch count and model change, and send to the same bounded sink. The cjson baseline intentionally allocates a complete source string, Lua object tree, branch container copies, and encoded output. Its immutable long Lua strings are shared across branch copies. The qjson path reads only model in lazy cases and uses normalized bounded output. The `explicit` case deliberately accesses the long value and is reported separately.

Scenarios cover a top-level prompt, input string, nested messages, escape-dense values, many short elements, explicit long-value access, and advisory cold file reads. Results record input/output bytes, RSS/current and VmHWM, sampled Lua heap, process CPU time, throughput, p50/p95 latency, first observed sink body chunk relative to client start, output chunk bound, and concurrent `/ping` latency. These are actual native processes. Lua heap samples are not an allocator peak. CPU is measured across the complete worker run to avoid double-counting overlapping requests.

Cold cases call Linux `fsync` and `posix_fadvise(POSIX_FADV_DONTNEED)` before file parsing and report the result; eviction is advisory, so this is not proof of a physically cold disk. Record filesystem/hardware/container limits with results. Source/index/Rust-heap/overlay counters that the core does not expose are explicitly `null`; source input length and explicit value bytes are measured separately. No unsupported Rust allocation estimate is inferred from RSS.

## Measured status

Implementation and verification results are recorded here after the source/decoder dependencies are integrated. The first native RED run confirmed that the adapter was missing; subsequent dependency-stage HTTP runs correctly fail where `decode_file`, `new_decoder`, `get`, and `close` have not yet been added. Those runs are not a passing acceptance claim. Lua lint and shell syntax checks pass for the initial scaffold.

The upstream baseline was isolated at `8e1b394e0dd0322bedae3a9fc87d15d8049a02ce`: 271 Lua checks and all 21 corpus/fixture checks pass. On Linux ARM64 the unmodified upstream full Rust test build fails at two hard-coded `*const i8` test casts, and Clippy reports 15 pre-existing ARM lints. With only the portable test-cast adjustment, all three Rust modes pass 383 tests. This is baseline evidence, separate from verification of the new source APIs.

API references: [OpenResty request socket and body ownership](https://github.com/openresty/lua-nginx-module#ngxreqsocket), [lua-resty-http 0.17.2 iterator send/error behavior](https://github.com/ledgetech/lua-resty-http/blob/v0.17.2/lib/resty/http.lua).
