# F16: LeanJSON module identity

Verified on 2026-11-03 against local F18 head
`72d424e8dd4de958f0f245b4f08ed909ae34df2e` (the exact base is recorded in
the evidence provenance). This change adds two public string fields:

```lua
local json = require("leanjson")
assert(json._NAME == "leanjson")
assert(json._VERSION == "0.1.0")
```

The version matches the package version in `Cargo.toml`. It describes LeanJSON,
not the reference lua-cjson version or the development rock's `scm-1` revision.
The fields are defined once in the public root module before its existing
instance API snapshot. Existing `new()` and safe-wrapper copying propagates
them to normal/nested instances, the safe module and normal/nested safe
instances. No new module, file read at runtime, native ABI or build step is added.
The package-version regression detects a future release bump without a matching
Lua version update.

## Verification

Pinned image: `lua-qjson-dev:task3-repro`, immutable ID
`sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47`.
The checkout is mounted at `/workspace`, with
`leanjson-bounded-target:/workspace/target` and
`qjson-cargo-registry:/usr/local/cargo/registry`.

| Check | Result |
| --- | --- |
| Identity RED | 0 passes / 7 expected failures / 0 errors: absent metadata |
| Identity GREEN | 7 passes: six public codec surfaces and package-version consistency |
| First canonical `make test` | Rust 444 pass; Lua 801 pass / 1 failure at `bounded_metadata_spec.lua:104` |
| Canonical repeat, no intervening runtime change | Rust 444 pass; Lua 802 pass / 0 failures / 0 errors |
| `make lua-lint` | 0 warnings / 0 errors across 89 files |
| Corrected baseline Lua control | 795 passes / 0 failures / 0 errors using the pre-change Lua sources |
| Complete upstream matrix, table carrier | Nine cells, 164 records per cell; harness healthy |
| Complete upstream matrix, userdata carrier | Nine cells, 164 records per cell; harness healthy |

The first full run measured 530.7265625 KiB of retained Lua memory after the
first traversal in the existing 512 KiB child-cache test. The same named
threshold has historical fluctuations, but this run does not establish a cause.
It did not recur in the unchanged-source canonical repeat or corrected baseline
control. No threshold, runtime cache, GC policy or assertion was changed; this
report does not call the underlying cause fixed or infer a general memory bound.

The first baseline-control invocation passed its 795 assertions but exited 1
because a semicolon in the supplied Busted `--lpath` was interpreted by its shell
launcher. That setup log is retained. The corrected invocation uses a copied
pre-change Lua source directory and one path pattern; it exits 0. This is separate
from the initial canonical memory-threshold failure.

## Upstream results and intentional brand difference

The vendored upstream remains pinned at
`617164a0fe3bb647128178f9caefb304b8573bb6`. No vendor expectation, test definition,
worker classification or runner implementation was changed. Targets still deny
native cjson during module bootstrap.

`test.lua:L94` expects `cjson / 2.1.0.11`. Every target cell now returns the real
strings `leanjson / 0.1.0`, has no unsupported/dependency marker, and is classified
as `behavioral_difference`. Its raw native exact verdict remains false, rather
than being promoted to compatibility success. Both `--strict` commands exit 1
because intentional differences remain; both harnesses are healthy.

| Carrier/loading | Pass records | Behavioral differences | Unsupported | Other |
| --- | ---: | ---: | ---: | --- |
| table lazy/preload | 156 | 4 | 0 | 3 helper successes, 1 environment inapplicable |
| userdata lazy/preload | 130 | 30 | 0 | 3 helper successes, 1 environment inapplicable |
| either carrier eager | 159 | 1 | 0 | 3 helper successes, 1 environment inapplicable |

Compared with the final F18 receipts, all eighteen cells retain the same 164
stable IDs. The sole classification change is L94 from unsupported to behavioral
difference. All other classifications and every raw exact verdict are unchanged.
Both matrices' 51 target source fingerprints match the tested checkout.

## Reproduction and retained evidence

The identity regression is `tests/lua/module_identity_spec.lua`. Run `make test`
and `make lua-lint` inside the pinned image. On the Docker host, run once per
carrier with distinct output directories:

```sh
task=.superpowers/sdd/2026-11-03-cjson-f16
python3 scripts/verify-cjson-compat.py --docker --strict --proxy-mode table \
  --output "$task/matrix-table" --locale-dir "$task/locale"
# Repeat with --proxy-mode userdata and --output "$task/matrix-userdata".
```

The task-owned locale is copied from the retained F18 locale, not modified in
place. The [evidence archive](f16-module-identity-logs.tar.gz) retains RED/GREEN,
both canonical attempts, baseline setup/corrected logs, both full matrices,
stable-ID comparison, source snapshots, provenance and checksums. `SHA256SUMS`
covers every archived file except itself.

Independent review passed with no findings. Its report is included in the
archive; archive sealing and per-file checksum verification were performed by
the parent after the review, rather than certified by the reviewer.

No fresh HTTP, paired RSS, loading-performance, native macOS or installed
LuaRocks acceptance is claimed for this metadata-only change. The functional
suite still covers lazy/eager/preload and memory/file/feed; both upstream
matrices exercise all nine combinations. Prior performance and distribution
boundaries remain unchanged.
