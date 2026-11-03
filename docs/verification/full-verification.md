# Lua-LeanJSON 完整验证报告

验证日期：2026-11-03。验证代码：`33d00b522d87cc760f757404186488453ffcb498`。

本轮由执行子代理运行，另一个子代理独立审查覆盖与原始结果，主代理核对证据并整理文档。当前工作分支为 `verify/full-suite-2026-11-03`。首次全量验证只修改报告及其文档引用，没有修改运行时代码、测试断言或通过阈值；后续脚本修订见下一节。

## V01–V03 脚本修订与复验（2026-11-03）

根据用户确认，V01/V02 修正测试脚本；V03 的三类已接受行为记录为 `expected_difference`，不作为验收不通过项。本节为首次全量报告之后的更新，基于相同 runtime commit `33d00b5` 加当前工作区的脚本补丁。`src/`、`lua/`、`include/` 无修改；以下旧基线与两份原归档保持原样，不将过去的非零退出改写成通过。

| 项目 | 修正 | 本次结果 |
| --- | --- | --- |
| V01 | corpus 使用独立 codec，明确关闭非标准数字、开启 UTF-8 校验，保留库的兼容默认值 | 原样 `make openresty-source-corpus` 退出 0；318 文件满足预期，覆盖 file 与两种 feed 分块 |
| V02 | 删除已不存在的 pooled `:parse()` 场景与误判逻辑；当前增量 `new_decoder()` 不冒充 pooled parser | `make bench-smoke` 退出 0；另跑 10 MiB smoke、小输入计时场景均退出 0 |
| V03 | 精确识别品牌、lazy 数组语义、userdata 载体三类差异，保留原始断言、值、类型与错误 | 两种 carrier 的完整 9 格 `--strict` 均退出 0；`accepted=true`、`compatible=false`；未声明差异为 0 |
| 完整总入口 | 原样执行 `make openresty-verify`，使用已存在的独立 TMPDIR | 退出 0：Rust 444 / 444 / 445，Lua 802，HTTP 72，lint、属性、stress、corpus 均通过；其中 `make test` 重跑 Rust 444，不加作独立覆盖 |
| 适配器检查 | 新增允许范围、内容/容器种类损坏、移除策略、配置/safe 回放及 cycle 观测检查 | 22/22 通过；修改前的预期失败与首次适配失败日志均保留 |

V02 的默认 smoke 覆盖 small、medium、github-100k、100k 和 interleaved；10 MiB 是额外的单场景检查。小输入计时用于确认计时路径可执行，缺少可选 simdjson 模块的行明确跳过；本轮未执行全部场景的正式性能比较，也不把这些结果当成性能提升证明。

V03 的允许策略与原始兼容性结论分开，详见[适配器说明](../../tests/upstream-cjson/README.md)：

- `module_identity`：仅允许 `test.lua:L94` 返回 `leanjson` 与当前 Cargo 版本；字段缺失、错误名称/版本不放行。
- `lazy_array_semantics`：仅允许 lazy/preload 的 `TEST12/13/14` 中空数组保持 `[]`，以及数组拒绝 hash 字段的指定错误；其他输出或异常不放行。
- `userdata_carrier`：17 个 direct decode、9 个 cycle 记录及 selective 的类型差异。除去载体后必须保持内容、返回数量、标量字节和值；通过独立 native shape 观测校验嵌套 object/array 种类，不能把 `{}`/`[]` 转换错误归为载体差异。

shape 观测与 cycle 内容检查都发生在原始上游比较之后，不提前物化代理来影响原生结果。cycle 保留输入 JSON 的容器种类，而不要求复刻 cjson 重编码时将无标记空数组变成对象的行为。允许策略表实际参与判定；删除一个策略项会恢复该差异的失败状态。

| carrier / 加载模式 | 每种输入的 exact pass | 预期差异 | 未声明差异 |
| --- | ---: | ---: | ---: |
| table / lazy、preload | 156 | 4 | 0 |
| table / eager | 159 | 1 | 0 |
| userdata / lazy、preload | 130 | 30 | 0 |
| userdata / eager | 159 | 1 | 0 |

每种输入均指 memory/file/feed；每格另有 3 个 setup helper、1 个环境不适用记录。主矩阵合计 2,952 条记录，其中 2,670 条适用断言 exact pass、210 条预期差异、54 条 helper、18 条环境不适用。210 条预期差异由品牌 18、数组 36、载体 156 构成，**不计入 exact pass 数**。

同时修复 selective 回放此前未应用实际 codec 配置和 safe 路径的问题：现在从原生调用捕获实例的四个 decode 配置与 safe/normal 路径，用新实例执行回放。table 每种输入 80 pass；userdata 每种输入 41 pass + 39 条载体预期差异，三种输入共 480 条。保留完整输出/roundtrip 诊断，它不额外假设原生默认数字精度完全无损。

首次总入口复跑因本次执行包装指定了尚未创建的 TMPDIR，出现 4 条 Rust 临时文件测试失败：`fingerprint_collision_still_compares_full_decoded_keys`、`held_workspace_does_not_accumulate_historical_traversal_regions`、`legacy_fnv_bucket_keys_have_linear_insertion_and_rehash_work`、`legacy_fnv_bucket_keys_have_linear_current_lookup_work`（均在 `source::duplicates::tests`）。创建该目录后，原命令完整重跑通过。首次 controls 运行还暴露手工 replay fixture 未补齐新增配置字段，影响 `test_real_worker_detects_differences_missing_api_failed_setup_and_malformed_input` 和 `test_reusing_output_keeps_only_the_current_invocation_status`；补齐 fixture 后全部通过。这些日志与红/绿阶段均保留，没有删除失败尝试。

