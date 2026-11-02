# Decode loading modes verification

This report covers `lazyload=false` and `preload_paths`. Explicit preloads ignore
`index_depth`, `index_array_limit` and `index_budget_bytes`, even when all are zero.
Unselected fields remain lazy and complete output is preserved.

## Environment and evidence

Final runtime revision: `1bacb136c6be27b91493dd39ab18271b0b471cfd`.
Refreshed independent acceptance passed 18/18 cells. The run preceded the final
runtime commit, with its dirty checkout recorded in the environment JSON; the Lua
fingerprint was rechecked after commit and matches exactly. Native code is
unchanged from the canonical/installed gates. Both the earlier full-gate runtime
and the final Lua ownership fix have separate evidence below.

- Linux ARM64, Rust 1.90.0, OpenResty 1.29.2.4, LuaJIT 2.1.ROLLING,
  lua-cjson 2.1.0.11.
- Dev image `lua-qjson-dev:task3-repro`, immutable ID
  `sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`.
- Native library SHA-256:
  `20e4db6e52ad82f7378550e2cc3943485e456cc1880e825f69ae445774c29d42`.
- Lua runtime tree SHA-256 (relative filename, NUL, content, NUL, sorted):
  `c6f539b2f4971378e62756cfdda779a6d340227f6ef83ed2126e91aa2e827843`.

The [raw evidence archive](decode-loading-modes-logs.tar.gz) includes commands,
complete logs, independent measurements, probe source, reports and a SHA-256
manifest. `acceptance-initial` is intermediate diagnostic evidence;
`acceptance-final` is the pre-review runtime, and `acceptance-reviewed` covers
the final runtime above. Review outcomes are retained separately from executed
test evidence.

At `db052d4`, the canonical `make openresty-verify` gate passed: Rust default/scalar/test-panic
matrices, Clippy with warnings denied, **435 Lua tests**, lint (67 files, zero
warnings), 2,000 encode property cases, 1,000 mutation cases with 100 operations
each, 500 + 500 source stress cases, pinned JSON corpus replay and **60 real HTTP
checks**. Focused loading tests cover option validation, selectors, one-byte
feeds, duplicates, source ownership/cancellation, raw numeric tokens, edits/forks,
ordinary results and operation without optional cjson.

All six fuzz targets compiled with locked, offline dependencies. This is compile
coverage, not a new fuzz campaign. A fresh LuaRocks installed-tree smoke passed
from `/tmp`, with `LD_LIBRARY_PATH` cleared and only installed Lua/native search
paths: new module/ABI loading, memory/file/feed eager results, repeat queries and
selective byte-preserved output. Existing published v1/v2 layouts are unchanged.

Review found that a repeated eager rebuild could retain its partial tree and
scratch native parser after decoder close while the coroutine stayed suspended.
The final Lua-only fix scopes that cleanup, clears payload references and releases
the native parser immediately; late resume cannot use or release it again. Four
new regressions failed before the fix. Afterward, **60 covering loading/lifecycle/
review tests** and full 67-file Lua lint passed. Both finish and container-get
cases pause after multiple reads and verify cleanup before resuming, plus normal
and error exits. The earlier full gate was not rerun for this two-file fix; native,
ABI and unchanged HTTP evidence retains its original revision boundary.

## Independent acceptance method

```sh
python3 scripts/verify-loading.py \
  --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target \
  --output-dir /tmp/leanjson-loading-evidence
```

Each cell gets a fresh native OpenResty process. Fixtures are generated outside
the measured worker. The cjson baseline does not load LeanJSON and enables
`decode_array_with_array_mt(true)` to retain empty-array shape. The host compares
every output with a typed Python oracle (including boolean/null and object/array
distinctions), rejects duplicate keys in normalized output and verifies original
input/output byte counts and hashes. Preloaded untouched output must be byte-for-
byte identical to the input, including an escaped duplicate `model` key.

All three automatic index settings are zero. Eager runs use native
`rawget`/`next`/`pairs` and ordinary table writes, then `json.encode`, corresponding
to cjson's full-string encoding API. Selective runs use bounded readers. Selected
deep and far-array values are read repeatedly; file/feed source callbacks must not
increase. An unselected field is read afterward, and both untouched and rewritten
outputs include all large unselected content. Runtime fingerprints are checked
before and after the run. Builds and other measurements are not concurrent.

