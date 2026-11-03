# Upstream lua-cjson compatibility matrix

Recorded 2026-11-02. The complete functional inventory of the pinned OpenResty
lua-cjson revision was adapted and executed across all nine requested cells.
**The harness is healthy; LeanJSON is not fully cjson-compatible.** This work adds
verification infrastructure and reports existing gaps without changing runtime
semantics or substituting native cjson for missing target behavior.

Follow-up work is tracked in the [cjson compatibility fix checklist](../design/cjson-compatibility-fixes.md),
with stable issue IDs, evidence, acceptance criteria and unresolved policy choices.

The later [F03 codec-instance report](f03-codec-instances.md) records the `new()`
implementation and a fresh nine-cell run. The counts below remain the historical
pre-F03 baseline.

The subsequent [F04 safe-codec report](f04-safe-codecs.md) adds the real safe
module, its factory and the next complete matrix run.

The measured runtime is `b928a20505165fc3c0f3399b68500cd02050b42f`.
Tests live in [tests/upstream-cjson](../../tests/upstream-cjson/README.md);
the entrypoint is [verify-cjson-compat.py](../../scripts/verify-cjson-compat.py).
The [evidence archive](upstream-cjson-compatibility-logs.tar.gz) contains raw
records, logs, commands, source/binary hashes, independent audits and review
reports. `SHA256SUMS` inside it covers every archived evidence file.

## Reference and coverage

The reference is vendored OpenResty lua-cjson commit
`617164a0fe3bb647128178f9caefb304b8573bb6`, built from source in a temporary
directory. It is not a claim about every historical or future lua-cjson release.
The original case definitions, expected values, shared configuration state and
agentzh Lua block bodies are retained. The generated runner changes only the
version display header to tolerate absent target metadata; the original metadata
assertion still tests the actual target fields.

| Inventory | Records per cell |
| --- | ---: |
| `test.lua` assertions | 128 |
| `test.lua` setup helpers | 3 |
| `agentzh.t` blocks | 24 |
| Supplied JSON decode-cycle fixtures | 9 |
| Total | 164 |

This is 161 assertions/blocks/cycles plus three helpers per cell, or **1,476
primary target records** across nine cells. Helpers are not passing assertions.
Benchmarks, build/package scripts and the replaced Perl test launcher are listed
as nonfunctional infrastructure, not silently omitted functional cases.

The source-built reference has **160 applicable passes, three successful helpers
and one environment-inapplicable block**, with no failures. That block tests
Lua 5.3 integers and merely prints canned expected output under LuaJIT. Its
stdout match is not counted as coverage. The applicable ordinary-table branch
of agentzh test 15 is recorded; its version-gated LuaJIT cdata branch is not
exercised by this `2.1.ROLLING` build. Czech-locale cases were run using a prepared
`cs_CZ` locale, verified by `os.setlocale` and libc's comma decimal separator.

An independent run bypassed the adapter and executed the original `test.lua`
with all nine JSON fixtures: **137/137 assertions passed**. It used the same
pinned source and build settings; its separate build's binary hash is retained
in `root-original-upstream-command.json`.

## Nine-cell results

`lazy` uses default lazy loading; `eager` passes `lazyload=false`; `preload` selects
`$` with `index_depth=0`, `index_array_limit=0`, and `index_budget_bytes=0`.

| Mode | Input | Pass | Behavioral difference | Unsupported / dependent | Environment |
| --- | --- | ---: | ---: | ---: | ---: |
| lazy | memory | 15 | 14 | 134 | 1 |
| lazy | file | 15 | 14 | 134 | 1 |
| lazy | incremental | 15 | 14 | 134 | 1 |
| eager | memory | 15 | 14 | 134 | 1 |
| eager | file | 15 | 14 | 134 | 1 |
| eager | incremental | 15 | 14 | 134 | 1 |
| preload | memory | 15 | 14 | 134 | 1 |
| preload | file | 15 | 14 | 134 | 1 |
| preload | incremental | 15 | 14 | 134 | 1 |

Each unsupported total includes three failed setup helpers: the 160 applicable
assertion outcomes are **15 pass + 14 difference + 131 unsupported/dependent**.
Of the 134 unsupported records, 48 contain direct unavailable-symbol evidence;
86 contain dependency-only evidence. Missing settings or failed instance resets
invalidate later assertions that depend on that state, even if their raw values
happen to match. This is not a finding that 134 JSON documents decode incorrectly.

