# F03 independent codec verification

Recorded 2026-11-02 against the F03 working-tree changes based on `3142f00`.
Reference: vendored OpenResty lua-cjson `617164a0fe3bb647128178f9caefb304b8573bb6`.

`leanjson.new()` now creates an independent codec with library defaults. It
retains the existing lazy/eager/preload modes and memory/file/feed inputs.
This resolves F03; it does **not** establish full cjson compatibility. The safe
factory belongs to F04, and the existing precision/sparse setter differences
remain F01/F02. See the [API contract](../../README.md#independent-codec-instances).

## Runtime validation

The same pinned Linux ARM64 image as the upstream baseline was used:
`lua-qjson-dev:task3-repro`, OpenResty 1.29.2.4 / LuaJIT 2.1 / Rust 1.90.

- `make test`: 428 Rust tests and 456 Lua tests pass, including 17 new codec
  tests. All nine source/loading combinations are covered. Tests include
  creator settings, defaults rather than inheritance, cross-instance encoding,
  sparse writes, detached/removed children, forks, shared markers, failed
  setters, get/finish results, reader snapshots, reentrant callbacks and coroutine
  suspension during source reads.
- `make lua-lint`: no warnings or errors.
- `make openresty-test`: all 60 existing native HTTP acceptance checks pass.
  These are integration regression checks; the new codec-specific cases run in
  native LuaJIT against the real Rust library.
- The instance-dispatch control verifies that each new codec still exercises
  the selected source and loading mode in all nine upstream cells.
- All 10 Python harness tests pass; negative controls report `healthy: true`,
  including missing/duplicate case detection, failed setup propagation and
  failed-reset getter dependency tracking.

The initial 15 codec tests failed because `new` was absent. After implementation
they passed; two additional lifecycle/reentrancy checks also pass. The matrix
control initially detected nine instances bypassing the selected source/mode;
the adapter now wraps real target instances and dispatches through their APIs.
The failed-reset negative control now injects an explicit reset failure, rather
than depending on `new()` being unavailable.

## Complete upstream matrix

Re-run command:

```sh
python3 scripts/verify-cjson-compat.py --docker \
  --output .superpowers/f03-new/matrix \
  --locale-dir .superpowers/f03-new/locale
python3 scripts/verify-cjson-compat.py --docker --controls \
  --output .superpowers/f03-new/controls
python3 -m unittest discover -s tests/upstream-cjson -p test_runner.py \
  -k test_instance_decode_keeps_source_and_loading_matrix_dispatch
```

The Czech locale was restored from the original evidence archive and its files
are hashed in the new provenance. The unchanged upstream reference has 160
passes, three successful helpers and one environment-inapplicable record.

| Cells | Records per cell | Pass | Setup success | Behavioral difference | Unsupported/dependency | Environment inapplicable |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| lazy × memory/file/feed | 164 | 27 | 3 | 19 | 114 | 1 |
| eager × memory/file/feed | 164 | 27 | 3 | 19 | 114 | 1 |
| preload × memory/file/feed | 164 | 27 | 3 | 19 | 114 | 1 |

The historical baseline had 15 passes, 14 behavioral differences and 134
unsupported records (including the three helpers). Each cell now has 20 fewer
blocked records: three successful resets, 12 newly valid passes, and five
unblocked behavioral differences. Those five are the existing precision setter
return differences (`test.lua:L420`, `L424`), precision API error messages (`L431`, `L439`),
and sparse option validation (`L487`). Previously passing records remain passing;
this is not five new runtime regressions.

Selective replay remains 80 inputs per source, with 36 passes and 44 behavioral
differences for memory/file/feed. Unsupported settings, safe APIs, errors and
other known discrepancies remain visible. Normal report-generation exit 0
means the harness completed; the report still has `compatible: false`.

Raw output, source hashes, RED/GREEN evidence, matrix records, controls and
review notes are retained in [the F03 evidence archive](f03-codec-instances-logs.tar.gz).
