# CJSON 派生扫描内核验证报告

## 结论与实现范围

已实现 CJSON 派生的普通字符串 C 扫描内核，接入内存、文件和增量输入。保持 Rust 语法／数字／转义校验、span、代理、有限索引、引用、preload、eager 和 Schema 路径；没有调用 cjson.decode 构建中间完整树，也没有整体移植 CJSON 递归解析器。

默认 `scanner="cjson"`，可用 `scanner="legacy"` 回退。完整内存输入只在 JSON 校验失败后重放诊断；流式输入保留增量诊断状态，并批量扫描普通字符串片段。所有输入仍被完整校验。C 内核不分配、不复制、不保留输入指针；事件仍按 chunk 排空。原生构造器默认仍为 legacy，新增选择器须在首次 feed 前调用。

**正确性与兼容性门禁通过。严格 RSS 门禁仍有 6 项失败，不能声明所有输入都比 CJSON 省内存；密集转义字符串也仍明显慢于 CJSON。**

## 环境与证据

- 基线：`25783b155ecd5eec3e924f859b004ed9530e4c7f`；工作分支：`feat/cjson-memory-scan`。
- Docker Linux ARM64，Rust 1.90.0；开发运行时：`lua-qjson-v06:restored-20261103`，摘要 `sha256:0b7b567601c1ec0b88c1ee6c81c7dea32867b60c97a5a230b7e28e436e70020f`。
- 另在原压测镜像 `llm-router-kong:leanjson-4f677b5` 中执行同一库的 CLI 基准，使用该镜像实际摘要；未启动 Kong 请求链路。
- 性能对照使用运行时自带 CJSON `2.1.0.11`；兼容矩阵则现场编译固定 OpenResty lua-cjson 提交 `617164a0fe3bb647128178f9caefb304b8573bb6`。两者分别记录，不混为同一个二进制。
- 所有最终矩阵、性能与内存结果中新构建的 LeanJSON 原生库摘要一致：`b412598942943f483b97ddf8ef44dcdb05c6ecfd11ac34b494cd0ac2cf0fc193`。
- [机器可读结果](cjson-scanner-results.json) 包含逐次 CPU／wall 测量、输入摘要、完整输出 oracle、兼容性统计、内存失败项与二进制／Lua 指纹。用户请求正文和完整序列化回执只留在本地临时证据目录，没有写入本仓库。

## 正确性验证

| 验证 | 最新结果 |
| --- | --- |
| Rust release | 487 passed |
| Rust 无默认 feature | 487 passed |
| Rust test-panic | 488 passed |
| 全量 Lua | 946 passed |
| 独立原生扫描回归 | 9 passed，包含任意字节与 Unicode 属性测试 |
| OpenResty HTTP | 77 passed，含 socket、文件、取消和并发输入清理 |
| JSONTestSuite | 318 个：95 valid、188 invalid、35 implementation-defined；文件及 17／65536-byte feed 一致 |
| Source stress | 500 valid + 500 mutated |
| Lua 属性测试 | 19 个测试通过；2,000 encode + 1,000×100 mutation steps |
| Clippy / Lua lint | 0 warnings；Lua 102 文件无错误 |
| C 内核 | ASan + UBSan + 保护页验证，长度 0 到一整页均不越界 |
| 安装验证 | SCM rock 安装成功；脱离源码目录、取消 LD_LIBRARY_PATH 后 smoke 通过；MIT notice 随包安装 |
| 验证器自身 | memory runner 4 项、兼容性 runner 22 项通过 |
| Miri 条件编译 | `--cfg miri` 的 cargo check 通过；本轮没有运行 Miri 解释器 |

上游兼容性覆盖 table／userdata 两种载体，每种 9 个单元：lazy／eager／preload × memory／file／feed；每单元 164 个上游定义，另有每输入 80 个 selective 用例。两种载体的 `accepted=true`、`harness_healthy=true`，无未声明行为差异。`compatible=false` 保留其原义：身份标识、懒数组和 userdata 载体等既有声明差异仍存在。每个单元有 1 项 Lua 5.3 integer 场景在 LuaJIT 下不适用，不计为通过或失败。

