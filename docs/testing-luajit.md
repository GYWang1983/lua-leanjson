# LuaJIT compatibility and Memcheck

Build the current library, install the Lua test dependencies, and select the
actual runtime explicitly. The runner keeps JIT compilation disabled in both
the suite and child fixtures, traces child processes, and preserves failing
exit codes. It invokes Busted's Lua entrypoint directly in that runtime,
avoiding LuaRocks launcher probes and re-exec. It also checks every captured
Memcheck summary so an ignored child diagnostic still fails the gate.
It writes command lines, source/runtime/library hashes, suite
output, per-process Memcheck logs and exit codes to the output directory.
Each invocation gets a fresh `run.XXXXXX` subdirectory containing its own
`runtime.txt`, `source-sha256.txt` and profile directories. Reusing an output
root preserves earlier identities and diagnostics, including concurrent runs.

```sh
make build
LUAJIT_BIN=/usr/bin/luajit \
  LEANJSON_VERIFY_OUTPUT=/tmp/leanjson-distro-check \
  scripts/verify-luajit.sh all
```

`plain` and `memcheck` run one profile. Additional arguments select Busted spec
paths. `VALGRIND_BIN` and `LEANJSON_LIBRARY_DIR` can select an explicit checker
or an isolated library build. Keep the LuaRocks installation on
`LUA_PATH` and `LUA_CPATH` when the selected LuaJIT has a different prefix.
The runtime's normal module paths are otherwise preserved.

## Debug symbols for Ubuntu Jammy ARM64 LuaJIT

The package `luajit 2.1.0~beta3+dfsg-6ubuntu0.1` has executable SHA-256
`5a52407336f5f614633c32d14b84c3cb83b0c93ea70ff9b32b7ff98431aa2b3b`
and build ID `c532105f1b77eb8e57e777c684b290e7b54c5ede`.
Install its matching debug symbols before running Memcheck:

```sh
curl --fail --location \
  https://debuginfod.ubuntu.com/buildid/c532105f1b77eb8e57e777c684b290e7b54c5ede/debuginfo \
  -o /tmp/luajit-c532105.debug
echo '3bc684d8122cc5a89050b4a21aecba4f7d068b2d5bfcf46901e1080942dd456b  /tmp/luajit-c532105.debug' | sha256sum -c -
sudo install -Dm644 /tmp/luajit-c532105.debug \
  /usr/lib/debug/.build-id/c5/32105f1b77eb8e57e777c684b290e7b54c5ede.debug
```

For another executable, use its own build ID and matching debug package.
Do not reuse these symbols merely because its version string matches.
A container can mount the matching file read-only at the same debug path.

The runner uses `--read-inline-info=no` so Memcheck reports physical frames.
This leaves instruction checking enabled. In Valgrind 3.18.1, this distro
binary's optimized string interning otherwise reports an unnamed inline
frame above `lj_str_new`, preventing the existing named suppression from
matching. Matching symbols and physical frames let the existing
`LuaJIT optimized string compare Cond lj_str_new` rule apply without changing
the runtime or adding a suppression. The original source reads up to three
bytes past a string's logical end and masks the final partial word; a
module-free `string.gsub` control reproduces the same warning.

## Check that real errors still fail

This intentionally invalid FFI write must exit **1** and produce
`Invalid write of size 1` in its Memcheck log:

```sh
LUAJIT_BIN=/usr/bin/luajit \
  LEANJSON_VERIFY_OUTPUT=/tmp/leanjson-negative-check \
  scripts/verify-luajit.sh negative-control
```

The negative fixture is excluded from the ordinary Busted suite. A zero exit
from this control means the checker has not verified its failure path.

Three table `__len` cases are explicitly pending on LuaJIT builds without
`LUAJIT_ENABLE_LUA52COMPAT`; the portable `leanjson.len` tests still run.
Likewise, native `ipairs` behavior follows the runtime's metamethod support,
while `leanjson.ipairs` checks empty-object traversal and closed ownership on
both table and userdata carriers. These are the documented portable APIs.
