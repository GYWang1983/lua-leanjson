# Source index and scan-time Schema verification — 2026-11-03

Implementation is based on `c913c2b`, with uncommitted library changes. No commit,
push, rock publication or permanent Kong integration change was made.

## Implemented behavior

- `structural_index` defaults true on memory/file/feed/OpenResty decode options;
  false disables selective validated string-span retention. This is a compact
  Source acceleration structure, not the old full `Document.indices` array.
- Automatic prefixes, structural spans and final demand-result caches share
  `index_budget_bytes`, including allocated unused capacity. Confirmed positive
  and absent keys, path ancestors and array indices are reusable across forks.
  Unconfirmed prefix occurrences cannot hide later decoded duplicate keys.
- A supplied reusable compiled Schema consumes the original scanner's events,
  rejecting before values are published. Type/length-only strings do not become
  complete Lua strings. The [executable profile](../schema-validation.md) has
  explicit supported constraints, asserted format/base64 behavior and compile-time
  rejection of unsupported dialect/features.
- Legacy scanners cap their initial offset reservation. Synchronous file I/O
  reuses at most64KiB and returns copied strings; large requested buffers are not
  retained in the pool.

## Correctness evidence

| Gate | Result |
| --- | --- |
| `cargo test --release` | Passed full suite |
| `cargo test --release --no-default-features` | Passed full suite |
| `cargo test --release --features test-panic` | Passed full suite |
| `cargo clippy --release --all-targets -- -D warnings` | Passed |
| Full Lua busted suite | 870 successes,0 failures/errors |
| Lua lint | 0 warnings/errors across96 files |
| Isolated LuaRocks SCM install + installed-package smoke | Passed; new Schema/switch and existing memory/file/feed/fork/reader APIs |
| Real HTTP scan-time Schema rejection/cleanup | Three400 rejections before Provider;1MiB accepted with full messages; Source FDs/readers released |
| Independent native task, Schema task and whole-change review | Approved,0 open findings |

New regressions were observed failing before their fixes. They cover actual
Source read bytes, positive/negative repeated paths, escaped and later duplicate
keys, forks, tiny/zero budgets, simultaneous lookup completions, one-byte windows,
>4GiB offsets, stopped-GC I/O allocation, plan-wrapper collection, exact numeric
assertions, schema composition, legal reserved-looking object keys, UTF-8 keys,
formats and rejection cleanup. Native focused suites include9 index tests and22
Schema tests; full corpus/property/Unicode gates remain in the commands above.

A separate official JSON Schema Test Suite draft-2020-12 run at commit
`245a45abc90190c0bff04d97e6d2b541b4bb9f12` evaluated924 cases:908 matched;
16 differ intentionally because this profile asserts14 format cases and2 base64
cases that the standard default vocabulary treats as annotations.142 unsupported
schema groups were explicitly rejected at compilation. This is evidence for the
stated profile, not a claim of complete selectable-dialect conformance.

## Controlled local HTTP comparison

Both variants use the same pinned final Kong image. The optimized variant mounts
this checkout's native library/Lua module and supplies the complete original Chat
Schema to decode; a test-only adapter substitutes its matching prior body pass.
All other application checks remain, and every upstream message is compared.
The original Schema fixture is frozen from the initial investigation, independent
of subsequent edits by the other agent in the Kong workspace.

| Input | Released LeanJSON latency | Optimized inline-Schema latency | Released worker HWM | Optimized worker HWM | Cumulative Source reads |
| --- | ---: | ---: | ---: | ---: | ---: |
| 8 MiB | 1.430 s | 0.203 s | 158.3 MiB | 116.7 MiB | 110.7 → 24.0 MiB |
| 64 MiB | 10.813 s | 1.691 s | 251.0 MiB | 156.0 MiB | 895.1 → 192.2 MiB |

Each measurement uses a fresh single worker, one tiny warmup, normal GC and the
ordinary abort yield hook. Requests are sequential and synthetic, with distinct
64KiB content per message. Cumulative Source reads include repeated reads, not
physical-disk traffic or retained memory. These four single-request observations
are exploratory; they do not establish production concurrency, an OOM limit or
an SLO. Raw input/image/library hashes, phases and `/proc` samples are in the
[benchmark data](source-index-schema-benchmarks-2026-11-03.json).

The prior cjson report recorded0.067s/0.607s for8/64MiB. Optimized LeanJSON remains
slower on that latency reference; Source's original validation and the reader's
depth/count/output work still consume CPU. This change establishes the requested
cache/Schema/index optimizations rather than claiming universal cjson throughput.

Source/index storage is bounded separately from explicit preloads, caller-held
values, validation equality/count state, I/O and Lua GC timing. The API does not
promise constant total process RSS. Production adoption still requires the Kong
caller to pass its compiled Schema and avoid repeating the same input-body
validation; this checkout does not replace the published rock or edit that
business integration automatically.
