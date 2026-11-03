# F08/F09/F11/F12 numbers and byte-string verification

Recorded 2026-11-02 on `fix/cjson-number-byte-compat`, working-tree changes based
on `18ca4c6`. Reference: OpenResty lua-cjson
`617164a0fe3bb647128178f9caefb304b8573bb6`. No commit or push in this task.

## Contract

The user confirmed native-compatible decode defaults. Normal/safe instances
isolate four new settings, with getters and atomic argument validation:

| Setting | Default | Accepted values |
| --- | --- | --- |
| `decode_invalid_numbers` | true | boolean, exact on/off |
| `decode_validate_utf8` | false | boolean, exact on/off; LeanJSON extension |
| `encode_invalid_numbers` | false | boolean, exact on/off, null |
| `encode_escape_forward_slash` | true | boolean, exact on/off |

Native decimal/hex forms, NaN payloads and large exponents are supported.
Plain decimal integers use signed-64 saturation; integer `-0` becomes positive
zero while floating `-0.0` stays negative. A private POSIX C numeric locale and
`strtod_l` handle exponents beyond LuaJIT's converter without changing process
locale. Native cjson is not used for target conversion.

Raw high bytes in strings/keys remain byte-exact. Unicode escapes, surrogate
pairs and unescaped controls are always validated. Decode policy is frozen per
source and reaches resumed/late walks, keys/scalars, preload, eager get and
repeated finish. The v2 C mode gains policy bits without changing layout;
legacy parse and zero-mode C sources retain strict defaults.

Nonfinite encoding applies to new values, source-backed values and numeric
object keys: true emits NaN/Infinity/-Infinity, null emits null, false rejects.
Pure positive-infinity keys retain the native sparse-array check; sparse
conversion must admit object encoding before key formatting. Distinct Lua keys
that format identically retain both serialized fields and all referenced source
leases. Logical proxy lookup keeps the final JSON name/value.

Source flags prevent raw-span/origin reuse from bypassing slash/DEL escaping or
nonfinite policy. Affected strings decode/escape in bounded chunks. DEL always
becomes `\u007f`; slash follows its setting. Readers freeze formatting, nonfinite
and escape policy when created, and length/output use the same callbacks.

## Boundaries

- Strict opt-in uses RFC number grammar, excluding native strict-mode acceptance
  of trailing-dot numbers and signed leading-dot fractions. This retains an
  actual strict mode and the existing C contract.
- Unchanged finite source numeric spellings remain unchanged, including native
  nonstandard forms. Unaffected source strings retain existing escapes; encoding
  is not a universal canonicalizer.
- F17 exact error text remains different. Both implementations rejecting an input
  is not recorded as an exact upstream pass when messages differ.
- F05 lazy structure and F18 proxy-operation boundaries remain documented gaps.
- Runtime execution is Linux ARM64. macOS locale declarations were checked
  against the SDK; native macOS LuaJIT was unavailable for execution.

## Verification

Pinned `lua-qjson-dev:task3-repro`: OpenResty 1.29.2.4, LuaJIT 2.1, Rust 1.90.

| Gate | Result |
| --- | --- |
| Rust default / scalar / test-panic | 438 / 438 / 439 pass |
| Full Lua suite | 552 pass, zero failures/errors/pending |
| New public specs | 45 cases across settings, nine cells, keys and limits |
| Clippy / Lua lint | clean; Lua lint covers 79 files |
| Native HTTP | 60 checks pass |
| Python harness controls | 11 tests pass |
| Memory comparisons | all 33 paired cases pass |
| Eager/preload acceptance | all 18 process cells pass |
| LuaRocks | local install and installed-only smoke pass |

Test-only refinements then used real file-backed sources for collision leases
and `rawset` for concat instrumentation; all 4 affected tests passed again.
Existing ignored-subtree and JSONTestSuite checks explicitly request strict
number/UTF-8 policy and retain their assertions. Overflow lookup now expects
native infinity and verifies default encode rejection. Integer-zero
materialization follows native conversion; directly supplied floating negative
zero still keeps its sign.

Large decimal/hex exponent conversion was also tested under process numeric
locale `cs_CZ`, which remained unchanged. Installed-only smoke disables native
cjson/source-tree fallback, verifies the installed native mapping, and exercises
the new policies. This is a local installation, not a LuaRocks publication.

Memory: default 11 scenarios × memory/file/feed, roughly 1 MiB inputs, depth/array
prefix 3 and 1 MiB index budget. All paired peak-RSS ratios are <=cjson, range
0.334–0.993. Fresh sequential processes with independent typed output oracles
do not prove every concurrent workload.

## Complete and focused upstream execution

```sh
python3 scripts/verify-cjson-compat.py --docker \
  --output .superpowers/f08-f09-f11-f12/final-matrix \
  --locale-dir .superpowers/f08-f09-f11-f12/locale
CJSON_COMPAT_TEST_OUTPUT=.superpowers/f08-f09-f11-f12/python-final \
  python3 -m unittest discover -s tests/upstream-cjson -p test_runner.py
```

| Cells | Records | Pass | Setup | Difference | Unsupported/dependency | Environment |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| lazy × memory/file/feed | 164 | 55 | 3 | 19 | 86 | 1 |
| eager × memory/file/feed | 164 | 58 | 3 | 16 | 86 | 1 |
| preload × memory/file/feed | 164 | 55 | 3 | 19 | 86 | 1 |

All previously passing F01/F02/F05 records remain passing in all 9 cells.
Selective replay is 42 passes/38 differences over 80 inputs per source.
Provenance covers all 49 runtime source hashes. The harness is healthy; overall
`compatible` remains false.

Some related test.lua rows remain blocked by F07 depth-reset dependencies.
Their complete-matrix classifications remain unchanged. Separately, archived
`focused-upstream.py` extracts exact upstream row definitions/fixture helpers
for L220–L282 and L312/L314, running at library defaults through the same real
adapter in every cell. It omits the unavailable prior depth-reset calls, not
assertions or expected results. Each cell executes 28 records: 19 exact passes
and 9 error-text differences. Those 9 are L233/L236/L241/L244/L247/L250/L253/
L262/L265; both implementations reject each input. Agentzh TEST21 passes in
the complete matrix. Focused results never replace its totals.

## Independent review and repairs

Astra review identified 2 Important findings: native-valid huge exponents failed
in Lua conversion, and numeric policy checks materialized arbitrarily long
tokens. Both were reproduced before root's single repair pass. Fixes add the
private-locale fallback and guaranteed-nonfinite metadata: a nonfinite scalar
needs only a bounded prefix; saturated integers retain raw output without
materialization. Tests cap intermediate concatenations while encoding modified
objects with 1 MiB NaN payloads/integers and compare every output chunk.

Signed integer zero and formatted-key collisions also have RED/GREEN evidence.
No Important finding or deferred minor remains. Initial failures, final logs,
probes, review notes, source snapshots, complete final matrix and SHA256 manifest
are in the [evidence archive](f08-f09-f11-f12-numbers-bytes-logs.tar.gz).