复验证据：[V01–V03 证据归档](v01-v03-fixes-evidence.tar.gz)，33,521,157 字节，4,925 个内容文件，SHA-256 `b35a2d73764f87ce11ea509768482a311209a39c46a00327398c6ba7c2649e50`。归档含源码补丁与快照、精确命令/退出码、最终双矩阵和 controls、原总入口及 benchmark 输出、HTTP artifacts、独立审查记录和内部校验清单；外部 [SHA256SUMS](SHA256SUMS) 同时校验更新后的报告。目录 `matrix-*-final/`、`controls-final/` 是最终复验，较早目录为修正过程证据。

本次只处理 V01–V03。原报告的 eager 内存代价、distro LuaJIT / Valgrind 问题、x86_64 ASan 和 OpenResty 1.27 覆盖缺口仍保留；没有重新执行这些平台检查或 122 组 RSS 对比。

## 首次全量基线的结论与验收边界（以下保留修正前证据）

**不能将这一版本标为“全量测试全部通过”或“完全兼容 cjson”。** 核心 Rust/Lua、真实 HTTP、有限样本的配对内存验证通过；canonical 总入口和旧 benchmark smoke 存在确定的失败。cjson 严格矩阵保留了设计上有意存在的行为差异。扩展检查结果见后文。

- 主环境 OpenResty 1.29 ARM64 的 Lua Busted 全套：802 项通过；真实 HTTP：72 项通过。
- 配对内存：122/122 通过，涵盖 table/userdata、memory/file/feed、默认/零/小预算、双分支以及 16 MiB 长文本。它只说明这些样本满足阈值，不证明任意输入始终不超过 cjson。
- eager/preload 加载：36/36 个进程单元通过语义检查。**这不是 36 项内存上限通过**：eager 的实测峰值明显高于 cjson。
- cjson：两种 carrier 各 9 个完整单元，每单元 164 条记录；`--strict` 均退出 1，harness 健康，无 unsupported 分类。精确差异与额外 selective 检查均保留。
- `make openresty-verify` 在 source corpus 处失败；显式严格策略的补充运行通过，但不改变原命令失败的结论。
- `make bench-smoke` 在已过时的 pooled decoder 调用处失败。本轮不引用旧吞吐/HTTP 延迟数字作为当前性能证据。
- 扩展 distro LuaJIT beta3 的非插桩完整运行仍有 7 fail / 3 pending；Valgrind 运行另有失败和告警。x86_64 ASan、OpenResty 1.27 因环境准备受阻而未执行测试。

## 版本、环境与证据身份

主验证环境为 macOS 27.0 ARM64 宿主上的 OrbStack Linux ARM64 容器。Docker 29.8.2、宿主 Python 3.9.6。容器为 OpenResty 1.29.2.4 / resty 0.29，LuaJIT 2.1.ROLLING（`LUAJIT_ENABLE_LUA52COMPAT`）、Rust/Cargo 1.90.0、GCC 11.4.0、Busted 2.2.0、Luacheck 1.2.0、LuaRocks 3.13.0。精确输出见 `primary/provenance.txt`。

| 对象 | 固定身份 |
| --- | --- |
| 测试镜像 `lua-qjson-dev:task3-repro` | `sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47` |
| 本轮构建的运行镜像 `lua-leanjson-openresty:full-20261103` | `sha256:08294519e73845acd28009b157a30e8e32dc2706c2037abf6b8449cb6244e7dc` |
| 主验证 `libleanjson.so` SHA-256 | `8bf0d9f2eedf09c39e8f1aa023c58851ae486ef0172dbdfd442096c01ec38c0b` |
| 上游 lua-cjson 子模块 | `617164a0fe3bb647128178f9caefb304b8573bb6` |
| JSONTestSuite 子模块 | `1ef36fa01286573e846ac449e8683f8833c5b26a` |
| cJSON 子模块 | `fb16e5cf358798aabb049655975cde8427101056` |
| simdjson 子模块 | `43766fc7efdedc87111c48bda55f758ca212335b` |

测试镜像的历史标签不是被测代码版本。测试使用当前 checkout 的 Lua 与重新确认的 release 库；运行镜像则通过精确 Git commit 的归档构建。首次全量验证期间，文档清理使工作区显示 dirty，但 177 个运行时/测试/构建文件的开始与结束指纹经核对一致，且没有运行时代码 diff。

两个 cjson 参照必须区分：兼容性矩阵从上述固定子模块独立编译，table/userdata 两次参考库的 SHA-256 分别为 `c7b4036f73d3472fb21d4308bc676d04bd7face8748e8377c7e1220de3805f07`、`a6ffb2398282a4724beb37df983a23cd3a9798838f8ef78452456fd7838dc106`；内存/加载测试使用镜像安装的 native cjson，实际加载 `/usr/local/openresty/lualib/cjson.so`，版本 `2.1.0.11`，SHA-256 为 `8825abcf6fca35d18d274d66ff850bd7a6d935e4552fc0bb4e19eff8b3705dab`。不能仅凭相同 `_VERSION` 把它们当成同一个二进制。

## 核心功能与真实 HTTP

