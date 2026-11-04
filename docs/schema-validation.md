# Scan-time Schema validation

`leanjson.compile_schema(schema)` compiles a boolean/table Schema into an opaque,
reusable plan. It is available on normal, independent and safe codecs. Passing an
existing genuine plan returns that plan. A raw boolean/table is also accepted as
`opts.schema`, but compiling once when configuration loads avoids per-request
compilation. Cyclic Lua tables, nonfinite assertion values, unsupported executable
keywords and invalid constraints raise compilation errors.

Empty arrays in Lua Schema tables use the codec's explicit array marker, for
example `setmetatable({}, json.array_mt)`; an ordinary empty table denotes an
object. Compiling an original Schema proxy preserves its array/object shapes.

```lua
local json = require "leanjson"
local plan = json.compile_schema {
    type = "object",
    required = { "messages" },
    properties = { messages = { type = "array", items = {
        type = "object", required = { "content" },
        properties = { content = { type = "string", minLength = 1 } },
    } } },
}
local decoder = json.new_decoder { schema = plan, structural_index = false }
assert(decoder:feed('{"messages":[{"content":"hello"}]}'))
local body, err = decoder:finish()
assert(body, err)
decoder:close()
json.close(body)
```

Memory, original-file, incremental and OpenResty sources use the same option.
Assertions consume the original scanner's decoded-key, value-start, scalar-chunk
and value-end events. They do not re-read Source or create a Lua instance tree.
No value is published before complete JSON and Schema validation. File/spool
resources close on failure through the ordinary ownership path. An active native
validator retains its plan independently of the Lua wrapper; a finished body does
not need to pin that wrapper.

## Executable profile

This is an explicit unified assertion profile, not a complete dialect selector.
An absent `$schema` or the standard draft-2020-12 Schema URI selects this profile;
unknown/custom dialect URIs are rejected. Legacy tuple `items`, `additionalItems`,
`definitions` and `dependencies` are also accepted as documented extensions.

| Area | Supported assertions |
| --- | --- |
| Values | Boolean schemas, `type` (including integer/type arrays), `enum`, `const` |
| Objects | `required`, `properties`, `patternProperties`, `additionalProperties`, `propertyNames`, `minProperties`, `maxProperties`, `dependencies`, `dependentRequired`, `dependentSchemas` |
| Arrays | Schema/tuple `items`, `prefixItems`, `additionalItems`, `minItems`, `maxItems`, `contains`, `minContains`, `maxContains`, `uniqueItems` |
| Numbers | `minimum`, `maximum`, numeric exclusive bounds, `multipleOf` |
| Strings | `minLength`, `maxLength`, ECMAScript `pattern`, asserted `format`, asserted base64 `contentEncoding` |
| Composition | `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`, local fragment JSON Pointer `$ref`, `$defs`, `definitions` |

`format` and base64 `contentEncoding` are **assertions** in this profile, matching
gateway-style validation. Standard draft-2020-12 treats these as annotations by
default; callers must account for that intentional difference. Format names are
`date`, `time`, `date-time`, `duration`, `email`, `hostname`, `ipv4`, `ipv6`, `uri`,
`uri-reference`, `uuid`, `regex`, `json-pointer` and `relative-json-pointer`.
Unknown formats fail compilation. Patterns use `regress` ECMAScript matching;
unsupported Unicode property escapes and POSIX named classes reject explicitly.

Dynamic/anchor/external references, nested `$id` scope, `unevaluatedProperties`,
`unevaluatedItems`, and unknown executable extensions reject at compilation.
Application hooks such as `x-gateway-image-size` are not executed by the library.
Known descriptive annotations and `x-gateway-authorizable` are accepted. Root
`$id` is descriptive and does not fetch a resource. Schema JSON nesting is limited
to 128; same-instance reference/applicator depth is limited to 256. Count
constraints must be integer-valued, nonnegative and fit `u64`.

## Values, duplicates and memory

Duplicate decoded keys use the final whole value. An earlier invalid occurrence
can be replaced by a later valid one; an earlier valid occurrence cannot hide a
later failure. Exact object equality ignores member order and uses final members.
Schema-attached invalid UTF-8 object keys reject instead of aliasing another key;
ordinary no-Schema raw-byte decoding keeps its existing policy.

Instance numeric assertions compare original decimal/exponent tokens exactly,
without a Lua/f64 round trip. Numerically equal spellings compare equally,
including signed zero. Assertion numbers supplied in ordinary Lua tables already
have Lua number precision; compiling an original LeanJSON Schema proxy or using
the native compiler ABI can preserve source numeric tokens. Compilation uses its
own strict serializer and does not inherit application encoder precision or
value-skipping options.

Type/length-only string assertions consume chunks and discard string contents.
Ordinary successful integer members need no permanent member index. Required and
dependency assertions retain watched-key state; failures remain replaceable until
the enclosing object ends. Constraints needing distinct-property counts retain
key sets. Patterns, formats and base64 checks retain the inspected string;
`enum`/`const` retain compared subtrees and `uniqueItems` retains canonical item
equality state. These necessary validation allocations are separate from
`index_budget_bytes`, which bounds optional Source indexes.

Scan-time validation proves the input snapshot. A later mapped/modified request
must still be checked against its applicable output/provider constraints. The
library does not automatically remove application validation or execute business
authorization rules.
