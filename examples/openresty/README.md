# Native OpenResty example

This example uses the independent `qjson` module and native OpenResty. It receives and validates a JSON object, forks it, rewrites `model`, and sends bounded output to a local HTTP sink. The sink hashes/counts chunks without assembling the body. Full validation precedes opening the upstream connection. The example makes one upstream attempt.

Build a runtime image from a committed fork revision:

```sh
scripts/build-openresty-image.sh HEAD lua-qjson-openresty:local
docker run --rm -p 8080:8080 -v qjson-body:/tmp/qjson-body lua-qjson-openresty:local
curl -i --data-binary '{"model":"original","prompt":"hello"}' http://localhost:8080/
curl -i --data-binary '{"model":"original","prompt":"hello"}' http://localhost:8080/incremental
```

The builder archives the exact resolved 40-character commit, excluding uncommitted edits, and records it in the image revision label. The Dockerfile pins native OpenResty 1.29.2.4 and Rust 1.90.0 by manifest digest. The runtime stage contains the library, Lua modules, and lua-resty-http 0.17.2; Rust is confined to build/dev stages. Preserve the included Apache-2.0 license.

`client_body_buffer_size 64k` selects buffering; it is separate from the 256 MiB example request limit. Larger completed requests use Nginx disk files. Use a disk-backed Docker volume for `/tmp/qjson-body`, size its budget for concurrent uploads, and monitor it. This path must not be mounted as tmpfs for memory experiments. The library retains a file descriptor rather than relying on Nginx's temporary pathname. Nginx owns and cleans its original files.

`/incremental` uses a sole request-socket reader only for HTTP/1.1 requests with a Content-Length and no Transfer-Encoding. HTTP/2 and chunked uploads use the completed-body adapter. `X-QJSON-Input-Mode` reports the actual path. The incremental producer does not mix request sockets with `ngx.req.read_body`, and `finish()` still completes before forwarding. A query for a last-wins field may wait until its containing object closes or the decoder finishes.

To use another test upstream, set `QJSON_UPSTREAM_HOST` and `QJSON_UPSTREAM_PORT`. The sink response reports encoded byte length and SHA256; it intentionally does not echo or parse a large request. The example accepts JSON objects; it does not implement application routing, authentication, schema validation, or retry policy.

File reads are synchronous bounded reads with Lua yields between chunks. They do not become asynchronous disk I/O. Measure worker delay on the intended storage before using this adapter in a latency-sensitive service.

See [verification and API details](../../docs/verification/openresty-json-source.md) for native acceptance tests, benchmarks, ownership, and error-state reporting.
