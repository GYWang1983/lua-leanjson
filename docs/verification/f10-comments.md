# F10 comment parsing verification

Recorded 2026-11-02, based on local main `af4f9df`. Compatibility oracle:
OpenResty lua-cjson `617164a0fe3bb647128178f9caefb304b8573bb6` in `vendor/lua-cjson`.
This task implements F10 and integrates it into local main; no remote push or
LuaRocks publication was requested.

## Contract and implementation

`decode_allow_comment([value])` defaults to false and accepts booleans or exact
on/off values. Normal/safe/new codecs have independent defaults, native getter/
setter errors and atomic invalid calls. Source/decoder creation snapshots it;
late lookup, cached-prefix resume, linked duplicate replay, selected preload and
eager get/repeated finish rebuild use the originating source policy.

A shared four-state scanner accepts `//` through LF/EOF (CR alone does not end
it), and non-nested `/* ... */` between tokens. It retains no comment payload.
Strings/keys own their marker bytes. Comments cannot concatenate partial numbers
or keywords. The native companion diagnostic scanner uses the same transitions,
including unclosed-block errors, first-NUL positions and global feed offsets.
Existing stricter raw control/NUL acceptance boundaries remain explicit.

Source v2 gains mode bit 4 and comment-bearing-container flag 16 without changing
C struct layouts. Zero modes, source v1 and legacy parse remain strict. The flag
propagates through parent completion, cached spans, loading events and duplicate
spill records. Reader output reconstructs affected containers through existing
bounded iterators, preserving eligible clean child spellings. Leading/trailing
comments outside the root span are omitted naturally. No full materialization or
second input copy is introduced to strip comments.

Affected keep_origin containers cannot reuse their whole original span. Their
eligible clean child/string records remain reusable. Traversal checks actual
output depth, so comment brackets cannot inflate or bypass depth limits. Existing
reader leases/cancellation apply while affected containers are scanned. Normal
encode, reader, fork, writes, materialize and cross-codec output omit actual
comments even when the calling codec disables comment decoding.

## Verification

Pinned Linux ARM64 image `lua-qjson-dev:task3-repro`, OpenResty 1.29.2.4,
LuaJIT 2.1 and Rust 1.90. Native macOS LuaJIT was not executed.

| Gate | Result |
| --- | --- |
| Rust default / no-default-features / test-panic | 444 / 444 / 445 passed |
| Final focused Rust policy test binary | 12 passed, including the final added UTF8-comment fixture |
| Full Lua suite | 583 passed, zero failures/errors/pending |
| New comment Lua suite | 16 passed; nine loading/source cells include normal and safe |
| Clippy / Lua lint | clean; Lua lint 83 files |
| Native OpenResty HTTP | 60 passed |
| Python compatibility harness controls | 11 passed |
| Eager/preload resource acceptance | 18 cells passed |
| Installed-only LuaRocks smoke | passed; cjson/source-tree fallback denied |
| Standard memory gate | 32/33 passed; boundary below |

RED: 16 expected Lua failures for the missing API, and 2 Rust failures for rejected
new mode flags. GREEN covers all input splits, line endings, touching invalid
numbers/literals, malformed/adjacent comments, string markers, initial encoding
precedence, block NUL, strict legacy APIs, selected and late fields, repeated
finish/get, cross-codec/fork/edit output, duplicate normalization, keep_origin,
depth and reader cancellation. Large-comment output is instrumented to require
<=127-byte backend reads and <=7-byte output chunks while scalar materialization
is disabled; comment bytes generate no loading payload or index growth.

Independent native comparison used 578 fixtures: 231 accepted and 347 rejected by
native. All 347 native-rejected inputs have matching messages, and accepted
values match wherever target policy also accepts. Five native-accepted fixtures
are rejected under the pre-existing raw-newline/NUL strict policy; they remain
reported differences. All successful outputs parse with native comments disabled.
An independent 1470-check every-split run has zero mismatches; 18 NUL strict-policy
observations are recorded separately rather than counted as parity passes.

Independent task/integration review passed with no actionable findings. Its five
additional probes covered cached numeric-array prefix resume, zero-index/selective/
full-preload duplicate replay, index clearing, large clean/dirty child origins,
and depth enforcement. Reviewer did not duplicate broad gates or build libraries.

## Complete upstream inventory

