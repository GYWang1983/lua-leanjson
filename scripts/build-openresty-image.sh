#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
revision=$(git -C "$repo" rev-parse --verify "${1:-HEAD}^{commit}")
tag=${2:-lua-qjson-openresty:${revision:0:12}}
context=$(mktemp -d "${TMPDIR:-/tmp}/qjson-image.XXXXXX")
trap 'rm -rf "$context"' EXIT
# Only committed files from one exact fork revision enter the build context.
git -C "$repo" archive "$revision" | tar -x -C "$context"
docker build --file "$context/examples/openresty/Dockerfile" \
    --build-arg "QJSON_REVISION=$revision" --target runtime --tag "$tag" "$context"
echo "Built $tag from $revision"
