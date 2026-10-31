#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
nginx=${NGINX:-/usr/local/openresty/nginx/sbin/nginx}
resty=${RESTY:-/usr/local/openresty/bin/resty}
export QJSON_TEST_PORT=${QJSON_TEST_PORT:-19841}
export QJSON_SINK_PORT=${QJSON_SINK_PORT:-19842}
export QJSON_TEST_PREFIX
QJSON_TEST_PREFIX=$(mktemp -d "${TMPDIR:-/tmp}/qjson-openresty.XXXXXX")
export LD_LIBRARY_PATH="$repo/target/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LUA_PATH="$repo/lua/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;"
worker_pid= sink_pid=
cleanup() {
    [[ -z "$worker_pid" ]] || kill "$worker_pid" 2>/dev/null || true
    [[ -z "$sink_pid" ]] || kill "$sink_pid" 2>/dev/null || true
    [[ -z "$worker_pid" ]] || wait "$worker_pid" 2>/dev/null || true
    [[ -z "$sink_pid" ]] || wait "$sink_pid" 2>/dev/null || true
    if [[ ${QJSON_KEEP_TEST_OUTPUT:-0} == 1 ]]; then
        echo "OpenResty artifacts: $QJSON_TEST_PREFIX"
    else
        rm -rf "$QJSON_TEST_PREFIX"
    fi
}
trap cleanup EXIT
mkdir -p "$QJSON_TEST_PREFIX/client-body" "$QJSON_TEST_PREFIX/logs" "$QJSON_TEST_PREFIX/decoder"
chmod 777 "$QJSON_TEST_PREFIX" "$QJSON_TEST_PREFIX/client-body" "$QJSON_TEST_PREFIX/decoder"
for config in nginx sink; do
    sed -e "s|@ROOT@|$repo|g" -e "s|@PREFIX@|$QJSON_TEST_PREFIX|g" \
        -e "s|@PORT@|$QJSON_TEST_PORT|g" -e "s|@SINK_PORT@|$QJSON_SINK_PORT|g" \
        "$repo/tests/openresty/$config.conf.in" > "$QJSON_TEST_PREFIX/$config.conf"
done
"$nginx" -p "$QJSON_TEST_PREFIX/" -c "$QJSON_TEST_PREFIX/sink.conf" &
sink_pid=$!
"$nginx" -p "$QJSON_TEST_PREFIX/" -c "$QJSON_TEST_PREFIX/nginx.conf" &
worker_pid=$!
for attempt in {1..100}; do
    if curl -fsS "http://127.0.0.1:$QJSON_TEST_PORT/health" > "$QJSON_TEST_PREFIX/health.json" 2>/dev/null && \
        curl -fsS "http://127.0.0.1:$QJSON_SINK_PORT/stats" > /dev/null 2>&1; then break; fi
    sleep 0.05
done
if ! "$resty" "$repo/tests/openresty/acceptance.lua"; then
    cat "$QJSON_TEST_PREFIX/error.log" >&2
    exit 1
fi
