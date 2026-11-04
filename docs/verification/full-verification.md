# Lua-LeanJSON 完整验证报告

验证日期：2026-11-03。源码基线：`b2c670e81051d62bc1b2af8979a678f14a484848`，加当前 V06/V08 修复；完整补丁和源文件指纹见运行时验证证据。

当前修复已覆盖 Rust/Lua 总入口、distro 与 rolling Memcheck、OpenResty 1.27、执行脚本控制及原生 x86_64 ASan。完整上游 cjson 矩阵、RSS/加载测量、benchmark、macOS、fuzz/Miri/ARM64 ASan 的最近验证仍对应各自记录的基线，未因本轮修复重复执行。

本报告维护各项检查的最新结果。核心总入口、V05 原生 x86_64 ASan、V06/V08 Memcheck 与 V07 精确版本验证通过。各项结果以注明的源码和环境范围为准，cjson 的三类预期差异继续保留。

| 验收范围 | 当前状态 | 结果与边界 |
| --- | --- | --- |
| V01：canonical source corpus | **PASS** | 318 个文件满足严格策略预期；完整 `make openresty-verify` 退出 0 |
| V02：benchmark 脚本 | **PASS** | 默认 smoke、额外 10 MiB smoke、小输入计时均退出 0；未完成全部场景的正式性能比较 |
| V03：cjson 兼容性 | **PASS（含预期差异）** | 两种 carrier 各 9 个完整单元，`accepted=true`、`compatible=false`；无未声明差异 |
| 主环境功能 / HTTP | **PASS** | Rust 444 / 444 / 445，Lua Busted 820，真实 HTTP 72 |
| lazy 配对内存 | **PASS：122/122** | 这些样本满足峰值 RSS 不超过 cjson；不是任意输入的上界保证 |
| eager/preload 加载语义 | **PASS：36/36** | 36 个进程单元通过语义检查；eager 峰值内存高于 cjson，不属于 RSS 门禁通过 |
| V05：原生 x86_64 ASan | **PASS** | 三组 FFI 共 11 项，实际退出 0；越界写入负向控制及二进制插桩核对通过 |
| V06：distro LuaJIT / Memcheck | **PASS** | 普通与 Memcheck 各 817 pass / 0 fail / 3 pending；命令退出 0，21 份进程日志严格审计通过 |
| V07：OpenResty 1.27 | **PASS** | 精确官方 ARM64 镜像：smoke 19、Lua 820、HTTP 72；全部退出 0 |
| V08：rolling Memcheck | **PASS** | 冻结源码完整套件 820 pass / 0 fail / 0 pending；执行脚本退出 0，21 份进程日志严格审计通过 |
| 其他扩展平台与内存安全 | **部分覆盖** | macOS、限时 fuzz、Miri、ARM64 ASan 有通过证据；范围与基线见对应章节 |

## 版本、环境与证据身份

主环境为 macOS 27.0 ARM64 宿主上的 OrbStack Linux ARM64 容器。Docker 29.8.2、宿主 Python 3.9.6。容器使用 OpenResty 1.29.2.4 / resty 0.29、LuaJIT 2.1.ROLLING（`LUAJIT_ENABLE_LUA52COMPAT`）、Rust/Cargo 1.90.0、GCC 11.4.0、Busted 2.2.0、Luacheck 1.2.0、LuaRocks 3.13.0。

| 对象 | 固定身份 |
| --- | --- |
| 当前修复及测试脚本 | `b2c670e81051d62bc1b2af8979a678f14a484848` + 证据中的 `delivery/source.patch`、`delivery/source-sha256.json` |
| Rust/C ABI 基线 | `src/`、`include/` 与 `33d00b522d87cc760f757404186488453ffcb498` 一致；Lua 数值转换修复见上述补丁 |
| V05 原生主机与工具链 | Ubuntu 22.04.5 LTS / x86_64；`nightly-2026-10-30`，rustc `92b5b8c87`，Cargo `31d3246e0` |
| V06/V08 镜像 `lua-qjson-v06:restored-20261103` | `sha256:0b7b567601c1ec0b88c1ee6c81c7dea32867b60c97a5a230b7e28e436e70020f` |
| V07 官方镜像 `openresty/openresty:1.27.1.2-0-jammy` | `sha256:59095000111495453846cb82fc1cbc281e5ef8d2c96179565e6b134410258b86`，Linux ARM64 |
| RSS 等检查的镜像 `lua-qjson-dev:task3-repro` | `sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47` |
| 运行镜像 `lua-leanjson-openresty:full-20261103` | `sha256:08294519e73845acd28009b157a30e8e32dc2706c2037abf6b8449cb6244e7dc` |
| 主验证 `libleanjson.so` SHA-256 | `8bf0d9f2eedf09c39e8f1aa023c58851ae486ef0172dbdfd442096c01ec38c0b` |
| 上游 lua-cjson 子模块 | `617164a0fe3bb647128178f9caefb304b8573bb6` |
| JSONTestSuite 子模块 | `1ef36fa01286573e846ac449e8683f8833c5b26a` |
| cJSON 子模块 | `fb16e5cf358798aabb049655975cde8427101056` |
| simdjson 子模块 | `43766fc7efdedc87111c48bda55f758ca212335b` |

