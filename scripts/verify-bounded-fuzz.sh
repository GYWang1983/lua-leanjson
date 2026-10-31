#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
# A separate nightly gate. Never silently replace libFuzzer with a smoke test.
seconds=${QJSON_FUZZ_SECONDS:-30}
for target in fuzz_parse_eager fuzz_parse_lazy fuzz_ffi_ops fuzz_depth fuzz_numbers; do
    cargo +nightly fuzz run "$target" -- -max_total_time="$seconds" -seed=760076 -max_len=1048576
done
