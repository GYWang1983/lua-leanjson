# LeanJSON Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver the same verified component as lua-leanjson with a clear fork README and renamed personal GitHub repository.
**Architecture:** Rename the entire runtime/build/package namespace coherently without algorithm changes. Preserve upstream provenance and historical measurements. One coding subagent owns the cross-file rename; the supervisor owns README, integration and GitHub changes.
**Tech Stack:** Rust 1.90, LuaJIT/OpenResty, LuaRocks, Docker, GitHub Actions.
**Spec:** docs/design/2026-11-01-leanjson-rename.md

## Global Constraints

- Package/repository `lua-leanjson`; Lua module/Rust crate/library `leanjson`; C `leanjson_*`/`LEANJSON_*`; adapter `leanjson.openresty`; environment `LEANJSON_*`.
- No JSON algorithm/behavior changes or qjson compatibility alias; keep upstream URL and Apache-2.0 provenance.
- Do not rewrite historical raw benchmark records, third-party/vendor code, git metadata or unrelated worktrees.
- Development rockspec `rockspec/lua-leanjson-scm-1.rockspec`; source URL personal renamed fork, existing `feat/openresty-json-source` branch; no publication/tag creation.
- Preserve source resource ownership and full-validation/synchronous-I/O limitations; no universal speed/memory claim.

## Review Focus

- An installed package must load with checkout paths and the old qjson library unavailable.
- Rust exports, C header and Lua cdef/required-symbol checks must agree under the new namespace.
- Docker/archive builds, test environment variables, package install and CI artifact paths must use the new name.
- Attribution and old benchmark records must remain honest while current instructions use the new API.
- Repository landing page and install/source URLs must resolve to the delivered renamed project.

### Task 1: Coherent runtime/package rename (coding subagent)

**Files:** Rust source/tests/benches/fuzz manifests and lockfiles; `include/qjson.h`; `lua/qjson.lua`, `lua/qjson/`; rockspec; Makefile; scripts; workflows; examples; tests; current API/contributor docs/AGENTS. Exclude README.md and supervisor's new spec/plan. Preserve historical verification JSONL and measured benchmark attribution.
**Interfaces:** All previous APIs keep their semantics under `leanjson`; compiled output `libleanjson.so`/`.dylib`, installed `leanjson.so`. No old module fallback.

- [x] Verify the new `require('leanjson')` fails on clean baseline, then rename owned tracked paths and identifiers coherently.
- [x] Update package metadata, development rockspec, current docs and all executable scripts/CI/examples without changing third-party/upstream provenance.
- [x] Run canonical full OpenResty verification once, compile renamed fuzz targets with locked dependencies, and perform isolated installed-package smoke including `leanjson.openresty`, file/feed/reader/close and absence of qjson modules from that tree.
- [x] Inspect remaining qjson references and explain intentional history/provenance only; run git diff --check and commit explicit owned paths. Report commands/results, commit SHA and remaining concerns.

### Task 2: README, final verification and repository delivery (supervisor)

**Files:** README.md plus this plan/spec; GitHub repository metadata and local origin.
**Interfaces:** Examples consume Task 1's final public names/rockspec; source URL becomes `https://github.com/GYWang1983/lua-leanjson`.

- [x] Rewrite README with origin, additions, memory explanation, supported runtime, source install, cleanup-safe examples and measured limits; verify examples/package/file links.
- [x] Review/integrate Task 1, perform one independent review of the complete rename/README diff; resolve concrete findings before publication.
- [x] Build and smoke-test exact committed runtime image; use the already-run canonical gate as code evidence without duplicating unchanged broad suites.
Publication handoff: rename GitHub repo, update origin/description/default branch, push the current feature branch, and verify URLs/remote SHA plus final hosted CI. The delivery message records the resulting repository, commit and CI receipt. No LuaRocks upload or release tag.
