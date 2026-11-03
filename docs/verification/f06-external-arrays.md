# F06 external-array encoding verification

Recorded 2026-11-02 against local main `161071f`. Oracle: untouched
`vendor/lua-cjson` at `617164a0fe3bb647128178f9caefb304b8573bb6`, built with its
Makefile and explicitly loaded using `package.loadlib`; the image's different
cjson build is not used as the binding oracle. No push or publication requested.

## Implementation and boundaries

The shared table classifier recognizes raw `__len` on the actual metatable,
including protected metatables and callable method values. An explicit
`array_mt` wins first and keeps raw length/values. Otherwise a present `__len`
forces array semantics: raw hash keys are ignored, ordinary raw-key sparse
classification is bypassed and `value[index]` honors Lua's normal `__index`.
A fabricated/inherited method from the metatable's own `__index` is ignored.
The library's own JSON proxies retain their node-based path.

Length conversion follows the pinned implementation for supported values:
number/string numeric conversion, truncation toward zero, nonnumeric/nil/
boolean/table/cdata results as zero and finite negative lengths as empty arrays.
Nonfinite results or a truncated result outside signed32 are rejected with
`Cannot serialise table: external array length must be finite and fit a signed 32-bit integer`.
Native's C float-to-int conversion outside that domain is not portable; the
probe records actual platform observations, not a compatibility promise.
There is no arbitrary lower cap for supported positive signed32 lengths.

The ordinary iterative encoder invokes the method once per visited occurrence;
keep_origin checks recognize virtual semantics without invoking the method again
or reusing stale original containers. A reader captures external values at
construction, and neither length nor output repeats callbacks. Nested arrays,
normal/safe/new codecs, indentation and unsupported-value skipping share the
same classification. Native deterministic non-callable errors and callback
errors are preserved; normal/safe encode keeps non-string error objects, while
reader follows its existing string error/nil return convention.

Snapshot capture now pins each encountered source node before a later callback
can close or collect its original public holder. Reader/fork acquire final
ownership before releasing temporary pins; assignment/insertion associate pins
with the initiating holder's existing cancellation scope. Failed/cancelled work
releases its own leases without implicitly closing caller-owned public proxies.
No new lease subsystem, Rust/C ABI change, runtime cjson fallback, recursive
encoder or whole-source materialization was introduced.

## Verification environment and gates

