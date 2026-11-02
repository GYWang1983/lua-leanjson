#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
export LD_LIBRARY_PATH="$repo/target/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LEANJSON_PROP_CASES=${LEANJSON_PROP_CASES:-2000}
export LEANJSON_MUT_PROP_CASES=${LEANJSON_MUT_PROP_CASES:-1000}
export LEANJSON_MUT_PROP_STEPS=${LEANJSON_MUT_PROP_STEPS:-100}
for path in tests/vendor/JSONTestSuite/test_parsing tests/vendor/cJSON/tests tests/vendor/simdjson/jsonexamples; do
    test -d "$path" || { echo "Missing pinned submodule $path; run git submodule update --init --recursive" >&2; exit 1; }
done
cargo test --locked --release
cargo test --locked --release --no-default-features
cargo test --locked --release --features test-panic
cargo clippy --locked --release --all-targets -- -D warnings
cargo build --locked --release
make test lua-lint lua-property-test lua-mutation-property-test openresty-source-stress openresty-source-corpus
"$repo/scripts/verify-openresty.sh"
