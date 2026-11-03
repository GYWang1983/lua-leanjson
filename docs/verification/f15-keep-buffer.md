# F15: encode_keep_buffer migration compatibility

Verified 2026-11-02 against the local `580a90a` baseline plus this change.

`encode_keep_buffer` is intentionally an inert compatibility setting, as requested.
It stores a per-codec boolean, defaults to true, supports native boolean/on/off
inputs and getter/setter results, and rejects invalid/excess arguments atomically.
Safe configuration calls continue to throw. Fresh instances use the default;
module, normal and safe instances do not share mutable state.

Neither setting changes encoding, GC, retained capacity or source/reader ownership.
No persistent output buffer was added. F16's separate decision is documented:
LeanJSON will use its own identity and version; the metadata fields are not added
by this change.

## Verification

Environment: pinned ARM64 image `lua-qjson-dev:task3-repro`, immutable ID
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`;
OpenResty 1.29.2.4, LuaJIT 2.1, Rust 1.90. Native reference is the vendored
lua-cjson revision `617164a0fe3bb647128178f9caefb304b8573bb6`, rebuilt by the
existing matrix runner. All pinned Czech locale categories were restored for
the locale cases. Native macOS, HTTP, RSS benchmarking and installed LuaRocks
validation were not rerun for this Lua-only compatibility setting.

| Check | Result |
| --- | --- |
| New regressions before implementation | 16 expected failures, zero errors: missing API |
| New regressions after implementation | 16 passes |
| Final canonical `make test` | Rust 444 passes; Lua 730 passes |
| Lua lint | Zero warnings/errors across 86 files |
| Upstream inventory | All 164 records retained per loading/source cell |
| F15 upstream L418/L426/L447 | Pass in all nine cells |
| Stable-ID comparison to final F06 archive | Four new passes per cell, including previously dependent L422; no previous pass regressed |

New coverage includes option parsing (including native C-string NUL handling),
failed setter state, safe error behavior, child defaults, consecutive large/small
encodes and full/reader output in lazy/eager/preload × memory/file/feed modes.
Reader output is also checked while changing the compatibility setting after
reader construction.

The strict matrix intentionally exits 1 with `harness_healthy=true` and
`compatible=false`. Lazy/preload cells have 156 passes, three known F05 array
marker differences (TEST12/13/14), one unsupported identity record (F16), three
successful helpers and one Lua-5.3-only inapplicable record. Eager cells have
159 passes, one unsupported F16 record, three successful helpers and one
inapplicable record. No identity assertion was changed to pretend cjson equality.
Supplemental selective replay remains 62/80 passes per source with 18 known
differences: that worker does not replay captured settings/safe routes. These
results are not normalized into compatibility passes.

## Initial memory-threshold failure

The first `make test` run passed all 444 Rust tests and 729 Lua tests, but
`bounded_metadata_spec.lua:104` failed with 523.3154296875 KiB retained after
pass 2, against a strict 512 KiB threshold. The original log is retained.
Without changing implementation or threshold, a complete Lua rerun passed all
730 tests and a focused run passed all ten metadata tests. The committed Lua
baseline, extracted to a separate directory and using the same native library,
passed all 714 original tests. The final canonical `make test`, after correcting
the new test's zero-based preload selector, passed all 730 Lua tests.

This observation does not establish the threshold failure's cause or prove that
the underlying fluctuation is fixed. Earlier observations are in the F06
report. This compatibility setting does not establish a worst-case memory bound.

## Evidence and reproduction

[Evidence archive](f15-keep-buffer-logs.tar.gz) contains runtime source snapshots,
RED/GREEN and full-suite logs, the original failed run, corrected baseline run,
lint output, complete upstream records/configs/provenance and a SHA256 manifest.
Local task output remains under `.superpowers/sdd/2026-11-02-cjson-f15/`.
Initial baseline-directory and incomplete-locale preparation failures are also
retained separately; corrected runs above are the functional evidence.

Canonical tests run inside the pinned container with this checkout mounted at
`/workspace`, `leanjson-bounded-target:/workspace/target` and
`qjson-cargo-registry:/usr/local/cargo/registry`: `make test` and `make lua-lint`.
The host matrix command is:

```sh
python3 scripts/verify-cjson-compat.py --docker --strict \
  --output .superpowers/sdd/2026-11-02-cjson-f15/matrix \
  --locale-dir .superpowers/sdd/2026-11-02-cjson-f15/locale
```
