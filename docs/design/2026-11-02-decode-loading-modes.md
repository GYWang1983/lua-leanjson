# Eager decoding and explicit path preloading

The user requests a switch to disable lazy loading and decode-time selection of
fields to load. They confirmed that unselected fields remain readable lazily and
encoding must retain the complete JSON. Explicit `preload_paths` must ignore
`index_depth`, `index_array_limit`, and `index_budget_bytes`, including zero.

## Public contract

- `lazyload` is a boolean, default `true`. It is independent of the existing
  `lazy` validation option; complete strict source validation remains mandatory.
- `lazyload=false` returns ordinary Lua tables/scalars, with no proxy descendants
  or hidden source ownership. `pairs`, `ipairs`, `next`, `rawget`, and normal table
  edits work directly. Numbers use Lua numbers, null uses `leanjson.null`, duplicate
  decoded keys use their final whole value, and empty-array identity is retained
  under LeanJSON encoding. This is eager cjson-style value behavior, not a promise
  to duplicate cjson's invalid-input extensions or allocator/CPU performance.
- `preload_paths` is an optional dense array of JSONPath-subset strings. Supported:
  `$`, dot member names, bracketed double- or single-quoted member names (including
  escaped names), zero-based nonnegative integer array indexes, `.*`, and `[*]`.
  Wildcards match immediate object members or array elements. Recursive descent,
  filters, slices, unions, negative indexes and malformed expressions are rejected
  explicitly. No JSON Schema API is introduced in this change.
- Selecting a scalar loads its complete value; selecting an object/array loads
  its complete subtree. Missing paths and incompatible encountered types are no
  matches. Duplicate/overlapping paths are harmless; `$` selects the full value.
  An empty array selects nothing. Options are validated before opening a file or
  creating a spool. Mutation of the caller's path array after construction cannot
  change a decoder's selection.
- Selection is applied during source scanning, sharing compiled path prefixes.
  Unselected branches still receive full syntax/UTF-8/depth validation, without
  materializing their values or retaining an unrestricted metadata tree. Do not
  implement this as full materialization followed by filtering, or one full scan
  per path. Bounded native events or selected spans may bridge scan and Lua value
  construction, but decoded selected values must be ready when decode returns.
- Preloaded data is immutable source data, not a mutation patch. Unmodified output
  retains original spans/tokens, including large-integer spellings; child writes,
  forks, lexical duplicate snapshots, and normalized output preserve existing
  semantics. Repeated selected reads require neither source reads nor re-decoding.
- Explicit selected data and its required path metadata are retained outside the
  automatic index budget. They are neither skipped nor evicted because any of
  the three index settings are small/zero. Account them separately with truthful
  source diagnostics; do not label native index bytes as total process memory.
- `lazyload=false` takes precedence over preloading: all fields are loaded, while
  supplied path syntax is still validated. It never produces a projection.
- Apply these options consistently to `decode`, `decode_file`, `new_decoder`, and
  OpenResty adapters through `opts.decode`. Eager file results own no descriptors;
  the incremental decoder retains its existing explicit ownership until close.
  Repeated `new_decoder` finish/get semantics remain independent of caller
  mutations: completed decoder queries read its immutable input, and full eager
  results are independent ordinary values. Preserve the existing OpenResty Session
  contract instead: it exposes one completed value, and repeated Session get/finish
  see edits to that value in both socket and completed-body fallback modes. No
  provisional values are exposed before final validation.

```lua
local plain = json.decode(raw, { lazyload = false })
local body = json.decode(raw, {
    preload_paths = { "$.model", "$.stream", "$.messages[*].role" },
    index_depth = 0,
    index_array_limit = 0,
    index_budget_bytes = 0,
})
```

## Approach and constraints

Extend the existing strict native scanner and shared memory/file/feed adapters;
preserve the contiguous parser and published v1/v2 ABI layouts with additive
entrypoints where necessary. Reuse existing ownership/cancellation and immutable
source-span machinery. Eager output should build ordinary values directly or use
a streaming lexical builder: it must not first build a full proxy/normalized
disk-key tree only to discard it. It must work without the optional cjson module.

Calling existing `get` repeatedly after decode would miss scan-time selection and
repeat source work. Filtering a full DOM defeats the requested memory behavior.
A JSON Schema API adds a separate shape/validation contract; the path array is
the chosen initial selector representation, following the user's allowance of
either representation.

No new dependency, Kong integration, publication or remote Git change is needed.
Implementation stays on `feat/decode-loading-modes` until requested otherwise.

## Validation

Cover memory/file/feed and real OpenResty input. Pin default/invalid options,
ordinary-table eager results, all scalar roots, null/false, escaped duplicate
keys and whole-subtree replacement, huge unselected strings, deep/far selections
with all indexes zero, wildcard/overlap/root/no-match selection, malformed ignored
subtrees, exact raw output, mutation/fork/held-child snapshots, source callbacks
that yield/close/abort, repeated decoder finish/get and deterministic cleanup.
Instrument source reads and retained/preloaded diagnostics. Measure wide eager
and selective large-body cases separately from default lazy mode; report memory
and CPU without extending the previous finite RSS result into a universal bound.