镜像、源码和对照库分别固定身份。当前完整总入口及 V06/V08 使用 `0b7b5676…` 镜像，V07 使用 `59095000…` 官方镜像；实际 LuaJIT、cjson 和 LeanJSON 库指纹均有记录。RSS 等未重跑检查仍使用其对应基线，不能把不同环境或不同代码的记录当作同一次执行。

cjson 参照分为两类：兼容性矩阵从固定子模块独立编译，实际库指纹见 `v01-v03/matrix-{table,userdata}-final/provenance.json`；内存/加载测试使用镜像安装的 native cjson，路径 `/usr/local/openresty/lualib/cjson.so`，版本 `2.1.0.11`，SHA-256 为 `8825abcf6fca35d18d274d66ff850bd7a6d935e4552fc0bb4e19eff8b3705dab`。相同版本号不代表相同二进制。

## 核心功能与真实 HTTP

| 检查 | 当前结果 | 证据/说明 |
| --- | --- | --- |
| Rust release default | PASS：444 项 | `v06/evidence/rolling-openresty.log`；`make test` 重复的 444 项不累计为独立覆盖 |
| Rust release scalar | PASS：444 项 | `--no-default-features` |
| Rust release panic barrier | PASS：445 项 | `--features test-panic` |
| Rust debug scalar | PASS：444 项 | `primary/debug-scalar.log` |
| Clippy release all-targets | PASS | `-D warnings` |
| Lua Busted | PASS：820 项 | 0 failure/error/pending |
| Luacheck | PASS：90 个文件 | 0 warning/error |
| 编码 / mutation 属性 | PASS：2 / 17 个 test | 下述样本数；不与 820 相加当作独立用例 |
| source stress | PASS | 500 valid + 500 mutated |
| canonical source corpus（V01） | **PASS：318 个文件** | `v06/evidence/rolling-openresty.log`；file 与 17/65,536 字节 feed 分块 |
| 完整验证总入口 | **PASS** | `v06/evidence/rolling-openresty.json`：`make openresty-verify` 退出 0 |
| 实际 OpenResty HTTP | PASS：72 项 | 完整总入口中的 TAP 为 72/72 |
| memory runner Python controls | PASS：4 项 | `primary/test-verify-memory.log` |
| cjson adapter Python controls | PASS：22 项 | `v01-v03/controls-final.log`，对应该矩阵基线 |
| LuaJIT 执行脚本 controls | PASS：12 项 | `v06/evidence/review-fixes-green.json`；覆盖子进程报错、缺失/截断摘要、退出码和证据隔离 |
| Memcheck 真实非法写入控制 | PASS（预期拒绝） | `v06/evidence/v08-frozen-negative.json`：检出 1 个非法写入，退出 1，未被 suppression 放行 |
| benchmark smoke（V02） | **PASS** | `v01-v03/bench-smoke-final.json`；额外 10 MiB smoke 与小输入计时通过 |
| 隔离安装的 Linux LuaRocks 包 | PASS | 从 `/tmp` 加载，清除库环境变量，安装树 smoke |
| 固定源码运行镜像构建/验证 | PASS | revision 标签与运行时基线一致；未发布镜像 |

corpus 使用独立 codec，`decode_invalid_numbers(false)`、`decode_validate_utf8(true)`。318 个文件包括 95 个 valid、188 个 invalid、35 个 implementation-defined；后者按策略接受 11 个、拒绝 24 个。严格 corpus 策略不改变库的 cjson 兼容默认值。

