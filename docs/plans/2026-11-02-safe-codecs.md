# F04 Safe Codec Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for this single integrated task.

**Goal:** Implement `leanjson.safe` with independent safe codecs and verified error/return contracts.

**Architecture:** Build each safe API around a fresh F03 codec. Validate call arity and loading options before protecting conversion; protect only conversion and source construction, retaining existing incremental method contracts and resource ownership. Do not wrap every helper or replace proxy metatables.

**Tech Stack:** LuaJIT/OpenResty, existing Rust source backend, pinned OpenResty lua-cjson oracle.

**Spec:** `docs/design/cjson-compatibility-fixes.md`, F04. User requested continuing the numbered fixes on the existing F03 worktree.

## Global constraints

- `safe.encode(value)` takes exactly one argument; explicit nil encodes null. `decode(raw[, opts])` and `decode_file(path[, opts])` take one or two, `new_decoder([opts])` zero or one. Invalid arity and invalid options throw before protection.
- Conversion failures return exactly `nil, err`; successful conversions return one value, including false and the shared null sentinel. Decode type failures are protected; numeric input receives the same string coercion as native cjson. `new()` ignores its arguments and returns another fresh safe codec.
- Default safe, default normal and all created instances have independent configurations. Configuration getters/setters remain directly callable and their errors throw. F01/F02/F05/F17 remain separate fixes.
- Safe file decoding/new decoder creation protect I/O and construction failures. Existing feed/finish/get/reader methods and lazy property access retain their current contracts; late errors are not hidden. Explicit close/release behavior must remain intact.
- Keep lazy/eager/preload × memory/file/feed. Preserve F03 uncommitted changes. Do not commit, push, merge, or publish.
- A Lua wrapper cannot distinguish `LUA_ERRMEM` from every runtime error as the native C wrapper can; document this VM OOM boundary without string-based error guessing or claiming full native parity.

## Approaches

Use a small safe adapter over the real isolated codec: this preserves loading modes and centralized resource ownership. A blanket wrapper around all functions would incorrectly hide configuration/argument failures and change iterator/decoder contracts. Reimplementing native cjson or disabling lazy loading is outside the approved direction.

## Review focus

- Explicit nil versus absent arguments, false/null success and trailing nil return counts.
- Independent safe factories, numeric coercion, shared markers and invalid configuration stability.
- Options rejected before creating file descriptors; failed file/decoder construction releases resources without GC.
- Deferred failures during lazy reads, reader output and callback reentrancy must keep existing lifecycle contracts.
- Matrix dispatch must use real safe APIs and preserve error pairs from feed/finish, including safe.new instances; negative controls must not depend on safe being missing.

### Task 1: implement and validate safe codecs

**Files:** new `lua/leanjson/safe.lua`, `tests/lua/safe_spec.lua`; rockspec install list; upstream worker/control tests; README, F04 checklist and verification report.

**Interfaces:** Safe API table shares stateless helpers/constants from its private `leanjson.new()` codec and exposes its protected encode/decode/source functions plus a safe `new()` factory.

- [x] Add success/error arity, config isolation, invalid options, file/feed cleanup, and all nine loading/source tests. Run focused Busted; expected RED because `leanjson.safe` is absent.
- [x] Add the safe adapter and packaging entry; rerun focused tests; expected GREEN with no real cjson fallback.
- [x] Add real safe facade/source-dispatch controls, observe RED against the old unsupported adapter, update the harness and fault-injected missing-safe controls; expected GREEN.
- [x] Run `make test lua-lint openresty-test`, all Python harness tests, and the full pinned nine-cell matrix with prepared Czech locale. Verify packaging install includes safe.lua. Report actual remaining differences, not merely successful report generation.
- [x] Update API/checklist/report, obtain independent read-only review of the F04 delta, fix important findings with regressions. Archive evidence and retain code uncommitted.
