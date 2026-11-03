# F04 safe codec verification

Recorded 2026-11-02 on top of the uncommitted F03 implementation, with git HEAD
`3142f00`. Reference: vendored OpenResty lua-cjson
`617164a0fe3bb647128178f9caefb304b8573bb6`.

`leanjson.safe` and `safe.new()` now provide protected conversions with isolated
settings. See [the public contract](../../README.md#safe-conversions) and
[the F04 checklist](../design/cjson-compatibility-fixes.md).

## Verified contract

- A native reference probe confirmed that arity/configuration errors throw,
  while decode type failures (including explicit nil) and conversion failures
  return exactly two values. Success, including false and null, returns one.
- LeanJSON retains its optional loading settings: decode/file accept one or two
  arguments; decoder construction accepts zero or one. Invalid options throw
  before constructing a source. Safe defaults and every safe/normal instance
  have isolated settings, with shared null/array markers.
- File and incremental error tests check descriptor closure without forced GC,
  spool removal, incomplete JSON, callback errors and later output/read failures.
  These tests instrument real POSIX source calls rather than substituting I/O.
- Late lazy property errors and existing decoder/get/reader contracts remain
  unchanged. The safe API does not claim to protect every later operation.
- The Lua wrapper cannot distinguish `LUA_ERRMEM` the way native cjson's C
  wrapper can. VM allocation-failure parity is not established. Exact messages
  remain F17; existing precision/sparse/array-marker gaps remain F01/F02/F05.

## Validation

Pinned Linux ARM64 image `lua-qjson-dev:task3-repro`: OpenResty 1.29.2.4,
LuaJIT 2.1, Rust 1.90.

| Check | Result |
| --- | --- |
| `make test` | 428 Rust + 473 Lua tests pass |
| New safe tests | 17 pass, including all nine source/loading combinations |
| `make lua-lint` | 0 warnings, 0 errors |
| `make openresty-test` | 60 existing native HTTP acceptance checks pass |
| Python harness suite | 11 tests pass; real safe module/factory error pairs verified in all nine cells |
| LuaRocks local installation | `luarocks make` succeeds; installed safe module and native library pass smoke checks |

The installation smoke runs from `/tmp`, with only the installed Lua search
paths, no `LD_LIBRARY_PATH`, and native cjson blocked. It checks process maps to
confirm the installed native library was loaded. It is a local install, not a
LuaRocks publication.

The initial 17 runtime tests failed because the safe module was missing. The
new harness dispatch control initially failed in all nine cells because the
old adapter reported safe as unsupported. Both went GREEN after implementation.
The missing-safe negative control now deliberately injects module unavailability
instead of relying on the missing feature.

## Complete upstream matrix

```sh
python3 scripts/verify-cjson-compat.py --docker \
  --output .superpowers/f04-safe/matrix \
  --locale-dir .superpowers/f04-safe/locale
CJSON_COMPAT_TEST_OUTPUT=.superpowers/f04-safe/python-controls \
  python3 -m unittest discover -s tests/upstream-cjson -p test_runner.py
```

The prepared Czech locale comes from the F03 evidence archive. Provenance
records its hashes and the real source/library hashes. No native cjson fallback
is allowed while loading either LeanJSON module.

| Cells | Records per cell | Pass | Setup success | Behavioral difference | Unsupported/dependency | Environment inapplicable |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| lazy × memory/file/feed | 164 | 29 | 3 | 22 | 109 | 1 |
| eager × memory/file/feed | 164 | 29 | 3 | 22 | 109 | 1 |
| preload × memory/file/feed | 164 | 29 | 3 | 22 | 109 | 1 |

Compared with F03, five previously blocked records now run: `test.lua:L501` and
`agentzh.t:TEST18` pass; `test.lua:L504`, `L512` and `L515` retain error wording
differences tracked by F17. All previously passing records remain passing in
every cell. Supplemental selective replay remains 80 inputs per source, with
36 passes and 44 differences.

The harness is healthy and `compatible` remains false. Successful report
generation is not a claim of complete cjson compatibility.

[Evidence archive](f04-safe-codecs-logs.tar.gz): raw records, reference probes,
RED/GREEN logs, installation smoke, source hashes and independent review notes.
