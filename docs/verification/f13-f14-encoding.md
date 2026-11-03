# F13/F14 encoding verification

Recorded 2026-11-02, based on local main `15bada3`. Oracle: untouched
`vendor/lua-cjson` at `617164a0fe3bb647128178f9caefb304b8573bb6`, compiled
using its Makefile and explicitly loaded with `package.loadlib`. Image cjson
observations from an initial probe are preserved as superseded setup evidence;
they are not the pinned-reference results used below. No push or publication
was requested.

## Behavior

`encode_indent([value])` has an empty-string default. It accepts strings and
native Lua numeric-to-string coercion, truncates at the first NUL, retains
non-whitespace indentation and returns the current setting. `nil` is a getter;
invalid types and extra arguments error atomically. Normal, new and safe codecs
have independent settings. The fixed native C implementation crashes on a fresh
or empty-reset getter (both isolated processes exit 139); LeanJSON safely returns
`""`. This is an explicit difference, not a successful crash-equivalence test.

`encode_skip_unsupported_value_types([value])` defaults to false and accepts
booleans or exact on/off with native NUL termination. Enabled unsupported root
values encode to the empty string; unsupported object members are omitted and
array elements compact. Nil/null remain null. Empty containers and nonempty
containers whose entries are all skipped retain native indentation distinctions,
including the final newline for the latter. Invalid object keys are validated
before skip; number, sparse-array, cycle and depth failures remain errors.

Two pre-existing value boundaries remain explicit: LeanJSON supports int64/uint64
numeric cdata, while native rejects/skips them. Native non-null lightuserdata
produces an empty token even with skip disabled and can generate malformed
container output; LeanJSON keeps its unsupported-type error with skip disabled
and omits it with skip enabled. Neither boundary is counted as native parity.

Nonempty indentation rebuilds container layout in the ordinary iterative encoder
and bounded reader, including clean raw spans, dirty nodes, nested proxies and
materialized keep_origin containers. Eligible raw scalar spellings remain intact.
Empty indentation retains prior raw-span reuse; it does not promise canonical
compact formatting of source-backed JSON. Pretty source traversal preserves
lexical duplicate occurrences unless `normalize_duplicates=true`; compact
reconstruction preserves its prior normalization behavior.

Reader construction snapshots both new settings. Length and next use the same
skip/format decisions. Indentation is emitted by a small repeat/cursor frame,
not an output-sized repeated string. Source strings keep their bounded chunk
path; no whole-document materialization, native cjson runtime fallback, Rust API
or C ABI change was introduced.

## Gates

Pinned Linux ARM64 `lua-qjson-dev:task3-repro`, image
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`,
OpenResty 1.29.2.4, LuaJIT 2.1 and Rust 1.90. Native macOS execution and
concurrent latency benchmarks were not performed.

| Gate | Result |
| --- | --- |
| Rust default / scalar / panic | 444 / 444 / 445 passed |
| Clippy | zero warnings/errors |
| Lua baseline / final full suite | 583 / 607 passed |
| New focused Lua suite | 24 passed |
| Lua lint | zero warnings/errors in 84 files |
| HTTP acceptance | 60 passed |
| Compatibility harness controls | 11 passed |
| Eager/preload resource acceptance | 18 cells passed |
| Installed-only local LuaRocks smoke | passed; source-tree and cjson fallbacks denied; installed native mapping verified |
| Standard RSS gate | 32/33 passed; failure retained below |

RED evidence separately records the missing public API, a real compact-versus-
indented output failure and the compact duplicate regression before their fixes.
A separate historical skip-behavior RED run was not captured; skip correctness
is demonstrated by the GREEN regression suite and independent native probes.
GREEN tests cover normal/safe/new settings, numeric/non-whitespace/NUL indent,
invalid arguments, unsupported roots/members/arrays/nested values, retained
errors, reader length/chunks/settings snapshots, raw/dirty/fork/keep_origin,
comments/duplicates, nine loading/source cells, depth and resource cleanup.

Independent parent probes have 44 exact native settings matches and 228 output
observations: 216 exact matches and 12 explicitly preserved integer-cdata
extension observations, with zero unexpected mismatches. The native oracle
scripts and direct raw results are included, including the isolated getter
crashes and setup errors. No upstream definitions or expected outputs changed.

Independent spec/quality and final integration review approved the change.
Its sole documentation finding was corrected: a separate historical skip RED
was not captured. No runtime fix or duplicate reviewer test run was needed.
The review checked source snapshot/key validation, raw/origin/duplicate behavior,
reader setting snapshots and source lease cleanup. All 51 runtime/header files
match the matrix provenance; built, installed and matrix native library hashes
are identical (`8bf0d9f2eedf09c39e8f1aa023c58851ae486ef0172dbdfd442096c01ec38c0b`).

## Complete upstream inventory

Each lazy/eager/preload × memory/file/feed cell retains all 164 original records.
Native baseline: 160 passes, 3 setup successes and one Lua 5.3-only environment
exclusion. The prepared `cs_CZ` locale is supplied and hashed.

| Mode | Per-source passes | Differences | Unsupported/dependent | Setup | Environment |
| --- | ---: | ---: | ---: | ---: | ---: |
| lazy / preload | 151 | 4 | 5 | 3 | 1 |
| eager | 154 | 1 | 5 | 3 | 1 |

All twelve F13 rows (`test.lua:L363` through `L396`) and F14 TEST22 pass in all
nine cells. The stable-ID audit against the preceding F10 archive finds thirteen
new passes per cell and no lost records or regressions among previous passes.
Remaining direct differences are F05 lazy array markers (TEST12/13/14) and F06
external array proxies (TEST23); F15/F16 and their dependencies remain unsupported.
The strict matrix therefore exits 1 with `compatible=false`, not full cjson parity.

The supplemental selective replay remains 62/80 passes per source, with eighteen
differences. Its existing worker does not reapply captured decoder settings or
use the captured safe route; it is retained separately and does not replace the
correctly configured main matrix and new preload tests.

## Memory boundary

The unchanged 11-scenario × three-source harness used approximately 1 MiB inputs,
metadata prefixes 3, a 1 MiB index budget and fresh native workers. It passes
32/33 pairs. `wide-scalars/memory`: LeanJSON 16296 KiB versus cjson 16212 KiB,
+84 KiB (ratio 1.005181, about 0.52%). The preceding task also failed this same
boundary (+72 KiB). No threshold was relaxed and no successful rerun replaced
the failed sample. These observations neither prove a universal RSS bound nor
establish a stable F13/F14-specific regression. The RSS harness uses default
formatting; bounded indented source traversal is checked by the focused
instrumented regression tests, not advertised as an all-workload memory result.

## Evidence

Reproducible commands, RED/GREEN logs, native oracle scripts, Rust/Lua/HTTP/lint
logs, complete matrix inventory/records/provenance, regression audit, resource
and RSS receipts, installed-only script/log, task report and independent review
are sealed in [the evidence archive](f13-f14-encoding-logs.tar.gz). It excludes
installed rocktree artifacts and native object files; source and native hashes
are recorded so the pin can be rebuilt. Only task files are committed; prior
local-main commits and other worktrees are preserved.
