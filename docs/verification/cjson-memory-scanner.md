# 原生字符串序列化与原文复用验证报告

更新日期：2026-11-05。本报告及[机器可读证据](cjson-scanner-results.json)维护当前结果；之前的扫描器报告通过 Git 历史保留。

## 实现与结论

完成两项优化：

1. `reader()` 默认 `preserve_raw_strings=true`，复用未修改 Source 字符串及符合条件的容器原始 JSON 片段。字符串长度直接来自 span，输出读取原始窗口，不再解码再编码。新增／修改的 Lua 字符串正常编码。
2. 字符串编码长度、转义输出、普通完整 `encode()` 的字符串／键编码，以及 raw 容器输出深度检查均移到 Rust。Lua 调度节点和分块，不再用 Lua 循环遍历 JSON 字符串字节。

`encode()`／`tostring()` 保持原有字符串编码行为。`reader(...,{preserve_raw_strings=false})` 恢复旧 reader 策略。原文模式可能改变 `/`、`\/`、`\uXXXX`、DEL 等输出拼写，JSON 值不变；默认值变更已获用户明确确认。注释清除、请求的重复键归一化、深度、取消和源读取错误仍然生效。

**正确性和既定兼容策略通过。真实请求的文件模式输出阶段从三轮中位数约 82.4 ms 降到 0.772 ms；严格编码模式约提速 10.4 倍。严格 RSS 门禁仍为 60/66 通过，6 项宽标量失败没有解决。**

## 身份与方法

- 基线提交 `82e36ee541db8d7d61406091a201592ccfb65b1b`；当前分支 `feat/native-serialization`。
- Docker Linux ARM64，Rust 1.90.0。开发镜像 `lua-qjson-v06:restored-20261103`：`sha256:0b7b567601c1ec0b88c1ee6c81c7dea32867b60c97a5a230b7e28e436e70020f`。
- 最终 native：`effc97492c6782a5b6079940943d461303942fb56cc8c9ec11fbff1fe2c0e089`；Lua 集合：`f95ac100952d37942173a17fc76519d44e247a4f50239ac313f2cfc84dfcee38`。
- 库阶段对照及 Kong 使用同一 Kong 运行时镜像。基线为 `a38ea127…`，最终测试镜像为 `d17123a9…`，完整摘要见 JSON。基线 native 为 `4674d4cd…`，构建环境与当前不同，小幅 decode 波动不能归因于本次编码优化。
- 两个 Kong 镜像内全部 **639 个 Kong Lua 文件**的摘要清单一致；overlay 仅替换 LeanJSON 模块和原生库。未修改 Kong 应用源码或生产依赖。
- 正文与完整输出回执仅留在本地临时目录；仓库证据保存输入／输出摘要、完整语义 oracle、逐次测量、兼容统计、内存阶段、复现脚本和构建身份。

## 正确性与兼容性

| 验证 | 最终结果 |
| --- | --- |
| Rust release / 无默认 feature / test-panic | 497 / 497 / 498 passed |
| 全量 Lua | 958 passed |
| C header/native ABI | 独立 C 程序调用长度、1-byte 输出及深度接口，通过 |
| 新原生编码测试 | 4 个：独立 Unicode oracle、任意小窗口、转义拼写、参数及深度边界 |
| 新序列化 Lua 回归 | 9 个：raw/strict、引用、preload、多来源、键／任意字节、深度、重入及指令预算 |
| OpenResty HTTP | 77 passed |
| 上游兼容矩阵 | table/userdata 各 9 单元，lazy/eager/preload × memory/file/feed；各单元 164 个定义，各来源另 80 个 selective 用例 |
| Lua 属性测试 | 2,000 encode；1,000×100 mutation steps，19 个测试通过 |
| Source stress / JSONTestSuite | 500 valid + 500 mutated；318 个语料，文件及 17/65536-byte feed |
| Clippy / Lua lint | 无警告；105 文件，0 warnings/errors |
| 安装验证 | SCM rock 安装；脱离源码路径并取消 LD_LIBRARY_PATH，9 个输入／加载组合通过 |
| 旧 native 混装 | 新加载器拒绝缺少编码 ABI 的旧库 |
| GC 重入压力 | 1,000 组完整编码／长度／reader 检查，140,000 次 finalizer 回调，通过 |

