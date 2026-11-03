# F03: independent LeanJSON codec instances

Spec: `docs/design/cjson-compatibility-fixes.md`, F03, with the user's clarification: `new()` creates a codec, isolates settings, and retains lazy/eager/preload and memory/file/feed input.

## Global constraints

- New codecs start at library defaults, not the parent's current settings. Keep existing setter behavior; F01/F02 and safe/F04 are separate work.
- Share sentinels, immutable metadata and stateless helpers, never mutable codec configuration. No temporary global configuration swaps or native-cjson delegation.
- Explicit `codec.encode`/`reader` use that codec. Readers snapshot number formatting at construction. Raw unchanged spans keep their bytes.
- Lazy proxy writes, child views, `tostring` and decoder results use their creating codec. Fork through a codec adopts that codec. Plain eager tables are encoded by the chosen encoder.
- Preserve resource ownership, per-call loading options and existing module behavior. Do not push or merge.

### Task 1: implement and verify codec isolation

**Files:** `lua/leanjson.lua`, `lua/leanjson/{table,proxy,reader,source,path}.lua`, `tests/lua/codec_instance_spec.lua`, upstream harness, README and compatibility docs.

**Interfaces:** Internal codec context accompanies lazy cells and source decoder results; all public instances expose the same supported API.

1. Add tests for independent defaults/settings, nested creation, plain/proxy encoding, sparse mutation, reader snapshots, child/fork behavior, and all nine loading/input combinations. Run focused Busted against the real Rust library. Expected: failure because `new` is absent.
2. Implement per-instance closures without replacing singleton proxy configuration. Run focused tests. Expected: all new tests pass.
3. Preserve instance dispatch in the upstream compatibility harness. Run the full upstream matrix and negative controls. Expected: no missing/duplicated cases; F03 executes, remaining differences are reported honestly.
4. Run `make test`, Lua lint and native OpenResty acceptance, update docs with semantics and evidence. Expected: project gates pass; unrelated compatibility gaps remain listed.
5. Obtain an independent review of the working-tree diff, address important findings with regression tests. Leave changes uncommitted for the user to review.

## Review focus

Check configuration isolation under reentrant/yielding reads, sparse plain-table snapshots, child detachment, forks across instances, incremental get/finish results, shared markers and exact resource lifetime. Check that upstream matrix instances do not bypass requested source/loading modes.