No forced GC occurs between input/decode, reads, output and mutation phases. CPU
and Linux process VmHWM are observations; they exclude neither transient
allocations nor already-loaded module memory. Input + decode CPU includes input
acquisition. Workload CPU includes both outputs. File/feed cjson reads the input
into a Lua string; LeanJSON can consume file windows or feed chunks. Memory-source
workloads retain the caller's input string. These are single-process measurements,
not concurrent HTTP throughput or a universal peak-memory guarantee.

## Results

The wide fixture has 32,768 small-object fields. The selective fixture is 4,486,310
bytes, with a large unselected prompt, 1,024 messages, a deep property and a selected
property on the final array element. The wildcard case selects every message role.

| Workload | Source | cjson peak RSS | LeanJSON peak RSS | cjson input + decode CPU | LeanJSON input + decode CPU |
| --- | --- | ---: | ---: | ---: | ---: |
| Wide, eager values + full encode | memory | 24.35 MiB | 40.41 MiB | 9.1 ms | 46.7 ms |
| Wide, eager values + full encode | file | 24.31 MiB | 36.11 MiB | 6.3 ms | 48.1 ms |
| Wide, eager values + full encode | feed | 24.32 MiB | 37.08 MiB | 6.9 ms | 38.4 ms |
| Selected fields + reader | memory | 34.41 MiB | 27.44 MiB | 5.1 ms | 73.0 ms |
| Selected fields + reader | file | 36.45 MiB | 14.50 MiB | 4.3 ms | 67.9 ms |
| Selected fields + reader | feed | 36.46 MiB | 14.11 MiB | 4.5 ms | 65.3 ms |
| Wildcard roles + reader | memory | 34.41 MiB | 30.16 MiB | 5.0 ms | 64.7 ms |
| Wildcard roles + reader | file | 34.38 MiB | 21.54 MiB | 3.9 ms | 68.7 ms |
| Wildcard roles + reader | feed | 34.42 MiB | 21.28 MiB | 4.0 ms | 66.1 ms |

Eager **decode-phase** peak RSS was 22.85–24.41 MiB, compared with 20.35–20.48 MiB
for cjson; output increased its peak further. Eager mode provides ordinary values,
not allocator/CPU parity with cjson. The earlier bounded-metadata RSS result is
not a guarantee for this opt-in eager workflow.

An initial diagnostic used `reader` even on eager ordinary tables. That existing
API snapshots the whole table into immutable logical nodes, reaching roughly
91–93 MiB in the wide workflow. It is a materially different output path from
direct `encode`; this change does not redesign that snapshot contract. The initial
intermediate-runtime results remain separate from the final acceptance evidence.

## Selected storage accounting

For the selected fixture after decode, `index_bytes=0`, `indexed_nodes=0`,
`preloaded_nodes=3`, `preload_path_nodes=8`, `preloaded_payload_bytes=23` and
`preloaded_key_bytes=27`. The wildcard fixture has 1,025 selected nodes, 1,026
route-only containers, 4,104 logical payload bytes and 4,106 key bytes. Repeated
selected reads added **zero** source callbacks for every file/feed cell.

These counters describe cache contents, not process allocations. Logical scalar
payload counts UTF-8 bytes for strings, 8 for numbers, 1 for booleans and 0 for
null. Key bytes count decoded retained occurrences, without modeling string
interning. Tables, native structures, paths, allocator overhead and user-held
values consume additional memory. Selecting a full subtree or `$` can retain a
large cache intentionally; the automatic index budget does not cap that request.

## API boundaries

- JSONPath is the documented subset; recursive descent, filters, slices, unions,
  negative indexes and JSON Schema are not implemented.
- All source input is validated before exposing results. There is no provisional
  JSON value or early forwarding of incomplete input.
- Eager incremental decoders transfer the first ordinary result and rebuild later
  results from their immutable spool; they do not retain a second complete DOM
  merely to support repeated queries. Close the decoder to release its own spool.
- The existing OpenResty Session exposes one completed value. Subsequent Session
  queries observe edits to it, in both socket and completed-body fallback modes.
- File I/O is synchronous. Native input adapters are tested against local HTTP
  fixtures; no Kong integration or production provider was involved.