兼容矩阵 `accepted=true`、`harness_healthy=true`。`compatible=false` 保留既有身份标识、懒数组和 userdata 载体差异；每单元 1 个 Lua 5.3 integer 场景在 LuaJIT 下不适用。没有修改上游预期值。

原有明确检查转义格式和解码流取消的本项目测试改为显式 `preserve_raw_strings=false`；新增独立回归检查默认保留的原始字节。真实正文四种来源的严格 reader 输出，均与基线逐字节相同。

独立审查发现并修复一个 Important 问题：GC finalizer／debug hook 可在无 coroutine yield 时重入，覆盖共享编码暂存区。确定性测试先复现完整输出错误和长度 11／682 的差异，再改为每次调用独立持有 count／cursor／buffer。两项回归 RED→GREEN，随后重跑全量 Lua、兼容矩阵、HTTP、安装、内存及最终性能证据。无 Critical、Minor 或被搁置的审查项。

## Lua 逐字节循环审计

| 位置 | 当前行为 |
| --- | --- |
| `reader.lua` 字符串长度 | Rust 计数；raw span 直接计算位置差 |
| `reader.lua` 字符串输出 | 原始窗口复制或 Rust 有界编码；包括大小为 1 的输出窗口 |
| `reader.lua` 原始容器深度 | Rust 增量词法状态，保留跨窗口引号／反斜杠状态 |
| `table.lua` 完整字符串／键编码 | Rust 计算和编码；请求完整结果时才拼成完整字符串 |
| `encode.lua` | 组织 native 调用；固定写入两个引号，没有载荷字节循环；无可写跨调用暂存区 |
| `path.lua` | 仍按字符解析调用者提供的 JSONPath 表达式，处理的不是请求正文 |
| `number.lua`、`source_backend.lua` | 数字类型判断固定读取前一／两个字节，没有随载荷长度增长的字节循环 |

Lua 仍有节点／数组／分块循环，以及 LuaJIT 原生实现的 `find/sub/gsub` 等操作。不能把审计结论表述为“整个 Lua 项目没有任何字符操作”。新增回归关闭 JIT，要求大字符串／键完整编码、严格流式输出及 raw 深度检查总计低于 500,000 条 Lua VM 指令；旧实现曾超过 35,000,000 条。

## 隔离性能

输入是此前压测的同一份真实 Session 正文，1,911,205 字节，包含 44,947 个 `/`。每个 source/policy 新进程，3 次预热、21 次正式测量，正式请求等长替换标记。写文件、GC、修改 model 和完整输出 oracle 在计时外；输出阶段只累计分块，不保留完整输出字符串。三轮分开保留，表中是三轮阶段中位数之和的中位数，单位 ms。

| 来源／输出策略 | 基线 length＋emit | 当前 length＋emit | 提速 |
| --- | ---: | ---: | ---: |
| memory／默认原文复用 | 62.888 | 0.281 | 223.8× |
| file／默认原文复用 | 82.421 | 0.772 | 106.8× |
| memory／显式严格策略 | 72.232 | 7.189 | 10.0× |
| file／显式严格策略 | 86.625 | 8.331 | 10.4× |

`file` 明确设置 `file_in_memory=false`。另外验证 buffered-file 和 file-backed incremental feed；完整逐次数据在 JSON 中。默认模式收益同时来自省略处理和 native 编码，严格模式体现必须转换时的改善。基线不识别原文选项，两个策略标签下均执行原有编码。

这些是 **reader 输出阶段** 的收益，不能当成整个 HTTP 请求或 decode 提速。三轮基线波动明显：file/raw 58.969～100.041 ms；当前 0.754～0.788 ms。测量使用热文件，没有证明并发冷盘 I/O 已解决。

