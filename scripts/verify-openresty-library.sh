#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
export LD_LIBRARY_PATH="$repo/target/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QJSON_PROP_CASES=${QJSON_PROP_CASES:-2000}
export QJSON_MUT_PROP_CASES=${QJSON_MUT_PROP_CASES:-1000}
export QJSON_MUT_PROP_STEPS=${QJSON_MUT_PROP_STEPS:-100}
for path in tests/vendor/JSONTestSuite/test_parsing tests/vendor/cJSON/tests tests/vendor/simdjson/jsonexamples; do
    test -d "$path" || { echo "Missing pinned submodule $path; run git submodule update --init --recursive" >&2; exit 1; }
done
cargo test --locked --release
cargo test --locked --release --no-default-features
cargo test --locked --release --features test-panic
cargo clippy --locked --release --all-targets -- -D warnings
cargo build --locked --release
make test lua-lint lua-property-test lua-mutation-property-test
"$repo/scripts/verify-openresty.sh"