benchmark 使用当前公开 API。默认 smoke 覆盖 small、medium、github-100k、100k、interleaved；另有 10 MiB smoke 与小输入计时检查。可选 simdjson 模块不可用，其行跳过。这些结果确认脚本和正确性路径可执行，不用于证明完整性能表现。

编码属性测试使用 2,000 个样本；mutation 属性测试使用 1,000 个样本，每个 100 步。source stress 使用 500 个合法、500 个变异输入，seed `760076`。

HTTP 的 72 项覆盖 table/userdata、preload/eager、内存/完成文件/增量/回退路径、精确长度输出、迟到重复键、非法 JSON 不向上游产生副作用、HTTP/1.1 chunked 与 HTTP/2 回退、客户端/上游断开、扫描/输出中取消、源文件读写故障、多等待者唤醒、fork 和文件 lease 回收。TAP 见 `v06/evidence/rolling-openresty.log`；V07 的精确镜像结果见 `v07/evidence/v06-native-http-stock-final.log` 及对应 Nginx 配置/日志。这是本地测试 sink 的验收，不涉及 Kong 或真实 LLM Provider。

## cjson 完整兼容性矩阵

本节完整上游矩阵最近运行于 `b2c670e` 基线；本轮新增数值兼容修复由 18 个回归单元和完整 Lua 套件验证，未重新执行此矩阵。

每个单元保留 164 条上游记录：160 条适用断言、3 条 setup helper、1 条环境不适用记录。下表只统计适用断言，差异列均为已接受的 `expected_difference`，不算作验收失败，也不计入 exact pass。

| carrier | 加载模式 | memory exact pass / 差异 | file exact pass / 差异 | feed exact pass / 差异 |
| --- | --- | ---: | ---: | ---: |
| table | lazy | 156 / 4 | 156 / 4 | 156 / 4 |
| table | eager (`lazyload=false`) | 159 / 1 | 159 / 1 | 159 / 1 |
| table | preload | 156 / 4 | 156 / 4 | 156 / 4 |
| userdata | lazy | 130 / 30 | 130 / 30 | 130 / 30 |
| userdata | eager | 159 / 1 | 159 / 1 | 159 / 1 |
| userdata | preload | 130 / 30 | 130 / 30 | 130 / 30 |

主矩阵共 2,952 条记录（2 × 9 × 164），其中 2,670 条适用断言 exact pass、210 条预期差异、54 条 helper、18 条环境不适用；不是 2,952 个不同测试。预期差异为品牌 18、数组 36、载体 156。两个 carrier 的完整 `--strict` 均退出 0，`accepted=true`、`compatible=false`，未声明差异与 unsupported 分类均为 0。

| 差异策略 | 适用记录 | 允许的行为 |
| --- | --- | --- |
| `module_identity` | 所有模式的 `test.lua:L94` | `_NAME="leanjson"`、`_VERSION="0.1.0"`，使用项目名称与当前 Cargo 版本 |
| `lazy_array_semantics` | lazy/preload 的 `agentzh.t:TEST12/13/14` | 空数组保持 `[]`；数组拒绝 hash 字段并返回指定错误 |
| `userdata_carrier` | userdata lazy/preload 的 17 个 direct decode、9 个 cycle 记录，以及 selective 的载体观测 | 返回 userdata，但内容、返回数量、标量字节和值、嵌套 object/array 种类符合要求 |

9 个 cycle 文件为 `example1.json` 至 `example5.json`、`numbers.json`、`rfc-example1.json`、`rfc-example2.json`、`types.json`。17 个 direct decode ID 为 `test.lua:L101,L110,L113,L116,L161,L167,L224,L226,L228,L231,L339,L341,L345,L347,L349,L351,L410`。

适配器保留上游原始判断。独立 native shape 观测在原始比较之后执行，校验嵌套 object/array 种类；cycle 检查输入 JSON 的容器种类，不要求复刻 cjson 将无标记空数组重编码为对象的行为。策略同时检查具体输出，不能只凭记录 ID 放行内容损坏。缺失 API、setup 失败、错误内容或未声明差异仍导致失败；22 项适配器检查包含这些负向控制。详见[适配器说明](../../tests/upstream-cjson/README.md)。

