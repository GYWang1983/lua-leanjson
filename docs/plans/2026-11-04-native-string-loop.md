# Native string loop implementation plan

> **For agentic workers:** Use superpowers:executing-plans and test-driven-development. The implementation is scoped to the approved native string loop.

**Goal:** Remove per-byte token dispatch for escaped strings without full decoded buffers.

**Spec:** docs/design/native-string-loop.md

**Architecture:** Rust chunk string kernel shared by initial scanning and scalar reads; existing byte state handles incomplete boundaries, and complete escapes can be reused by diagnostics. Preserve the C long-plain-run helper and legacy scanner.

## Constraints and review focus

- Public layouts/exports and Lua string assembly remain unchanged.
- Complete escapes validate before commit; invalid/error byte positions and diagnostic text match legacy.
- UTF-8/Unicode chunks and small output windows retain at most four pending bytes.
- No unselected string materialization, no per-character full-Token moves, bounded selected/Schema batches.
- Propagate scanner settings through walkers/readers; keep legacy as an actual baseline.

### Task 1: Bounded chunk kernel

Files: src/source/validate.rs; new src/source/validate/scan.rs and string_loop_tests.rs.

- [x] Write split/output-limit/error differential tests against byte feed; observe RED.
- [x] Implement complete short/Unicode escape parsing, raw/strict UTF-8, quote handling and bounded emissions.
- [x] Pass native unit/property checks.

### Task 2: Integrate native consumers

Files: src/source.rs, src/source/window.rs, src/source/diagnostic.rs, src/source_ffi/sparse.rs; source native/Lua tests.

- [x] Add end-to-end escaped key/value, scalar reader and Schema/preload regression coverage.
- [x] Hold String Token once per chunk; batch only needed decoded data.
- [x] Reuse valid escape scanning in diagnostics and chunk decoding in readers; propagate scanner policy.
- [x] Pass focused/native/Lua/compatibility gates and independent review.

### Task 3: Verify and record results

Files: benchmark evidence and docs/verification/cjson-memory-scanner.md and cjson-scanner-results.json, relevant API documentation.

- [x] Run default/scalar/panic, full Lua, upstream matrix, HTTP, reader bounds and memory checks.
- [x] Compare original prior-kernel artifact, new kernel, legacy and CJSON on identical escaped/plain/context inputs; include lazy/eager/preload and Schema.
- [x] Record exact fingerprints, distributions, RSS failures and limits; leave a scoped feature commit without merging or pushing.
