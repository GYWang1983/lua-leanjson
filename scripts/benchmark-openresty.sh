#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
# Every method/scenario gets a new worker; HWM never carries over from its pair.
for scenario in ${LEANJSON_BENCH_CASES:-prompt input messages escaped short-elements explicit cold}; do
    for method in cjson leanjson; do
        LEANJSON_BENCH_CASE="$scenario" LEANJSON_BENCH_METHOD="$method" LEANJSON_RUN_MODE=benchmark \
            "$repo/scripts/verify-openresty.sh"
    done
done
