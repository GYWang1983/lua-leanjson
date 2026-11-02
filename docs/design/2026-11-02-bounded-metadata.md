# Bounded metadata and lazy expansion

The user approved the seven optimization directions discussed in the conversation and requested implementation. Initial metadata depth and array prefix are configurable and both default to 3. The acceptance objective is to avoid the prior small-object regression and keep memory comparable to, preferably below, native lua-cjson under matched operations, including a shallow object with 32,768 unique keys whose values are small objects.

## Contract

1. Duplicate object keys use the last occurrence, comparing decoded key content (including escaped equivalence). Reuse the member slot/replace its span when feasible. Normalized output contains only the final member; duplicate values replace entire subtrees, including null/false. Unknown duplicate status is never interpreted as clean.
2. `index_depth` defaults to 3. Root is depth 0; a root field is depth 1, so `a.b.c` is the default frontier. The frontier retains type and immutable source span; deeper metadata is obtained on demand. This does not change the actual JSON nesting limit or full eager validation.
3. `index_array_limit` defaults to 3, per array. Array length is exact even with a partial index. Access outside the prefix scans from known source positions and need not retain skipped elements. Sparse checkpoints may be used within the shared budget.
4. `index_budget_bytes` defaults to 1048576 (1 MiB), allocated lazily, limiting rebuildable index/cache metadata across initial and later expansion per source, not just first parse. Zero disables optional cached indexes. It is a metadata budget, not a claimed total-process RSS limit. Account native capacities and any Lua caches; avoid keeping unbounded key copies/child tables alongside it. Tight budget triggers correct scanning/eviction, never missing fields or truncating output.
5. Unmodified clean subtrees use raw bounded spans. Duplicate normalization and changed containers use incremental traversal/patches without building all Lua members. `reader:length()` must not materialize the document. Preserved lexical iteration remains lexical; normalized iteration/encoding remains last-wins.
6. Eliminate duplicated per-member Lua bookkeeping on hot paths; use compact records, reused windows/iteration buffers, and limited temporary state. The new sparse path must apply to memory, file and feed APIs, including OpenResty. Do not conceal a full Rust tree below a lazy Lua wrapper.
7. Rebuildable cache and durable mutation overlays are independent. Forks share immutable input/index state while changes are isolated. Cache eviction cannot invalidate live public views/readers, lose changes, break linked-child semantics, or close resources prematurely. Sparse array insert/remove and object delete/re-add remain correct.

`index_depth` and `index_array_limit` accept nonnegative integers; zero means no optional child pre-indexing, not rejection. Validate non-finite/fractional/negative/non-number options. Default bounds must be threaded consistently through decode/decode_file/decoder/read_body/start_body. Document finite supported upper bounds honestly and reject overflow before FFI conversion.

## Architecture

Separate full streaming validation from optional retained indexes. Maintain immutable source spans as stable identities; missing cached metadata is reconstructed from the source. A bounded source scanner/walker may expose an additive versioned C ABI where necessary; preserve the existing contiguous `parse` API and published v1 struct layouts/functions. Reuse existing Rust string/number validation, source windows and resource ownership rather than introducing a second inconsistent JSON grammar.

Provide targeted field/index/length operations and streaming member iteration to the proxy. Avoid the current `proxy.members()` eager expansion for lookup, COW update, normalized reader counting and emission. Mutations record sparse differences over a raw base rather than copying every sibling. Full materialization remains explicitly full materialization, but must release optional metadata that would unnecessarily duplicate the returned tree. User-retained values, explicit full output strings, mutation payloads and independent snapshots are real semantic storage, not evictable index caches.

Duplicate recognition may use compact fingerprints with exact decoded-key comparison on collisions. Correctness must never depend on collision probability. Wide-object handling must not impose an unbounded in-memory table or an all-fields quadratic rescan in the 32,768-key acceptance workload. Use compact bounded state and source rescanning/checkpoints, or spill oversized temporary indexes to owned storage if necessary, with the same cleanup guarantees. Do not change default duplicate semantics to rejection.

## Approaches considered

- Merely cap the Lua wrapper: rejected because Rust still retains all nodes and output can rebuild the entire Lua tree.
- Fully decode or fall back to cjson: preserves correctness but loses the long-context benefit and may temporarily retain both representations. Not the primary design.
- Bounded source indexing plus lazy expansion, sparse patches and streaming normalization: selected by the approved seven-point discussion. Trades additional first-access scanning for limited retained metadata.

## Verification

Preserve existing semantic, corpus, mutation, ownership/cancellation, reader and native HTTP gates. Add focused regressions for lazy frontier reads/writes, option boundaries, late/escaped duplicate keys, whole-value/null replacements, nested duplicates in untouched tails, exact long-array length/far/random access, wide objects, repeated traversal beyond the cache budget, eviction with held children/readers/forks, array structural mutations, source truncation and chunk-boundary errors. Test all memory/file/feed modes; feed split points must not change behavior. Both normal and tiny/zero index budgets must work.

Native OpenResty comparisons use fresh processes per method/case, byte-identical fixtures, same branch count/edits/concurrency, and an untimed semantic output oracle. Record baseline RSS, peak RSS, Lua heap samples, time, source/output bytes and relevant allocation/index stats; never substitute RSS for Rust heap. Include 32,768 short array objects, a shallow 32,768-key object of small objects, wide scalar objects, deep objects, duplicate/escaped keys, long prompts/messages, far access and iterative scans. Measure parse, read, mutation, length, output and close phases with no forced GC in the primary comparison; supplemental forced-GC diagnostics are separately labeled.

The required small-object cases must show no greater measured process peak than native cjson under the paired gate; do not relax this gate merely to complete the task. If a case fails, inspect its allocations and fix it. Finite benchmark results do not prove a universal bound across every JSON shape, caller-held value, allocator or operation; report this boundary without claiming universal dominance. No Kong integration, GitHub rename, package publication or unrelated dependency work is in scope.
