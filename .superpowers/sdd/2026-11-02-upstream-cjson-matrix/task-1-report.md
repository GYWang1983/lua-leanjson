# Task 1 implementation and validation report

Task: complete upstream lua-cjson adaptation and nine-cell LeanJSON matrix.
Branch: `test/upstream-cjson-matrix`; implementation base: `f653902`.
Authoritative final evidence: `task-1-artifacts/final/` beside this report.

## Result

The harness is healthy and the measured implementations are **not fully
compatible**. Every baseline/cell has exactly 164 inventoried records: 161
assertions/blocks/cycles and 3 setup helpers. The final baseline has 160 applicable
assertion passes, 3 successful helpers, and 1 explicitly inapplicable Lua 5.3
conditional case. No baseline assertion or harness failures remain.

Each of the nine target cells has 15 applicable passes, 14 behavioral differences,
134 unsupported cases/dependencies, and the same 1 conditional exclusion. Helpers
are never counted as successful assertions. All 3 target helpers are included in
the unsupported count. Thus each cell's 160 applicable assertion outcomes are
15 pass + 14 difference + 131 unsupported. There are no uncounted skips.

The final direct Python strict invocation exited **1**, as intended for
incompatibility, with `harness_healthy=true` and `compatible=false`. GNU make exits
2 when its recipe exits 1; this is distinct from a Python harness-failure exit 2.
Report generation mode returns 0 for that same healthy/incompatible summary; the
focused exit-policy test verifies both paths.

## Implementation

Owned files:

- `scripts/verify-cjson-compat.py`: fixed-suite lexical inventory, host-side Docker
  orchestration, temporary reference build, provenance, completeness validation,
  full matrix, selective replay, classification, summary and strict exit policy.
- `tests/upstream-cjson/worker.lua`: original Lua definition execution, native or
  direct LeanJSON dispatch, explicit unavailable symbols, shared setup dependency
  tracking, original/logical verdicts, typed bounded observations and cleanup.
- `tests/upstream-cjson/test_runner.py`: seven focused tests, including real
  native/target worker fault controls and source-inventory alias checks.
- `tests/upstream-cjson/README.md`: reproduction, schema, adaptation and limits.
- `Makefile`: `cjson-compat`, `cjson-compat-strict`, `cjson-compat-controls`, output,
  image and optional locale-directory variables.
- This task report. Root-owned README/design/plan/final report were not edited.

Runtime sources, product semantics, and `vendor/lua-cjson` were not edited. No
remote actions, pushes, PRs, merges, images changes, or additional agents occurred.

All 131 `test.lua` rows execute in original order and shared state. The adapter
replaces only the upstream *runner* entrypoints in `cjson.util`; original cases,
input/expected expressions, generators, helper bodies and comparisons remain Lua.
Helpers are protected individually so an unsupported API cannot abort the rest.
All 24 `agentzh.t` blocks execute verbatim in fresh LuaJIT processes, with stdout
and exit verdicts retained. All 9 supplied JSON files run through the original
decode-cycle function. The sole temporary source transformation is display-only:
`tostring(json._VERSION)` in the version header. The actual identity assertion
still returns the real missing target fields and remains unsupported.

The native reference loads the freshly built library through `package.loadlib`
from its temporary source copy. Target bootstrap denies native cjson before
requiring LeanJSON, selecting the product's standalone null and empty-array
sentinels. Afterwards the `cjson` facade calls real LeanJSON APIs directly.
Missing configuration functions raise explicit markers; constants remain absent;
`cjson.safe` is explicitly unsupported. Nothing calls native cjson for the target
or emulates cjson settings. Process maps enforce absence of native cjson there.

The unmodified `util.compare_values` runs before logical observations. Proxy
operations, iteration, metatable checks, mutation and encoding are not replaced.
Only final logical observation may use `leanjson.pairs`. OpenResty LuaJIT in this
image also honors proxy `__pairs` in the original comparison. Exact and logical
verdicts happen to match in this run, and both remain recorded independently.

Failed configuration calls taint later calls in the matching encode/decode domain;
getters also retain failed reset/setting dependencies. Failed helpers remain
explicit dependencies. Raw exact matches are retained even when classification is
unsupported: 31 such assertion matches occur per cell. Of 134 unsupported records,
48 have direct missing-symbol/module evidence and 86 have dependency-only evidence.

