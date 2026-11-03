# F08/F09/F11/F12 numbers and byte strings

Scope: implement the four numbered items in `docs/design/cjson-compatibility-fixes.md` against the pinned OpenResty lua-cjson. User confirmed native-compatible defaults. No commit/push requested for this task.

## Design and alternatives

Use the existing resumable source parser and bounded reader. A Lua preprocessor would copy input and miss late reads; full materialization would lose the component's memory benefit. Extend existing native policy and scalar state instead. The source v2 `mode` gains documented policy bits without changing struct layout; zero remains strict for existing C callers. Public decode defaults allow native nonstandard numbers and raw bytes; `decode_invalid_numbers(false)` and new `decode_validate_utf8(true)` enable strict policies. Legacy parse C ABI remains unchanged.

Per-codec setters retain independent state and validate before updating: `decode_invalid_numbers` default true, `decode_validate_utf8` default false, `encode_invalid_numbers` default false (also accepts true and `null`), `encode_escape_forward_slash` default true. Decode snapshots policy at source construction; readers snapshot encoding settings. Safe codecs share implementation and error contracts.

Raw source remains reusable when unaffected. Source flags mark strings/keys containing decoded slash or DEL and nonfinite numeric tokens, and propagate to ancestors. Such spans traverse bounded output: source strings decode and escape in chunks, nonfinite numbers use the active encoder policy. This prevents source reuse from bypassing F09/F12, while finite unchanged numeric spellings and unrelated original escapes retain the existing preservation contract. No lossy UTF-8 conversion; Unicode escape/surrogate validation remains mandatory even in byte mode.

## Task 1: Native source policy (F08/F11)

Files: `src/source.rs`, `src/source/validate.rs`, `src/source/window.rs`, `src/source/sparse.rs`, relevant `src/source_ffi*`, header; new Rust tests.

Interface: v2 mode bits 1 allow invalid numbers, 2 allow raw non-UTF8 bytes. `SPAN_STRING_ESCAPE = 4` signals decoded slash/DEL in a string or object key; `SPAN_NONFINITE = 8` signals NaN/Infinity/floating overflow; saturated plain integers stay finite. Preserve these flags through indexed/rescanned/loading nodes and ancestors. Zero-mode C source stays strict. Policy must reach resumed walkers, key/scalar readers and eager rebuilds.

1. Add failing Rust tests for split-token permissive decimal/hex/Inf/NaN grammar, strict counterparts, byte values/keys, Unicode failures and late walkers/readers. Watch RED.
2. Implement fixed/bounded token state, policy propagation and flags; do not retain a number token proportional to input size. Run targeted native tests GREEN.

## Task 2: Codec settings and full encoding (F09/F12)

Files: `lua/leanjson/table.lua`, `lua/leanjson.lua`, settings helpers if needed; new Lua settings/encoding tests.

Interface: four public setters above, passed into source policy by Task 3. `_new_reader` passes `number` and `escape(byte)` closures frozen at construction. `escape` returns escaped bytes or nil (handles slash, DEL, control bytes). Native encode tokens are `NaN`, `Infinity`, `-Infinity`; null mode yields `null`. Explicit materialization origin reuse must not bypass string escaping.

1. Add failing public tests for defaults, setter arity/invalid values, isolation, normal/safe, NaN/Inf modes, all 256 string bytes, slash toggle and reader snapshot. Watch RED.
2. Implement setters, formatting, full encoding and origin safeguards; run focused tests GREEN.

## Task 3: Source/reader integration and verification

Files: source/loading options and backend, bounded reader, tests and documentation.

1. Add failing nine-cell policy tests, late children/strict rejection, arbitrary byte keys/duplicates, chunk splitting, source nonfinite encode policy, source slash/DEL output and close/yield behavior. Watch RED.
2. Snapshot codec policy into normalized options and native mode, convert nonstandard numbers consistently in eager/preloaded/late scalar paths, stream decoded source strings for reader output without materialization; preserve reader length and cancellation invariants.
3. Run project tests/lint, native HTTP, scalar/panic Rust gates as appropriate, complete pinned upstream nine-cell matrix and Python controls. Re-run bounded memory/loading acceptance and installed-only LuaRocks smoke. Review changes independently and fix important findings via failing regressions. Update checklist and report with actual residual differences. Archive compact evidence and leave changes uncommitted.

## Review focus

Nonfinite values hidden in raw spans; marker/keep-origin shortcuts; strict settings changing mid-decoder or during yields; Unicode escape validation versus raw byte acceptance; native grammar edge cases and overflow; source/reader leases on cancellation; raw source string transformation stays bounded; native ABI zero mode and legacy parse remain strict.