Every one of the nine lazy/eager/preload × memory/file/feed cells retains all 164
original records. Native baseline: 160 assertion passes, 3 setup successes, 1
Lua 5.3-only environment exclusion; `cs_CZ` locale was supplied.

| Mode | Each source cell: pass | Differences | Unsupported/dependent | Setup | Environment |
| --- | ---: | ---: | ---: | ---: | ---: |
| lazy / preload | 138 | 4 | 18 | 3 | 1 |
| eager | 141 | 1 | 18 | 3 | 1 |

All 11 original F10 rows (`test.lua:L337`–`L359`) pass in every cell, and every
previously passing record remains passing. Remaining direct differences are F05
lazy markers (TEST12/13/14) and F06 external array proxies (TEST23). Unsupported
records concern F13/F14/F15/F16 and dependencies. Strict matrix exits 1 with
`compatible=false`; those outcomes are retained, not represented as full cjson
compatibility.

Supplemental selective replay remains 62/80 passes per source with 18 recorded
differences. As documented before F10, this supplemental worker records captured
configuration without reapplying it and uses the normal rather than captured
safe route. It therefore still runs with comments disabled. Its results are
preserved and do not replace the correctly configured full matrix or new
selected-preload/safe regressions. No adapter expectations were changed.

## Memory and bounded processing

The standard 11-scenario × three-source harness uses the pinned development
image's native cjson, approximately 1 MiB fixtures, metadata prefixes 3 and 1 MiB
budget, fresh processes and an external semantic oracle. 32/33 pass; wide-scalars/
memory measures 16320 KiB against 16248 KiB, +72 KiB (ratio 1.004431). The previous task
also recorded the same boundary failing by 68 KiB. No threshold was relaxed or
passing retry substituted for this failed sample. These data do not prove a
universal RSS bound or establish a stable F10-specific regression.

An additional pinned-reference-cjson experiment generates a 16777297-byte input
with a 16 MiB block comment outside measured workers. Each method/source runs in a
fresh native OpenResty process; target native cjson loading is denied during
LeanJSON bootstrap. All outputs match the independent semantic oracle and are 70
bytes; reader chunks are <=4096 bytes.

| Input path | Native cjson peak KiB | LeanJSON peak KiB | Ratio |
| --- | ---: | ---: | ---: |
| memory | 44188 | 45092 | 1.0205 |
| file | 44224 | 12788 | 0.2892 |
| feed | 44192 | 12748 | 0.2885 |

Native has no file/feed API here and reads the full input for comparison. Memory
mode retains the original input; its whole-process peak is slightly higher than
native and is not advertised as a memory pass. File/feed plus fixed scanner state
and bounded-read instrumentation support the intended comment-processing memory
behavior; they do not measure latency, concurrent workloads or all possible
working sets. The initial scratch experiment had a resty argument-wiring error,
corrected before any measurements; its setup log is retained separately.

## Reproduction and evidence

```sh
docker run --rm -v "$PWD:/workspace" \
  -v leanjson-bounded-target:/workspace/target \
  -v qjson-cargo-registry:/usr/local/cargo/registry \
  -w /workspace lua-qjson-dev:task3-repro \
  sh -c 'make test lint lua-lint openresty-test && cargo test --release --no-default-features && cargo test --release --features test-panic && cargo build --release'
python3 scripts/verify-cjson-compat.py --docker --strict \
  --output .superpowers/sdd/2026-11-02-cjson-f10/final-matrix \
  --locale-dir .superpowers/sdd/2026-11-02-cjson-f10/locale
```

[Evidence archive](f10-comments-logs.tar.gz) contains RED/GREEN, raw complete/
selective matrix records, controls, memory/loading outcomes, installed-only
smoke, the independent 578-fixture and 1470-split scripts/results, the 16 MiB
comment input recipe, reports/review, source snapshots and SHA256 receipts.
The final matrix's 51 runtime/header hashes match current files; built and
installed native SHA256 both equal
`8bf0d9f2eedf09c39e8f1aa023c58851ae486ef0172dbdfd442096c01ec38c0b`.
The reference library hash is recorded separately.

Decisions: reuse the existing isolated worktree to preserve known build/cache
state; output removes comments using bounded affected-container reconstruction
(native-style semantic output, with lossless comment preservation outside this
scope). Retain observed RSS failures rather than tune speculatively or weaken
the gate; the universal memory goal remains unproven. Only this task is committed
to local main, preserving the previous three unpushed commits; no remote push.