每种 carrier 的 native 基线独立执行 164 条记录，结果均为 160 pass + 3 setup + 1 environment-inapplicable。LeanJSON bootstrap 显式禁止加载 native cjson，防止回退实现掩盖差异。每个主单元实际调用 decode 的上游 case 为 71 个、decode 调用为 80 次；settings/encode-only 测试不必经过 decode。

selective replay 捕获实际 codec 的四个 decode 配置及 safe/normal 路径，并在新实例上回放。每种输入的结果为 table 80 pass、userdata 41 pass + 39 条载体预期差异；memory/file/feed 合计 480 条记录，363 pass + 117 expected_difference，无未声明差异。这是补充回放，不是另一套完整 164 项矩阵，也不覆盖原始 upstream exact verdict。

矩阵覆盖固定 OpenResty lua-cjson 分支的上游用例，不能穷举所有 Lua/C API 输入。其他行为边界见[兼容性修复清单](../design/cjson-compatibility-fixes.md)和[迁移说明](../migrating-from-cjson.md)。

## 配对内存与加载模式

本节测量对应运行时基线 `33d00b5`，本轮未重测 RSS 或 CPU。

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

本节的测试与 RSS 测量分开执行。native macOS 与 Linux 工具使用独立 target/安装树，不共享可写的主测量产物。

| 检查 | 结果 | 范围与限制 |
| --- | --- | --- |
| 原生 macOS 27.0 ARM64 Rust | PASS：444 / 444 / 445 | release default / scalar / test-panic；均 0 failed / ignored |
| 原生 macOS Clippy | PASS | `-D warnings`，0 warning/error |
| 原生 macOS 隔离安装 smoke | PASS | checkout 之外运行，实际从隔离 rock tree 加载，LD/DYLD 库路径清空 |
| Linux bounded fuzz | PASS：6 目标 | 每目标预算 30 秒，实际约 31 秒；无 crash artifact，不是无限时长验证 |
| corpus replay | PASS：6 次 | depth / ffi_ops 无预置语料，各只有 2 次初始化运行 |
| Miri scalar | PASS：12 次调用、57 项 | x86_64 / i686 / powerpc64 各 4 个测试文件、19 项；0 failed / ignored |
| ARM64 ASan | PASS：3 次调用、11 项 | `ffi_smoke` 6、`ffi_strings` 3、`ffi_ops_interleave` 2；无 advisory 放行 |
| 原生 x86_64 ASan（V05） | **PASS：3 次调用、11 项** | `ffi_smoke` 6、`ffi_strings` 3、`ffi_ops_interleave` 2；实际退出均为 0，显式启用 leak detection |
| 原生 x86_64 扫描器补充验证 | PASS：2 项实质检查 | AVX2/PCLMUL 运行时探测均为 true；2,000 个属性测试样本及反斜杠边界检查；另有 1 项 `skip_neon` 占位，不计入实质覆盖 |
| x86_64 ASan 真实非法写入控制 | PASS（预期拒绝） | 编译退出 0；执行检出 `heap-buffer-overflow` / `WRITE of size 1`，实际退出 1 |
| `cargo audit` | PASS | cargo-audit 0.22.2；1,403 条 RustSec advisory、117 个依赖 |

macOS 使用 task-local Rust/Cargo 1.90.0、LuaJIT `v2.1` commit `ea9eb7edb5eac4a9d175d74523db34fac0fa5180`（运行时 `2.1.1793383622`）及 LuaRocks 3.13.0。安装后的 native module SHA-256 为 `65a84e3e6150bad2aec13cbaba69279ff7549f190bdbb679df289606be480cdb`。`MACOSX_DEPLOYMENT_TARGET=13.0` 是构建参数；本轮只在 macOS 27.0 实际运行，不代表验证了 macOS 13。没有在 macOS 上跑完整 Busted 或真实 OpenResty HTTP。

Linux fuzz/Miri/ARM64 ASan 使用镜像 `lua-qjson-dev:fuzz`，ID `sha256:c4c8f06d4c8552c7d91a01da676966d4975d801efc1fb7a55dbb0887a37951c5`，rustc `1.101.0-nightly (92b5b8c87 2026-10-29)`、Cargo `1.101.0-nightly (31d3246e0 2026-10-27)`、cargo-fuzz 0.13.2。源代码对应上述运行时基线；fuzz 使用独立 lockfile。Miri 显式关闭 default features，属于解释器下的标量验证，不是原生 x86/32 位/大端硬件或 SIMD 执行证明。

