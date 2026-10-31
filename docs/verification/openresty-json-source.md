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

`opts.chunk_size` defaults to 65536. `opts.decode` supplies the same parsing policy in completed-memory, completed-file, incremental and fallback modes. `max_depth` must be an integer from 0 through 4294967295: zero selects 1024, and values above 4096 clamp to 4096. Negative, fractional, nonfinite and non-number values are rejected in every mode. Lazy validation is rejected for HTTP input. `opts.on_chunk(bytes_sofar)` runs in Lua between bounded file/parser steps and may yield; the default yields with `ngx.sleep(0)`. Memory decoding validates the options but does not invoke file callbacks or create a spool. `temp_dir` controls incremental spools only. Reads remain synchronous disk I/O. This API does not promise constant memory for every JSON shape: structural indexes, selected long values, and overlays consume memory.

## Incremental input

```lua
local session, err, info = input.start_body {
    chunk_size = 65536,
    temp_dir = "/disk/qjson-spool",
    read_timeout = 30000, -- socket milliseconds
    wait_timeout = 30,  -- semaphore seconds
}
if err then return fail(err) end
local model, branch
local function cleanup()
    qjson.close(model) -- a container query result owns an independent lease
    qjson.close(branch)
    session:close()
end
local unregister, abort_err = input.on_abort(cleanup)
if not unregister then cleanup(); return fail(abort_err) end
local ok, work_err = pcall(function()
    local status, get_err
    model, status, get_err = session:get("model") -- can yield
    if status == "ERROR" then error(get_err) end
    -- Inspect model here, then release its view, even if it is an object/array.
    qjson.close(model)
    model = nil
    local value, finish_err = session:finish()
    if finish_err then error(finish_err) end
    branch = qjson.fork(value)
    session:close() -- branch remains usable
    -- Only now may the application use branch for external side effects.
end)
unregister()
cleanup() -- normal completion and ordinary errors release every owned holder
if not ok then return fail(work_err) end
```

`start_body` returns `session, nil, info` or `nil, error, info`. Live socket mode is restricted to HTTP/1.1 with a valid Content-Length and no Transfer-Encoding. Other inputs take `read_body`; `info.fallback` reports `http-version`, `transfer-encoding`, or `content-length`. `info.mode` reports `incremental`, `completed-memory`, or `completed-file`.

One producer owns the input socket. Every waiter shares one decoder and semaphore notifications. `get(path)` returns `value, "READY"`, `nil, "ABSENT"`, or `nil, "ERROR", error`; it waits through NEED_INPUT. Paths use the core's dot/zero-based-bracket syntax. Last-wins field values are not final until their object closes; the current eager source decoder publishes values at finish. The adapter does not promise early values.

`finish()` waits for one producer-owned decoder finish and full validation. `abort(reason)` stops unfinished input and wakes waiters. `close()` is idempotent, closes session ownership, and preserves independently held forks/children/readers. Every container returned by `get`, including a value used only for a check, must be explicitly closed by its owner; skip the query when its value is unused. Scalars need no resource cleanup. `temp_dir` is passed to the owned decoder spool and must be writable; cleanup occurs at the final lease. The producer never yields through Rust FFI or mixes `ngx.req.socket` with `read_body`/`discard_body`. Configure `lua_check_client_abort on`; the adapter coordinates one `ngx.on_abort` hook per request.

Register cleanup for application-owned forks with `local unregister, err = input.on_abort(function() qjson.close(branch) end)`. This joins the adapter's single abort callback and returns an unregister function for normal completion. Closing the input root or session alone intentionally preserves those forks; their owner must close them too. Callbacks must not yield.

Register holder cleanup before the first field mutation/read that can yield. Protect application mutation, connection and response work with an error-unwind path that closes every owned holder/client on ordinary errors as well as aborts. The [complete example](../../examples/openresty/handler.lua) shows both paths; an abort callback alone does not handle an ordinary source or connection failure.

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

Acceptance covers memory/file selection; large siblings; independent branches and mixed changes; exact output length and bounded chunks; malformed input without upstream side effects; one-attempt disconnects; final duplicate values with multiple waiters; false/null; one input owner; chunked/HTTP2 completed fallbacks; slow and aborted uploads; real source truncation and unlink; output cancellation; descriptor/temp-file cleanup; and worker liveness. First-write cancellation, source errors and upstream connection errors check the actual fd returns EBADF with GC stopped. Separate direct-core, adapter and completed-fallback controls check forgotten roots release their fd after request-end GC. Test instrumentation retains only fd numbers, paths and event flags and is disabled for benchmarks. Set `QJSON_KEEP_TEST_OUTPUT=1` to keep logs/captures. Set `QJSON_TEST_PORT`/`QJSON_SINK_PORT` to change the default 19841/19842 ports.

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

