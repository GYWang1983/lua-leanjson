# CJSON-derived memory scanner prototype

## Approved direction

Implement the first stage agreed in the conversation: reuse CJSON's tight scanning approach for complete memory input, retain LeanJSON spans/proxies and bounded indexes, and verify compatibility, speed and memory before expanding incremental input. After confirming the memory prototype improvement, apply the same bounded plain-string kernel to streaming/file-backed feeds. Preserve incremental grammar/diagnostic states and accelerate their ordinary-string spans in batches. No merge or publication is included.

## Architecture and choices

Extract the ordinary-string scanning loop from the pinned OpenResty lua-cjson source into a small, length-bounded C kernel. It returns a byte span and escaping flags without allocating or copying the string. Keep the existing Rust container/number/escape validators and span/event consumers: they already encode the project's compatibility, numeric overflow, preload and Schema rules. This isolates the dominant long-string cost without creating a second grammar implementation. This is a lexical-kernel adaptation, not a wholesale replacement with cjson.decode.

Alternative: transplant the complete recursive CJSON parser, replace its Lua stack operations with events, and bridge those events into Rust. That duplicates syntax/policy machinery and requires a larger migration of incremental state. A Rust-only optimization remains possible but does not directly test the selected CJSON-derived implementation. Start with the smaller C kernel and measure its actual benefit.

For memory input, feed bounded chunks through additive C ABI functions. The main parser is authoritative for acceptance. Do not run the independent Diagnostics parser on successful memory input; on a parse/finalization error, replay the available complete original input through Diagnostics before formatting the error. Neither C nor Rust retains pointers into a feed call. The Lua backend continues pinning the source string. Eager/preload construction events are drained after every chunk, and Schema sees the same decoded byte stream in batches.

Expose scanner = "cjson" (default) or "legacy" for controlled comparisons and rollback. Existing source option layouts and v1 feed semantics remain unchanged. The additive scanner selector enables batching on v2 streaming sources; their diagnostics remain incremental. The C kernel stops at quotes, backslashes, controls and (in strict UTF-8 mode) non-ASCII bytes; the existing validator handles those boundaries. Slash/DEL escaping flags must match the old implementation. Index budgets, depth/array limits, preload exceptions, duplicate-key last-wins semantics and independent codec settings remain unchanged.

## Verification and acceptance

Test bounded scanning, every chunk split, escapes/Unicode, raw bytes/strict UTF-8, malformed suffixes, deep documents, duplicate keys, Schema and eager/preload with zero metadata budget. Compare memory results with legacy and streaming, not just acceptance. Run default/scalar/panic Rust suites, Lua suite, pinned upstream CJSON matrix, JSONTestSuite and fresh-process memory cases. Benchmark pre-read input with interleaved calls, recording CPU/wall and full input/compiled-library hashes. Include the previous 1,911,205-byte report payload and synthetic long-string/wide-object cases. No end-to-end Kong throughput or universal CJSON-parity claim follows from an isolated decode benchmark.

This prototype may be retained only with an explicit account of measured gains and remaining limitations. The measured memory prototype (35.743 ms legacy versus 1.447 ms new median CPU in the initial 15-trial run) justified extending the same kernel to incremental input. The extension changes block-local scanning, not incremental acceptance or publication semantics.