| fuzz 目标 | bounded run 次数 | replay 预置语料 / 执行次数 |
| --- | ---: | ---: |
| `fuzz_parse_eager` | 1,779,887 | 296 / 297 |
| `fuzz_parse_lazy` | 32,172 | 13 / 14 |
| `fuzz_ffi_ops` | 4,515,515 | 0 / 2 |
| `fuzz_depth` | 66,803 | 0 / 2 |
| `fuzz_numbers` | 2,255,702 | 10 / 11 |
| `fuzz_source_windows` | 165,557 | 296 / 297 |

run 次数不是互不重复的测试输入数，也不作为吞吐 benchmark。source windows 使用 `max_len=16384`；其他目标使用 wrapper 的上限，固定 seed `760076`。生成语料共 6,016 个 corpus 文件，未生成 crash artifact。无语料的两个 replay 只验证了初始化路径，其有效压力覆盖来自各自的限时 fuzz。

RustSec 数据库固定为 `6c5fedf8ff03c485ed674d8f941e0180f3f72d70`，数据库 commit 时间 `2026-11-03T10:44:19+01:00`，网络审计记录时间 `2026-11-03T10:45:09Z`。结构化审计与 `cargo audit` 命令输出均已归档。结论限于该锁文件和数据库快照，不代表未来没有新 advisory。

### 原生 x86_64 ASan（V05）

本项在原生 Ubuntu 22.04.5 x86_64 主机执行，使用当前工作区的 180 文件源码快照，上传前后及测试结束后散列一致。工具链固定为 `nightly-2026-10-30`：rustc `92b5b8c87c61b20adc9001b41baf587634a74734`、Cargo `31d3246e0`、LLVM 23.1.4。它与 ARM64 ASan 原始工具版本日志中的 rustc 提交一致；Rust 与 Cargo 的提交号分别记录。

Rustup、Cargo 和构建产物使用独立目录。采用原生工具链，未拉取 Docker 镜像或修改 Docker 配置。工具链通过 rsproxy 传输，安装器和日期固定的 manifest 均按官方 SHA-256 校验，镜像 manifest 与官方文件逐字节一致；实际下载的 crate 均与 `Cargo.lock` 校验和一致。

三组测试沿用 CI 的目标和 ASan 参数，并增加 `--locked` 与 `ASAN_OPTIONS=detect_leaks=1`；本次要求真实退出 0，不使用 CI 的 advisory 放行。三个测试程序、扫描器和负向控制共五个实际执行文件均核对 ELF64/x86_64、SHA-256 和 ASan 符号；FFI 函数反汇编进一步确认产品代码含 sanitizer 检查。正向测试没有 AddressSanitizer 或 LeakSanitizer 错误报告，真实越界写入控制能够被拒绝。

```sh
# 在该快照、固定工具链和独立 Cargo target 目录中执行
RUSTFLAGS='-Z sanitizer=address' ASAN_OPTIONS=detect_leaks=1 \
  cargo +nightly-2026-10-30 test --locked --release \
  --target x86_64-unknown-linux-gnu --test ffi_smoke
# 将 ffi_smoke 分别替换为 ffi_strings、ffi_ops_interleave，逐条检查退出码
```

命令、输出、来源信息与最终核对见运行时归档的 `v05/acceptance-summary.json`、`v05/receipts/post-run-verification.json` 和对应日志。本项覆盖上述 FFI 与扫描器检查，不代表在 x86_64 上重新执行了完整 Rust/Lua 套件、RSS 或性能测量。

### LuaJIT / Valgrind（V06/V08）

| 实际环境与执行 | 当前 Busted 结果 | 门禁结果 |
| --- | --- | --- |
| Ubuntu Jammy distro LuaJIT，JIT 关闭 | 817 pass / 0 fail / 0 error / 3 pending | 普通完整套件退出 0 |
| 同 distro LuaJIT，Memcheck | 817 pass / 0 fail / 0 error / 3 pending | 完整命令退出 0；21 份进程日志通过最终严格解析器审计 |
| OpenResty rolling LuaJIT，Memcheck | 820 pass / 0 fail / 0 error / 0 pending | 冻结源码命令退出 0；21 份进程日志严格审计通过 |
| 真实非法内存写入负向控制 | 有意执行 1 字节越界写入 | 检出 1 error、0 suppressed，命令退出 1 |

