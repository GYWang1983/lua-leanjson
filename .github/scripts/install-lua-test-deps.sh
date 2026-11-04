#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y lua5.1 liblua5.1-0-dev luarocks

# Ubuntu LuaRocks targets Lua 5.1 by default; LuaJIT is ABI-compatible
# with 5.1 so rocks built for 5.1 load fine under each runtime.
sudo /usr/bin/luarocks install busted 2.2.0-1

# Match the verification report: the pinned OpenResty cjson reference exposes
# comment/array settings that the unrelated LuaRocks lua-cjson package lacks.
make -C vendor/lua-cjson LUA_INCLUDE_DIR=/usr/include/lua5.1

# Busted --lpath changes only its own VM. Child fixtures need inherited paths.
if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'LUA_PATH=%s/lua/?.lua;;\n' "$GITHUB_WORKSPACE" >> "$GITHUB_ENV"
    printf 'LUA_CPATH=%s/vendor/lua-cjson/?.so;;\n' "$GITHUB_WORKSPACE" >> "$GITHUB_ENV"
fi
