# F07/F17 depth and public diagnostic verification

Recorded 2026-11-02, based on local main `545f172`. Reference: pinned OpenResty
lua-cjson `617164a0fe3bb647128178f9caefb304b8573bb6`. Implementation and evidence
are included in this task's main commit; no remote push or LuaRocks publication.

## Contract and implementation

`decode_max_depth` and `encode_max_depth` default to 1000 and accept 1–2147483647.
They are independent per ordinary/safe codec, return current/new settings, and
retain native numeric-string/coercion and argument-error behavior. Decode
sources/decoders and output readers freeze their respective settings. Nonzero
source `opts.max_depth` overrides the codec setting; zero inherits it. Index
bounds remain independent of legal nesting.

Source v2 no longer clamps at 4096, and late walkers/eager rebuild carry the
originating limit. Legacy parse/source-v1 limits remain separate. Actual 5000
container inputs were tested with zero optional indexes, late reads, eager and
preload, repeated finish/get, materialization, ordinary encode, fork and readers.
Ordinary encoding, snapshots, materialization, origin matching and dependency
walking use explicit stacks, preserving the public setting beyond Lua recursive
call-stack limits. Extreme configured depths can still exhaust memory.

Reader length checks actual output depth before raw-span reuse, including
relocated subtrees and patches. An accepted source-depth bound proves safety
when possible; otherwise a bounded scan tracks quotes/escapes. Construction has
no source I/O. Scan reads honor cancellation immediately before and after a
yielding read. Native `empty_array` retains its scalar-token depth exception
through snapshots; actual source arrays and ordinary tables still count, and
editing a sentinel snapshot removes the exception.

A native companion tokenizer retains fixed-size token payloads and a nesting
stack, not a decoded tree. It handles native lexical precedence for unexpected
tokens, numeric-prefix rollback, escapes, surrogate pairs, first-two-byte
UTF16/32 detection and global byte-based character positions across feed splits.
Pending strict failures retain their original machine-readable tuple while
native token classification completes. The additive
`leanjson_source_v2_format_error` exposes public text without replacing
`code/detail/offset`; successful completion releases diagnostic workspace.

Conversion arguments, unsupported values/keys (including standalone sentinels),
sparse arrays, nonfinite numbers, cycles and nesting now use native public
messages. Safe conversions preserve the same errors and setter errors still
throw. Strict RFC number/control/NUL rejection and optional UTF8 validation remain
explicit extensions where native accepts input. Unsupported comments and other
open features were not enabled. No cjson parser/encoder is used by target
runtime diagnostics, and no upstream expected error was normalized.

## Validation

Pinned Linux ARM64 image `lua-qjson-dev:task3-repro`: OpenResty 1.29.2.4,
LuaJIT 2.1, Rust 1.90. Native macOS LuaJIT was unavailable for execution.

| Gate | Result |
| --- | --- |
| Rust default / no-default-features / test-panic | 441 / 441 / 442 passed |
| Final Lua suite | 567 passed; zero failures/errors/pending |
| Clippy / Lua lint | clean; Lua lint 82 files |
| Native OpenResty HTTP | 60 checks passed after review fixes |
| Python harness controls | 11 tests passed after review fixes |
| Independent native syntax oracle | default 519 and strict 526 both-rejected inputs; zero public-message mismatches |
| Independent all-split oracle | 1617 checks; zero message/position mismatches |
| Eager/preload resource acceptance | 18 cells passed after review fixes |
| Installed-only LuaRocks smoke | passed; native cjson/source-tree fallback denied |
| Memory gate | initial 33/33; final 32/33; one boundary sample described below |

RED evidence includes missing setters, generic syntax errors, signed strict
numeric errors, deep ordinary/materialize Lua stack overflow, and all four
independently reviewed edge failures. Focused new suites contain 9 depth/error
contracts and 6 review regressions. Existing assertions changed only for intended
wording/default/unclamped-depth behavior. The new error helper compares messages
verbatim. Rust tests preserve the original error tuple at every split and verify
separate legacy limits.

Task and integration review found four P2 issues: omitted fork depth, sentinel
snapshot depth semantics, cancellation within raw scans, and standalone sentinel
key type wording. All were fixed in one wave with RED/GREEN regressions and
approved on scoped re-review. No findings remain open in those repaired paths.

## Complete upstream inventory