完整套件的逐进程摘要均为零未屏蔽错误，definite/indirect/possible lost 均为 0。`still reachable` 表示退出时仍可达，本次不将其作为 lost 类别错误；distro 与 rolling 的单进程最大值均为 826 字节。

修复与验证规则：

- 数值转换保留浮点负零和负向下溢的符号，包括 `-0.0`、`-0e0`、`-0x0p0`；整数 `-0` / `-000` 保持 cjson 的正零语义。新增 18 个 source × loading × carrier 回归单元。
- 编码负零测试使用运行时构造的负零；外部数组长度按同一 VM 的原生数值转换语义断言。原生 `ipairs` 按 VM 能力验证，`leanjson.ipairs` 的遍历和关闭状态检查在两种 carrier 上始终执行。
- 64 文件描述符限制在新 Lua 进程内设置并读回；耗尽控制确认最高可用 fd 为 63，之后返回 EMFILE，保证深层 spill 用例实际受限。
- 执行器直接用选定 LuaJIT 运行 Busted 入口，避免 LuaRocks 启动器的额外编译器探测。每次执行使用独立目录，保留源码、运行时、命令、日志和退出码。
- 每个 Memcheck 进程日志都必须含结构完整、计数合法的零错误摘要。子进程错误、缺失/截断摘要和非零测试退出均不能被父进程成功掩盖。

Distro 包为 `2.1.0~beta3+dfsg-6ubuntu0.1`，Valgrind `3.18.1`。其三项 pending 是仅适用于 `LUAJIT_ENABLE_LUA52COMPAT` 的 table `__len` 检查；可移植的 `leanjson.len` 仍被验证，没有新增跳过项。

Distro LuaJIT SHA-256 为 `5a52407336f5f614633c32d14b84c3cb83b0c93ea70ff9b32b7ff98431aa2b3b`，build ID 为 `c532105f1b77eb8e57e777c684b290e7b54c5ede`。匹配的调试符号和源码将告警定位到 `str_fastcmp` 的尾部字读取，内联于 `lj_str_new`。不加载 LeanJSON 的字符串、FFI 和 native-cjson 对照均支持该归因；这些原始控制有意返回非零。

Memcheck 使用匹配调试符号及 `--read-inline-info=no`，让已有的具名 LuaJIT 规则正确匹配。`valgrind.supp` 未改动，SHA-256 为 `bf8b64340b88ff078edc1b8a7af945350a6b64b12e6e6dd9d5ea78130eb852ca`。Rolling 的 21 份进程日志均为零错误、零抑制；Distro 审计记录 4,051,437 次已归因抑制、54 个上下文；这不是“所有检测原本都为零”。真实非法写入负向控制同时验证检查门禁仍会拒绝内存错误。

V06 的完整命令及最终解析器逐日志审计分别留有退出记录；V08 使用只读源码快照运行最终执行器，完整命令自身退出 0。复现步骤见 [LuaJIT/Memcheck 验证指南](../testing-luajit.md)。

### 固定 OpenResty 版本覆盖

| 版本 / 镜像 | 当前覆盖与结果 |
| --- | --- |
| 官方 `1.21.4.4-0-jammy` | smoke 19 个断言、退出 0；该版本未覆盖本轮 Lua 修复的完整套件 |
| 官方 `1.27.1.2-0-jammy`（`59095000…`） | 当前修复：smoke 19、Lua Busted 820、真实 HTTP 72，全部退出 0 |
| `1.29.2.4` 开发镜像（`0b7b5676…`） | 当前修复：完整总入口、Lua 820、HTTP 72；rolling Memcheck 820 项通过 |
| 固定基线运行镜像（`08294519…`） | 4 个 length/SHA smoke 检查及非法输入拒绝；不是完整套件覆盖 |

V07 的 nginx 与 LuaJIT 使用官方镜像原始二进制。完整 Busted 的兼容性对照库是固定 `617164a` 源码单独编译的 cjson，SHA-256 为 `87c13272cb1b9c6d4db1c91965ae64c7fae64011b6c8382baeaf8cc1b59c2489`；镜像自带库缺少部分测试对照 API。实际进程映射验证了 LuaJIT 和对照库路径。