## Inventory and provenance

Inventory counts and categories after the safe-factory/alias audit:

| Inventory | Count |
|---|---:|
| `test.lua` rows | 131 |
| Helpers (lines 404, 412, 495) | 3 |
| Direct-decode rows, including `safe.new().decode` | 57 |
| Encode-only rows | 39 |
| Settings/metadata rows | 32 |
| `agentzh.t` blocks | 24 |
| Supplied JSON decode-cycle fixtures | 9 |
| Total records per full cell | 164 |
| Assertions/blocks/cycles per cell | 161 |

Benchmark `tests/bench.lua`, package/build orchestration (`runtests.sh`,
`build-packages.sh`), and replacement Perl runner `tests/TestLua.pm` are explicitly
listed as exclusions/setup infrastructure, not omitted functional cases. Every
functional block that Perl would execute is included. `agentzh` test 15 records
the selected ordinary-table branch because this LuaJIT version string does not
contain `LuaJIT 2.1.0`. Test 24 prints canned output on Lua 5.1 and is explicitly
environment-inapplicable; it provides no actual Lua 5.3 integer coverage.

Pinned upstream revision: `617164a0fe3bb647128178f9caefb304b8573bb6`.
Its loaded source-built module reports `cjson`, version `2.1.0.11`; the rockspec's
`2.1.0.17` label is not used as binary provenance. Original suite/helper/fixture
SHA256s are all in `final/inventory.json`; definition hashes accompany stable IDs.

Final reference library SHA256:
`c70945c3a528bc88a787e2b6fc138f41819fbce8dc3d6c759d1164527f3561c3`.
The complete `.so` is retained as `final/native-reference.so`, with matching
requested paths and process maps in baseline worker records. Build uses the
upstream Makefile, GCC 11.4.0, LuaJIT 2.1 headers, `-O3 -Wall -pedantic -DNDEBUG -g`,
`-fpic`, `-shared`, libc `fpconv.o`. No vendor build artifacts were written.