| 检查 | 结果 | 证据/说明 |
| --- | --- | --- |
| Rust release default | PASS：444 项 | `canonical.log`；`make test` 内重复 444 项，不能当成额外独立覆盖 |
| Rust release scalar | PASS：444 项 | `--no-default-features` |
| Rust release panic barrier | PASS：445 项 | `--features test-panic` |
| Rust debug scalar | PASS：444 项 | `debug-scalar.log` |
| Clippy release all-targets | PASS | `-D warnings` |
| Lua Busted | PASS：802 项 | 0 failure/error/pending |
| Luacheck | PASS：89 个文件 | 0 warning/error |
| 编码 / mutation 属性 | PASS：2 / 17 个 test | 下述样本数；不与 802 相加当作独立用例 |
| source stress | PASS | 500 valid + 500 mutated |
| canonical source corpus | **FAIL** | V01，导致总入口退出 2 |
| 显式严格策略 source corpus | PASS：318 个文件 | 独立诊断运行；95 valid / 188 invalid / 35 implementation-defined |
| 实际 OpenResty HTTP | PASS：72 项 | 独立继续执行，不被总入口提前退出漏掉 |
| memory runner Python controls | PASS：4 项 | `test-verify-memory.log` |
| cjson adapter Python controls | PASS：12 项 | `cjson-controls.log`，含固定元测试输出 |
| benchmark smoke | **FAIL** | V02，无当前 benchmark 结果 |
| 隔离安装的 Linux LuaRocks 包 | PASS（包装纠正后） | 从 `/tmp` 加载，清除库环境变量，安装树 smoke；首个 setup 错误保留 |
| 精确 commit 运行镜像构建/验证 | PASS | revision 标签等于被测 commit；未发布镜像 |

编码属性测试使用 2,000 个样本；mutation 属性测试使用 1,000 个样本，每个 100 步。source stress 为 500 个合法 + 500 个变异输入，seed `760076`。这些是有限、可复现的压力样本。

真实 HTTP 的 72 项覆盖：table/userdata，preload/eager，内存/完成文件/增量/回退路径，精确长度输出，迟到重复键，非法 JSON 不向上游产生副作用，HTTP/1.1 chunked 与 HTTP/2 回退，客户端/上游断开，扫描/输出中取消，源文件读写故障，多等待者唤醒、fork 和文件 lease 回收。完整 TAP 及 Nginx 配置/日志保留在 `primary/actual-http.log` 与 `primary/tmp-http/`。它是本地测试 sink 的验收，不涉及 Kong 或真实 LLM Provider。

## cjson 完整兼容性矩阵

每个单元保留 164 条上游记录：160 条适用断言、3 条 setup helper、1 条环境不适用的条件记录。表中的“通过/差异”只统计 160 条适用断言；没有把 helper 或条件空操作加进通过数。每行的三种输入结果一致，完整逐条记录仍分别保存。

| carrier | 加载模式 | memory 通过/差异 | file 通过/差异 | feed 通过/差异 |
| --- | --- | ---: | ---: | ---: |
| table | lazy | 156 / 4 | 156 / 4 | 156 / 4 |
| table | eager (`lazyload=false`) | 159 / 1 | 159 / 1 | 159 / 1 |
| table | preload | 156 / 4 | 156 / 4 | 156 / 4 |
| userdata | lazy | 130 / 30 | 130 / 30 | 130 / 30 |
| userdata | eager | 159 / 1 | 159 / 1 | 159 / 1 |
| userdata | preload | 130 / 30 | 130 / 30 | 130 / 30 |

共 2,952 条主矩阵记录（2 × 9 × 164），不是 2,952 个不同测试。每种 carrier 的 native 基线另跑 164 条记录，结果为 160 pass + 3 setup + 1 environment-inapplicable。native cjson 在 LeanJSON bootstrap 阶段被显式禁止加载，避免用回退实现掩盖差异。

差异记录与原因：

| 适用模式 | 记录 ID | 原因 |
| --- | --- | --- |
| 所有主矩阵模式 | `test.lua:L94` | 项目按要求使用 `_NAME="leanjson"` / `_VERSION="0.1.0"`，参照为 `cjson` / `2.1.0.11`；不伪装名称 |
| table/userdata 的 lazy/preload | `agentzh.t:TEST12/13/14` | `array_mt` 与保持代理数组身份的语义差异；eager 对齐普通值行为 |
| userdata 的 lazy/preload | 9 个 `decode-cycle:*` | 上游 cycle 逻辑依赖原生 Lua table；userdata 返回使原生断言为 false |
| userdata 的 lazy/preload | 17 个 direct decode 记录 | 逻辑内容相符，但原生比较器要求 table，实际返回 userdata |

9 个 cycle 文件：`example1.json` 至 `example5.json`、`numbers.json`、`rfc-example1.json`、`rfc-example2.json`、`types.json`。17 个 direct decode ID：`test.lua:L101,L110,L113,L116,L161,L167,L224,L226,L228,L231,L339,L341,L345,L347,L349,L351,L410`。

selective replay 不重放完整 setup/settings。其 table 的 18 个差异包括深度策略 2 个、数字策略 5 个、注释/诊断 9 个、safe 错误形状/诊断 2 个；userdata 另有 33 个 carrier 相关差异。它们不能解释为“已经修复的配置 API 又失效”。精确 ID 和 raw verdict 见归档中的 `coverage-results-audit.md` 与两份 `selective/`。

