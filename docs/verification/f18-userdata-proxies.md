# F18: optional strict userdata proxies

Verified on 2026-11-03 in the pinned Linux ARM64 OpenResty image, against
baseline `2d84e43d203bb847354a254cb6ff8dbb1e8e0469`. The task and evidence directory
retain their 2026-11-02 start date.

`decode`, `decode_file` and `new_decoder` now accept the per-decode option
`proxy_mode="table"|"userdata"`, defaulting to table. Strict lazy object/array
views are actual userdata; native raw/table-only operations reject their type.
Logical reads, edits, iteration helpers, snapshots, source-span reuse and bounded
readers use the existing node and lease model. Three shared metatables serve the
object, array and marked-array shapes, without one metatable per view.

Forks preserve the source carrier across codecs. Assignment/insertion views use
the destination parent's carrier. Nested/preloaded containers, decoder get and
repeated finish results, detached children and array-remove results retain that
carrier and independent ownership. Decoder `get` still returns NEED_INPUT until
finish. Eager decoding and materialization return ordinary values; scalar/null
contracts, configuration tables and the legacy parse API remain unchanged.

Own userdata proxies are recognized before generic unsupported-value handling,
including skip-unsupported encoding inside mixed plain/proxy trees. Foreign
userdata retains its existing error/skip policy. No builtin, native ABI, Rust
scanner, F16 identity field or Kong integration was changed. Third-party code may
reject or skip userdata; materialize at interfaces requiring ordinary tables.

## Functional verification

| Check | Result |
| --- | --- |
| Initial focused RED | 19 passes, 37 expected failures, zero errors: mode validation/carrier missing |
| Initial affected GREEN | 148 passes across strict, overlay, lease, loading and skip suites |
| Object native `ipairs` follow-up | RED 61 passes / 4 expected failures; final focused GREEN 65 passes |
| Final canonical `make test` | Rust 444 passes; Lua 795 passes, including 65 new regressions |
| `make lua-lint` | Zero warnings/errors across 88 files |
| Python runner controls | 16 passes, including real native/target workers and strict actual-type/exact-verdict checks |
| Real OpenResty HTTP acceptance | 72 passes; initial 20 expected failures retained |
| Independent loading acceptance | 18 cells per carrier, 36 total, with external typed output/duplicate/byte-count oracles |
| Parent's standalone integration probe | Initial 1,481 assertions; final-source refresh 1,489 assertions passes, including object native `ipairs`/close; initial pre-finish READY assumption corrected in scratch without a runtime change |

Coverage includes normal/new/safe/safe.new, lazy/eager/preload across memory,
file and feed input, invalid modes before I/O, no-factory failure, shared/marked
metatables, actual native operation rejection, mixed carriers, cross-codec forks,
detachment/removal after close, codec flags, reader snapshots, zero index budgets,
selected read reuse, GC without explicit close and yielding-holder cancellation.
HTTP tests check actual userdata in business processing, edits, the receiving
server's full capture/hash/length, and bounded chunks for memory, file,
incremental and transfer-encoding fallback paths.

## Upstream observations

Both complete nine-cell matrices retain all 164 stable IDs per cell and are
`harness_healthy=true`, `compatible=false`. The `--strict` exit is 1 in both runs.
The vendor tree and upstream expectations were not changed. Default table-mode
classifications and raw native exact verdicts match F15 at every stable ID in
all nine cells: no missing IDs, additional IDs or changed verdicts.

| Carrier/loading | `pass` records | Behavioral differences | Other records per cell |
| --- | ---: | ---: | --- |
| table lazy/preload | 156 | 3 | 1 F16 unsupported, 3 helper successes, 1 inapplicable |
| userdata lazy/preload | 130 | 29 | 1 F16 unsupported, 3 helper successes, 1 inapplicable |
| either carrier eager | 159 | 0 | 1 F16 unsupported, 3 helper successes, 1 inapplicable |

The three retained table differences are F05 TEST12/13/14. The 26 additional
strict differences comprise 17 direct container comparisons and nine
decode-cycle checks. Direct comparisons have successful logical observations
but retain their failed native exact verdicts. Decode-cycle definitions call
the unchanged native table comparator themselves and return false; those
results remain false, including in logical reporting.

The observer traverses owned userdata while recording `type="userdata"` and
its actual Lua type. It does not rewrite these to tables. Supplemental selective
replay remains 62/80 per source for table mode and 29/80 for userdata, with all
18 and 51 respective differences retained. These are typed observations rather
than recast compatibility passes. F16 remains pending.

## Paired memory observations

Each carrier ran the existing complete 33-pair gate: eleven workloads/access
patterns across memory/file/feed, with one fresh native process per method and
cell. Input generation and semantic oracles run outside the measured process;
there are no concurrent workloads or forced GC during measured phases. Source
index policies, source bytes, emitted bytes, reader chunk bounds, visited
container counts and runtime fingerprints are checked.

| Carrier | Passing pairs | Failures | Largest LeanJSON/native-cjson peak-RSS ratio |
| --- | ---: | ---: | ---: |
| table | 33/33 | 0 | 0.998524 |
| userdata | 33/33 | 0 | 0.995337 |

