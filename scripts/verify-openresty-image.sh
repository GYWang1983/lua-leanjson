#!/usr/bin/env bash
set -euo pipefail
image=${1:?Usage: verify-openresty-image.sh IMAGE}
repo=$(cd "$(dirname "$0")/.." && pwd)
container=$(docker run --rm --detach --mount type=volume,target=/tmp/leanjson-body \
    --mount "type=bind,source=$repo/tests/openresty/image-smoke.lua,target=/verify.lua,readonly" "$image")
cleanup() { docker rm --force "$container" > /dev/null 2>&1 || true; }
trap cleanup EXIT
for attempt in {1..100}; do
    if docker exec "$container" curl --silent --max-time 1 http://127.0.0.1:8080/ > /dev/null 2>&1; then break; fi
    sleep 0.05
done
docker exec "$container" sh -c '! command -v cargo && ! command -v rustc'
docker exec "$container" /usr/local/openresty/bin/resty -I /opt/leanjson/lua /verify.lua
logs=$(docker logs "$container" 2>&1)
if [[ "$logs" =~ \[(alert|emerg)\] ]]; then
    printf '%s\n' "$logs" >&2
    exit 1
fi
docker image inspect "$image" --format 'runtime image {{.Id}} source {{index .Config.Labels "org.opencontainers.image.revision"}}'
