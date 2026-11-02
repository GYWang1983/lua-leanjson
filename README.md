# LeanJSON

**Memory-conscious JSON processing for LuaJIT and OpenResty.**

LeanJSON is a Rust-backed JSON library for applications that receive large
payloads but inspect or change only a few fields. It exposes mutable Lua proxies
while keeping untouched content in its original source. File-backed input and
chunked output let applications avoid assembling the entire request, object
tree and rewritten body in Lua memory.

This project is a fork of **[api7/lua-qjson](https://github.com/api7/lua-qjson)**.
It builds on qjson's Rust structural scanners, offset indexes, lazy field access
and LuaJIT FFI integration. The fork adds source-backed mutation, independent
snapshots, bounded output, file/incremental sources and native OpenResty body
adapters. It is distributed under its own name, **`lua-leanjson`**, with the Lua
module **`leanjson`**. Credit for the original implementation belongs to the
qjson authors; the project retains the [Apache-2.0 license](LICENSE).

## Why LeanJSON?

A gateway may need only `model`, `stream` or a few routing parameters from a
request containing megabytes of messages, prompts or inline media. Decoding all
that content into Lua values and building another complete JSON string can
consume substantially more memory than the fields being changed require.

LeanJSON keeps source spans for untouched values. Reading a selected value
decodes it on demand; writing a field records a replacement. A reader then
combines original spans and modifications into bounded chunks.

This is most useful when:

- Large strings or subtrees pass through unchanged.
- Only a small part of the document is inspected or modified.
- Several independent variants share the same input.
- Input can stay in a file and output can be consumed incrementally.

Memory use still includes structural indexes, keys, modifications and any
values explicitly read. A long string becomes a complete Lua string when
accessed. In-memory input retains its original string. LeanJSON does **not**
promise constant memory or lower memory use for every JSON shape.

## What this fork adds

| Capability | What it enables |
| --- | --- |
| Mutable JSON proxies | Read and assign fields without decoding untouched sibling values. |
| Copy-on-write forks | Create independent request variants that share immutable source data. |
| Bounded JSON reader | Emit original spans and changed values in chunks, and calculate the encoded length without building a complete output string. |
| File-backed decoding | Validate and access a file through bounded windows instead of reading the whole file into Lua. |
| Incremental input | Feed incoming chunks into a parser and owned disk spool. Final values become available after complete validation. |
| Native OpenResty adapter | Receive memory/file/request-socket input and send readers through lua-resty-http, with explicit cancellation and error handling. |
| Explicit resource ownership | Close holders deterministically; independently held children, forks and readers keep their source alive. |

The JSON core does not depend on `ngx`. OpenResty integration is isolated in
`leanjson.openresty`.

## Install from source

The renamed package has **not yet been published to LuaRocks**. Install from
this fork's development branch; pin a commit for reproducible deployments:

```sh
git clone --branch feat/openresty-json-source https://github.com/GYWang1983/lua-leanjson.git
cd lua-leanjson
luarocks --lua-version=5.1 make rockspec/lua-leanjson-scm-1.rockspec
```

Building requires Rust/Cargo and LuaRocks configured for LuaJIT's Lua 5.1 ABI.
The pinned verification environment uses Rust 1.90 and OpenResty LuaJIT.
Standard PUC Lua is not supported: the library requires LuaJIT FFI.

Rust is a **build-time dependency only**. Runtime deployments need LuaJIT,
`leanjson.so` and the installed `leanjson.lua` / `leanjson/` modules. The supplied
[OpenResty Docker example](examples/openresty/README.md) builds and copies the
native library and Lua modules into a runtime image without Rust.

If using a raw Cargo build rather than a LuaRocks installation, make
`libleanjson.so` (Linux) or `libleanjson.dylib` (macOS) discoverable by the FFI
loader. For example, Linux development uses `LD_LIBRARY_PATH=target/release`.

## Read, change and fork a document

```lua
local json = require "leanjson"

local body = json.decode([[{
  "model": "public-model",
  "stream": true,
  "messages": [{"role": "user", "content": "Hello"}]
}]])

print(body.model)                  -- public-model
local variant = json.fork(body)
variant.model = "provider-model"  -- body.model stays public-model
variant.stream = false

local encoded = json.encode(variant)
json.close(variant)
json.close(body)
print(encoded)
```

`encode()` is convenient for small results but allocates the complete output
string. For large results, consume a reader instead. `materialize()` explicitly
creates ordinary Lua values; reserve it for consumers that require them.

## Rewrite a file without assembling the output

This example keeps the original file as its source, changes `model`, and writes
chunks of at most 64 KiB to standard output. Cleanup covers ordinary errors as
well as successful completion.

```lua
local json = require "leanjson"
local body, variant, reader

local ok, err = pcall(function()
    body = json.decode_file("request.json", { chunk_size = 65536 })
    variant = json.fork(body)
    variant.model = "provider-model"
    json.close(body)
    body = nil

    reader = json.reader(variant, {
        chunk_size = 65536,
        normalize_duplicates = true,
    })
    json.close(variant)             -- the reader owns its snapshot
    variant = nil

    while true do
        local chunk, read_err = reader:next()
        if read_err then error(read_err) end
        if chunk == nil then break end
        assert(io.write(chunk))
    end
end)

if reader then reader:close() end
json.close(variant)
json.close(body)
if not ok then error(err) end
```

`reader:length()` returns the actual encoded byte count or `nil, error`, without
advancing output. `next()` returns `nil, nil` at EOF and `nil, error` on failure.
It completes validation/counting before returning its first chunk. Do not turn
reader errors into ordinary EOF when integrating with an HTTP client.

The input file must stay immutable while holders use it. LeanJSON closes its
file descriptor when the final holder releases it; it never deletes an
original input file. Incremental decoder spools are owned by LeanJSON and are
removed after their final holder closes.

## Native OpenResty integration

```lua
local input = require "leanjson.openresty"
```

- `input.read_body(opts)` waits for Nginx to receive the body, then uses its
  memory buffer or temporary file.
- `input.start_body(opts)` can receive and scan chunks while a fixed-length
  HTTP/1.1 upload is arriving. HTTP/2 and chunked uploads use the completed-body
  fallback. The current decoder publishes final query values only after EOF
  and full validation; this is not early forwarding of an incomplete JSON body.
- `input.request(httpc, request, value, opts)` sends bounded JSON chunks through
  lua-resty-http, sets the encoded Content-Length, and preserves reader errors.
  It makes one attempt and does not retry automatically.

The [complete handler](examples/openresty/handler.lua) covers client aborts,
source errors, holder cleanup and connection cleanup. Configure
`lua_check_client_abort on`, register cleanup before operations that may yield,
and close each independently owned container view, fork and reader. Closing
only the root intentionally leaves independently held children alive.

Run the reproducible example from a committed checkout:

```sh
scripts/build-openresty-image.sh HEAD lua-leanjson-openresty:local
scripts/verify-openresty-image.sh lua-leanjson-openresty:local
docker run --rm -p 8080:8080 -v leanjson-body:/tmp/leanjson-body lua-leanjson-openresty:local
```

Then, from another terminal:

```sh
curl --data-binary '{"model":"public-model","prompt":"hello"}' http://localhost:8080/
```

The example forwards to a local test sink. See the [deployment instructions](examples/openresty/README.md)
for buffering, disk storage, upstream settings and cancellation behavior.

## Measured advantages and current limits

A recorded native OpenResty benchmark of this fork, **before the LeanJSON
rename and final ownership/policy fixes**, measured these process RSS high-water
marks under the same input, concurrency and branch count:

| Workload | lua-cjson | This fork's measured baseline |
| --- | ---: | ---: |
| 8 MiB prompt dominated by a long string | 73.8 MiB | 15.1 MiB |
| 8 MiB nested messages with long content | 73.8 MiB | 14.9 MiB |
| 32,768 short objects, about 0.9 MiB input | 45.9 MiB | 254.3 MiB |

The long-string cases used much less memory but had **higher latency and lower
throughput**. Many short objects were substantially worse in both memory and
CPU. These historical measurements are not timings of the renamed revision or
a production guarantee. The [full verification report](docs/verification/openresty-json-source.md)
records commits, hardware, methodology, latency, throughput and limitations;
[raw measurements](docs/verification/openresty-json-source-benchmarks.jsonl)
retain their original qjson labels for traceability.

Additional boundaries:

- File I/O is synchronous. Bounded buffers and yields do not make disk access
  asynchronous; storage latency can still delay an OpenResty worker.
- This is not a transparent drop-in replacement for lua-cjson. Use
  `leanjson.encode` for proxies, or explicitly materialize for other encoders.
- Native `next`, `rawget` and `rawset` bypass proxy behavior. Use
  `json.pairs`, `json.ipairs` and `json.len`; these also work on stock LuaJIT
  without Lua 5.2 compatibility support.
- Proxy arrays stay dense. Use `array_insert` / `array_remove` for structural
  changes. `nil` deletes a field; `json.null` represents JSON null.
- Concurrent mutations on the same branch may report a stale-mutation conflict
  across a yield. Use independent forks or handle the conflict explicitly.
- The core follows strict validation by default. File/incremental Source APIs
  require complete validation; the inherited low-level `parse` API also has
  an explicitly opt-in lazy-validation mode.

## Compatibility and migration

All current public names use the new namespace:

| Surface | LeanJSON name |
| --- | --- |
| Repository / LuaRocks package | `lua-leanjson` |
| Lua module / OpenResty adapter | `leanjson` / `leanjson.openresty` |
| Rust crate / native library | `leanjson` / `libleanjson` |
| C header / exported symbols | `include/leanjson.h` / `leanjson_*` |
| Environment variables | `LEANJSON_*` |

There is no `qjson` compatibility alias. Applications using this fork's old
name must update imports and build/package references; C callers must use the
new header and rebuild against the new library. Upstream qjson remains a
separate project and package.

## Verification and contributing

The canonical full gate builds Rust modes, checks Clippy/Lua lint, runs the Lua
suite and extended properties, replays JSON corpora, and exercises real native
OpenResty HTTP paths including cancellation and resource cleanup:

```sh
git submodule update --init --recursive
make openresty-dev-image
make openresty-docker-test
```

`make help` lists focused build, test and benchmark commands. CI additionally
checks Linux/macOS, multiple OpenResty versions, installed packaging, fuzz
corpus replay and memory tooling. Test results describe their recorded revision;
see the [CI runs](https://github.com/GYWang1983/lua-leanjson/actions/workflows/ci.yml)
for the current branch.

- [Proxy, mutation and reader API](docs/source-proxy-api.md)
- [File/incremental input and ownership](docs/file-source-api.md)
- [OpenResty APIs, verification and benchmarks](docs/verification/openresty-json-source.md)
- [Migrating from lua-cjson](docs/migrating-from-cjson.md)
- [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md) · [License](LICENSE)