## 真实 Kong 并发复验

使用原报告的真实 Session runner；同一应用、2 个 worker、64 KiB Nginx body buffer、5 GiB 容器限制，隔离 PostgreSQL/Redis 与本地 Mock。Mock 随机等待 4～6 秒；表中网关额外延迟是完整 HTTP 往返减去实际 Mock 等待，含上传／业务／网络／响应，单位秒。

每组 185 个正式请求和 1 次预热；10／25／50／100 并发均全部成功，无数据库错误。两组客户端正文摘要集合相同，185/185 唯一；Mock 预热校验完整 messages，正式上游摘要逐个唯一。

| 并发 | 冻结基线 p50 / p95 | 最终版本 p50 / p95 |
| ---: | ---: | ---: |
| 10 | 0.304 / 0.309 | 0.089 / 0.094 |
| 25 | 0.915 / 1.079 | 0.142 / 0.148 |
| 50 | 1.946 / 1.969 | 0.225 / 0.238 |
| 100 | 4.740 / 6.478 | 0.422 / 0.477 |

最终对照先运行当前版本，再运行冻结基线；JSON 另保留较早的一批同一冻结基线，其 100 并发 p50 为 2.372 秒，说明环境／排队波动明显。改善方向清晰，但不据此声明稳定的 11 倍生产加速。

同版本补充诊断确认自动接收路径可能为 incremental/memory，Nginx buffer 大小不能证明 LeanJSON 的 Source 存在磁盘。本次两组 Kong 的输入配置保持相同；**明确的 file_in_memory=false 比较由上述 CLI 阶段实验提供**。没有复跑 200～500 并发，不把先前数据库容量错误归因于 JSON 库。输入的变体标记不同，但内联图片文字仍相同，不能证明全部长字段均不同的并发内存上界。

## 内存与适用边界

严格 fresh-process RSS 门禁维持原阈值：66 对中 **60 PASS、6 FAIL**。失败仍是 32,768 个标量字段，table 的 memory/file/feed 比值约 1.029/1.047/1.040；userdata 约 1.023/1.059/1.043。没有将其标为通过。

另以固定随机种子生成 16 MiB 十六进制文本，257 个 64 KiB chunk 全部不同；memory/file/feed 均通过完整输出 oracle 与原内存门禁。逐阶段 KiB 值见 JSON。此项是单请求，不是并发总内存证明。

reader 每步编码临时输出最多 64 KiB（并受调用方 chunk_size 限制），无完整解码字符串暂存；`encode()` 按接口约定生成完整结果，允许完整编码缓冲。调用者数据、索引、输出和 GC 时机仍影响 RSS。未进行新 x86/macOS 运行验证或 Miri 解释器执行；未发布或部署生产版本。

## 复现

```sh
make test
cargo test --locked --release --no-default-features
cargo test --locked --release --features test-panic
make lint
make lua-lint
scripts/verify-openresty.sh
make lua-property-test LEANJSON_PROP_CASES=2000
make lua-mutation-property-test LEANJSON_MUT_PROP_CASES=1000 LEANJSON_MUT_PROP_STEPS=100
```

构建库和 Lua 目录必须对应同一版本；自备正文须包含固定标记 `0123456789abcdef`：

```sh
python3 scripts/benchmark-serialization.py --image <runtime-image> \
  --target-volume <built-target-volume> --lua-directory lua \
  --input /tmp/request.json --trials 21 --output /tmp/serialization
python3 scripts/verify-memory.py --image <development-image> \
  --target-volume <built-target-volume> --proxy-mode table --output-dir /tmp/memory-table
```

userdata 将载体改为 userdata。兼容矩阵需设置真实的镜像、摘要、target/registry volume，并准备 cs_CZ locale，再执行 `scripts/verify-cjson-compat.py --docker --strict` 的两种载体。Kong runner、Mock、overlay、环境和全部逐请求结果保存在 JSON 的 `kong_load` 中；运行只使用本地测试依赖。
