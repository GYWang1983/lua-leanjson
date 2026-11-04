#!/usr/bin/env bash
# Build the downloaded source rock, then verify the installed binary package.
set -euo pipefail
version=${1:?release version required}
expected_arch=${2:?LuaRocks architecture required}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$(getconf GNU_LIBC_VERSION)" == 'glibc 2.35' ]]
[[ "$(luarocks config arch)" == "$expected_arch" ]]
repo=$PWD
output=$repo/dist
prefix=lua-leanjson-$version-1
build_tree=${RUNNER_TEMP:?}/leanjson-build-tree
runtime_tree=$RUNNER_TEMP/leanjson-runtime-tree
luarocks --lua-version=5.1 --tree "$build_tree" install "$output/$prefix.src.rock"
lib=$build_tree/lib/lua/5.1/leanjson.so
readelf -h "$lib" | rg 'Class:.*ELF64|Machine:'
readelf --version-info "$lib" > "$RUNNER_TEMP/leanjson-elf-versions.txt"
python3 - "$RUNNER_TEMP/leanjson-elf-versions.txt" <<'PY'
from pathlib import Path
import re
import sys
versions = [tuple(map(int, value.split('.'))) for value in
            re.findall(r'GLIBC_([0-9]+\.[0-9]+(?:\.[0-9]+)?)', Path(sys.argv[1]).read_text())]
if not versions or max(versions) > (2, 35):
    raise SystemExit('Unsupported GLIBC requirements: ' + repr(sorted(set(versions))))
print('Maximum required GLIBC:', '.'.join(map(str, max(versions))))
PY
ldd "$lib" > "$RUNNER_TEMP/leanjson-ldd.txt"
cat "$RUNNER_TEMP/leanjson-ldd.txt"
if rg 'not found' "$RUNNER_TEMP/leanjson-ldd.txt"; then exit 1; fi
(
    cd "$output"
    luarocks --lua-version=5.1 --tree "$build_tree" pack lua-leanjson "$version-1"
)
# Only an installed .rock is used below; Cargo is outside this PATH.
env PATH=/usr/bin:/bin /usr/bin/luarocks --lua-version=5.1 --tree "$runtime_tree" \
    install "$output/$prefix.$expected_arch.rock"
(
    cd "$RUNNER_TEMP"
    env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH \
        PATH=/usr/bin:/bin \
        LUA_PATH="$runtime_tree/share/lua/5.1/?.lua;$runtime_tree/share/lua/5.1/?/init.lua" \
        LUA_CPATH="$runtime_tree/lib/lua/5.1/?.so" \
        /usr/bin/luajit "$repo/.github/scripts/installed-package-smoke.lua"
)
# Also exercise the exact library in a Rust-free, glibc 2.35 OpenResty runtime.
docker run --rm --network none --read-only --tmpfs /tmp \
    -v "$runtime_tree:/opt/leanjson:ro" \
    -v "$repo/.github/scripts/installed-package-smoke.lua:/opt/smoke.lua:ro" \
    -e LUA_PATH='/opt/leanjson/share/lua/5.1/?.lua;/opt/leanjson/share/lua/5.1/?/init.lua' \
    -e LUA_CPATH='/opt/leanjson/lib/lua/5.1/?.so' \
    --entrypoint /usr/local/openresty/luajit/bin/luajit \
    openresty/openresty:1.29.2.4-0-jammy@sha256:0a887716d1bc7a3d38e6a765e4c9df31a4b4e27473fc30def6601511330c7f2f \
    /opt/smoke.lua
{
    printf 'commit=%s\nversion=%s\narch=%s\n' "$GITHUB_SHA" "$version" "$expected_arch"
    getconf GNU_LIBC_VERSION
    rustc --version
    cargo --version
    cat "$RUNNER_TEMP/leanjson-ldd.txt"
    sha256sum "$lib" "$output/$prefix.$expected_arch.rock"
} > "$output/build-info.$expected_arch.txt"
