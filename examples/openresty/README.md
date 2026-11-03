# Native OpenResty example

This example uses the independent `leanjson` module and native OpenResty. It receives and validates a JSON object, forks it, rewrites `model`, and sends bounded output to a local HTTP sink. The sink hashes/counts chunks without assembling the body. Full validation precedes opening the upstream connection. The example makes one upstream attempt.

Build a runtime image from a committed fork revision:

```sh
scripts/build-openresty-image.sh HEAD lua-leanjson-openresty:local
scripts/verify-openresty-image.sh lua-leanjson-openresty:local
docker run --rm -p 8080:8080 -v leanjson-body:/tmp/leanjson-body lua-leanjson-openresty:local
curl -i --data-binary '{"model":"original","prompt":"hello"}' http://localhost:8080/
curl -i --data-binary '{"model":"original","prompt":"hello"}' http://localhost:8080/incremental
```

The builder archives the exact resolved 40-character commit, excluding uncommitted edits, and records it in the image revision label. The Dockerfile pins native OpenResty 1.29.2.4 and Rust 1.90.0 by manifest digest. The runtime stage contains the library, Lua modules, and lua-resty-http 0.17.2; Rust is confined to build/dev stages. Preserve the included Apache-2.0 license.

The image verification script checks installed-module loading, absence of Rust, memory/file/incremental HTTP input, exact rewritten length/SHA256, malformed-input rejection, and clean Nginx startup. It starts and removes a private container with an anonymous disk volume and does not publish a port.

`client_body_buffer_size 64k` selects buffering; it is separate from the 256 MiB example request limit. Larger completed requests use Nginx disk files. Use a disk-backed Docker volume for `/tmp/leanjson-body`, size its budget for concurrent uploads, and monitor it. This path must not be mounted as tmpfs for memory experiments. The library retains a file descriptor rather than relying on Nginx's temporary pathname. Nginx owns and cleans its original files.

`/incremental` uses a sole request-socket reader only for HTTP/1.1 requests with a Content-Length and no Transfer-Encoding. HTTP/2 and chunked uploads use the completed-body adapter. `X-LEANJSON-Input-Mode` reports the actual path. The incremental producer does not mix request sockets with `ngx.req.read_body`. The current decoder publishes queried fields only after `finish()` and full validation; the example then connects upstream.

The handler registers application-holder abort cleanup before its first mutation and protects the whole mutation/connection/response path with error unwind. It closes independently owned forks, input ownership and the HTTP client on normal completion, ordinary errors and cancellation. An abort callback alone would not cover an ordinary source or connection error.

To use another test upstream, set `LEANJSON_UPSTREAM_HOST` and `LEANJSON_UPSTREAM_PORT`. The sink response reports encoded byte length and SHA256; it intentionally does not echo or parse a large request. The example accepts JSON objects; it does not implement application routing, authentication, schema validation, or retry policy.

File reads are synchronous bounded reads with Lua yields between chunks. They do not become asynchronous disk I/O. Measure worker delay on the intended storage before using this adapter in a latency-sensitive service.

See the [complete verification report](../../docs/verification/full-verification.md)
for native acceptance, installed-image checks and measured limits. The
[source API](../../docs/file-source-api.md) and
[proxy/reader API](../../docs/source-proxy-api.md) describe ownership and errors.