本矩阵只覆盖固定 OpenResty lua-cjson 分支的上游用例，不能穷举所有 Lua/C API 输入。严格策略、原生崩溃或非法输出等主动保留的边界，仍需结合[兼容性修复清单](../design/cjson-compatibility-fixes.md)和[迁移说明](../migrating-from-cjson.md)阅读。

额外 selective replay 每种输入 80 条：table 为 62 pass / 18 difference，userdata 为 29 pass / 51 difference，合计 480 条诊断记录。这不是另一套完整 164 项矩阵，也不能用其 logical pass 覆盖原始 upstream exact verdict。

三种输入覆盖并不意味着每条 settings/encode-only 测试都会经过 decode。每个主单元实际 decode 的上游 case 为 71 个、decode 调用为 80 次。原始记录保留 Lua 类型、配置变化、原生判断、逻辑诊断及输出 roundtrip 的完成/未完成状态。

## 配对内存与加载模式

### 方法与覆盖

内存阈值为每个配对的 `LeanJSON process peak RSS <= native cjson process peak RSS`，未使用 report-only，也未提高阈值。每个 cell 启动新的 native OpenResty 进程，顺序执行，无并发请求；测量阶段不强制 GC；输入生成与结果 oracle 在进程外完成。保留峰值 RSS、Lua heap 采样、CPU、source/input/output SHA-256、语义 oracle、参数、运行镜像与库指纹。

输入模式分别为持有完整字符串的 memory、完成文件 file、分块 feed。RSS 包含 LuaJIT、native 库及进程开销，不仅是 Lua heap。宿主仍运行原有服务，未为了测量停止它们；样本不提供统计置信区间。预设内存测试的默认深度与数组索引限制均为 3，预算 1 MiB，直接修改、不 fork。

| 配置 | table | userdata | 每种 carrier 的覆盖 |
| --- | ---: | ---: | --- |
| 默认 | 33/33 | 33/33 | 11 场景 × 3 输入 |
| 16 MiB 长文本 | 6/6 | 6/6 | prompt/messages × 3 输入 |
| index_budget_bytes=0 | 9/9 | 9/9 | 3 宽容器场景 × 3 输入 |
| index_budget_bytes=1024 | 9/9 | 9/9 | 3 宽容器场景 × 3 输入 |
| branches=2 | 4/4 | 4/4 | short-elements/wide-objects × file/feed |

默认 11 场景包括 8 个形状和 far/scan/scan-auto 访问变体。长文本默认约 1 MiB；short-elements、wide-objects、wide-scalars 使用 32,768 个条目。16 MiB 测试是另加的 12 对，没有混入默认 66 对。

### 默认 66 对完整结果

单位为 MiB；每种 carrier 使用各自独立的 cjson 进程作基线，因此两组 cjson 数字不必相同。

| 场景 / 输入 | cjson（table 组） | table | cjson（userdata 组） | userdata |
| --- | ---: | ---: | ---: | ---: |
| short-elements / memory | 18.64 | 15.20 | 18.55 | 15.11 |
| short-elements / file | 18.64 | 13.96 | 18.61 | 13.93 |
| short-elements / feed | 18.63 | 13.98 | 18.61 | 14.03 |
| wide-objects / memory | 23.20 | 17.68 | 23.12 | 17.68 |
| wide-objects / file | 23.17 | 15.14 | 23.12 | 15.05 |
| wide-objects / feed | 23.19 | 14.98 | 23.13 | 14.78 |
| wide-scalars / memory | 15.91 | 15.76 | 15.83 | 15.82 |
| wide-scalars / file | 15.87 | 15.03 | 15.80 | 15.11 |
| wide-scalars / feed | 15.92 | 15.04 | 15.88 | 15.32 |
| duplicate-tail / memory | 19.73 | 18.04 | 19.78 | 18.07 |
| duplicate-tail / file | 19.63 | 14.67 | 19.77 | 14.80 |
| duplicate-tail / feed | 19.64 | 14.52 | 19.72 | 14.64 |
| wide-duplicates / memory | 27.90 | 22.53 | 27.95 | 22.68 |
| wide-duplicates / file | 27.88 | 15.54 | 27.98 | 15.55 |
| wide-duplicates / feed | 27.86 | 15.25 | 27.96 | 15.39 |
| deep-objects / memory | 41.91 | 18.44 | 42.00 | 18.50 |
| deep-objects / file | 41.91 | 14.68 | 41.96 | 14.77 |
| deep-objects / feed | 41.88 | 14.12 | 41.99 | 14.38 |
| prompt / memory | 16.14 | 14.10 | 16.20 | 14.19 |
| prompt / file | 16.14 | 13.05 | 16.23 | 13.14 |
| prompt / feed | 16.11 | 13.10 | 16.25 | 13.25 |
| messages / memory | 16.10 | 14.14 | 16.16 | 14.23 |
| messages / file | 16.09 | 13.22 | 16.24 | 13.31 |
| messages / feed | 16.11 | 13.24 | 16.21 | 13.50 |
| short-elements:far / memory | 18.61 | 15.14 | 18.70 | 15.20 |
| short-elements:far / file | 18.57 | 13.93 | 18.68 | 14.12 |
| short-elements:far / feed | 18.61 | 13.95 | 18.67 | 14.13 |
| wide-objects:scan / memory | 23.25 | 18.39 | 23.32 | 18.50 |
| wide-objects:scan / file | 23.22 | 15.83 | 23.32 | 15.51 |
| wide-objects:scan / feed | 23.27 | 15.58 | 23.33 | 15.59 |
| wide-objects:scan-auto / memory | 23.21 | 19.23 | 23.34 | 19.48 |
| wide-objects:scan-auto / file | 23.27 | 16.70 | 23.35 | 16.81 |
| wide-objects:scan-auto / feed | 23.23 | 16.65 | 23.31 | 16.95 |

