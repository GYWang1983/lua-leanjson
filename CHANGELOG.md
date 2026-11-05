# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- Add explicit `ref(value[, path])` snapshot handles for source-backed mapping, independent leases and bounded serialization without decoding long scalar strings.
- Add optional-path `len`, `exists` and `is_empty` queries over memory/file/feed proxies and eager values, preserving Lua truthiness and counting lazy string bytes without full materialization.
- Add reusable `compile_schema` plans and scan-time Schema assertions for memory/file/incremental input, without materializing type/length-only string bodies.
- Add the default-on `structural_index` switch, budgeted string-boundary metadata and final positive/negative demand lookup caching shared across forks, with additive native stats.

### Changed

- Receive unread fixed-length HTTP/1.1 bodies through `ngx.req.socket()` in `read_body`, with safe completed-body fallbacks. File and incremental input retain source chunks in memory by default; `file_in_memory=false` preserves fd/spool storage.
- Bound legacy scanners' initial structural-offset reservation and reuse synchronous file-read buffers up to 64 KiB to reduce temporary allocation.

## [0.1.0] - 2026-11-03

First release of the lua-leanjson fork. Release notes:
[English](docs/releases/0.1.0.en.md) · [简体中文](docs/releases/0.1.0.zh-CN.md).

### Changed

- Rename the fork, Lua module, Rust crate, native library, C ABI, header and environment variables to `lua-leanjson` / `leanjson` / `LEANJSON_*`; existing imports and native consumers must migrate and rebuild. No `qjson` compatibility module is installed.
- Publish a versioned source rock and Linux x86_64/aarch64 binary rocks targeting glibc 2.35; retain the SCM rockspec for main development.

### Added

- Add private mutable proxies with copy-on-write snapshots, `fork`, explicit dense-array operations and bounded `reader` output without implicit full-body encoding.
- Add `decode_file`, an owned incremental spool decoder, shared eager decode policy and a versioned window-fed Source ABI while preserving the original parser ABI.
- Add deterministic source ownership across children/forks/readers, cancellation cleanup and nonterminal stale-mutation rejection across yielding callbacks.
- Add a native OpenResty memory/file and single-owner incremental input adapter, fixed-length bounded HTTP output, and explicit transfer error/cleanup reporting.
- Add a pinned native OpenResty/Rust example image, real worker HTTP acceptance tests, reproducible library gates, and cjson/leanjson process-memory and latency benchmarks.
- Add a standalone GitHub Actions supply-chain audit job using `cargo-audit`.
- Add this changelog as the canonical human-readable release history.
- Use versioned `CHANGELOG.md` entries as GitHub Release notes and document the changelog update policy for public behavior changes.
- Add deterministic exhaustive Unicode escape, surrogate, raw byte, and Lua string encode roundtrip coverage.
- Run Lua CI integration tests under both upstream LuaJIT and OpenResty LuaJIT.
- Add optional Miri, ASan, and LuaJIT valgrind CI coverage for the FFI boundary.

## [upstream-0.1.0] - 2026-05-19

### Added

- Initial Rust JSON decoder crate exposed to LuaJIT through FFI, including parse/free APIs, root-path getters, cursor APIs, type checks, length checks, and a panic barrier for exported C symbols.
- Two-phase parse/access architecture: phase 1 records structural offsets only, while phase 2 lazily resolves requested paths and decodes only the values callers access.
- Scalar, AVX2/PCLMUL, and ARM64 NEON/PMULL structural scanners with runtime dispatch and scanner cross-check coverage.
- Lazy string and number decoding, including escape handling, surrogate-pair support, integer overflow checks, and float parsing.
- LuaJIT wrapper module with parse, cursor, and accessor APIs, plus Lua busted integration tests.
- `qjson.decode` lazy table API with object/array proxies, pair/ipair/length helpers, mutation materialization, and cjson-compatible sentinel handling.
- `qjson.encode` support for lazy proxies, mixed lazy/materialized trees, and plain Lua tables, including an original-subtree fast path for unmodified data.
- RFC 8259 validation coverage, cjson/simdjson fixture coverage, and release CI for Rust, Lua, and LuaRocks package checks.
- Benchmark harness comparing `qjson` with `lua-cjson` and `lua-resty-simdjson`, with benchmark summaries in the README and documentation.

[Unreleased]: https://github.com/GYWang1983/lua-leanjson/compare/v0.1.0...main
[0.1.0]: https://github.com/GYWang1983/lua-leanjson/releases/tag/v0.1.0
[upstream-0.1.0]: https://github.com/api7/lua-qjson/releases/tag/v0.1.0
