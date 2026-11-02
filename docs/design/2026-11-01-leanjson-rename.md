# LeanJSON rename and project presentation

The user selected `lua-leanjson` and requested a rewritten README, code changes by a subagent, and a GitHub repository rename. This is a naming/package migration; JSON behavior stays unchanged.

- Project/repository/rock: `lua-leanjson`; display name: LeanJSON; module and Rust crate/library: `leanjson`; C ABI/header: `leanjson_*`, `LEANJSON_*`, `include/leanjson.h`; environment names: `LEANJSON_*`.
- Native OpenResty adapter: `leanjson.openresty`. Do not add qjson compatibility aliases: the fork receives its own namespace and may coexist with upstream qjson.
- Keep upstream attribution and Apache-2.0 license; `https://github.com/api7/lua-qjson` remains the upstream source. Preserve historical benchmark raw records and commit attribution rather than relabeling past measurements.
- Rewrite README in English for public distribution, stating the fork origin, additions, large-payload memory use case, clear API examples, installation from the current branch, native OpenResty deployment, compatibility, resource cleanup, verification and limitations. Do not claim universal memory/throughput improvements, early final query values, zero-copy operation, asynchronous file I/O, or current LuaRocks publication.
- Use a development rockspec (`lua-leanjson-scm-1.rockspec`) pointing to this fork/branch; do not reference an uncreated release tag or publish a rock/release in this task.
- After validation and review, rename the personal fork to `GYWang1983/lua-leanjson`, update origin and repository description, push the existing `feat/openresty-json-source` branch and make it the default so the project homepage shows the delivered implementation. Preserve upstream remote, main/history/tags, local checkout path and unrelated worktrees.

Alternatives considered: package-only rename would leave namespace collisions and inconsistent instructions; backward-compatible qjson shims would retain ambiguity. A consistent separate namespace is the selected approach, following the naming accepted by the user. Existing users must change imports/FFI names and rebuild.