Every cell retains all 164 original records, including 3 setup helpers. Native
baseline: 160 assertion passes, 3 setup successes, 1 Lua 5.3-only environment
exclusion. Locale `cs_CZ` was supplied and exercised.

| Loading mode | Sources | Pass | Behavioral differences | Unsupported/dependent | Setup | Environment |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| lazy / preload | memory, file, feed; each cell | 127 | 4 | 29 | 3 | 1 |
| eager | memory, file, feed; each cell | 130 | 1 | 29 | 3 | 1 |

All previously passing records remain passing. Applicable F07 depth and F17
upstream error rows pass in the complete matrix. Remaining direct differences
are F05's lazy structure/marker semantics (TEST12/13/14) and F06 external array
proxies (TEST23). Unsupported records concern F10 comments, F13 indentation,
F14 skipping types, F15 buffer settings/dependencies, and F16 identity. Strict
matrix exit 1 and `compatible=false` are retained; this is not complete cjson
compatibility.

Supplemental selective replay retains 80 decode calls/source: 62 pass and 18
recorded differences. This older replay uses default normal-codec policy; it
records configuration metadata without applying it and does not preserve the
captured safe-call route. Thus its differences include the configured-depth/
strict-number calls, safe error calls and unsupported comments. These are not
substituted for the complete matrix's correctly configured normal/safe calls or
for the new selected-preload/source regressions. Replay results are preserved,
not normalized into passes.

## Memory boundary

Default 11 scenarios × memory/file/feed, approximately 1 MiB inputs, metadata
prefixes 3 and budget 1 MiB, fresh processes and independent output oracles. The
initial complete run passed 33/33 with RSS ratios 0.337–0.993. After review fixes,
32/33 passed; `wide-scalars/memory` measured 16324 KiB versus native 16256 KiB,
ratio 1.004183 (+68 KiB). That strict gate failure remains recorded.

A controlled five-repeat comparison rotated native, pre-review-fix Lua and
final Lua over the same input/native library. Final Lua was below native in 4/5
pairs (ratios 0.9919–1.0052); pre-fix Lua was below in 4/5
(ratios 0.9916–1.0020). Means were 16201.6 KiB final, 16215.2 KiB pre-fix and 16270.4 KiB
native. Both variants crossed the threshold; these observations do not establish
a stable regression from the review fixes or prove a universal RSS bound. No
threshold was relaxed and no passing rerun replaced the failed complete sample.
Large full-value loads, concurrent workloads and extreme depths remain outside
this memory claim.

## Commands, provenance and evidence

Final affected gates:

```sh
docker run --rm -v "$PWD:/workspace" \
  -v leanjson-bounded-target:/workspace/target \
  -v qjson-cargo-registry:/usr/local/cargo/registry \
  -w /workspace lua-qjson-dev:task3-repro make test lint lua-lint openresty-test
python3 scripts/verify-cjson-compat.py --docker --strict \
  --output .superpowers/sdd/2026-11-02-cjson-f07-f17/post-review-matrix \
  --locale-dir .superpowers/sdd/2026-11-02-cjson-f07-f17/locale
```

Three-mode Rust commands, strict numeric/split probes, memory/loading controls,
local install and installed-only scripts are retained in the archive. Python
negative controls now deliberately inject missing-symbol/divergent-error faults
instead of relying on depth APIs or diagnostics remaining broken. Ordinary
matrix workers have no such injections.

The final matrix hashes 50 runtime/header files; all match the final source.
The built and installed native library share SHA256
`8f4be768b2791d5d74bd29e34239523495e235bbc8e1899eda0313aec6614f8a`.
Reference cjson's library hash is separate. The report does not confuse them.

Evidence: [logs and source snapshots](f07-f17-depth-diagnostics-logs.tar.gz).
It includes task/fix reports, reviews, RED/GREEN, final gates, raw full/selective
matrix records and inventory, controls, failed/passing memory runs, all five
controlled comparisons, install smoke, source manifest and SHA256 receipts.
`post-review-*` is the final runtime evidence; earlier runs remain historical.

Decisions made: reuse the existing isolated worktree and integrate only this task
on local main; lift the source-v2 clamp while retaining legacy limits (larger
limits can cost stack/workspace memory); retain the strict failed RSS sample
without speculative runtime tuning or threshold changes (the all-workload
memory goal remains unproven). No unrelated feature branch was merged and no
remote push was requested.