最紧张的样本为 userdata / wide-scalars / memory：cjson `16,212 KiB`，LeanJSON `16,196 KiB`，仅低 **16 KiB**（ratio `0.999013`）。table 同场景低 156 KiB。该裕量不足以证明在不同分配器、运行时或系统状态下总能通过。

16 MiB prompt 的 table 组中，cjson/file 为 91.23 MiB，LeanJSON/file 为 15.50 MiB；userdata 组为 91.18 / 15.25 MiB。memory 模式仍需保留原始内容，约为 44 MiB，不能按文件模式的数字估算其内存。

### eager/preload：语义通过与内存代价分开

每种 carrier 的 18 个单元为 3 场景 × 3 输入 × 2 实现，合计 36 个进程单元、18 对比较。`wide` 测 eager 普通值和完整 encode；`selected` / `wildcards` 测强制 preload、未选字段后读及完整输出。通过条件包括 oracle、eager 普通值类型和已预加载读取不再触发 source callback；**没有“RSS 不得超过 cjson”的判定**。

以下为完成文件输入；`wide` 输入 1,168,670 字节，另两个输入 4,486,310 字节。CPU 是进程内工作量计时，不是 HTTP p50。

| carrier / 场景 | cjson RSS MiB | LeanJSON RSS MiB | cjson CPU 秒 | LeanJSON CPU 秒 |
| --- | ---: | ---: | ---: | ---: |
| table / wide (eager) | 24.34 | 49.29 | 0.020444 | 0.191547 |
| table / selected (preload) | 34.43 | 14.65 | 0.013668 | 0.491871 |
| table / wildcards (preload) | 36.49 | 20.34 | 0.014013 | 0.470512 |
| userdata / wide (eager) | 24.30 | 46.39 | 0.018974 | 0.211095 |
| userdata / selected (preload) | 36.48 | 14.74 | 0.016218 | 0.555886 |
| userdata / wildcards (preload) | 34.40 | 20.36 | 0.016555 | 0.483599 |

关闭 lazy 是普通 Lua 值兼容模式，不承诺 cjson 的内存或速度。preload 选中字段会绕过索引预算，选择整个大子树也可能大量物化。即使 lazy 的 RSS 更低，也存在 CPU 成本：默认 table / wide-objects / file 的完整工作量为 LeanJSON 0.896806 秒、cjson 0.014293 秒；16 MiB prompt/file 为 0.946203 / 0.037164 秒。同步文件操作仍会占用 OpenResty worker；本轮没有建立生产吞吐或延迟保证。

## 扩展环境、模糊测试与内存安全

本节的测试与 RSS 测量分开执行。native macOS 与 Linux 工具使用独立 target/安装树，不共享可写的主测量产物。构建缓存及工具链不作为测试通过证据。

| 检查 | 结果 | 范围与限制 |
| --- | --- | --- |
| 原生 macOS 27.0 ARM64 Rust | PASS：444 / 444 / 445 | release default / scalar / test-panic；均 0 failed / ignored |
| 原生 macOS Clippy | PASS | `-D warnings`，0 warning/error |
| 原生 macOS 隔离安装 smoke | PASS | checkout 之外运行，实际从隔离 rock tree 加载，LD/DYLD 库路径清空 |
| Linux bounded fuzz | PASS：6 目标 | 每目标预算 30 秒，实际约 31 秒；无 crash artifact，不是无限时长验证 |
| corpus replay | PASS：6 次 | depth / ffi_ops 无预置语料，各只有 2 次初始化运行 |
| Miri scalar | PASS：12 次调用、57 项 | x86_64 / i686 / powerpc64 各 4 个测试文件、19 项；0 failed / ignored |
| ARM64 ASan | PASS：3 次调用、11 项 | `ffi_smoke` 6、`ffi_strings` 3、`ffi_ops_interleave` 2；无 advisory 放行 |
| x86_64 ASan | **BUILD BLOCKED**：3 次退出 101 | ARM64 容器的 `cc` 不支持 `-m64`，链接阶段失败，0 项测试执行；不由 ARM64 或 Miri 结果替代 |
| `cargo audit` | PASS | cargo-audit 0.22.2；1,403 条 RustSec advisory、117 个依赖 |

macOS 使用 task-local Rust/Cargo 1.90.0、LuaJIT `v2.1` commit `ea9eb7edb5eac4a9d175d74523db34fac0fa5180`（运行时 `2.1.1793383622`）及 LuaRocks 3.13.0。安装后的 native module SHA-256 为 `65a84e3e6150bad2aec13cbaba69279ff7549f190bdbb679df289606be480cdb`。`MACOSX_DEPLOYMENT_TARGET=13.0` 是构建参数；本轮只在 macOS 27.0 实际运行，不代表验证了 macOS 13。此前扩展子代理还执行过一次独立的 `+dfsg` beta3 来源 smoke，其来源说明单独保留，不声称与 upstream Git tag 或 CI 完全相同。没有在 macOS 上跑完整 802 项 Busted 或真实 OpenResty HTTP。

