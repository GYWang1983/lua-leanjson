# Pinned upstream functional matrix

`make cjson-compat` builds the pinned OpenResty lua-cjson source in a temporary
directory and executes its complete functional inventory against that library,
then LeanJSON in all nine loading/source cells. It emits a report even when
compatibility differs. `make cjson-compat-strict` runs the same work and exits 1
from the Python runner for unexpected differences or unsupported APIs. The three
declared differences below are recorded as `expected_difference`, not failures. Harness
failures exit 2 from the runner; GNU make reports a failing recipe as make exit 2.
`make cjson-compat-controls` runs focused negative controls, including real native
cjson and LeanJSON worker processes.

Requirements: host Python 3 and Docker, the exact ARM64 image
`lua-qjson-dev:task3-repro` (immutable ID checked by the runner), and the built
LeanJSON library in `leanjson-bounded-target:/workspace/target`. The image and
volume match this repository's loading-mode verification environment. The runner
does not download an image, change runtime code, or build into the vendor tree.
The image contains LuaJIT, a compiler, Perl, and `libcrypto.so.3`; Python runs on the
host. Output must be inside the checkout so workers can use the same bind mount.

Override `CJSON_COMPAT_OUTPUT` to retain a separate run. Its default is the task's
scratch artifact directory. `CJSON_COMPAT_IMAGE` is overridable only to another
tag pointing to the same pinned image ID. A fresh run rebuilds the reference from
source, generates upstream `utf8.dat`, verifies its known MD5, and records source
SHA256s, build commands, library SHA256s, LuaJIT version, and actual process maps.
Set `CJSON_COMPAT_LOCALE_DIR` to a prepared directory containing `cs_CZ/LC_NUMERIC`
to exercise the Czech locale cases. The runner sets `LOCPATH`, probes setlocale,
and hashes that directory in provenance. Without it, unavailable locale behavior
is reported explicitly.

The Python control suite (`python3 -m unittest discover -s tests/upstream-cjson`)
writes to `.superpowers/upstream-cjson-tests` by default. Set
`CJSON_COMPAT_TEST_OUTPUT` to an absolute or checkout-relative path to retain a
separate run; it must remain inside the checkout for the Docker bind mount.

## Execution and observations

- All 131 `test.lua` rows retain their original definitions and order. The adapter
  intercepts `cjson.util.run_test_group`/`run_test` so unavailable APIs and failed
  helpers become individual records. The three helpers are setup records and are
  excluded from assertion pass counts. The nine supplied JSON files are passed as
  original decode-cycle arguments. All 24 `agentzh.t` Lua blocks execute verbatim
  in separate processes, with both stdout and exit outcomes recorded.
- The only generated source change is the display header's
  `tostring(json._VERSION)`. This allows an absent target metadata field to reach
  its original identity assertion. That assertion still returns the real target
  fields and compares to the original expected module name and version.
- Native cjson loads through `package.loadlib` from the temporary source build.
  Target bootstrap explicitly denies optional cjson loading, selecting LeanJSON's
  standalone null/empty-array sentinels. Afterwards `require "cjson"` names a thin
  target facade. Existing APIs call LeanJSON directly; missing functions raise an
  explicit unsupported marker and missing constants remain absent. `cjson.safe`
  maps to the real `leanjson.safe` module. No configuration API is emulated.
- Decode dispatch records show the actual API, input SHA256/blob, options, source
  statistics, feed chunk counts, and cleanup. Feed uses deterministic widths
  1, 2, 3, 5, 8, 13, 64, 256, 1024, 4096, 16384 bytes. Full-root preload uses `$`
  with all three optional index limits zero. Every observed proxy and decoder is
  closed, and temporary input files are removed after each case.
- `new()` returns a facade around the actual independent codec, keeping instance
  decode calls in the requested loading/source cell. `codec_scope` distinguishes
  instance and module calls. The failed-reset control injects its failure
  explicitly, so it remains useful when the factory is supported.
- Safe file/feed dispatch preserves actual safe conversion or decoder error
  pairs rather than throwing them. Non-string inputs and arity checks call the
  actual decode API directly, since they cannot represent file/feed bytes.
  The missing-safe negative control explicitly injects module unavailability;
  normal matrix runs load the implementation and its shared marker constants.
  The missing-API control deliberately looks up a nonexistent control symbol,
  and the malformed-input control deliberately raises a divergent error after
  confirming real target decode rejection. They remain negative controls as
  depth APIs and native syntax messages become supported; ordinary matrix
  workers have no such injections.
- The original `util.compare_values` runs before the separate logical comparison.
  Upstream operators, iteration, metatable access, mutation, and encoding are
  unchanged. No eager materialization or global `pairs` patch precedes them.
  The logical observation alone may use `leanjson.pairs` to traverse a proxy.
  This image's OpenResty LuaJIT also honors the proxies' `__pairs` in the original
  comparison. Exact and logical verdicts remain distinct fields.
- Failed configuration calls taint subsequent encode/decode calls in that
  configuration domain. Failed helpers remain explicit dependencies until a
  successful reset. A raw exact match with such a dependency is classified
  unsupported, preserving the raw verdict alongside that classification.
