# Bounded metadata verification

This report records the memory acceptance work for the sparse source runtime.
The implementation remains independent of Kong and Gateway.

## Measurement contract

`scripts/verify-memory.py` generates fixtures outside the measured processes and
runs native OpenResty with LuaJIT in a fresh process for every method and source
mode. Each pair consumes byte-identical JSON. The native cjson comparison fully
decodes and encodes; LeanJSON uses source spans, sparse mutation and a bounded
reader. Both perform the same requested edits and number of independent forks.
`--branches 0` modifies the decoded root directly, without an artificial copy.

The primary measurement performs no forced garbage collection between parse,
read, mutation, length, output and close phases. Input generation and the typed
semantic oracle run separately. The oracle rejects duplicate output keys,
including escaped-equivalent names, and checks complete output semantics and
byte counts. Runtime fingerprints must remain unchanged during a measurement.

The paired gate is strict: LeanJSON's process RSS high-water mark must be no
greater than cjson's for each measured cell. Baseline RSS, phase RSS, sampled
Lua heap, CPU time, source/output hashes and index diagnostics are recorded.
Process RSS is not a Rust allocation count or total container memory: OS page
cache and memory-backed temporary files can affect container memory separately.

## Before optimization

The immutable baseline runtime is image
`lua-leanjson-openresty:rename-ea3c11a`, image ID
`sha256:8af93a03e3820302f834fbb0824ed1b2bed2ae110b2a28235ccd3473f4017a89`,
source revision `ea3c11a4f4809988cfac587f1cdc2109acc1e6ef`.
The later `6926158` baseline checkout adds documentation, not runtime changes.
These measurements use completed-file input, 32,768 entries and two independent
forks. No compilation ran concurrently with the measurements.

| Shape | Native cjson peak RSS | Previous LeanJSON peak RSS | Gate |
| --- | ---: | ---: | --- |
| Array of short objects | 27.61 MiB | 133.00 MiB | Fail |
| Shallow object with 32,768 small-object fields | 34.51 MiB | 149.31 MiB | Fail |
| Shallow object with 32,768 scalar fields | 19.68 MiB | 57.82 MiB | Fail |

All three baseline output oracles passed. The old runtime increased memory
both during initial indexing and when Lua expanded members for mutation or
normalized counting/output. Raw records are retained in
[bounded-metadata-before.jsonl](bounded-metadata-before.jsonl).

## Updated runtime

