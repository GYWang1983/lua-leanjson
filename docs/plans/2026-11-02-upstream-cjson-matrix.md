# Upstream lua-cjson matrix implementation plan

**Spec:** docs/design/2026-11-02-upstream-cjson-matrix.md
**Goal:** Execute every upstream functional case in all nine requested cells and
produce an independently checked, honest compatibility report.
**Base:** b928a20505165fc3c0f3399b68500cd02050b42f

## Global Constraints

- Fixed upstream commit `617164a0fe3bb647128178f9caefb304b8573bb6`; preserve vendored source.
- All functional cases from test.lua and agentzh.t, helpers, conditions and supplied
  JSON cycle fixtures must be inventoried; every matrix cell has the complete inventory.
- Matrix is lazy/eager/preload × memory/file/feed. Preload ignores all three zero
  index bounds; add sparse preloading coverage alongside root selection.
- No cjson fallback or product-semantic changes to make cases pass; no early
  materialization hiding proxy behavior. Exact and logical comparisons stay distinct.
- Unsupported/dependent/environment/baseline outcomes never count as target passes.
- Completeness and harness failures are fatal; strict compatibility mode fails on
  differences/unsupported. Report mode must clearly distinguish execution from parity.
- Do not add product dependencies, reformat unrelated code, push, merge or publish.
- Use explicit staging manifests, preserve other work, no concurrent heavy builds.

### Task 1: Full upstream adapter, runner, checks and execution (Sol 6.1 max)

**Own:** focused files under `tests/upstream-cjson/`, `scripts/verify-cjson-compat*`
and supporting focused test files, Makefile target and minimal CI entry if useful.
Do not edit root-owned README, design/plan or final verification report. Runtime
source and upstream vendor tree are outside this task's mutation scope.

Read the binding spec as well as this brief. Implement a maintainable runner that
executes unmodified upstream definitions where possible, isolates reference and
target processes, records all cases and prevents missing APIs from aborting the
entire inventory. Do not simply emulate the cjson configuration API in an adapter.
Native comparison baseline must be built from the pinned vendor source into a
temporary location, with UTF-8 generated fixtures and helper modules resolved there.
Use source hashes and runtime provenance, not the `_VERSION` string alone.

Provide full-root preload in the nine-cell upstream run and supplemental selective
decode replay with bounded chunks and zero automatic indexes. In output, separate
direct decode, encode-only, settings, helpers and any conditional no-op cases.
Retain typed and exact output/error details without unbounded repeated multi-megabyte
diagnostic values. Use digest/length plus concise samples when needed.

Unsupported API/module use, failed setup dependencies and conditional branches
require explicit records. Helpers are setup records, not successful assertions.
Never hide incompatibility by normalizing error messages or running cjson for the
target. Logical proxy traversal belongs only in the final observation/comparison.

Write focused runner negative controls before relying on it: omitted/duplicate case,
intentional differing return, missing API, setup failure and malformed input. Show
red/green evidence. Run baseline and every matrix cell; keep JSON/JSONL reports,
raw logs and command evidence in this plan's scratch directory for root to archive.
One full `make test` gate suffices after focused checks; no unrelated performance
benchmark/fuzz campaign needed for harness-only changes.

Environment: worktree `/Users/wanggy/Projects/lua-qjson/.worktrees/bounded-metadata`,
branch `test/upstream-cjson-matrix`; image `lua-qjson-dev:task3-repro`, immutable ID
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`,
target volume `leanjson-bounded-target:/workspace/target`, registry volume
`qjson-cargo-registry:/usr/local/cargo/registry`, bind worktree to `/workspace`.
Native runtime already built and verified at the base; coordinate any build with root.

- [ ] Inventory and negative-control tests; document adapter design choices.
- [ ] Implement baseline/target dispatch and all matrix cells without omissions.
- [ ] Run full matrix, focused controls and project gate; self-review and commit.
- [ ] Task review and covering fixes complete.

### Task 2: Independent audit, evidence and user documentation (supervisor)

**Own:** README compatibility notes, docs/verification/upstream-cjson-compatibility.md
and raw report archive, this spec/plan/ledger. Read-only audit of Task 1 runtime.

- [ ] Independently enumerate suite definitions and reconcile every cell/fixture/helper.
- [ ] Verify baseline source/native provenance and no cjson target delegation.
- [ ] Reproduce representative mismatch categories and audit selective source dispatch.
- [ ] Record complete per-cell totals, limitations and exact reproduction commands.
- [ ] Independent task/final review; preserve local branch and all evidence.
