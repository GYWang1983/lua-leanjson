#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
# A separate nightly gate. Never silently replace libFuzzer with a smoke test.
seconds=${QJSON_FUZZ_SECONDS:-30}
output_dir=${QJSON_FUZZ_OUTPUT_DIR:-${TMPDIR:-/tmp}}
mkdir -p "$output_dir"
scratch=$(mktemp -d "$output_dir/qjson-fuzz.XXXXXX")
cleanup() {
    local result=$?
    if [[ "$result" != 0 || ${QJSON_KEEP_FUZZ_OUTPUT:-0} == 1 ]]; then echo "Fuzz artifacts: $scratch";
    else rm -rf "$scratch"; fi
}
trap cleanup EXIT
for target in fuzz_parse_eager fuzz_parse_lazy fuzz_ffi_ops fuzz_depth fuzz_numbers fuzz_source_windows; do
    mkdir -p "$scratch/corpus/$target" "$scratch/artifacts/$target"
    seed_dir="$repo/fuzz/corpus/$target"
    max_len=1048576
    if [[ "$target" == fuzz_source_windows ]]; then
        seed_dir="$repo/fuzz/corpus/fuzz_parse_eager"
        max_len=16384
    fi
    if [[ -d "$seed_dir" ]]; then cp -R "$seed_dir/." "$scratch/corpus/$target/"; fi
    cargo +nightly fuzz run "$target" "$scratch/corpus/$target" -- \
        -max_total_time="$seconds" -seed=760076 -max_len="$max_len" \
        -artifact_prefix="$scratch/artifacts/$target/"
done