Measured runtime commit: `1f21ab56f87327afa968f35536238b19f06182d3`.
Pinned development image: `lua-qjson-dev:task3-repro`, image ID
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`. Linux ARM64, native OpenResty 1.29.2.4,
LuaJIT 2.1 and Rust 1.90. Native library SHA256:
`c3818c97b38a774660a7a8b39a21f504af2c2b5728746ee5c7254e035495bdab`; Lua runtime tree digest:
`7b2aa1efab8bf927e812c871274505b3335839f5353a9dd30477982470a36738`. The image revision is the development
image's own revision, not the mounted runtime revision. The checkout was dirty
only because the supervisor was preparing documentation. Native and Lua
fingerprints remained unchanged throughout all four matrices.

**63/63 paired process comparisons passed**, including every complete semantic,
duplicate-output, length/chunk and metadata-budget assertion:

| Configuration | Cases across memory/file/feed | Passed pairs |
| --- | --- | ---: |
| Defaults: depth 3, array prefix 3, 1 MiB budget, direct mutation | 11 shapes/access patterns | 33/33 |
| Defaults with two independent forks | Short array objects, wide objects, wide scalars | 9/9 |
| Depth 0, array prefix 0, budget 0, direct mutation | Far-array read, natural-GC wide traversal, wide duplicates, deep objects | 12/12 |
| Depth 1, array prefix 1, 512-byte budget, direct mutation | Short array objects, wide objects, wide scalars | 9/9 |

The default matrix also includes late/escaped duplicates, long prompts/messages,
explicit-close traversal and natural-GC traversal. It uses a 1 MiB fixture
**target**, not an assertion that every generated document has the same size:
32,768 short objects occupy 939,196 bytes, wide small-object fields 1,222,992
bytes, and wide scalar fields 469,328 bytes. A `model` field is added for the
same routing-style edit in both implementations.

| Shape | Source | cjson RSS | LeanJSON RSS | cjson CPU | LeanJSON CPU |
| --- | --- | ---: | ---: | ---: | ---: |
| 32,768 short array objects | memory | 19.10 MiB | 14.11 MiB | 10.7 ms | 36.3 ms |
| 32,768 short array objects | file | 19.15 MiB | 13.61 MiB | 10.9 ms | 30.4 ms |
| 32,768 short array objects | feed | 19.06 MiB | 13.55 MiB | 12.0 ms | 31.2 ms |
| 32,768 small-object fields | memory | 23.64 MiB | 17.48 MiB | 15.9 ms | 696.6 ms |
| 32,768 small-object fields | file | 23.68 MiB | 14.93 MiB | 17.2 ms | 757.8 ms |
| 32,768 small-object fields | feed | 23.61 MiB | 14.49 MiB | 28.3 ms | 837.0 ms |
| 32,768 scalar fields | memory | 16.36 MiB | 15.80 MiB | 10.5 ms | 678.9 ms |
| 32,768 scalar fields | file | 16.36 MiB | 15.09 MiB | 7.8 ms | 717.8 ms |
| 32,768 scalar fields | feed | 16.34 MiB | 14.70 MiB | 8.3 ms | 748.9 ms |

The old baseline above uses two forks. Its directly comparable updated
completed-file/two-fork results are 13.62 MiB (array objects), 14.96 MiB (wide
objects), and 14.84 MiB (wide scalars), versus paired cjson 27.54, 34.47, and
19.61 MiB respectively. Do not compare the old two-fork rows to direct-mutation
rows as if only the implementation changed.

Raw process records: [bounded-metadata-after.jsonl](bounded-metadata-after.jsonl).
Each matrix starts with its own environment record. `source_stats.index_bytes`
measures retained native index capacity, not the entire Rust/Lua allocator.

### Real HTTP comparison

Fresh OpenResty workers, completed-file input, two concurrent clients, three
requests per client (six timed requests per method/shape), direct mutation,
64 KiB reader chunks. All four semantic oracle probes passed. These are small
local runs, not production throughput forecasts.

| Shape | cjson RSS | LeanJSON RSS | cjson p50 | LeanJSON p50 |
| --- | ---: | ---: | ---: | ---: |
| 32,768 short array objects | 30.17 MiB | 14.00 MiB | 24 ms | 63 ms |
| 32,768 small-object fields | 46.82 MiB | 16.70 MiB | 30 ms | 1461 ms |

**Memory improved; wide-object processing is still much slower than cjson.**
Exact duplicate handling spills large key maps to disk and performs many small
synchronous I/O operations. The wide-object HTTP run recorded roughly 2.7
million write syscalls and 5.6 million read syscalls over six requests. This is
an explicit CPU/I/O/latency cost, not a speed improvement. Consider it before
using this path for latency-sensitive workloads consisting of many small fields.

Raw HTTP records: [bounded-metadata-http.jsonl](bounded-metadata-http.jsonl).

## Functional and resource checks

On the same runtime: complete `make openresty-verify` passed Rust default,
scalar-only and panic-injection suites, strict clippy, **403 Lua tests**, clean
luacheck (62 files), 2,000 encode property cases, 1,000 mutation cases x100
steps, 500 valid +500 mutated source stress cases, the pinned source corpus,
and **50/50 native HTTP checks**. All fuzz targets compiled with the locked
offline manifest; this is not a new timed fuzz campaign. A fresh isolated
LuaRocks installation passed memory/file/feed/fork/get/reader/close/import smoke
checks from outside the checkout with library paths restricted to that install.

Four independent Valgrind 3.18.1 probes (unfinished iterators, normal GC,
explicit close, and deep shared spill) exited zero with **0 errors, 0 suppressed
errors and 0 bytes in use at exit**. JIT was disabled for these probes; they do
not replace an exhaustive sanitizer campaign. A 48-level child-first
wide/duplicate fixture passed under a 64-descriptor limit. The held-reader
regression repeats 24 length/drain traversals, checks reused/coalesced spill
regions, bounded backing-file high-water, and zero file/live/free state on final
release. These address actual shutdown double-release and active-workspace
reclamation defects found during implementation.

Selected check receipts: [bounded-metadata-checks.txt](bounded-metadata-checks.txt).
Independent review and exact committed runtime-image smoke are recorded after
their final completion; they are not claimed by the process measurements.

## Reproduction

Build the mounted runtime in the pinned development image using
`make openresty-verify`; then run these sequentially with no competing builds.
Every output directory must be new/empty. `make openresty-memory-gate` is the
convenient default entry point; explicit commands for all 63 pairs are:

```sh
python3 scripts/verify-memory.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --branches 0 --output-dir /tmp/lean-default
python3 scripts/verify-memory.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --branches 2 \
  --cases short-elements wide-objects wide-scalars --output-dir /tmp/lean-forks
python3 scripts/verify-memory.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --branches 0 \
  --index-depth 0 --index-array-limit 0 --index-budget-bytes 0 \
  --cases short-elements:far wide-objects:scan-auto wide-duplicates deep-objects \
  --output-dir /tmp/lean-zero
python3 scripts/verify-memory.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --branches 0 \
  --index-depth 1 --index-array-limit 1 --index-budget-bytes 512 \
  --cases short-elements wide-objects wide-scalars --output-dir /tmp/lean-tiny
```

The `leanjson-bounded-target` volume must hold that revision's release library;
the runner records/checks fingerprints but does not compile it. To reproduce
HTTP rows, run `scripts/benchmark-openresty.sh` inside the same development
image with the checkout and target volume mounted, setting
`LEANJSON_BENCH_CASES="short-elements wide-objects"`,
`LEANJSON_BENCH_BYTES=1048576`, `LEANJSON_BENCH_BRANCHES=0`,
`LEANJSON_BENCH_CONCURRENCY=2`, and `LEANJSON_BENCH_REQUESTS=3`.

## Scope of conclusions

The index budget limits rebuildable retained source metadata; it does not cap
input strings, explicitly materialized trees, returned large strings, mutation
payloads, live views, active validation/duplicate work or output buffers. Exact
wide-object duplicate handling can use temporary disk indexes. The memory/CPU
tradeoff and disk I/O must be considered together.

A finite matched workload matrix can demonstrate that the reported regressions
are fixed. It cannot prove a universal RSS ordering against cjson for every
JSON document, allocation history, caller-retained value or workload.
