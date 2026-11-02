# Bounded Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver the seven approved memory optimizations with configurable initial depth/array prefix defaulting to 3 and eliminate small-object memory blowups.
**Architecture:** Full validation with bounded retained source indexes; lazy span access; sparse COW patches; streaming normalized output. Keep legacy C ABI and ownership semantics intact.
**Tech Stack:** Rust 1.90, LuaJIT/OpenResty 1.29.2.4, LuaRocks, Docker.
**Spec:** docs/design/2026-11-02-bounded-metadata.md

## Global Constraints

- `index_depth = 3`, root depth 0; `index_array_limit = 3` per array; both accept nonnegative integers, zero disables optional pre-indexing.
- `index_budget_bytes = 1048576` default per source, lazy allocation, covers rebuildable initial and later metadata; zero means uncached correctness, never missing data.
- Full eager syntax/value/depth validation remains mandatory before final values/output; metadata depth is independent of `max_depth`.
- Last decoded key wins; normalized output removes earlier duplicates including escaped-equivalent keys; unknown is not duplicate-free.
- Apply the sparse runtime to memory/file/feed/OpenResty paths. Preserve old contiguous parse and v1 ABI layouts with additive APIs if needed.
- Preserve fork isolation, linked live-child semantics, stable snapshot readers, deterministic cleanup, cancellation across yields, exact lengths and bounded output.
- No algorithm fallback to a hidden full DOM for the required small/wide cases; no unbounded Lua per-member caches during lookup/count/output.
- No dependency changes, Kong integration, public release or GitHub operations. Explicit stage manifests; preserve unrelated worktrees and historical benchmark data.

## Review Focus

- Late duplicate keys after a lazy frontier or array prefix, escaped-equivalent keys and overwritten malformed subtrees still validate and resolve correctly.
- Budget churn with live child handles, forks and suspended readers cannot stale-reference reclaimed cache slots or discard patches.
- Very wide shallow objects must avoid both Lua-table amplification and quadratic per-member duplicate search.
- Count/normalization/output must not reconstruct the entire tree, and cache accounting must include capacity/auxiliary state rather than just nominal nodes.
- Adversarial long keys, deep arrays, I/O failure and close/abort during lazy source reads retain complete cleanup and bounded temporary buffers.

### Task 1: Bounded source, proxy and reader runtime (coding subagent)

**Files:** `src/source.rs`, `src/source/`, additive sparse-source modules if needed, `src/source_ffi.rs`, `src/lib.rs`, `include/leanjson.h`, `lua/leanjson/` (all runtime adapters), `lua/leanjson.lua` if required, focused Rust/Lua/source-stress tests, module manifest in rockspec and ABI loader tests. Exclude supervisor-owned README, design/plan, benchmark scripts/handler/driver and final report.
**Interfaces:** Existing public Lua operations keep semantics; new options specified in Global Constraints flow through every high-level source API. Any additive ABI must be described in header and Lua cdef with panic boundaries. Internal targeted lookup/streamed iteration may change coherently across this task's files. Add honest stats needed to verify cache bounds (private test helper or documented diagnostic API; no misleading total-memory claims).

- [x] Write focused regressions demonstrating option propagation/defaults and the existing eager-member regression before changing runtime. Record the expected failures.
- [x] Implement validation/index separation, bounded retained state and stable span-based identities. Validate 0/1/3 settings, default frontier at a.b.c, far-array access and late duplicates across chunk boundaries.
- [x] Implement targeted proxy access and sparse COW mutation independent of index-cache lifetime. Tests retain children/readers/forks across budget eviction and structural array updates; confirm no lost edits or stale references.
- [x] Implement incremental normalized count/output and duplicate handling without full Lua member expansion. Tests cover untouched nested duplicates, decoded-key equality, null/false, whole-subtree replacements, wide keys, output byte/length correctness and tiny windows/budgets.
- [x] Reduce transient allocations/whole-container metadata duplication and expose bounded diagnostics. Work with supervisor's independent paired memory gate; required short/wide cases must not regress above cjson.
- [x] Run focused checks after each change, then one complete `make openresty-verify` gate in pinned Docker; locked fuzz target compilation and isolated installed-package smoke when ABI/module paths change. Coordinate exclusive build/benchmark timing with supervisor.
- [x] Self-review, run diff check, commit only owned paths and write Task 1 report with commands/results, limitations, ABI/options details and source SHA. Do not spawn other agents, push, or alter supervisor files.

### Task 2: Independent memory acceptance and documentation (supervisor)

**Files:** `tests/openresty/benchmark.lua`, `tests/openresty/benchmark-handler.lua`, new bounded-memory probe/helpers under tests/openresty, `scripts/benchmark-openresty.sh` or new memory-gate script, Makefile gate target, README, docs/api.md if present (coordinate ownership), new verification report/raw JSONL, this plan/spec.
**Interfaces:** Task 1 public options and unchanged proxy APIs. Same fixtures and operations for leanjson/cjson. Use real native processes, no mock allocator; use corpus/semantic oracle separate from timed output.

- [x] Add shallow 32768-key small-object and wide-scalar fixtures plus phase and cache-stress cases; preserve existing historical raw records. Capture baseline failure in the existing runtime.
- [x] Run paired native process memory checks on the integrated implementation, recording peak RSS, sampled Lua heap, elapsed/CPU and input/output semantics. Repeat only for code changes/noise affecting conclusions; no concurrent cargo builds during measurements.
- [x] If any required memory row exceeds native cjson, pass concrete measurements to Task 1 for correction; do not silently relax criteria.
- [x] Document defaults, semantics, budgets/caller-held-memory boundaries, CPU/I/O tradeoffs and fresh measured results; update README historical caveat with links to new results.
- [x] Independent whole-change review after functional/memory gates; resolve findings, verify exact committed runtime image and final diff. Leave local feature branch/worktree for user; no new push/publication requested.
