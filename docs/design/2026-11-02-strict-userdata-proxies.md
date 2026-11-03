# F18: optional userdata proxies

The user approved adding a strict userdata carrier while retaining the current
table carrier and eager decoding. This document records the implementation
choices for that approved direction.

## Contract

- `decode`, `decode_file`, and `new_decoder` accept `proxy_mode = "table" | "userdata"` in their existing options. Default is `"table"`. Other supplied values are errors, even with eager loading. Safe option errors continue to throw as they do for other invalid options.
- With lazy loading, every object/array view uses the selected carrier, including nested/preloaded containers, decoder get/finish results, detached children and array-remove results. Scalars and null/empty-array sentinels keep their existing contracts.
- `lazyload=false` always returns ordinary Lua values. `materialize()` always returns ordinary Lua values. The legacy `parse` API is unchanged.
- `fork(proxy)` preserves the source proxy's carrier, including cross-codec forks. Forking an ordinary table defaults to table proxies. Assignment and array insertion snapshot data; subsequent views use the destination parent's carrier, independent of the source's carrier.
- Preserve logical access, assignment/deletion, dense-array editing, snapshot isolation, original-span reuse, index budgets, preload guarantees, codec policies and bounded reader behavior. `json.type` continues to return object/array. `type()` genuinely returns userdata in strict mode.
- Keep existing leases, cancellation and GC token machinery for this carrier change. Share carrier metatables rather than allocating one per proxy. No new native ABI or Rust scanner changes are required by this design.
- Existing `array_mt` exposure remains observable when the array marker setting is enabled; `materialize` retains existing marker rules. `new()` and configuration/options tables remain ordinary tables.
- Ordinary native raw/table-only operations on userdata reject the type. Do not patch global builtins or implicitly materialize to make them succeed. A runtime without the userdata factory must fail clearly when strict mode is selected rather than silently returning table proxies.
- Recognize own proxies before generic unsupported-userdata logic in encoding, including unsupported-value skipping. Foreign userdata keeps its existing unsupported behavior.
- Third-party code may reject, skip or otherwise handle userdata; no universal third-party error guarantee is made. Materialize at interfaces that require plain tables.

## Approaches and scope

Keeping only table proxies cannot intercept raw read operations. Globally
wrapping builtins cannot cover cached references or C internals. The approved
direction is an opt-in userdata carrier on the same logical node/source model.
Default/eager behavior stays available for migration.

Scope includes runtime integration, targeted regressions, OpenResty acceptance,
explicit upstream observations for both carriers and paired memory evidence.
It excludes F16 metadata implementation, Kong integration, new buffer pooling,
and remote Git operations. Memory/latency improvements are not assumed.

## Acceptance boundaries

Run the default suite without weakening existing expectations. Strict-mode
functional regressions cover lazy/eager/preload × memory/file/feed, normal/safe
and independent codecs, mixed carriers, flags and ownership. Upstream strict
runs must preserve actual Lua types and raw exact verdicts separately from
logical comparisons; userdata versus table differences are not passes.

Compare both carriers using the existing 33-case memory gate and record every
threshold failure. Do not change thresholds or fix unrelated memory behavior
to manufacture a pass. Verify reader output/chunk limits and real HTTP sending.
Retain first failures and setup failures alongside corrected runs.