- A missing `cs_CZ` locale makes its setup and the two locale cases explicitly
  environment-inapplicable. The upstream Lua 5.3 integer test emits canned output
  on LuaJIT; it is also environment-inapplicable, even when stdout matches.

Supplemental selective replay uses every decode call captured from the reference,
including inputs hidden behind target-only unsupported setup. Each successful
container selects one existing child from the reference typed observation; a
second child, when present, is accessed without preloading it. Scalars select `$`;
empty containers record that no child is selectable. Each source reports selected
paths, initial zero-index statistics, unselected values, the complete encoded
output, and an encode/decode logical roundtrip diagnostic. Lossless roundtrip
results are reported separately in `encoded_roundtrip_diagnostics` and do not
change compatibility classification or strict status: native cjson's default
precision can lose the same numeric information. Supplemental comparisons use
decode results, unselected access and index checks. Each decode event snapshots
the actual instance's four native decode settings and safe/normal route, including
changes made inside a test function. Replay applies them to a fresh target codec
before selecting fields. Encode/roundtrip observations remain supplemental, not a
claim to replay every upstream encoder setting. Original evidence is retained.

## Declared differences and acceptance

The allowlist in `scripts/verify-cjson-compat.py` has three groups:

| Group | Scope | Required observation |
| --- | --- | --- |
| `module_identity` | `test.lua:L94`, all loading modes | `leanjson` and the actual Cargo package version, with both return values present |
| `lazy_array_semantics` | `agentzh.t:TEST12/13/14`, lazy/preload | Empty arrays remain `[]`; assigning a hash field to a proxy array raises the specified array-index error |
| `userdata_carrier` | 17 named direct-decode and 9 cycle records, userdata lazy/preload; selective container observations | Only the proxy carrier differs; contents, return arity, scalar bytes/values and errors must match |

Matching a case ID alone does not allow a failure. Wrong metadata, changed array
output, unrelated exceptions, missing APIs, failed setup and content corruption
remain failing results. Cycle decode contents are observed **after** the original
upstream comparator, so a false userdata comparison cannot hide damaged data.
A separate native codec records the original JSON object/array kinds after that
comparison; this also rejects a `{}`/`[]` kind regression hidden by equal empty
contents. It does not change the upstream test's array-marker settings. The
declared-policy map is enforced by both the main matrix and selective gate.
Eager mode only allows the module-identity difference.

Schema version 2 separates `summary.accepted` (project acceptance) from
`summary.compatible` (no observed compatibility differences). Strict exit status
uses `accepted`. A report may have `accepted=true, compatible=false` with zero
unexpected failures. Each difference retains its group and the original
`upstream_exact_pass`, Lua types, stdout/errors and observed values; it is never
counted as an exact pass. New differences require an explicit policy decision.

## Evidence schema and limits

`inventory.json` contains stable IDs, original locations, definition hashes,
categories, setup definitions, and explicit benchmark/packaging exclusions.
`baseline/records.jsonl`, `matrix/<cell>/records.jsonl`, and
`selective/<source>/records.jsonl` hold per-case evidence. Worker directories retain
Lua configs and raw process logs. `commands.jsonl`, `provenance.json`, the saved
reference library, and `summary.json` provide run-level evidence.

Typed values distinguish nil, false, null, table key types, return arity, NaN,
infinities, negative zero, and exact string bytes. Long strings use length,
SHA256, bounded hexadecimal samples, and deduplicated complete `.bin` artifacts.
Original plain Lua tables do not retain empty-array/object identity after native
cjson decoding; that ambiguity remains in the raw observation. The separate
`reference_shape_result` probe retains array markers solely for the allowance guard.
Known target proxy container kinds and exact encoded output remain visible.
Deep/cyclic *input* diagnostics are bounded; the unmodified generating definition
and source hash retain reproducibility. Output/error observations are not replaced
with upstream expectations or normalized messages.

Completeness checks reject missing, duplicate, and unexpected IDs. Report-mode exit
0 means a healthy harness, not acceptance success; use `summary.accepted` or
strict mode. `summary.compatible` retains the stronger equivalence result.
Baseline failures, unsupported APIs/dependencies, expected and unexpected
differences, environment exclusions, helper setup outcomes, and raw assertion
matches have separate fields/counts. The matrix is functional validation, not a
performance measurement or a claim of full cjson API support.

Each CLI invocation clears prior `summary.json` and `harness-error.json` before
work. A failure removes any partial summary before writing its current error;
other logs and diagnostics are retained. Use separate output directories when
preserving previous runs.


For a restored development image or an isolated target volume, set
`CJSON_COMPAT_IMAGE`, `CJSON_COMPAT_IMAGE_ID`, `CJSON_COMPAT_TARGET_VOLUME` and
`CJSON_COMPAT_REGISTRY_VOLUME` before invoking the runner or its Python controls.
The image ID must be the actual immutable `sha256:...` digest; the runner still
rejects image identity or architecture mismatches. Defaults retain the original
pinned environment. Keep the output directory inside the mounted checkout and
pass `--locale-dir` for the prepared `cs_CZ` locale when running the full matrix.