Raw exact/logical matches are retained separately: 47 per cell, including the
conditional no-op and 31 assertions affected by failed dependencies. Those raw
matches must not be presented as 47 valid compatibility passes. Every cell has
the same counts because the observed gaps are shared across these modes; the
runner does not copy one cell's results into another.

Reference execution captures 80 decode calls in 71 cases. Each primary target
cell actually reaches 75 calls in 66 cases; absent APIs or earlier failures
prevent the remaining calls. All such cases still have inventory records. Each
call records its real path: `leanjson.decode`, `leanjson.decode_file`, or
`leanjson.new_decoder` followed by `feed` and `finish`. Encode-only and settings
cases are repeated but do not claim input-source coverage. A supplemental replay
below covers all 80 captured inputs through every source.

## Observed gaps

The 14 untainted behavioral differences per cell are:

- Twelve malformed-input cases, `test.lua:L121` through `L154`: both libraries
  reject the input, but error text and positions differ. These include UTF-16/32,
  truncated JSON, escapes, keywords and number syntax. For example, partial JSON
  reports `leanjson: JSON parse error at byte 20` instead of the reference's
  `Expected value but found T_END at character 21`.
- `agentzh.t:TEST20`: the existing `encode_number_precision` accepts 1–14 rather
  than the reference's 1–16. The original test stops when it requests precision
  16. Additional setting/return differences remain visible in dependency-tainted
  raw records rather than being promoted to passes.
- `agentzh.t:TEST23`: encoding a foreign array-like object driven by `__len` and
  `__index` produces `{}` instead of `["foo","bar","baz"]`.

Directly unavailable APIs/fields include `new`, `safe`, module identity fields,
maximum-depth controls, invalid-number controls, comments, indentation, buffer
configuration, cjson empty-array/metatable controls, forward-slash escaping and
unsupported-value skipping. Some have analogous LeanJSON features, but the
adapter deliberately does not invent cjson-compatible aliases or semantics.
The per-case `unsupported` and `dependencies` fields identify which condition
blocked each assertion.

## Selective preload replay

All 80 reference decode inputs are also replayed through each source with
selective `preload_paths` and all three automatic index limits zero. For a
nonempty container the runner selects an existing child from the native typed
result, including properly escaped object keys; a second child, when present,
is read without preloading. Scalars select `$`; empty containers explicitly have
no selectable child. Complete encoding and a lossless logical roundtrip are
retained as diagnostics after the original operations. They do not change decode
compatibility classification or strict status.

| Input | Compatibility pass | Behavioral difference | Proxies with initial stats | Zero-index violations | Unselected sibling checks |
| --- | ---: | ---: | ---: | ---: | ---: |
| memory | 36 | 44 | 31 | 0 | 9, all match |
| file | 36 | 44 | 31 | 0 | 9, all match |
| incremental | 36 | 44 | 31 | 0 | 9, all match |

The 80 outcomes per source break down more precisely as follows:

| Reference / target decode result | Count | Interpretation |
| --- | ---: | --- |
| Both succeed, typed values agree | 36 | All pass compatibility; 35 also satisfy the diagnostic lossless roundtrip |
| Both reject, error details differ | 27 | Exact error parity fails |
| Reference succeeds, target rejects | 15 | Includes permissive settings and safe-return behavior not emulated by replay |
| Reference rejects, target succeeds | 2 | Original maximum-depth setting is not emulated |

The separate incomplete-roundtrip diagnostic is `agentzh.t:TEST20#decode1`:
decoding `2^53` agrees exactly and passes compatibility, but default 14-digit
encoding produces `9.007199254741e+15`, losing
precision on re-decode. **Native cjson's default output in the original block is
the same.** This additional lossless-roundtrip diagnostic does not fail
compatibility or strict mode. The primary cjson compatibility gap is inability to
select 16-digit precision. Summary diagnostics separately record 37 complete
roundtrips, 1 incomplete and 42 not run after decode failure per source; all
original encoded-output evidence is retained. The 44 compatibility differences
are the 27 exact error mismatches, 15 reference-success/target-failure and 2
reference-failure/target-success outcomes above.

All stats-bearing proxies show actual preloads and zero automatic index bytes;
all final cleanup error lists are empty. This functional matrix does not measure
peak memory, throughput, or prove that every subsequent access avoids source I/O.

## Trust checks and project regression

