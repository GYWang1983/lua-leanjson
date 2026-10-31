#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
# Every method/scenario gets a new worker; HWM never carries over from its pair.
for scenario in ${QJSON_BENCH_CASES:-prompt input messages escaped short-elements explicit cold}; do
    for method in cjson qjson; do
        QJSON_BENCH_CASE="$scenario" QJSON_BENCH_METHOD="$method" QJSON_RUN_MODE=benchmark \
            "$repo/scripts/verify-openresty.sh"
    done
done
