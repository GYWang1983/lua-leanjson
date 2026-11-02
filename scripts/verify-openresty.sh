#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
nginx=${NGINX:-/usr/local/openresty/nginx/sbin/nginx}
resty=${RESTY:-/usr/local/openresty/bin/resty}
export LEANJSON_TEST_PORT=${LEANJSON_TEST_PORT:-19841}
export LEANJSON_SINK_PORT=${LEANJSON_SINK_PORT:-19842}
export LEANJSON_TEST_PREFIX
LEANJSON_TEST_PREFIX=$(mktemp -d "${TMPDIR:-/tmp}/leanjson-openresty.XXXXXX")
export LD_LIBRARY_PATH="$repo/target/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LUA_PATH="$repo/lua/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;"
worker_pid= sink_pid=
cleanup() {
    [[ -z "$worker_pid" ]] || kill "$worker_pid" 2>/dev/null || true
    [[ -z "$sink_pid" ]] || kill "$sink_pid" 2>/dev/null || true
    [[ -z "$worker_pid" ]] || wait "$worker_pid" 2>/dev/null || true
    [[ -z "$sink_pid" ]] || wait "$sink_pid" 2>/dev/null || true
    if [[ ${LEANJSON_KEEP_TEST_OUTPUT:-0} == 1 ]]; then
        echo "OpenResty artifacts: $LEANJSON_TEST_PREFIX"
    else
        rm -rf "$LEANJSON_TEST_PREFIX"
    fi
}
trap cleanup EXIT
mkdir -p "$LEANJSON_TEST_PREFIX/client-body" "$LEANJSON_TEST_PREFIX/logs" "$LEANJSON_TEST_PREFIX/decoder"
chmod 777 "$LEANJSON_TEST_PREFIX" "$LEANJSON_TEST_PREFIX/client-body" "$LEANJSON_TEST_PREFIX/decoder"
for config in nginx sink; do
    sed -e "s|@ROOT@|$repo|g" -e "s|@PREFIX@|$LEANJSON_TEST_PREFIX|g" \
        -e "s|@PORT@|$LEANJSON_TEST_PORT|g" -e "s|@SINK_PORT@|$LEANJSON_SINK_PORT|g" \
        "$repo/tests/openresty/$config.conf.in" > "$LEANJSON_TEST_PREFIX/$config.conf"
done
"$nginx" -p "$LEANJSON_TEST_PREFIX/" -c "$LEANJSON_TEST_PREFIX/sink.conf" &
sink_pid=$!
"$nginx" -p "$LEANJSON_TEST_PREFIX/" -c "$LEANJSON_TEST_PREFIX/nginx.conf" &
worker_pid=$!
for attempt in {1..100}; do
    if curl -fsS "http://127.0.0.1:$LEANJSON_TEST_PORT/health" > "$LEANJSON_TEST_PREFIX/health.json" 2>/dev/null && \
        curl -fsS "http://127.0.0.1:$LEANJSON_SINK_PORT/stats" > /dev/null 2>&1; then break; fi
    sleep 0.05
done
test_script=acceptance.lua
if [[ ${LEANJSON_RUN_MODE:-acceptance} == benchmark ]]; then test_script=benchmark.lua; fi
if ! "$resty" -I "$repo/tests/openresty" "$repo/tests/openresty/$test_script"; then
    cat "$LEANJSON_TEST_PREFIX/error.log" >&2
    exit 1
fi