Linux fuzz/Miri/ASan 使用镜像 `lua-qjson-dev:fuzz`，ID `sha256:c4c8f06d4c8552c7d91a01da676966d4975d801efc1fb7a55dbb0887a37951c5`，Rust nightly `1.101.0-nightly (31d3246e0 2026-10-27)`、cargo-fuzz 0.13.2。源代码来自固定 HEAD 的可写归档副本；生成的 fuzz lockfile独立保存，没有修改仓库的 lockfile。Miri 显式关闭 default features，属于解释器下的标量验证，不是原生 x86/32 位/大端硬件或 SIMD 执行证明。

| fuzz 目标 | bounded run 次数 | replay 预置语料 / 执行次数 |
| --- | ---: | ---: |
| `fuzz_parse_eager` | 1,779,887 | 296 / 297 |
| `fuzz_parse_lazy` | 32,172 | 13 / 14 |
| `fuzz_ffi_ops` | 4,515,515 | 0 / 2 |
| `fuzz_depth` | 66,803 | 0 / 2 |
| `fuzz_numbers` | 2,255,702 | 10 / 11 |
| `fuzz_source_windows` | 165,557 | 296 / 297 |

run 次数不是互不重复的测试输入数，也不作为吞吐 benchmark。source windows 使用 `max_len=16384`；其他目标使用 wrapper 的上限，固定 seed `760076`。本轮生成 6,016 个 corpus 文件，未生成 crash artifact。无语料的两个 replay 只验证了初始化路径，其有效压力覆盖来自各自的限时 fuzz。

RustSec 数据库固定为 `6c5fedf8ff03c485ed674d8f941e0180f3f72d70`，数据库 commit 时间 `2026-11-03T10:44:19+01:00`，网络审计记录时间 `2026-11-03T10:45:09Z`。先保存结构化审计，再单独执行 literal `cargo audit`，均保留输出。结论限于该锁文件和数据库快照，不代表未来没有新 advisory。

### LuaJIT / Valgrind 与同环境对照

| 实际环境与执行 | Busted 结果 | Memcheck / 命令结果 |
| --- | --- | --- |
| OpenResty rolling LuaJIT，JIT 关闭 | 802 pass / 0 fail / 0 pending | 所有记录的摘要均为 0 error，definite/indirect/possible lost 均为 0；后续 shell 把 `--lpath` 误当命令，外层退出 **127**，不记为命令通过 |
| Ubuntu Jammy distro beta3，Valgrind | 785 pass / 14 fail / 3 pending | 主测试进程 PID 382：4,044,609 errors / 28 contexts，未记录 definite/indirect/possible lost；子进程另有错误；退出 **1** |
| 同 distro beta3，不加载 LeanJSON/cjson 的最小对照 | 不执行 Busted | 1 个 LuaJIT 未初始化值错误，全部 heap block 释放，退出 **1** |
| 同 distro beta3，无 Valgrind、JIT 关闭 | 792 pass / 7 fail / 3 pending | 完整功能套件退出 **1** |

上述零 lost 类别不等于退出时零保留内存：部分进程仍记录 `still reachable`，完整数值保存在原日志。

测试的 distro 包为 `luajit 2.1.0~beta3+dfsg-6ubuntu0.1`，Valgrind 3.18.1，Linux ARM64。它缺少 `LUAJIT_ENABLE_LUA52COMPAT`，因此三条 `__len` 用例 pending。上游 beta3 tag/archive 在此次获取时不可用，未取得精确上游源码构建；distro 包结果不能标成上游 tag 的等价结果。

无 Valgrind 时仍失败的 7 项如下，保留为实际运行时兼容性缺口；没有用 OpenResty rolling 的通过结果覆盖它们：

| 用例 | 实际值 / 差异 |
| --- | --- |
| `cjson_external_arrays_spec.lua:77` | 嵌入 NUL 的外部长度转换：`["a","b"]`，期望 `[]` |
| `cjson_settings_spec.lua:27` | 负零格式化：`0`，期望 `-0` |
| `cjson_source_numeric_bytes_spec.lua:119` | 数值转换符号：`Inf`，期望 `-Inf` |
| `strict_userdata_spec.lua:160`，closed table | native `ipairs` 未产生期望的关闭状态错误 |
| `strict_userdata_spec.lua:149`，空 userdata object | native `ipairs` 拒绝 userdata，测试期望空遍历 |
| 同上，字符串键 `"1"` 的 object | 同样因 userdata 类型被拒绝 |
| `strict_userdata_spec.lua:160`，closed userdata | native `ipairs` 先产生类型错误，与测试期望不同 |

Valgrind 下增加的 marker/metamethod、loading、shutdown 和 missing-factory 失败另保留在完整日志；深度 spill 子进程还记录 `ulimit` 权限错误。最小对照只证明运行时自身可触发一个 Memcheck 警告，**不能据此认定完整套件的数百万条错误都是误报，也不能宣称通过内存安全验收**。没有新增 suppression、修改断言或屏蔽失败。

精确命令、包版本、原 suppression 指纹、原始日志 SHA-256 见扩展归档 `runtime-memory-tools/receipts.json`。首次大规模 apt 安装在测试前停滞并被终止，其命令和退出记录保留，但一次终端原始输出被后续包装覆盖，未能恢复；报告不声称所有失败尝试均有完整原始日志。

### 固定 OpenResty 版本覆盖

