# F01/F02/F05 settings and array verification

Recorded 2026-11-02, working-tree changes on `ecbea6b`, branch
`fix/cjson-config-array-markers`. Reference: vendored OpenResty lua-cjson
`617164a0fe3bb647128178f9caefb304b8573bb6`.

Implemented precision 1–16 with new-value setter returns, sparse option validation,
shared `empty_array`/`array_mt`/`empty_array_mt`, and isolated empty-table/array-marking
configuration. [Public API and migration](../../README.md#precision-sparse-arrays-and-array-markers).

## Contract and boundaries

- Settings accept numeric strings and truncate fractions within documented
  bounds. Integers and negative zero now use configured numeric formatting;
  unchanged source tokens retain original bytes, while readers snapshot format.
- Sparse option failures are atomic, as explicitly required by F02. Native C
  partially updates earlier arguments on a later failure; this side effect is
  intentionally not reproduced. Native overflow-to-int and NaN conversion
  accidents are also excluded; nonfinite/out-of-range settings are rejected.
- Explicit `array_mt` uses raw length/values and ignores hash fields, including
  when marker metamethods exist. `empty_array_mt` checks normal sparse policy
  before its array fallback. Normal array classification still uses indexed
  reads (including `__index`); only the forced fallback uses raw values. Marker
  identity uses `rawequal`, bypassing `__eq` and protected metatable presentation
  in the supported runtime.
- Eager output uses native defaults: unmarked empty arrays become ordinary
  empty tables, which normally encode as `{}`. Enable array marking to retain
  their array identity. Decoder construction snapshots marking, including later
  get/repeated finish rebuilds. Normal and safe codecs share markers but isolate
  configuration.
- Lazy/preload continue preserving source array/object identity and original
  tokens. Marked views expose the public array marker through a private
  metatable. F18 mutation restrictions remain. Explicit materialize keeps its
  pre-existing shape/sparse reclassification contract; this helper has no native
  cjson counterpart. These boundaries remain real compatibility differences.

## Validation

Pinned Linux ARM64 `lua-qjson-dev:task3-repro`: OpenResty 1.29.2.4, LuaJIT 2.1,
Rust 1.90. No real cjson fallback is used by LeanJSON conversion.

| Gate | Result |
| --- | --- |
| `make test` | 428 Rust + 507 Lua tests pass |
| New settings/array tests | 34 cases, including 18 normal/safe input/loading cells |
| `make lua-lint` | No warnings or errors |
| `make openresty-test` | 60 native HTTP acceptance checks pass |
| Python harness | 11 control tests pass |
| Process memory gate | All 33 paired input/scenario cases pass |
| Loading acceptance | All 18 native eager/preload/reference cells pass |
| LuaRocks | Local install plus installed-only settings/marker smoke |

Old tests relying on eager shape preservation now assert native unmarked defaults
or explicitly enable marking. Their other assertions remain intact. The
standalone fixture tests both unmarked defaults and marked values without cjson.
Source mutation/ownership, callbacks, materialization and reader tests remain
part of the full gate.

Settings tests first failed against the old range/return/validation behavior;
array tests first failed on missing markers/settings. Raw-marker tests exposed
protected metatable/raw-length behavior and went RED→GREEN after correction.
The marker-mutation fixture runs in a separate Lua VM to avoid changing
registry-shared metatables for other tests. Initial failing runs and final runs
are retained rather than relabeled as passes.

Independent read-only review found five important edge cases. Each was
reproduced as a failing regression before repair: recursive origin reuse after
nested marker changes, marker `__len` during origin checks, marker spoofing by
`__eq`, marking lost after all source-backed array slots were replaced/removed,
and `empty_array_mt` holes no longer honoring `__index`. The final focused run
passes all 34 tests. Marking is stored as a boolean on edits, allowing source
resources to be released without losing the decoding policy. Whole-parent
origin reuse now checks descendant classification before using original bytes.
The full project, HTTP and upstream matrix were rerun after these repairs.

## Memory and loading regression

```sh
python3 scripts/verify-memory.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target \
  --output-dir .superpowers/f01-f02-f05/memory-post-review
python3 scripts/verify-loading.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target \
  --output-dir .superpowers/f01-f02-f05/loading-marked-post-review
```

The default 11 scenarios × memory/file/feed yield 33 paired comparisons, using
roughly 1 MiB fixtures, automatic depth/array limit 3 and 1 MiB index budget.
Every LeanJSON process peak RSS is at or below its cjson reference; measured
ratios range from 0.332 to 0.994. These are fresh, sequential OpenResty processes
with independent typed output checks, not a guarantee for every workload or
concurrent HTTP traffic.

The loading workload's typed roundtrip compares against cjson with array
marking enabled. Its first eager run correctly exposed the changed unmarked
empty-array default (`[]` became `{}`); the only typed difference was the
`empty_array` field. The workload now explicitly enables eager marking as it
already does for cjson, retaining the unchanged typed oracle. The separate
public API suite verifies both marked and unmarked defaults. The resulting 18
fresh-process cells pass; both initial and final observations are archived.

## Complete upstream matrix

```sh
python3 scripts/verify-cjson-compat.py --docker \
  --output .superpowers/f01-f02-f05/post-review-matrix \
  --locale-dir .superpowers/f01-f02-f05/locale
CJSON_COMPAT_TEST_OUTPUT=.superpowers/f01-f02-f05/python-post-review \
  python3 -m unittest discover -s tests/upstream-cjson -p test_runner.py
```

The prepared Czech locale is restored from the F04 evidence archive. Final
provenance hashes match all 48 current runtime source entries. An independent
record comparison against the F04 archive confirms the old passing set is
preserved in all nine cells (`post-review-audit.json`).

| Cells | Records per cell | Pass | Setup success | Difference | Unsupported/dependency | Environment inapplicable |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| lazy × memory/file/feed | 164 | 45 | 3 | 19 | 96 | 1 |
| eager × memory/file/feed | 164 | 48 | 3 | 16 | 96 | 1 |
| preload × memory/file/feed | 164 | 45 | 3 | 19 | 96 | 1 |

`test.lua:L420`, `L424`, `L431`, `L439`, `L487` and `agentzh.t:TEST20` pass in
every cell. Array TEST2–11 and TEST15–18 now run with real public markers and
settings. TEST12/13/14 pass in eager; lazy/preload retain the source-container
and F18 differences described above. The TEST15 conditional branch is still
the actual pinned LuaJIT branch, not an emulated alternative.

All previously passing F04 records remain passing. Selective replay remains
36 passes and 44 differences per source over 80 inputs. Overall `compatible`
remains false; F06 and the other checklist items remain separate work.

[Evidence archive](f01-f02-f05-config-arrays-logs.tar.gz) contains source hashes,
reference probes, raw matrix records, RED/GREEN logs, installation checks and
independent review notes.
