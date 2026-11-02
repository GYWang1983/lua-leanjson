# Decode Loading Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Track completed steps below.

**Goal:** Add eager plain-value decoding and scan-time explicit path preloading.
**Architecture:** Share the strict source scanner and source lifetimes; use selected
scan state and immutable cached values outside automatic metadata budgets. Eager
mode builds independent plain values, and preloading preserves raw source spans.
**Tech Stack:** Rust 1.90, LuaJIT/OpenResty 1.29.2.4, LuaRocks, Docker.
**Spec:** docs/design/2026-11-02-decode-loading-modes.md

## Global Constraints

- `lazyload=true` by default; `false` means complete ordinary Lua values.
- `preload_paths` follows the exact subset/combination semantics in the spec.
- Explicit preloading ignores `index_depth`, `index_array_limit`, and
  `index_budget_bytes`, even when all are zero. Count selected storage separately.
- Preserve full validation, final decoded-key wins, raw untouched output, linked
  child/fork/snapshot behavior, and cancellation/resource ownership in every source.
- Preserve v1/v2 published layouts and legacy `parse`; additive ABI is allowed.
- No new dependency or cjson requirement, no hidden full-DOM selective fallback,
  no per-path full rescans, and no unbounded metadata for unselected fields.
- Explicit path manifests for Git commits. No push/merge/publication in this task.

## Review Focus

- Later duplicated ancestors must invalidate all selected descendants of their
  earlier value, including when the later value has no selected descendant.
- Wildcard and explicit paths overlap without repeated payloads; null/false and
  escaped literal member names are distinct from absence and wildcard syntax.
- Preloaded original number tokens retain exact serialization after reads and
  unrelated edits; loaded child writes propagate only through current live links.
- A zero automatic cache budget cannot discard explicit preloads or bypass full
  validation of unselected data; failure/cancel cleans all partially built state.
- Eager finish/get must not alias caller mutations or keep hidden file leases in
  ordinary results; no optional cjson dependency becomes mandatory.

### Task 1: Coupled runtime, API and regression implementation (Sol 6.1 max)

**Files:** `src/source.rs`, focused modules under `src/source/`, `src/source_ffi.rs`
and `src/source_ffi/`, `include/leanjson.h`, `lua/leanjson/` shared options/backend/
source/proxy/node/table modules and focused selector/builder modules as needed,
`lua/leanjson.lua`, rockspec module install manifest, Rust source/ABI tests,
`tests/lua/decode_loading_spec.lua`, relevant source lifecycle/options tests,
`tests/openresty/acceptance.lua` and its fixtures, `docs/source-proxy-api.md`,
`docs/file-source-api.md`. Exclude supervisor README, spec/plan and final report.

**Interfaces:** Implement the two source options from the spec for all high-level
entrypoints. Expose truthful `source_stats` selected payload/metadata counts with
documented units; these remain separate from automatic `index_bytes`. Any new
native interfaces must have panic boundaries, header/cdef/export parity, loader
checks and existing-layout assertions. Shared cached nodes must preserve source
identity and remain immutable beneath branch overlays.

- [x] Write focused red tests for ordinary eager values and selective cache loads
  at `a.b.c.d.e`/far array positions with depth/prefix/budget all zero; record exact
  commands and expected missing behavior before implementation.
- [x] Add validated immutable selector compilation, native scan integration and
  eager/selected builders. Tests exercise `$`, escaped quoted keys, indexes,
  wildcards, empty/missing/overlapping paths, invalid syntax, and optional cjson
  absence. Default mode retains its original behavior.
- [x] Integrate immutable preloaded state into lookup/scalar/iteration/reader and
  sparse mutation paths. Test later duplicate ancestor replacement/no-match,
  numbers above Lua exact range, byte-preserved untouched output, fork isolation,
  linked children and normalized/lexical duplicate behavior.
- [x] Integrate all adapters and deterministic lifetime/error handling. Test one-
  byte feeds, file I/O failure, callback close/abort during builds, repeated finish/
  get after caller edits, malformed ignored subtrees, no leaked eager descriptors,
  and no retained unselected giant scalar/metadata tree.
- [x] Record focused read-count/storage/work regressions, then run one canonical
  `make openresty-verify` in the pinned dev image with the shared target/registry
  volumes. Run locked offline fuzz-target compilation and isolated installed-tree
  smoke if ABI/module changes require them. Coordinate heavy tests with supervisor.
- [x] Self-review, explicit-path commit, and report commands/output/remaining
  limitations to the task report. No subagents or remote Git actions.

### Task 2: Independent acceptance and user documentation (supervisor)

**Files:** README, focused probes/scripts under `tests/openresty` or `scripts`,
`docs/verification/decode-loading-modes.md` and raw evidence, this plan/spec.
**Interfaces:** Task 1 options and documented diagnostics; no private test-only
shortcuts for measured public behavior.

- [x] Independently verify selected reads perform no source I/O with every index
  disabled; unselected content remains lazy, readable and fully encoded. Verify
  eager results work through ordinary Lua operations and release source ownership.
- [x] Measure matched eager cjson/LeanJSON wide small-object cases and selective
  large-prompt/message cases, with external typed output oracles and separate CPU/
  RSS reporting. Preserve prior evidence and avoid concurrent builds/measurements.
- [x] Update README examples and report exact revisions, scopes, selected-memory
  accounting, path limitations and performance tradeoffs. Do not claim a complete
  JSONPath/Schema implementation or universal cjson performance equivalence.
- [x] Complete independent task/whole-change review and meaningful final checks;
  preserve the local branch/worktree and original raw evidence.