| 版本 / 镜像 | 覆盖与结果 |
| --- | --- |
| 官方 `1.21.4.4-0-jammy` | 原样执行 `run-openresty-runtime.sh` smoke；19 个断言，退出 0；不是完整 Busted |
| 官方 `1.27.1.2-0-jammy` | ARM64 manifest 可读取；120 秒与 300 秒限时拉取均未完成镜像提交，**未执行测试** |
| `1.29.2.4` 开发镜像 `1a287857…` | 复用本轮主验证的 802 Busted / 72 HTTP；与官方 base 的前四层及 resty、LuaJIT executable/library、nginx 的散列一致，但额外层不同 |
| 精确 commit 运行镜像 `08294519…` | 单独完成 4 个 length/SHA smoke 检查及非法输入拒绝；不是上述 802/72 的执行镜像 |

1.29 的结论是同运行时的开发镜像证据，没有另跑官方 stock 镜像的完整套件，也不声称两个镜像整体相同。1.27 的失败属于环境准备阻塞，没有替换成其他版本冒充通过。镜像 ID、manifest digest、实际 binary hash 和命令保存在 `runtime-profiles/receipts.json` 及 `evidence/dev-vs-public-1.29-comparison.md`。

## 失败、补充运行与待处理项

| 编号 | 原始结果 | 解释与处置边界 |
| --- | --- | --- |
| V01 | `make openresty-verify` 退出 2；`source-corpus.lua:33` 接受 `n_number_+1.json` | corpus 要求严格 JSON，但脚本使用当前兼容 cjson 的宽松默认。未修改原脚本。显式设置 `decode_invalid_numbers(false)` 和 `decode_validate_utf8(true)` 的诊断运行通过：95 valid、188 invalid、35 implementation-defined（11 接受/24 拒绝），分别走 file 与 17/65536 字节 feed。该次原总入口为 FAIL；后续修正与复验见前文 V01–V03 更新。 |
| V02 | `make bench-smoke` 退出 2；`lua_bench.lua:670` 调用不存在的 `pooled_decoder:parse` | benchmark 的 pooled API 探测仍把当前增量 `new_decoder` 当成旧 pooled parser。首次验证未修改脚本或以其他测试代替 benchmark 成功；后续 V02 修正已复验通过。 |
| V03 | 两个 cjson `--strict` 退出 1 | 有意的品牌、lazy 数组及 userdata 类型差异；harness 健康，与脚本执行失败分开。 |
| V04 | eager 内存高于 cjson；最差默认 lazy 样本仅余 16 KiB | 功能检查通过不等于内存目标对所有模式、所有输入成立。需要在目标业务输入和部署平台继续评估。 |

扩展检查另保留以下环境覆盖与 setup 记录：

- **V05：x86_64 ASan 未完成。** 三个命令严格退出 101，根因是当前 ARM64 容器缺少相应交叉链接器，尚未运行测试；后续需要在合适的 x86_64 sanitizer 环境补验。
- 首次 fuzz 尝试把源码挂载为只读，Cargo 无法写 `fuzz/Cargo.lock`，未进入 fuzz；改用固定 HEAD 的可写任务副本后六目标完成。最初复制的 297 个 seed 文件不是 crash 文件。
- 首次 Miri 等待交互安装 rust-src，取消前未完成测试；显式安装组件后 12 个目标/测试组合完成。
- 原生 LuaJIT 首次构建缺少 `MACOSX_DEPLOYMENT_TARGET`，在编译前失败；为隔离构建明确设置 13.0 后通过。另有一次任务交接时取消的 native Rust 调用，未作为失败测试或通过测试计数。

- **V06：distro LuaJIT 兼容性与 Memcheck 尚未通过。** 非插桩完整运行为 7 fail / 3 pending，插桩运行为 14 fail / 3 pending，并有 Memcheck 报错。需分别定位运行时语义、子进程环境与 native 内存检查问题；最小无模块对照不足以免除完整套件的告警。
- **V07：OpenResty 1.27 环境准备受阻。** 指定镜像未拉取完成，没有执行 smoke/full suite。1.21 仅 smoke，1.29 复用同运行时开发镜像结果；不能将版本矩阵写为全绿。
- **V08：rolling Valgrind 执行包装退出 127。** 已观察到 802 项通过、Memcheck 摘要干净，但测试之后的 shell 命令拼接失败。记录这一有限结论，不把外层非零退出改写为通过。

执行包装自身也出现过错误，均保留原记录：canonical 外层 zsh 使用只读变量 `status`，内部 make 的退出 2 可从日志确认；首次安装 smoke 的诊断打印对 boolean 做字符串拼接，在 smoke 开始前失败，修正临时包装后完整重跑；运行镜像验证已成功后，外层 `docker inspect` 的引号转义有误，另行补记正确元数据。它们没有被包装为产品 bug，也没有删除首次失败。

本轮是验证与整理，不包含上述问题的运行时代码修复。没有以反复重跑直至通过的方式改变结论。

## 复现与证据导航

本目录保留以下交付物；首次全量的两个归档各含内部 `SHA256SUMS`，外部 [SHA256SUMS](SHA256SUMS) 校验报告及归档本身。

| 交付物 | 大小 / 内容文件数 | SHA-256 |
| --- | --- | --- |
| [主验证证据](full-verification-primary-evidence.tar.gz) | 17,642,272 字节 / 2,570 个 | `77aea26436ad83fec617436a88ef0a3782d9b8678fe97e4c962d9ba09d028c29` |
| [扩展验证证据](full-verification-extended-evidence.tar.gz) | 1,863,542 字节 / 6,254 个 | `68968f66b45de528e36991741d8ace1990199e68022cba8a59ec59522e8323b3` |