Each method/scenario uses a fresh qjson worker so process RSS high water never carries over from its pair. Both methods receive identical payloads, make the same branch count and model change, and send to the same bounded sink. The cjson baseline intentionally allocates a complete source string, Lua object tree, branch container copies, and encoded output. Its immutable long Lua strings are shared across branch copies. The qjson path changes model without reading long values and uses normalized bounded output. The `explicit` case deliberately accesses the long value and is reported separately.

Input generation uses fixed key order and records SHA256 so paired payload identity is checkable. `requests` counts timed transfers only. After elapsed time and worker health/CPU/I/O snapshots are frozen, each method makes one additional untimed disk-capture request. The separate client checks its SHA256 and complete JSON semantics against the input with `model="rewritten-1"`; the result appears under `oracle`. Timed requests do not enable capture or full output parsing.

Scenarios cover a top-level prompt, input string, nested messages, escape-dense values, many short elements, explicit long-value access, and advisory cold file reads. Results record input/output bytes, RSS/current and VmHWM, sampled Lua heap, process CPU time, throughput, p50/p95 latency, first observed sink body chunk relative to client start, output chunk bound, and concurrent `/ping` latency. These are actual native processes. Lua heap samples are not an allocator peak. CPU is measured across the complete worker run to avoid double-counting overlapping requests.

Cold cases call Linux `fsync` and `posix_fadvise(POSIX_FADV_DONTNEED)` before file parsing and report the result; eviction is advisory, so this is not proof of a physically cold disk. Record filesystem/hardware/container limits with results. Source/index/Rust-heap/overlay counters that the core does not expose are explicitly `null`; source input length and explicit value bytes are measured separately. No unsupported Rust allocation estimate is inferred from RSS.

## Measured status

Verified locally on 2026-10-31 at final code commit `92aefc0e107dd62dd32e3b5ffd7a6c91487862f9`. This includes the final review fixes for query-holder cleanup, consistent memory/file/feed decode policy and coherent mutation publication across yields. The exact runtime image was built from that commit and passed installed-module loading (including `qjson.options`), no-Rust checks, four memory/file/incremental length/SHA cases, malformed-input rejection, direct and HTTP completed-memory depth-policy checks, and clean Nginx startup. Later documentation-only commits do not change that tested code.

| Gate | Result |
| --- | --- |
| Rust release default / scalar / panic-barrier | 412 / 412 / 413 tests passed |
| Clippy | Passed with warnings denied |
| Lua suite / lint | 388 tests passed; 53 files, no warnings/errors |
| Extended properties | 2,000 encode cases; 1,000 mutation cases × 100 steps |
| Seeded source stress | 500 valid + 500 byte-mutated cases, seed 760076 |
| New-source JSONTestSuite | All 318 files via file + 17/65536-byte feeds; 95 valid, 188 invalid, 35 implementation-defined (11 accepted/24 rejected) |
| Native HTTP acceptance | 49 checks passed, including stopped-GC query ownership and input-mode policy parity |
| Installed LuaRocks package | Isolated tree, workspace paths unset; memory/file/feed/fork/linked get/reader, options policy and OpenResty module smoke passed |
| Bounded ASan/libFuzzer | Six targets × 30 seconds passed; new-source target included |
| Source FFI under ASan | 8 tests passed, no sanitizer findings |

The dev image used for gates and measurements was `sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`. The final runtime image was `sha256:14d94f94b4465c5bc24e34137bedf8443689d67faebbe3c68d6494f03cd35b90`, with the exact final code commit in its revision label.

The supplemental sanitizer image was `sha256:c4c8f06d4c8552c7d91a01da676966d4975d801efc1fb7a55dbb0887a37951c5`, adding nightly `1.101.0-nightly (92b5b8c87 2026-10-29)` and cargo-fuzz 0.13.2 to the dev environment. The fuzz/ASan-tested Rust sources are unchanged in both the measured and final code commits. On this ARM64 image, the additional source-FFI command was:

```sh
RUSTFLAGS='-Zsanitizer=address' CARGO_TARGET_DIR=target/source-asan cargo +nightly test --locked --release --target aarch64-unknown-linux-gnu --no-default-features --features test-panic --test source_ffi
```

### Paired local measurements

These measurements were taken at `e44eb74362129ee0d26256dcc08bdc9da0a1f3b1`, before the final Lua ownership/policy/mutation fixes. The benchmark workload and raw records are unchanged; the matrix was not rerun at `92aefc0`. They establish the observed workload limits of that measured baseline, not exact final-revision timings.

[Raw benchmark JSONL](openresty-json-source-benchmarks.jsonl) contains one environment record and all 18 measured method/scenario records, including current RSS, HWM, sampled Lua heap, CPU, I/O, input digest, output bounds, latency, first sink body chunk, ping delay and the untimed semantic oracle. All nine pairs have byte-identical input SHA256 and passing complete-output semantic/SHA checks. Each method/scenario starts fresh workers. The default output bound is 64 KiB; the separate sink reads at most 16 KiB. No body capture or full output parsing occurs during timed requests.