The runner rejects omitted, duplicate and unexpected inventory IDs. Eight
focused tests exercise real native/target processes, deliberate incorrect
returns, missing APIs, failed setup, malformed input, typed values/return arity,
one-byte chunk boundaries, actual partial preload, and strict/report exit policy.
A real native/target regression proves identical default-precision loss stays
compatible through all three selective sources and returns strict exit 0.
Those eight tests passed in the preceding round. A ninth, separately run focused
test now covers real CLI output reuse in both directions (success to failure and
failure to success), proving current status files are mutually exclusive while
other diagnostics remain. The final status-housekeeping change was verified only
with that focused test; the recorded matrix and project gate were not repeated.
Observed red and green logs are retained. The independent supervisor audit
reconciles suite locations/hashes, all 1,476 primary records, native binary hash,
UTF-8 fixture, real source dispatch, loading options, cleanup and summary totals.

One `make test` run in the pinned environment passed **428 Rust tests and 439 Lua
tests**, with zero failures. Runtime source did not change in this task. The
previous native HTTP gate was not rerun for this test-only change and is not
counted as new evidence. Project regression success does not override the failed
compatibility result.

The refreshed direct Python strict run exited **1** in 21.741 seconds with
`harness_healthy=true`, `compatible=false`. Report mode exits 0 for healthy report
generation, even with incompatibilities. Python exit 2 denotes harness failure;
GNU make also returns 2 for a failed recipe, including Python compatibility exit
1. Inspect `summary.json` and the direct runner exit to distinguish them.

## Reproduction and evidence

This recorded run uses Linux ARM64/OpenResty 1.29.2.4/LuaJIT 2.1 in the existing
local image `lua-qjson-dev:task3-repro`. The runner checks its immutable ID:
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`.
It requires host Python 3, Docker and the built LeanJSON library in the
`leanjson-bounded-target` volume. The image is not published by this task; a
fresh image build may have another ID and is outside this recorded baseline.
The source and binary provenance are retained; this is not cross-platform
compatibility evidence.

Extract the archive inside the checkout to restore the recorded locale and
evidence paths, then choose a new output directory to preserve the old run:

```sh
tar -xzf docs/verification/upstream-cjson-compatibility-logs.tar.gz
python3 scripts/verify-cjson-compat.py --docker --strict \
  --output .superpowers/cjson-new-run \
  --locale-dir .superpowers/sdd/2026-11-02-upstream-cjson-matrix/locale
make cjson-compat-controls
```

`make cjson-compat` and `make cjson-compat-strict` expose the same runner;
`CJSON_COMPAT_OUTPUT`, `CJSON_COMPAT_IMAGE` and `CJSON_COMPAT_LOCALE_DIR` configure
their inputs. Changing the image tag is allowed only when it resolves to the
same pinned ID. Without a prepared Czech locale, the locale helper and two
locale assertions are explicitly environment-inapplicable. Output and locale
directories must be inside the checkout for container bind-mount access.

Archive paths are rooted at
`.superpowers/sdd/2026-11-02-upstream-cjson-matrix/`. The authoritative run is
`task-1-artifacts/final/`, containing `inventory.json`, `provenance.json`,
`commands.jsonl`, `summary.json`, baseline/matrix/selective `records.jsonl`, raw
worker logs/configurations, exact string blobs and the source-built reference
library. Earlier failed attempts remain separately named and are not merged
into the final totals. `locale/` includes the locale package, hashes, generation
commands and probes; `root-*` files hold independent audit evidence.

The reference library SHA256 is
`6daf540edbc1fbdd1f0ee1ca331d901f5f94f29e59b05e8190b805ec212894ea`;
the measured LeanJSON library SHA256 is
`20e4db6e52ad82f7378550e2cc3943485e456cc1880e825f69ae445774c29d42`.
The generated UTF-8 scalar fixture is 4,382,592 bytes, matching both the upstream
MD5 `cff03b039d850f370a7362f3313e5268` and an independently generated SHA256
`e0a7693f7362e88827c15e772e55b3490bd983f90711df7f3ef36c2b1ef6847e`.

The target was loaded with optional native cjson denied and used its standalone
sentinels. Original assertions ran before separate logical observation; no early
materialization or global `pairs` replacement hid proxy behavior. Native plain
Lua tables lose empty-array/object identity, so observations explicitly retain
that ambiguity. Other cjson-integration profiles and Lua 5.3 integer behavior
remain outside this matrix. Full compatibility requires separate runtime work.
