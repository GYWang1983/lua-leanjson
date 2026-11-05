# Native Serialization Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and test-driven-development. Execute directly; request one final whole-change independent review.

**Goal:** Preserve unmodified raw strings for forwarding and eliminate Lua JSON byte-scanning/encoding loops.

**Architecture:** Stateless native length/encoding helpers with a bounded caller-owned cursor, plus native incremental raw depth state. Lua remains responsible for node/chunk scheduling and lifetime. Reader raw-preservation policy is separate from cjson-compatible encode.

**Tech Stack:** Rust, C ABI, LuaJIT FFI, Docker/OpenResty.

**Spec:** docs/design/native-serialization.md

## Global Constraints

- Preserve existing C ABI layouts, panic barriers, cjson encode behavior and output chunk limit, including size 1.
- Never retain borrowed Lua bytes or build a full native decoded string.
- Existing file/source cancellation and ownership remain effective.
- No Kong source edits, main merge or push.

## Review Focus

- Partial escape output and arbitrary byte strings with windows 1/2/3/5/65536.
- Raw reuse with refs, preloaded values, duplicate keys, comments and modified descendants.
- Exact strict encoding with slash/DEL/Unicode and unchanged cjson defaults.
- Encoder depth below accepted source depth, including quote/backslash chunk splits.
- Encoder scratch must be call-owned: GC finalizers/debug callbacks may reenter without a yield; no writable input/output/state aliasing.

### Task 1: Native bounded string and depth helpers

**Files:** new src/encode.rs, src/encode_ffi.rs, tests/native_string_encode.rs; src/lib.rs, include/leanjson.h.

**Interfaces:** leanjson_encode_string_length(bytes,len,flags,out); leanjson_encode_string_chunk(bytes,len,flags,cursor,output,capacity,out_len); leanjson_encode_depth_chunk(bytes,len,state). flags bit 0 selects slash escaping; cursor holds byte offset/partial escape offset; depth state holds nesting/limit/quoted/escaped.

- [x] Add literal, serde_json Unicode oracle, tiny-capacity, split-depth and invalid-argument tests; observe missing-export RED.
- [x] Implement safe Rust helpers and panic-protected FFI; verify targeted test GREEN and clippy.

### Task 2: Integrate raw reuse and native Lua encoding

**Files:** new lua/leanjson/encode.lua; lua/leanjson/lib.lua, reader.lua, table.lua; rockspecs; tests/lua/native_serialization_spec.lua and loader tests.

**Interfaces:** wrapper length(value,slash), encode(value,slash), cursor(value,slash), next(cursor,capacity), depth(state,bytes); reader preserve_raw_strings boolean, codec._new_reader uses strict option for complete encode/tostring.

- [x] Add raw preservation, strict encoding, source/ref/mutation/keys/windows/depth and Lua-instruction budget regressions; observe RED.
- [x] Replace reader length/output/depth byte loops and complete encode string loop. Implement raw policy and update FFI loader/install manifests.
- [x] Verify focused then whole suite, lint, source compatibility and HTTP behavior. Audit every Lua byte loop with classification.

### Task 3: Verify performance, memory and independent review

**Files:** benches/scripts as needed; docs/verification/cjson-memory-scanner.md and cjson-scanner-results.json; API/README documentation.

- [x] Run default/scalar/panic, full Lua, 2-carrier compatibility matrix, HTTP and installation checks.
- [x] Compare exact frozen 82e36ee artifact with current on identical real Session input: decode/length/emit for memory and explicit file modes; verify complete output oracle, keys/escapes and bounded output.
- [x] Run unchanged RSS gates; retain failures explicitly. Record precise Lua loop audit and proof boundaries.
- [x] One independent review, resolve important findings with RED→GREEN, then scoped feature commit.
