# CJSON memory scanner implementation plan

> **For agentic workers:** Use superpowers:executing-plans task-by-task; test-driven-development governs code changes.

**Goal:** Accelerate complete-memory decode while preserving LeanJSON's memory and compatibility contracts.

**Architecture:** CJSON-derived bounded C string scanner plus existing Rust syntax/span/event engine. Memory-only feeds defer compatibility diagnostics until error. The Lua wrapper keeps bounded feeds and exposes a legacy comparison option.

**Tech Stack:** C99, Rust 1.90, LuaJIT/OpenResty, cc build dependency.

**Spec:** docs/design/cjson-memory-scanner.md (approved conversational approach recorded here).

## Global constraints

- Preserve source v1/v2 layouts, error behavior, bounded metadata, Schema and preload semantics.
- No retained native input pointers, per-byte FFI calls or whole-document temporary strings.
- Preserve streaming/file-backed feed semantics while batching string scans after the successful memory prototype.
- Keep unrelated work, main and remote unchanged.

## Review focus

- Chunk boundaries inside escaped/UTF-8 strings must match legacy input.
- Invalid input must preserve native-compatible diagnostics, including numeric-prefix and encoding errors.
- Slash/DEL flags and duplicate-key replacement must survive edits/references/encoding.
- Eager/preload and Schema must consume bounded events, including with metadata disabled.
- Empty inputs, range errors and mixed feed modes must fail safely across the ABI.

### Task 1: Native lexical kernel and memory feed

**Files:** build.rs, Cargo.toml/Cargo.lock, src/source/cjson_scan.c, src/source/cjson.rs, src/source.rs, src/source/validate.rs, src/source/diagnostic.rs, src/source_ffi/sparse.rs, include/leanjson.h, tests/source_scanner.rs.

**Interfaces:** Add memory feed/finalize ABI functions accepting the complete borrowed input plus the feed range. Keep the old feed/finalize API unchanged. C scanning returns a bounded plain-string prefix plus escaping flags; Rust applies the batch to its existing token/events.

- [x] Write failing native tests for memory feed, chunked flags, malformed diagnostics and invalid ranges/mixing.
- [x] Observe the missing implementation fail, then implement the C kernel and Rust integration.
- [x] Pass native cross-path tests and lint.

### Task 2: Lua integration and compatibility

**Files:** lua/leanjson/lib.lua, lua/leanjson/source_memory.lua, lua/leanjson/options.lua, tests/lua/scanner_spec.lua, docs/source-proxy-api.md.

**Interfaces:** scanner = cjson | legacy; default cjson. Native construction events remain chunk-drained. A pre-feed v2 scanner selector enables the same C kernel and batched incremental diagnostics for file/feed/socket sources.

- [x] Write failing option/integration tests covering lazy, eager, preload, Schema, errors and encoding/reference mutation.
- [x] Run RED, wire the memory-only feed/finalize path, run GREEN.
- [x] Run full Rust/Lua and pinned upstream compatibility/corpus suites.

### Task 3: Controlled performance and memory evidence

**Files:** benches/memory_decode.lua, scripts/benchmark-memory-decode.py, scripts/verify-cjson-compat.py, docs/verification/cjson-memory-scanner.md and benchmark summary JSON.

**Interfaces:** Benchmark cjson, legacy and new paths on identical pre-read input; semantic assertions outside timed calls and native/Lua fingerprints in evidence.

- [x] Run the report payload and long-string/wide-object inputs in interleaved trials.
- [x] Run paired fresh-process memory checks and native/scalar/panic/lint checks.
- [x] Review the complete diff, record evidence and limitations, and leave the implementation reviewable on its feature branch.

## Execution notes

- Memory prototype measured ~25x lower decode CPU on the report payload and justified stage 2. The shared C string kernel now also batches file/feed/socket parsing and incremental diagnostics.
- Native constructors still default to legacy scanning. Lua's default scanner is cjson; its configure step selects batching before feeds. Explicit native selectors apply to both ordinary and memory feeds.
- Independent review found selector handling, argument-error diagnostic masking and missing required-symbol checks. All were corrected; the latter two have RED-to-GREEN regressions.
- The original compatibility image was absent. The harness now accepts explicit image/digest and isolated volume environment variables, retaining digest/architecture checks. Default settings remain unchanged; the provided restored image is identified by its actual digest.
- Strict RSS comparison is not universally green. Wide scalar objects fail on both the current base main and the new branch in this environment. Preserve every measured failure and the controlled comparison in the verification report; do not relax thresholds.