文件数不含归档内部的校验清单。已逐文件读回验证 SHA-256，并检查主矩阵中的 case 集合、分类与输出引用；源代码快照与最终工作区的 177 项指纹一致。

| 归档内路径 | 内容 |
| --- | --- |
| 主归档 `primary/summary.json`、`command-manifest.json`、`*.receipt.txt` | 27 个检查/准备步骤的退出状态、命令来源、版本及原始日志位置 |
| `primary/cjson-table/`、`cjson-userdata/` | 2 个 native 基线、18 个主矩阵单元、selective 诊断、逐 case 输出与指纹 |
| `primary/memory-*/`、`loading-*/` | RSS/CPU 原始 JSONL、每个样本的参数、输入/输出及 oracle 散列 |
| `primary/canonical.log`、`actual-http.log`、`tmp-http/` | 原总入口失败、独立 HTTP TAP、Nginx 配置和日志 |
| 主归档 `source-snapshot/`、`dependencies/cs_CZ-locale/` | 本轮被测运行时/测试/构建源快照与 locale 依赖；完整源仍以固定 Git commit 和子模块为准 |
| 扩展归档 `extended/receipts.json`、`extended/evidence/` | fuzz、replay、Miri、ASan、依赖审计的命令、输出和失败 setup |
| `extended/generated-fuzz-output/` | 本轮生成的 6,016 个 corpus 文件及对应输出；无 crash artifact |
| `native-macos/` | 三组 Rust 测试、Clippy、安装 smoke、环境记录及实际安装的 Lua/native 模块 |
| `runtime-memory-tools/` | 两种 LuaJIT 下的 Valgrind 原始日志、同环境最小/非插桩对照、脚本和退出记录 |
| `runtime-profiles/` | 固定 OpenResty 镜像结果、拉取阻塞、manifest、实际二进制比对 |
| 归档根的 `*-audit.md` / `delivery-review.md` | 独立结果、归档完整性与最终报告审查 |

主命令清单区分 2 条原始外层命令、20 条 receipt 内层记录、5 条依据保留环境重建的外层命令。安装 smoke 的两个 receipt 内层条目是简写步骤，不能当作逐字 shell 捕获；具体安装树、实际加载路径、输出和脚本另行保留。绝对工作路径可用于追踪当时环境，异机复现需按归档相对结构重定位。

扩展子代理的 `artifact-manifest.md` 记录其当时的 compact copy，提到生成 corpus 未复制；本次最终主归档工作另外加入了上述 `extended/generated-fuzz-output/`，以本节及内部校验清单为最终交付范围。工具链、Cargo target/cache、完整 Docker 镜像和重复源副本未归档；可以根据固定来源重新构建，不把它们算作新验证结果。

```sh
# 在 docs/verification 中校验最终交付物
shasum -a 256 -c SHA256SUMS

# 分别解压到空目录后，校验每个归档的内部文件
# tar -xzf <archive> -C <empty-directory>
# cd <empty-directory>
# shasum -a 256 -c SHA256SUMS
```

基本复现从固定代码和子模块开始：

```sh
git checkout 33d00b522d87cc760f757404186488453ffcb498
git submodule update --init --recursive
make openresty-dev-image
make openresty-docker-test
```

在上述固定的旧 commit 上，最后一条会在 V01 失败；应用本节前面记录的 V01–V03 脚本补丁后，已完整复验通过。独立继续 HTTP 可运行 `scripts/verify-openresty.sh`；严格 corpus 的临时 wrapper、原始命令、环境变量和退出码均在证据中，不应默默修改被测入口。

在 Linux dev 环境中，Rust 入口为 `cargo test --locked --release`、追加 `--no-default-features`、追加 `--features test-panic`，以及 `cargo clippy --locked --release --all-targets -- -D warnings`；feature 切换后重新执行默认 `cargo build --locked --release`，再跑 Lua，以免加载了错误 feature 的库。macOS 与 Linux 的 native 库不可互换。

主宿主侧矩阵命令形式如下；镜像、volume 和 locale 应替换为自己的同版本环境，输出目录应独立：

```sh
python3 scripts/verify-cjson-compat.py --docker --strict \
  --proxy-mode table --locale-dir <cs_CZ-locale-dir> --output <compat-output>
python3 scripts/verify-memory.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --proxy-mode table --output <memory-output>
python3 scripts/verify-loading.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --proxy-mode table --output-dir <loading-output>
```

将 carrier 改为 `userdata` 分别执行。其他内存参数及 16 MiB / 双分支命令见各 `*.receipt.txt`。locale 本轮使用已有 `cs_CZ` 文件并验证散列与 `setlocale`；复用的是输入依赖，不是历史测试结果。

## 历史整理

按用户选择，删除 `docs/verification` 原有 37 个报告及证据文件（217,076,807 字节），不建立 history 子目录、不把旧日志塞入新归档。它们只保留在 [Git 固定历史](https://github.com/GYWang1983/lua-leanjson/tree/33d00b522d87cc760f757404186488453ffcb498/docs/verification)。需要引用旧阶段结论的文档链接改为该固定 commit；README 与兼容性清单的当前入口改为本报告。

当前目录只保留这一份完整报告、首次全量验证的两份归档、V01–V03 复验归档及校验清单。报告所描述的是上述固定代码版本，不代表之后的提交、未运行的平台、无限 fuzz 时间或真实业务负载。