原固定测试镜像已不存在，因此验证器新增显式镜像／摘要／volume 环境配置，仍强校验真实摘要与架构；未伪造旧镜像摘要或修改上游预期值。完整矩阵使用准备好的 cs_CZ locale。

独立审查发现并修复：内存 feed 未遵守原生 scanner 选择、参数／关闭错误被 JSON 诊断掩盖、加载器未验证新增符号。错误掩盖与旧库加载均先复现失败，再通过回归；矩阵在修复后的构建上重新执行。

## 解码性能

每单元新建 OpenResty 进程，3 轮预热、21 轮交错测量，轮换执行位置；每次计时前执行两次 GC。读文件、构造输入、编译 Schema、字段检查和输出语义 oracle 均在计时区外。只测 decode；feed 额外包含切片、feed 和 finish 的成本，CJSON 对照始终为完整内存 decode。CPU 时间为单进程自身消耗。

原请求为 1,911,205 字节。每轮只替换既有的固定宽度标记，保证正文不同且长度不变；其他长字段保持原样。完整输出 oracle 在全部计时结束后执行，避免提前保留大字符串影响驻留／GC。表中为 CPU 中位数，单位 ms；全部逐次 wall／CPU 数据见 JSON。

| 场景 | CJSON | 旧扫描器 | 新扫描器 | 相对旧扫描器提速 |
| --- | ---: | ---: | ---: | ---: |
| 原压测运行时／请求／内存 | 1.460 | 34.591 | 1.449 | 23.9× |
| 原压测运行时／请求／增量 | 1.248 | 36.042 | 2.848 | 12.7× |
| 完整 Chat Schema／内存 lazy | 1.355 | 38.771 | 1.719 | 22.6× |
| 完整 Chat Schema／内存 preload | 1.542 | 38.828 | 1.816 | 21.4× |
| 完整 Chat Schema／内存 eager | 1.312 | 40.406 | 2.099 | 19.3× |
| 完整 Chat Schema／增量 lazy | 1.239 | 38.613 | 3.120 | 12.4× |
| 16 MiB 普通长字符串／内存 | 11.922 | 310.772 | 11.039 | 28.2× |
| 32,768 个小对象／内存 | 5.165 | 12.822 | 7.131 | 1.8× |
| 32,768 个标量字段／内存 | 2.912 | 9.413 | 4.880 | 1.9× |
| 密集转义字符串／内存 | 1.949 | 53.907 | 22.516 | 2.4× |

控制面当前完整 Chat Facility Schema（`backend/kong/facilities/open-ai-chat-v1.openapi.json`）保留 5 个定义，只将 OpenAPI `#/components/schemas/` 引用机械转换到 JSON Schema `$defs`；没有简化 schema。Schema 作用于两种 LeanJSON 路径，CJSON 列不包含 Schema 校验，不能据此宣称等工作量比较。原完整 OpenAPI 文件 7,014 字节，绑定后 schema 摘要见 JSON。

原压测运行时中，长上下文内存 decode 已从约 34.6 ms 降到约 1.45 ms，与同组 CJSON 的约 1.46 ms 接近。合成普通长字符串可略快于 CJSON；宽容器和密集转义仍有差距。密集转义及严格 UTF-8 的非 ASCII 字节仍需走现有逐字节状态处理，不能把普通长字符串结果推广到所有 JSON。

以上是隔离库验证，未复跑 Kong 并发、数据库、路由及完整上下游链路；不能直接换算成 HTTP p50、吞吐或 500 并发内存。

## 内存验证

沿用现有 fresh-process、无阶段间强制 GC 的内存门禁，不修改阈值。