Native image:
`lua-qjson-dev:task3-repro`, immutable ARM64 ID
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`.
LuaJIT reports `2.1.ROLLING`. The prebuilt target library SHA256 is
`20e4db6e52ad82f7378550e2cc3943485e456cc1880e825f69ae445774c29d42`.
Every runtime source SHA256 and actual mapping is retained. The single project
gate reused this release build and passed; no native product source changed.

Upstream `genutf8.pl` ran in the temporary reference tree. Generated fixture:
4,382,592 bytes; MD5 `cff03b039d850f370a7362f3313e5268`;
SHA256 `e0a7693f7362e88827c15e772e55b3490bd983f90711df7f3ef36c2b1ef6847e`.
This agrees with the supervisor's independent oracle.

The supervisor prepared `../locale/cs_CZ` from Ubuntu package
`locales_2.35-0ubuntu3.15_all.deb` in a disposable container. Package SHA256 is
`9094f7e6c619a385b05995e0d71d12122368fd3d2f0526a5298a9bd392a94b64`.
Final workers use explicit `LOCPATH`; `os.setlocale('cs_CZ')` succeeds, and the
supervisor separately verified libc decimal comma. Package, generator commands,
locale files, probes and hashes remain in `../locale/`. Final provenance hashes
that directory and records its successful setlocale probe. The initial run's
three unavailable-locale records remain archived; they are not final exclusions.

## Full matrix

| Cell | Pass | Behavioral difference | Unsupported/dependency | Environment | Exact raw matches | Logical matches | Real source decode calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| lazy-memory | 15 | 14 | 134 | 1 | 47 | 47 | 75 |
| lazy-file | 15 | 14 | 134 | 1 | 47 | 47 | 75 |
| lazy-feed | 15 | 14 | 134 | 1 | 47 | 47 | 75 |
| eager-memory | 15 | 14 | 134 | 1 | 47 | 47 | 75 |
| eager-file | 15 | 14 | 134 | 1 | 47 | 47 | 75 |
| eager-feed | 15 | 14 | 134 | 1 | 47 | 47 | 75 |
| preload-memory | 15 | 14 | 134 | 1 | 47 | 47 | 75 |
| preload-file | 15 | 14 | 134 | 1 | 47 | 47 | 75 |
| preload-feed | 15 | 14 | 134 | 1 | 47 | 47 | 75 |

Every row contains 164 records, including 3 unsupported helper records. Category
breakdown is identical across cells:

| Category | Pass | Difference | Unsupported | Environment |
|---|---:|---:|---:|---:|
| Direct decode (57) | 8 | 12 | 37 | 0 |
| Encode-only (39) | 0 | 0 | 39 | 0 |
| Settings/metadata (32) | 2 | 0 | 30 | 0 |
| Setup helpers (3) | 0 | 0 | 3 | 0 |
| Decode cycles (9) | 0 | 0 | 9 | 0 |
| Functional agent blocks (23) | 5 | 2 | 16 | 0 |
| Conditional no-op (1) | 0 | 0 | 0 | 1 |

The 12 untainted direct-decode differences are exact error/details differences at
`test.lua:L121` through `L154`. They remain different errors; none is replaced
with upstream's expected message. `agentzh` test 20 reaches the unsupported
precision-16 argument range of the existing precision API and aborts after its
first output line. Test 23's foreign `__len`/`__index` proxy encodes as `{}` instead
of the reference array. All other differences/unsupported behavior remain visible
in per-case raw outputs, API evidence and dependency records.

Actual target decode paths are exclusively 75 calls to `leanjson.decode` in each
memory cell, `leanjson.decode_file` in each file cell, or
`leanjson.new_decoder:feed:finish` in each feed cell. These occur in 66 cases per
cell. Reference dispatch captures 80 decode calls; target-only unavailable APIs,
failed setup and earlier execution errors explain the missing calls within those
explicitly reported cases. Supplemental replay covers all 80 reference inputs.
Encode-only/settings/helper cases do not claim source coverage.

Preload cells use `$`, with `index_depth`, `index_array_limit` and
`index_budget_bytes` all zero. Eager cells pass `lazyload=false`. Deterministic
feed widths are 1,2,3,5,8,13,64,256,1024,4096,16384 bytes. Every case has explicit
cleanup evidence; all final cleanup error lists are empty.

## Supplemental sparse replay

All 80 reference decode calls are replayed separately through each source, with
real selective `preload_paths` and all optional indexes zero. Existing array
elements/object keys are selected using quoted JSONPath derived from the native
typed observation. Scalars select `$`; empty containers report no selectable child.
Original inputs, reference API/configuration and original case IDs remain attached.

| Source | Combined pass | Combined difference | Stats-bearing proxies | Zero-index violations | Nonzero actual preloads | Unselected sibling reads | Sibling mismatches |
|---|---:|---:|---:|---:|---:|---:|---:|
| memory | 35 | 45 | 31 | 0 | 31 | 9 | 0 |
| file | 35 | 45 | 31 | 0 | 31 | 9 | 0 |
| feed | 35 | 45 | 31 | 0 | 31 | 9 | 0 |

Each source has 36 successful reference/target decodes with equal typed results;
27 both-error outcomes with different exact details; 15 reference-success/target-
failure outcomes; and 2 reference-failure/target-success outcomes. Settings and
safe-module semantics are not emulated during ordinary-decode replay.

The combined pass count additionally requires a complete encoded-output logical
roundtrip. One value-equivalent case, `agentzh.t:TEST20#decode1` (2^53), fails that
stronger check because default precision rounds the encoded number. It is a
combined supplemental difference, not a decode-value mismatch. Native cjson's
default 14-digit encoding has the same precision loss, so this extra lossless
roundtrip failure is **not a target-only cjson incompatibility**. The primary
precision difference is the target API's inability to select 15/16 digits. There are 37
successful encoded roundtrips including the two reference-rejected values. Exact
encoded bytes and that separate invariant are retained, so these totals must not
be advertised as 35/80 direct-decode compatibility. Automatic-index checks and
supplemental differences also feed strict mode.

## Negative controls, execution and self-review

Tests were written and observed red before implementation. Evidence directory:
`task-1-artifacts/negative-controls/`.

- `red.log`: initial six failing tests for the absent runner.
- `selection-red.log`: missing real-child selective control.
- `metadata-red.log`: reproduced supplemental nested-list serialization failure.
- `review-behavior-red.log`: safe constant wrongly classified as a difference;
  getter after failed reset wrongly classified pass while its raw match was true.
