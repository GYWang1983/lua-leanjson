# Native string serialization and source reuse

Continue from 82e36ee. Remove redundant source string decode/re-encode, and move JSON string byte processing out of Lua while preserving bounded output and cjson-compatible complete encoding.

Source-backed, unmodified string tokens may be emitted directly, including original quotes/escape spellings. Reader option `preserve_raw_strings` controls this independently of the codec; default true is the user-approved forwarding behavior. Ordinary Lua/new/modified strings still use the codec. `encode()` and `tostring()` explicitly disable preservation and keep existing compatibility behavior. Containers with comments/duplicates/changed descendants remain reconstructed as needed; string reuse must not bypass cancellation, source EOF checks, unsupported-value handling, indentation or depth checks.

Add native decoded-string encoded-length and bounded encoding helpers. They accept borrowed Lua bytes only for a synchronous call, retain no pointers, and expose a small offset/partial-escape cursor. Output capacity 1 must work, with partial escape state bounded to at most five remaining bytes. Escape slash per codec, DEL as \\u007f, standard short escapes and remaining control bytes as cjson does; arbitrary other bytes pass through. Use these helpers for reader values/keys and full encode strings/keys. Lua coordinates chunks, containers and final concatenation only.

Replace the reader's raw-container depth byte loop with a native resumable depth check across chunks. Keep path-expression parsing distinct: it may iterate over the caller's JSONPath expression, but no Lua loop may scan JSON payload/string bytes for validation, output length, escaping or raw depth.

No existing C ABI layout changes. Add exports, panic barriers and loader requirements consistently to Rust/header/Lua. Update rock installation for the new Lua wrapper. Do not modify Kong, merge main or push.

Validation: native literal/property/capacity/argument tests; lazy/eager/preload × memory/file/feed, table/userdata; raw preservation vs explicit canonical behavior, mutated/ref strings and keys, tiny chunks, depth/cancellation and large escaped strings; instruction-count regression proving Lua work is chunk/node-oriented; default/scalar/panic Rust, full Lua, compatibility matrix, HTTP, lint, install smoke, unchanged RSS gates; real Session staged benchmark against frozen 82e36ee with explicit file_in_memory true/false. Audit all Lua byte loops and report any remaining control-expression parsing honestly.