V07 最终 HTTP 使用镜像原配 cjson（SHA-256 `1a1a63451597f538bd6c595cc2792e2b6552827ad661d8372d62751ed7fdb347`），无需为部署替换该库；测试依赖 `lfs` / `resty.http` 在临时容器安装。两类检查的依赖和指纹分别记录。V07 不包含 RSS、性能或 sanitizer 结论。

## 当前限制与待完成验证

| 编号 | 当前状态 | 范围与后续验证要求 |
| --- | --- | --- |
| V04 | **内存/性能限制** | eager 峰值内存高于 cjson；默认 lazy 最紧张样本仅余 16 KiB。目标业务输入及部署平台仍需单独评估。 |

## 复现与证据导航

发布前已清理本目录的临时归档和校验文件；下列下载链接固定到清理前的 `7232dec` 提交，保留历史证据导航。验证结果及其覆盖边界未因此改变，也未重新执行全量验证。

下表列出当前结果对应的证据。四个归档各有内部 `SHA256SUMS`；外部 [SHA256SUMS](https://github.com/GYWang1983/lua-leanjson/blob/7232dec8672c1dcd9cf38c2cf9c57de6fdc3d7f6/docs/verification/SHA256SUMS) 校验本报告和归档本身。文件数不含归档根目录的 `SHA256SUMS`。

| 交付物 | 大小 / 内容文件数 | SHA-256 |
| --- | --- | --- |
| [V05–V08 运行时验证证据](https://github.com/GYWang1983/lua-leanjson/blob/7232dec8672c1dcd9cf38c2cf9c57de6fdc3d7f6/docs/verification/runtime-verification-evidence.tar.gz) | 5,958,484 字节 / 1,472 个 | `244e983bb8b2dc40371608642a7683705f0bbcb69eb0fba04e61f3a08f7ea7b6` |
| [核心门禁与兼容性证据](https://github.com/GYWang1983/lua-leanjson/blob/7232dec8672c1dcd9cf38c2cf9c57de6fdc3d7f6/docs/verification/v01-v03-fixes-evidence.tar.gz) | 33,521,157 字节 / 4,925 个 | `b35a2d73764f87ce11ea509768482a311209a39c46a00327398c6ba7c2649e50` |
| [内存与安装验证证据](https://github.com/GYWang1983/lua-leanjson/blob/7232dec8672c1dcd9cf38c2cf9c57de6fdc3d7f6/docs/verification/full-verification-primary-evidence.tar.gz) | 17,642,272 字节 / 2,570 个 | `77aea26436ad83fec617436a88ef0a3782d9b8678fe97e4c962d9ba09d028c29` |
| [扩展环境验证证据](https://github.com/GYWang1983/lua-leanjson/blob/7232dec8672c1dcd9cf38c2cf9c57de6fdc3d7f6/docs/verification/full-verification-extended-evidence.tar.gz) | 1,863,542 字节 / 6,254 个 | `68968f66b45de528e36991741d8ace1990199e68022cba8a59ec59522e8323b3` |

| 归档 | 当前结果的证据路径 |
| --- | --- |
| V05–V08 | `v05/acceptance-summary.json`、`v05/receipts/asan-*.json` / `.stdout` / `.stderr`：原生 x86_64 ASan 的实际命令与结果；`v05/source/`：当前源码快照和散列 |
| V05–V08 | `v05/receipts/post-run-verification.json`、`v05/receipts/binary-provenance.json`、`v05/receipts/negative-control-*`：实际二进制插桩与越界负向控制；`v05/parent-acceptance-review.json`：独立复核 |
| V05–V08 | `delivery/source.patch`、`delivery/source-sha256.json`：当前修复；`v06/evidence/source-final-manifest.json`：冻结执行快照 |
| V05–V08 | `v06/evidence/rolling-openresty.*`：当前完整总入口；`v06/evidence/distro-canonical.*`、`v06/evidence/distro-strict-audit.*`：V06 完整运行与严格审计 |
| V05–V08 | `v06/evidence/v08-frozen-final.*`、`v06/evidence/v08-frozen-strict-audit.*`、`v06/evidence/v08-memcheck-audit.json`：V08 执行与逐进程审计；`v06/evidence/v08-frozen-negative.*`：负向控制 |
| V05–V08 | `v06/evidence/review-fixes-green.*`：12 项执行器控制；`v06/evidence/runtime/`、`v06/evidence/original-contexts.json`、`v06/evidence/original-symbols.json`：运行时归因证据 |
| V05–V08 | `v07/evidence/v06-canonical-smoke.*`、`v07/evidence/v06-full-busted-pinned-reference.*`、`v07/evidence/v06-native-http-stock-final.*`：V07 最新结果；`v07/evidence/final-stock-runtime-identities.log`：官方二进制指纹 |
| 核心门禁与兼容性 | `v01-v03/bench-smoke-final.*`、`v01-v03/bench-smoke-10m.*`、`v01-v03/bench-timed-small.*`：benchmark 执行结果 |
| 核心门禁与兼容性 | `v01-v03/matrix-table-final/`、`v01-v03/matrix-userdata-final/`：基线、完整矩阵、selective、逐 case 输出与 provenance；同名 `.json` 为外层退出记录 |
| 核心门禁与兼容性 | `v01-v03/controls-final.*`、`v01-v03/script-provenance.json`、`source-snapshot/`、`v01-v03/tmp/`：适配器检查、脚本指纹、源码和 HTTP 配置/日志 |
| 内存与安装验证 | `primary/memory-*/`、`primary/loading-*/`：RSS/CPU JSONL、样本参数、输入/输出及 oracle 散列 |
| 内存与安装验证 | `primary/debug-scalar.log`、`primary/test-verify-memory.log`：debug Rust 与 memory runner controls |
| 内存与安装验证 | `primary/command-manifest.json`、`primary/installed-package-retry.receipt.txt`、`primary/runtime-image-*.receipt.txt`：安装 smoke、运行镜像和环境记录；`source-snapshot/`、`dependencies/cs_CZ-locale/`：源码与 locale |
| 扩展环境验证 | `extended/receipts.json`、`extended/evidence/`：fuzz、replay、Miri、ASan、依赖审计；`extended/generated-fuzz-output/`：6,016 个生成语料 |
| 扩展环境验证 | `native-macos/`：Rust、Clippy、安装 smoke、环境及实际安装模块 |
| 扩展环境验证 | `runtime-profiles/`：1.21 smoke 和固定基线运行镜像；当前 V06/V07/V08 结果以上述运行时验证归档为准 |

工具链、Cargo target/cache 和完整 Docker 镜像不包含在归档内，可按固定来源重新构建。证据中的绝对工作路径需按自己的环境重定位；安装 smoke 的部分 receipt 是步骤简写，具体安装树、加载路径和脚本另有记录。

```sh
# 从上述历史链接下载原始交付物到独立目录后校验（包含原版报告）
shasum -a 256 -c SHA256SUMS

# 每个归档解压到独立空目录后，在该目录校验内部文件
# tar -xzf <archive> -C <empty-directory>
# cd <empty-directory>
# shasum -a 256 -c SHA256SUMS
```

在独立 checkout 中准备基线、子模块及运行时证据归档内的当前补丁，再运行主门禁：

```sh
git checkout b2c670e81051d62bc1b2af8979a678f14a484848
git submodule update --init --recursive
# <runtime-evidence> 为 runtime-verification-evidence.tar.gz 的解压目录
git apply <runtime-evidence>/delivery/source.patch
make openresty-dev-image
make openresty-docker-test
```

在 Linux dev 环境中，Rust 入口为 `cargo test --locked --release`、追加 `--no-default-features`、追加 `--features test-panic`，以及 `cargo clippy --locked --release --all-targets -- -D warnings`。feature 切换后重新执行默认 `cargo build --locked --release` 再跑 Lua，避免加载错误 feature 的库。macOS 与 Linux 的 native 库不可互换。

宿主侧矩阵命令形式如下；镜像、volume、locale 应使用自己的同版本环境，输出目录应相互独立：

```sh
python3 scripts/verify-cjson-compat.py --docker --strict \
  --proxy-mode table --locale-dir <cs_CZ-locale-dir> --output <compat-output>
python3 scripts/verify-memory.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --proxy-mode table --output <memory-output>
python3 scripts/verify-loading.py --image lua-qjson-dev:task3-repro \
  --target-volume leanjson-bounded-target --proxy-mode table --output-dir <loading-output>
```

将 carrier 改为 `userdata` 分别执行。其他内存参数、16 MiB / 双分支、benchmark 与扩展检查的精确命令见对应退出记录。locale 使用准备好的 `cs_CZ` 文件，需确认散列及 `setlocale` 可用。