Both largest ratios were wide-scalars/memory. Final table mode measured
16,232 KiB versus native cjson's 16,256 KiB, only 24 KiB of headroom; userdata
measured 16,224 KiB versus 16,300 KiB, with 76 KiB of headroom. The initial
pre-`ipairs`-fix userdata run had 68 KiB of headroom and is retained separately. These are
single-run observations, not a worst-case bound or a general userdata memory or
latency improvement. The gate still requires LeanJSON peak RSS to be no greater
than the paired native process in every cell; no threshold was changed.

The historical `bounded_metadata_spec.lua:104` 512 KiB fluctuation did not occur
in this task's canonical run. This does not identify its cause or establish that
it was fixed. Independent loading observations also show that eager decoding
can use more memory and CPU than native cjson; eager mode remains a compatibility
choice rather than a performance promise.

## Independent review

Task review approved the implementation and identified one minor native object
`ipairs` inconsistency. Commit `9c79e41` addresses it with the shared existing
iterator and six regressions; scoped re-review found no new breakage. A fresh
whole-branch review found no remaining Critical, Important or Minor issues and
approved the reviewed implementation. Both reports are included in the archive.
Archive construction and per-file checksum verification were performed by the
parent after that review; the reviewer did not certify the sealing operation.

## Provenance and reproduction

Image: `lua-qjson-dev:task3-repro`, immutable ID
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`.
OpenResty 1.29.2.4, LuaJIT 2.1.ROLLING, Rust 1.90.0. The same tested runtime
fingerprints are retained in both matrices and memory/loading environments:

- Native LeanJSON SHA256: `8bf0d9f2eedf09c39e8f1aa023c58851ae486ef0172dbdfd442096c01ec38c0b`.
- Aggregate Lua SHA256: `9b05041af08e3c562b1232ef5291aeceef0cf4afddc25129cbd2bb0be469ab2d` (sorted relative path, NUL, file bytes, NUL).

The upstream matrices rebuild vendored lua-cjson commit
`617164a0fe3bb647128178f9caefb304b8573bb6` and load that reference with
`package.loadlib`. Their reference binaries have SHA256
`740bcce5bce5a29f85dbd779d2302e04bcd40b20285f30d97bb6f241252f5037`
(table run) and
`b4774823b6734fcc9287170d33793a59a04fe5003241e5713f9df5cf1434f026`
(userdata run); each build's source/compiler/path provenance is retained.
All twelve Czech locale categories were restored from the committed F15 archive.
Targets explicitly deny native cjson during bootstrap.

The memory/loading comparisons instead use the image-installed native
`/usr/local/openresty/lualib/cjson.so`, SHA256
`8825abcf6fca35d18d274d66ff850bd7a6d935e4552fc0bb4e19eff8b3705dab`.
A separate immutable-image probe confirms the actual mapped path and native C
decode function outside measured phases. Both image and vendored builds report
`_VERSION="2.1.0.11"`; that shared version string does not make their binaries
the same reference. Supplementary reference provenance is retained alongside
each memory/loading environment.

Canonical tests run inside that image with the repository at `/workspace`,
`leanjson-bounded-target:/workspace/target` and
`qjson-cargo-registry:/usr/local/cargo/registry`: `make test`, `make lua-lint`
and `make openresty-test`. Host runners, once per carrier, are:

```sh
task=.superpowers/sdd/2026-11-02-cjson-f18
python3 scripts/verify-cjson-compat.py --docker --strict --proxy-mode table \
  --output "$task/final-matrix-table" --locale-dir "$task/locale"
python3 scripts/verify-memory.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --proxy-mode table --output-dir "$task/final-memory-table"
python3 scripts/verify-loading.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --proxy-mode table --output-dir "$task/final-loading-table"
# Repeat with --proxy-mode userdata and distinct userdata output directories.
```

The final runtime is commit `9c79e4169f34922c81fc5bddd84f3a3f59c3c878` after
implementation commit `0afb1fa6640f12cb678458fe7628b82effbb9ddc`. The object
`ipairs` follow-up reuses the existing iterator; six regression cases cover both
carriers and closed holders. Initial evidence is retained at its original paths;
`final-*` directories/logs are the fresh HTTP, matrix, memory, loading and parent
probe receipts for this amended runtime. All 18 Lua runtime files and matrix
source fingerprints were checked against the final checkout. Final stable-ID
classifications and raw exact verdicts match the initial F18 matrices for both
carriers; the default table comparison against F15 therefore remains unchanged.
The final HTTP run retains all 72 TAP successes and server captures under
`final-http/leanjson-openresty.5bm2B9/`.

One first focused GREEN attempt failed during module bootstrap with
`table.lua:18: attempt to index local 'proxy' (a boolean value)` (zero tests,
one error). Its full log is retained as `review-fix-ipairs-green.log`. The cause
is unproven; no production amendment occurred before the following 65-case and
795-case successful runs and the final process matrices. This report does not
label that observation fixed. An earlier parent concern about incomplete HTTP
output was a stale read: both the completed original log and final log contain
72 successes and `1..72`; the ledger records that correction separately.

Raw evidence, initial failures, typed/exact matrix records, measurements, review
reports, source snapshots and checksums are retained in the
[F18 evidence archive](f18-userdata-proxies-logs.tar.gz). Its `SHA256SUMS` covers
every archived file except itself. The archive preserves the task-owned
`.superpowers/sdd/2026-11-02-cjson-f18/` structure without including sibling tasks.
Native macOS, installed LuaRocks distribution acceptance and additional Rust
feature combinations were not rerun.