- 默认 11 场景 × 3 输入 × 2 载体：66 对；60 PASS、6 FAIL。
- 失败均为 32,768 个标量字段，table／userdata 的 memory／file／feed 各 1 项；实际比值与 KiB 数在 JSON 中保留。
- 32,768 个小对象，以及深对象、重复键、长文本、遍历与远端数组访问场景均通过本轮默认门禁。

为避免重复字符串／重复 chunk 驻留掩盖真实存储成本，另以 `random.Random(760076).randbytes(8*1024*1024).hex()` 生成 16 MiB 文本。257 个 64 KiB 输入块的摘要全部不同；三种输入均做完整输出语义校验。此组 peak RSS 单位 MiB：

| 输入 | CJSON | LeanJSON | 门禁 |
| --- | ---: | ---: | --- |
| memory | 91.21 | 60.38 | PASS |
| file | 91.20 | 45.80 | PASS |
| feed | 91.18 | 45.64 | PASS |

这仍是单请求新进程结果。内存／增量缓冲模式保留原文，不能将重复内容合成样本的低 RSS 理解为固定内存或磁盘窗口模式。

针对宽标量失败，重新编译基线 main 并使用同一镜像、同一输入、同一测量脚本对照。单次 fresh-process peak RSS（MiB）：

| 输入 | CJSON | 基线 main | 新构建＋legacy | 新构建＋cjson |
| --- | ---: | ---: | ---: | ---: |
| memory | 15.89 | 16.32 | 16.34 | 16.41 |
| file | 15.91 | 16.73 | 16.82 | 16.86 |
| feed | 15.91 | 16.64 | 16.49 | 16.41 |

基线 main 在这些对照中也高于 CJSON，严格最差 RSS 目标尚未满足。阶段数据中，扫描完成后的索引字节相同，RSS／Lua 堆接近；额外峰值主要出现在修改／输出阶段，且受尚未回收的 Lua 堆影响。这里只确认观测，不把回收时机差异视为已定位根因，也不宣称扫描器改造解决了此门禁。

## 复现入口

先在目标 Linux/OpenResty 环境运行 `cargo build --locked --release`，再执行：

```sh
cargo test --locked --release
cargo test --locked --release --no-default-features
cargo test --locked --release --features test-panic
cargo clippy --locked --release --all-targets -- -D warnings
luajit scripts/run-busted.lua tests/lua
make lua-lint
scripts/verify-openresty.sh
cc -std=c99 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
  src/source/cjson_scan.c tests/cjson_scan_bounds.c -o /tmp/leanjson-scan-bounds
/tmp/leanjson-scan-bounds
```

Docker 性能与内存入口；镜像和 target volume 必须对应自己的构建：

```sh
python3 scripts/benchmark-memory-decode.py --image <image> \
  --target-volume <target-volume> --synthetic --trials 21 --output /tmp/decode-bench
python3 scripts/benchmark-memory-decode.py --image <image> \
  --target-volume <target-volume> --input /tmp/request.json \
  --schema /tmp/request-schema.json --loading lazy preload eager --trials 21
python3 scripts/verify-memory.py --image <image> \
  --target-volume <target-volume> --proxy-mode table --output-dir /tmp/memory-table
```

自备输入须包含固定标记 `0123456789abcdef`，用于等长替换；脚本不自动改写用户字段。userdata 复验将 carrier 改为 userdata。完整兼容矩阵需设置 `CJSON_COMPAT_IMAGE`、`CJSON_COMPAT_IMAGE_ID`、`CJSON_COMPAT_TARGET_VOLUME`、`CJSON_COMPAT_REGISTRY_VOLUME`，然后执行：

```sh
python3 scripts/verify-cjson-compat.py --docker --strict --proxy-mode table \
  --locale-dir <prepared-locale> --output <output-inside-checkout>
```

本轮未发布 rock、未合并 main、未推送远端。后续性能缺口未自动创建 Issue：仓库当前关闭了 Issues，本轮没有修改仓库设置。
