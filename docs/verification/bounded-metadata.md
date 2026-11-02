# Bounded metadata verification

This report records the memory acceptance work for the sparse source runtime.
The implementation remains independent of Kong and Gateway.

## Measurement contract

`scripts/verify-memory.py` generates fixtures outside the measured processes and
runs native OpenResty with LuaJIT in a fresh process for every method and source
mode. Final cjson cells load neither LeanJSON Lua modules nor its native library.
The final harness and runtime are commit
`5729eb2bcacf015f54dcbc039cb3192ac13a4e91`. Each pair consumes byte-identical
JSON. The native cjson comparison fully decodes and encodes; LeanJSON uses source spans, sparse mutation and a bounded
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
These historical measurements use completed-file input, 32,768 entries and two
independent forks. The old harness preloaded LeanJSON in cjson cells, so this
table is a historical comparison with both libraries loaded, not the final
pure-cjson acceptance baseline. No compilation ran concurrently with the measurements.

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

Measured runtime commit: `5729eb2bcacf015f54dcbc039cb3192ac13a4e91`.
Pinned development image: `lua-qjson-dev:task3-repro`, image ID
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`. Linux ARM64, native OpenResty 1.29.2.4,
LuaJIT 2.1 and Rust 1.90. Native library SHA256:
`1fdc408e86e236178777fab94c57afe55e5fc78e518a888b3e00fee11eddbd88`; Lua runtime tree digest:
`9472b8880f4d4949010ec210bf8962008539819a3b18d29d805efbcfd5390db3`. The image revision is the development
image's own revision, not the mounted runtime revision. The mounted runtime and harness revision is stated above.
The runner resolves the image ID before assembling any Docker command, executes
that immutable ID, and fingerprints both native and Lua code in mounted and
packaged modes. Checkout dirty status is recorded in each environment row. Native and Lua
fingerprints remained unchanged throughout all four matrices.

**63/63 paired process comparisons passed against a pure-cjson baseline**, including every complete semantic,
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
| 32,768 short array objects | memory | 18.62 MiB | 14.16 MiB | 9.9 ms | 28.1 ms |
| 32,768 short array objects | file | 18.68 MiB | 13.70 MiB | 9.5 ms | 29.4 ms |
| 32,768 short array objects | feed | 18.64 MiB | 13.59 MiB | 9.5 ms | 31.6 ms |
| 32,768 small-object fields | memory | 23.16 MiB | 17.69 MiB | 13.1 ms | 658.2 ms |
| 32,768 small-object fields | file | 23.18 MiB | 15.07 MiB | 13.3 ms | 774.6 ms |
| 32,768 small-object fields | feed | 23.17 MiB | 14.86 MiB | 13.4 ms | 732.4 ms |
| 32,768 scalar fields | memory | 15.89 MiB | 15.68 MiB | 7.6 ms | 632.9 ms |
| 32,768 scalar fields | file | 15.88 MiB | 14.87 MiB | 7.7 ms | 695.1 ms |
| 32,768 scalar fields | feed | 15.89 MiB | 14.90 MiB | 8.8 ms | 739.7 ms |

The final completed-file/two-fork results are 13.70 MiB (array objects),
15.07 MiB (wide objects), and 15.18 MiB (wide scalars), versus paired pure
cjson 27.22, 34.12, and 19.26 MiB respectively. The historical table above
used two forks and the old import policy; do not attribute differences caused
by branch count or corrected imports solely to runtime optimization.

Raw process records: [bounded-metadata-final.jsonl](bounded-metadata-final.jsonl).
Each matrix starts with its own environment record. `source_stats.index_bytes`
measures retained native index capacity, not the entire Rust/Lua allocator.

### Real HTTP comparison

Fresh OpenResty workers, completed-file input, two concurrent clients, three
requests per client (six timed requests per method/shape), direct mutation,
64 KiB reader chunks. All four semantic oracle probes passed. These are small
local runs, not production throughput forecasts.

| Shape | cjson RSS | LeanJSON RSS | cjson p50 | LeanJSON p50 |
| --- | ---: | ---: | ---: | ---: |
| 32,768 short array objects | 22.76 MiB | 13.59 MiB | 20 ms | 62 ms |
| 32,768 small-object fields | 43.00 MiB | 17.18 MiB | 26 ms | 1413 ms |

**Memory improved; wide-object processing is still much slower than cjson.**
Exact duplicate handling spills large key maps to disk and performs many small
synchronous I/O operations. The wide-object HTTP run recorded 2,687,346
write syscalls and 5,660,302 read syscalls over six requests. This is
an explicit CPU/I/O/latency cost, not a speed improvement. Consider it before
using this path for latency-sensitive workloads consisting of many small fields.

Raw HTTP records: [bounded-metadata-final-http.jsonl](bounded-metadata-final-http.jsonl).

## Functional and resource checks

On the same runtime: complete `make openresty-verify` passed Rust default,
scalar-only and panic-injection suites, strict clippy, **408 Lua tests**, clean
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

Selected check receipts: [bounded-metadata-final-checks.txt](bounded-metadata-final-checks.txt).
Independent task reviews found and verified fixes for canonical object-child
iteration, object ipairs compatibility, cjson import isolation and HTTP decoder
option forwarding. Normal/cold file and small-memory HTTP probes verify actual
zero/tiny decoder settings; the benchmark driver now asserts effective index
settings on each LeanJSON sample. The 32,768-member zero-budget iteration probe
completes without a retained sibling cache; annotated iteration supplies exactly
two input-length passes in its native window test. The final whole-branch
review and scoped fix review are summarized below.

Earlier candidate records remain at [bounded-metadata-after.jsonl](bounded-metadata-after.jsonl)
and [bounded-metadata-http.jsonl](bounded-metadata-http.jsonl). They used the
pre-review runtime with LeanJSON preloaded in cjson cells, and are retained for
traceability rather than used as final acceptance evidence. The original
[check receipts](bounded-metadata-checks.txt) apply to that earlier runtime.

## Final review and hardened hash map

The independent whole-branch review covered `6926158..e7b3218`. It found one
important issue: public fixed FNV hashing with disk linear probing allowed
chosen decoded keys to cause quadratic synchronous I/O. Commit `5729eb2`
replaces it with a per-map standard-library `RandomState` hashing the complete
key. Insertion, rehashing and current-occurrence lookup use consistent keyed
fingerprints; full decoded-key comparison remains mandatory on hash matches.
It adds constant state per active map and no new dependency.

The deterministic shared-path work regression uses 1,024 keys that collide in
the former FNV buckets. Insertion/rehash logical file reads fell from **920,807
to 7,085**, and current/stale lookup reads from **1,053,696 to 7,138**. These
are instrumented read operations, not kernel syscall counts. Production uses
randomized state; tests inject a deterministic standard-library hasher into the
same map implementation. Forced full-hash collisions still preserve exact
comparison, growth, replacement and final-value/order semantics. This removes
the demonstrated cheap collision construction, without claiming a universal
worst-case CPU bound.

The same grouped fix pins every benchmark Docker command to its resolved image
ID, fingerprints packaged Lua contents, and removes trailing whitespace from
selected receipts. Three host-side runner tests pass, including rejection of
a Lua-only change when the native fingerprint is unchanged. The scoped
`e7b3218..5729eb2` re-review marked all three findings **addressed**, with no
new Critical, Important or Minor breakage. Refreshed process/HTTP/Valgrind
results above apply to this hardened runtime, not the earlier reviewed binary.

Exact committed runtime image: `lua-leanjson-openresty:bounded-5729eb2`, built from
`5729eb2bcacf015f54dcbc039cb3192ac13a4e91`, ID
`sha256:2de4db568da7f59aa895aae055080dffe4a3f2f3161268ed4e0a8d1bbd09b51c`. The smoke check used the immutable image ID and passed
four memory/file/incremental length-and-SHA cases plus malformed-input
rejection. The runtime contains neither Rust nor Cargo. No hosted CI,
GitHub publication or package publication is claimed.

The [raw-log archive](bounded-metadata-logs.tar.gz) retains original review
reports, red/green and full-gate
logs, prior final JSONL records, matrix summaries and image receipts. Earlier
failed runs remain labeled by their original filenames. During the final
Valgrind refresh OrbStack stopped and interrupted the fourth probe before a
result; its Docker transport-error log is retained. The same probe passed after
restoring the existing environment. All four accepted logs report zero errors
and zero bytes remaining.

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