Hardware was an Apple M5 Pro with 48 GiB host memory; Docker Linux ARM64 exposed 18 vCPUs and 8,371,556,352 bytes of VM memory. Containers had no additional cgroup CPU/memory cap. Body/spool files used Linux overlay disk, with no tmpfs; the checkout used virtiofs. No build/fuzz jobs ran concurrently, while other local services remained running. This single local campaign has four timed requests per method in the approximately 1 MiB cases (two clients, two requests each), and eight in the 8 MiB cases (four clients, two requests each). Every request creates two branches. These small samples describe this run, not a production latency guarantee.

Every paired cell below is **cjson / qjson**. Throughput counts input MiB per elapsed second; HWM is process peak RSS, while Lua heap is a sampled maximum rather than an allocator peak.

| Shape | HWM MiB | Sampled Lua MiB | p95 ms | Input MiB/s |
| --- | ---: | ---: | ---: | ---: |
| 1 MiB prompt | 16.7 / 12.7 | 6.0 / 3.7 | 14 / 15 | 210.53 / 166.67 |
| 1 MiB input | 16.7 / 11.8 | 6.0 / 3.0 | 12 / 16 | 285.72 / 173.92 |
| 1 MiB messages | 16.7 / 12.8 | 6.0 / 3.7 | 11 / 15 | 250.01 / 160.01 |
| 1 MiB escaped | 15.2 / 12.9 | 5.5 / 3.9 | 12 / 14 | 250.01 / 181.82 |
| Short elements (939,196 bytes) | 45.9 / 254.3 | 29.8 / 197.2 | 33 / 3103 | 58.73 / 0.60 |
| 1 MiB explicit long value | 15.7 / 14.3 | 6.0 / 5.2 | 11 / 24 | 266.68 / 100.00 |
| 1 MiB advisory cold | 16.7 / 12.2 | 6.0 / 3.2 | 26 / 21 | 114.29 / 117.65 |
| 8 MiB prompt | 73.8 / 15.1 | 41.0 / 5.7 | 85 / 141 | 453.90 / 245.21 |
| 8 MiB messages | 73.8 / 14.9 | 41.0 / 5.5 | 94 / 141 | 438.36 / 232.73 |

The long-string cases reduce RSS and sampled Lua heap, with higher latency and CPU cost. At 8 MiB, prompt/messages first upstream body chunk p50 was 43/48 ms for cjson versus 103/114 ms for qjson; concurrent ping maximum was 28/23 ms versus 4/4 ms. Thus improved worker responsiveness and lower memory did not produce higher throughput in those cases.

The 32,768-short-object shape is a material limitation: qjson consumed much more memory and CPU and was substantially slower at the same size, concurrency and branch count. Its worker CPU was 5,902 ms versus cjson's 58 ms. Normalized container traversal and per-node bookkeeping can dominate; bounded output alone does not establish bounded overall memory or a speedup. The explicit long-value case also narrows the memory benefit and adds latency.

Both cold runs reported successful fsync/fadvise advice and 4,210,688 process read bytes. Cold first-chunk p50 was 8 / 11 ms and ping maximum 19 / 5 ms. This remains an advisory Linux page-cache experiment on Docker overlay storage, not evidence of physical disk cache eviction or asynchronous I/O. Structural-index, Rust-heap and overlay allocation counters remain unavailable (`null` in each record); RSS is not substituted for them.

Reproduce the measured sizes/concurrency with:

```sh
QJSON_BENCH_BYTES=1048576 QJSON_BENCH_CONCURRENCY=2 QJSON_BENCH_REQUESTS=2 QJSON_BENCH_BRANCHES=2 scripts/benchmark-openresty.sh
QJSON_BENCH_BYTES=8388608 QJSON_BENCH_CONCURRENCY=4 QJSON_BENCH_REQUESTS=2 QJSON_BENCH_BRANCHES=2 QJSON_BENCH_CASES='prompt messages' scripts/benchmark-openresty.sh
```

The upstream baseline was isolated at `8e1b394e0dd0322bedae3a9fc87d15d8049a02ce`: 271 Lua checks and all 21 corpus/fixture checks pass. On Linux ARM64 the unmodified upstream full Rust test build fails at two hard-coded `*const i8` test casts, and Clippy reports 15 pre-existing ARM lints. With only the portable test-cast adjustment, all three Rust modes pass 383 tests. This is baseline evidence, separate from verification of the new source APIs.

API references: [OpenResty request socket and body ownership](https://github.com/openresty/lua-nginx-module#ngxreqsocket), [lua-resty-http 0.17.2 iterator send/error behavior](https://github.com/ledgetech/lua-resty-http/blob/v0.17.2/lib/resty/http.lua).
