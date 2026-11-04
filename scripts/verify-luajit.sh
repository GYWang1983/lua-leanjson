#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
mode=${1:-all}
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in
    all|plain|memcheck|negative-control) ;;
    *) echo "Usage: $0 [all|plain|memcheck|negative-control] [Busted spec paths...]" >&2; exit 2 ;;
esac
export LUAJIT_BIN
LUAJIT_BIN=$(command -v "${LUAJIT_BIN:-luajit}")
export LUA_INIT='if jit then jit.off() end'
export LD_LIBRARY_PATH="${LEANJSON_LIBRARY_DIR:-$repo/target/release}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
output=${LEANJSON_VERIFY_OUTPUT:-$repo/target/luajit-verification}
mkdir -p "$output"
output=$(cd "$output" && pwd)
output=$(mktemp -d "$output/run.XXXXXX")
printf 'Verification artifacts: %s\n' "$output"
specs=("$@")
if [[ ${#specs[@]} == 0 ]]; then specs=(tests/lua); fi
if command -v sha256sum >/dev/null 2>&1; then hash=(sha256sum); else hash=(shasum -a 256); fi
{
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git rev-parse HEAD; fi
    "$LUAJIT_BIN" -v
    "${hash[@]}" "$LUAJIT_BIN" "${LEANJSON_LIBRARY_DIR:-$repo/target/release}/libleanjson.so" valgrind.supp
} > "$output/runtime.txt" 2>&1
shopt -s nullglob
{
    if command -v rg >/dev/null 2>&1; then
        rg --files -0 src lua include tests/lua -g '*.rs' -g '*.lua' -g '*.h'
    else
        find src lua include tests/lua -type f \( -name '*.rs' -o -name '*.lua' -o -name '*.h' \) -print0
    fi
    printf '%s\0' scripts/verify-luajit.sh scripts/run-busted.lua scripts/check-memcheck.awk valgrind.supp
} | xargs -0 "${hash[@]}" > "$output/source-sha256.txt"

run() {
    local profile=$1 status log
    local directory="$output/$profile"
    mkdir -p "$directory"
    local command=("$LUAJIT_BIN" "$repo/scripts/run-busted.lua" "${specs[@]}" "--lpath=$repo/lua/?.lua")
    if [[ "$profile" != plain ]]; then
        local valgrind
        valgrind=$(command -v "${VALGRIND_BIN:-valgrind}")
        "$valgrind" --version > "$directory/valgrind-version.txt"
        if [[ "$profile" == negative-control ]]; then
            command=("$LUAJIT_BIN" tests/lua/fixtures/valgrind_invalid_write.lua)
        fi
        command=("$valgrind" --trace-children=yes --error-exitcode=1 --leak-check=full
            --show-leak-kinds=definite,indirect,possible --errors-for-leak-kinds=definite,indirect,possible
            --num-callers=24 --read-inline-info=no -s "--suppressions=$repo/valgrind.supp"
            "--log-file=$directory/memcheck.%p.log" "${command[@]}")
    fi
    printf '%q ' "${command[@]}" > "$directory/command.txt"
    printf '\n' >> "$directory/command.txt"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$directory/started-at.txt"
    set +e
    "${command[@]}" 2>&1 | tee "$directory/suite.log"
    status=${PIPESTATUS[0]}
    set -e
    if [[ "$profile" != plain && "$status" == 0 ]]; then
        local logs=("$directory"/memcheck.*.log)
        # Launchers can ignore a child exit; its Memcheck diagnostics must
        # still fail the gate. Missing summaries are not evidence of a pass.
        if [[ ${#logs[@]} == 0 ]]; then status=1; fi
        for log in "${logs[@]}"; do
            if ! awk -f "$repo/scripts/check-memcheck.awk" "$log"; then status=1; break; fi
        done
    fi
    printf '%s\n' "$status" > "$directory/exit-code.txt"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$directory/finished-at.txt"
    return "$status"
}

if [[ "$mode" == all ]]; then
    result=0
    if run plain; then :; else result=1; fi
    if run memcheck; then :; else result=1; fi
    exit "$result"
fi
run "$mode"