- `inventory-alias-red.log`: factory decode incorrectly categorized as settings.
- `green.log`: final **7 tests pass**. Native/target controls exercise omitted,
  duplicate and unexpected IDs; intentional wrong return after real target decode;
  missing API; failed helper dependency; malformed input with unmodified error;
  nil/false/null/bytes/NaN/infinity/arity; one-byte UTF-8/escape/exponent/structural
  splits; actual escaped-key sparse preload and unselected sibling access; missing
  safe constant/module; failed-reset getter; strict/report/harness exit policy.

Authoritative final command (exit 1, 21.328 seconds):

```sh
python3 scripts/verify-cjson-compat.py --docker --strict \
  --output .superpowers/sdd/2026-11-02-upstream-cjson-matrix/task-1-artifacts/final \
  --locale-dir .superpowers/sdd/2026-11-02-upstream-cjson-matrix/locale
```

Equivalent canonical entrypoint:

```sh
make cjson-compat-strict \
  CJSON_COMPAT_OUTPUT=.superpowers/sdd/2026-11-02-upstream-cjson-matrix/task-1-artifacts/final \
  CJSON_COMPAT_LOCALE_DIR=.superpowers/sdd/2026-11-02-upstream-cjson-matrix/locale
make cjson-compat-controls
```

One full project gate ran in the pinned image with the requested target/registry
volumes: `make test`, exit 0 in 11.063 seconds. **428 Rust tests passed** across
31 cargo summaries; **439 Lua successes, 0 failures, 0 errors, 0 pending**. Evidence:
`task-1-artifacts/project-test.log` and `project-test-exit.json`.
No unrelated benchmark, fuzz campaign or repeated project gate was run.

The initial matrix completed baseline/nine cells, then correctly failed the
harness on supplemental metadata serialization. That failure is retained in
top-level logs and `attempt-1/`. The metadata regression was fixed and supplemental
alone rerun with separately tagged provenance. A subsequent locale/review refresh
and a final source-inventory-annotation refresh were justified by the new inputs
and classification corrections. The prior locale run is preserved in
`locale-before-inventory-annotation-fix/`; final/ is authoritative.

Self-review checks in `final/self-review-checks.json` independently re-read all
164-record baseline/cell outputs and 80-record selective outputs, verify no
missing/duplicate/unexpected IDs, confirm all actual source paths and empty
cleanup errors, check every stats-bearing selective proxy has zero index bytes,
verify **9,424 typed string lengths/SHA256s** against exact hex/blob data, and
verify the saved reference library hash. `git diff --check` passed. The supervisor
independently reconciled inventory/source hashes, native maps, dispatch, cleanup,
locale provenance and representative classifications, and reported that the
original unmodified reference `test.lua` plus all nine fixtures passed 137/137
assertions (`root-original-upstream.log` beside this report).

## Remaining limits and concerns

- Compatibility gaps are measured results; no runtime repair was attempted.
  Unsupported status includes failed setup dependencies, not only directly absent
  APIs. Raw verdicts remain available to distinguish those cases.
- Native plain Lua tables lose empty-array/object identity; observations state
  this ambiguity, while target proxy kinds, typed keys and exact encodings remain
  visible. Logical comparison only adapts final traversal; it does not establish
  metatable/storage identity or normalize errors/numbers/bytes.
- Target dependency profile is explicitly standalone, with optional native cjson
  denied during bootstrap. Other sentinel-integration profiles were not run as
  another matrix.
- Lua 5.3 integer behavior is not exercised by the pinned LuaJIT environment.
  The canned-output branch remains the sole environment-inapplicable full case.
- Full-root preload proves full-value preload behavior; sparse replay separately
  proves real selections, unselected access and complete observations. Supplemental
  combined counts include the stricter encoding invariant described above.
- Deep/cyclic input diagnostics are bounded at 48 levels and point to unmodified
  generation definitions; outputs/errors retain typed exact values or complete
  deduplicated byte artifacts. Long strings are not repeatedly dumped into logs.
- Logs, binary/blob artifacts and prepared locale are intentionally scratch
  evidence for supervisor archival. The task commit includes only the focused
  source files and this report. No outstanding harness failure or counted-case
  classification omission remains in the final evidence.
