# F01/F02/F05 Configuration and Array Compatibility

> Use superpowers:executing-plans and test-driven-development; finish with one independent review.

**Goal:** Implement precision 1–16, validated sparse settings, and array/empty-table markers and configuration on isolated normal/safe codecs.

**Spec:** `docs/design/cjson-compatibility-fixes.md` F01/F02/F05; F03/F04 preserve all source/loading modes.

**Architecture:** Share pure setting validation in `leanjson.settings`; retain per-codec settings. Carry decode marker policy in normalized source options so scanning, delayed views and eager rebuilds use a stable policy. Keep source-backed values lazy and use a private marked-array metatable with the public marker exposed through `__metatable`.

## Constraints and decisions

- Precision setters return the new value; accept native numeric-string/coercion/truncation semantics within the documented range 1–16. Formatting applies to newly encoded numbers, including integers and negative zero; raw unchanged tokens remain unchanged.
- Sparse convert accepts booleans or exactly `on`/`off`; ratio/safe use truncated integers 0–2147483647. Invalid calls are atomic, as F02 explicitly requires, even though the C implementation partially updates earlier fields. Reject nonfinite/out-of-range input rather than reproducing native integer-wrap/NaN accidents.
- Add shared `array_mt` and `empty_array` alongside distinct `empty_array_mt`. Explicit array markers use native table length/raw values and ignore hash entries; empty_array_mt still validates sparse policy before its fallback.
- Add per-codec `encode_empty_table_as_object` (default true) and `decode_array_with_array_mt` (default false), with boolean/on/off getters/setters and arity checks. Safe instances use the same settings without hiding setter errors.
- Eager decode becomes native-compatible: unmarked empty arrays encode as ordinary empty tables; marking enables persistent explicit arrays. Update old tests that relied on implicit eager shape preservation to request marking explicitly.
- Lazy/preload views retain JSON container identity and raw source spans. Marking is observable via getmetatable without replacing proxy mechanics. Existing lazy array mutation restrictions (F18) remain; do not materialize upstream results to make its mutation cases pass. Explicit materialize retains its existing shape-preserving helper contract.
- Snapshot decode settings when decode/file/new_decoder starts; repeated finish/get and late children keep that snapshot. Encoder/reader settings retain F03 timing semantics.
- Work on `fix/cjson-config-array-markers`, preserve main, no commit/push requested.

## Review focus

Check setting failure atomicity and native coercion boundaries; explicit marker precedence over origin/type hints; marked proxy metatable identity and resource ownership; eager rebuild/get/finish snapshot semantics across callback yields; reader formatting/sparse snapshots and cross-codec settings; report genuine remaining lazy differences instead of adapting them away.

### Task 1: Precision and sparse settings

Files: new `lua/leanjson/settings.lua`; `table.lua`, rockspec; settings/precision/instance tests.

Interfaces: pure integer/boolean/arity validators; per-codec precision/sparse closures retain ownership, return current/new settings.

1. Write public API tests for precision 1/3/14/15/16, numeric strings/fractions, invalid arguments/arity, negative zero/2^53/integer formatting, sparse boolean/on/off/coercion/bounds and atomic failure. Update legacy precision expectations. Run focused Busted: expected RED on current range/return/coercion behavior.
2. Implement validators and settings; run focused tests: expected GREEN. Keep helpers restoring settings by getter rather than obsolete setter return.

### Task 2: Array markers and loading policy

Files: `table.lua`, public wrapper, `proxy.lua`, `loading.lua`, `options.lua`, memory/file sources, new array tests, existing loading tests and documentation.

Interfaces: Task 1 validators support boolean settings. Internal normalized `decode_array_with_array_mt` is a per-input snapshot; proxy's private marked metatable exposes the shared public marker.

1. Write marker/empty table/config isolation tests across memory/file/feed × lazy/eager/preload, safe/normal instances, materialization/origin and reader output. Run RED on missing markers/options.
2. Implement marker policy and source propagation without global swaps. Run GREEN; update old roundtrip tests to explicitly request eager marking where preservation is intended, retaining dedicated unmarked-default checks.
3. Run full project, lint, native OpenResty and Python harness gates, pinned upstream nine-cell matrix, installation smoke. Compare original passes and classify changes honestly. Update README, checklist/report; obtain independent read-only review and fix important issues with failing regressions.
4. Archive verifiable evidence; leave changes uncommitted.
