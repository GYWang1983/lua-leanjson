# Upstream lua-cjson compatibility matrix

## Request and baseline

Adapt the complete functional upstream lua-cjson suite to execute against LeanJSON,
then validate lazy, eager (`lazyload=false`) and explicit-preload decoding across
memory, file and incremental input. Report actual compatibility rather than equating
our project tests with upstream coverage. The user explicitly requests subagent
implementation with supervisor review.

Use the existing `vendor/lua-cjson` OpenResty upstream at commit
`617164a0fe3bb647128178f9caefb304b8573bb6`. Record its source version, suite hashes,
native build settings and actual baseline library provenance. Use the project's
pinned Linux ARM64 Rust/OpenResty dev image. Baseline LeanJSON is `b928a20`.

## Approach and scope

Execute upstream test definitions through a thin test adapter rather than hand-copying
a selection into Busted. Preserve original inputs, expectations, helper state and
case order. Keep vendored upstream files unchanged; use temporary generated harness
files only where the original runner cannot report unsupported APIs safely.
Manual selected translations were rejected because they can silently omit cases.
Replacing LeanJSON behavior with cjson in the adapter was rejected because it would
measure the reference implementation instead of the target.

Inventory every functional case in `tests/test.lua`, `tests/agentzh.t`, helper/setup
steps, conditional cases and supplied JSON decode-cycle fixtures. Benchmark drivers
and build-packaging orchestration are not behavioral cases; list exclusions explicitly.
Run native cjson from the pinned source as the baseline before classifying target
results. A baseline failure is evidence to report, never a silent expected-value edit.

This task adds validation infrastructure, not a promise to implement every cjson API.
Runtime gaps are results to disclose; do not change product semantics merely to make
the compatibility report green. No merge, push, issue creation or publication in this task.

## Matrix and adapter contract

Run every functional case in each of nine cells: lazy/eager/preload crossed with
memory/file/feed. Encode-only and configuration cases still execute in every cell,
but report them separately from cases that actually exercise a decode source.
Preload uses real `preload_paths` with all three optional index limits zero; select
`$` for the full upstream value, and add a sparse-selection supplemental replay for
decode inputs so full-root preloading cannot stand in for selective behavior.
Preserve complete output and lazy access to unselected data in the supplemental run.
Feed input uses deterministic bounded chunks; include boundary-splitting regression
coverage. Ensure decoder, proxy and file owners are closed after each case.

Do not materialize before upstream Lua operations: doing so would conceal proxy
behavior differences. Logical result comparison may traverse proxies after execution,
with that adaptation disclosed separately from the unmodified exact upstream verdict.
Keep distinctions such as null/false/absence, array/object, errors versus successful
values, numerical edge cases, return arity, bytes, settings and source ownership.
Do not replace an error with the upstream expected message. Unsupported module/API
use must be recorded explicitly and cannot fall back to native cjson or fake success.
Missing setup/config APIs must not silently make dependent cases appear compatible.

## Results and acceptance

Emit machine-readable inventory and per-case records keyed by stable upstream IDs,
suite, source location and matrix cell. Include exact and semantic outcomes where
they differ, called APIs, actual decode path and enough diagnostic evidence to
reproduce mismatches. Separate pass, behavioral difference, unsupported,
environment-inapplicable, baseline failure and harness failure. No uncounted skips.
Completeness must be machine checked: missing, duplicate or unexpected cases fail.

Provide a reproducible Makefile entrypoint and a strict compatibility exit mode that
fails when applicable target cases differ or are unsupported. A report-generation
mode may succeed when the harness is healthy, but must never present differences as
compatibility success. Preserve raw reports and commands; publish totals for each
matrix cell and categories. Add focused negative controls demonstrating that the
harness detects missing cases, target differences and unsupported APIs rather than
just verifying its own formatting. Run the full matrix and meaningful project checks.

Root independently audits completeness, real target dispatch, baseline provenance,
classification and representative failures. Independent task and final reviews are
required. Final documentation states the actual result and all material limitations.