Pinned Linux ARM64 image `lua-qjson-dev:task3-repro`,
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`,
OpenResty 1.29.2.4, LuaJIT 2.1 and Rust 1.90. Native macOS execution,
concurrent load and latency measurements were not performed.

| Gate | Result |
| --- | --- |
| Rust default / scalar / panic | 444 / 444 / 445 passed |
| Clippy | clean |
| Lua baseline | 607 passed |
| Final F06 cases / affected reader-resource suite | 107 / 179 passed |
| Final full Lua after review fix | 714 passed; initial-version boundary below |
| Initial-version focused bounded metadata suite | 10 passed on unchanged source |
| Lua lint | zero warnings/errors, 85 files |
| HTTP acceptance | 60 passed |
| Python compatibility harness controls | 11 passed |
| Eager/preload resource acceptance | 18 cells passed |
| Standard RSS comparison | 33/33 passed; historical limits retained below |
| Installed-only LuaRocks smoke | passed; cjson/source-tree fallbacks denied; installed native mapping verified |

The complete focused RED preceded runtime edits: 1 pass, 78 failures and one
expected behavioral error (raw function hash value wrongly visited instead of
being ignored by virtual-array classification). TEST23 encode and reader both
emitted `{}`. After classifier changes, separate RED artifacts reproduced lost
source ownership. An overlay of pre-fix snapshot modules also reproduced actual
unreachable-holder GC failures in all eight source/operation combinations.
The GREEN tests retain these regressions rather than relying on public API
presence alone. Initial independent review then found one cleanup defect:
reader error formatting could throw before temporary lease release. Round-1
RED added twelve file/feed construction/length/output cases with throwing or
invalid `__tostring` (95 passes, twelve failures). A shared failure helper now
drops references/leases before protected formatting and uses
`leanjson.reader: error message unavailable` when formatting cannot produce a
string. Normal/safe encode retains original error objects. The affected suite
passes 179 cases, including all 107 F06 cases, and the final full suite passes
714. The parent's independent replay of the review probe verifies zero leases
and closed descriptors before GC; both pre-fix and fixed observations remain
archived. No exception is silently swallowed into successful output.

Coverage includes marker priority, protected/raw/callable/non-callable metadata,
length coercion and unsafe boundaries, sparse/hash/hole/unsupported values,
origin bypass, nested/cross-codec own proxies, callback errors, cycles/depth,
nine loading/source cells, one-time reader snapshots, exact output length,
1/7-byte output chunks and file/feed GC/explicit-close/error/yield/cancellation.
Explicit no-GC descriptor/lease checks release the snapshot's ownership while
preserving caller ownership of original public handles.

The parent independently compared 168 pinned native output and callback-trace
combinations, with zero mismatches. Before the fix the same probe observed 156
mismatches; all raw outputs and scripts are retained. No upstream definitions,
expected values or compatibility adapters were changed.

Independent spec/quality re-review marked P2 addressed; final integration review
passed with no open findings. All 51 runtime/header files match final matrix
provenance. The three installed Lua modules match current source, and native
build/install/matrix libraries share hash
`8bf0d9f2eedf09c39e8f1aa023c58851ae486ef0172dbdfd442096c01ec38c0b`.
The parent also probed abandoned suspended reader/fork construction: file
handles close after coroutine GC through existing idempotent native lease
finalizers; no new fallback ownership mechanism was needed.

## Full upstream inventory

Each lazy/eager/preload × memory/file/feed cell retains all 164 original records.
Native baseline: 160 passes, three setup successes, one Lua5.3-only environment
exclusion, with prepared and hashed `cs_CZ` locale.

| Mode | Per-source passes | Differences | Unsupported/dependent | Setup | Environment |
| --- | ---: | ---: | ---: | ---: | ---: |
| lazy / preload | 152 | 3 | 5 | 3 | 1 |
| eager | 155 | 0 | 5 | 3 | 1 |

TEST23 passes in all nine cells. Stable-ID comparison with the preceding
F13/F14 archive finds one new pass per cell, no omitted records and no regression
among previous passes. Remaining behavioral differences are F05 lazy array
markers (TEST12/13/14); F15/F16 and dependencies remain unsupported. Strict
matrix therefore exits 1 with `compatible=false`; this is not a claim of full
lua-cjson equivalence. Supplemental selective replay remains 62/80 passes per
source with eighteen known differences because that existing worker does not
restore captured settings/safe dispatch; it remains separate evidence.

## Memory observations, including failed first full run

The initial F06 version's first full Lua run had 700 passes and one failure in
`bounded_metadata_spec.lua:104`, discarded-child-view retained-heap assertion:
513.1279296875 KiB after pass 1 against a strict <512 KiB threshold. The full
unchanged-source recheck had 701 passes; the same focused file had ten passes.
The subsequent error-cleanup fix passes all 714 tests on its first full run.
All runs are retained. No threshold was changed and no memory-specific runtime
fix was made for this observation; neither later passing run demonstrates that
this intermittent heap threshold is fixed or that its cause has been established.

The independent standard RSS harness uses 11 scenarios × three input sources,
approximately 1 MiB inputs, metadata prefixes 3, a 1 MiB index budget and fresh
workers. Both the initial and final error-cleanup versions pass 33/33 pairs in their
separate source-matched runs. In the final run, `wide-scalars/memory` is
16248 KiB for LeanJSON vs 16280 KiB for cjson (ratio
0.998034). Previous F07/F10/F13-F14 runs exceeded that boundary. These isolated
passing runs do not establish a stable memory improvement or universal RSS
upper bound. The full-suite Lua heap threshold and this RSS comparison measure
different things; neither is silently substituted for the other.

## Evidence

[The sealed archive](f06-external-arrays-logs.tar.gz) contains reproducible native
probes, build commands, RED/GREEN and failed/recheck logs, complete upstream
inventory/records/provenance, stable-ID audit, controls, loading/RSS receipts,
installed-only script/log, implementation and independent review reports and
source hashes. Installed rocktree and copied native object files are excluded.
Only explicit task paths are committed to local main; previous local-main
commits, other worktrees and ignored sibling plan directories are preserved.
