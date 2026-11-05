# 原生字符串循环验证报告

更新日期：2026-11-04。此文档及[机器可读结果](cjson-scanner-results.json)维护当前实现和本轮实测，之前的报告通过 Git 历史保留。

## 结论与实现范围

本轮在 CJSON 派生普通字符串扫描内核上继续优化 Rust 原生字符串循环。一个 chunk 内持有字符串状态，直接处理完整短转义、Unicode 转义及 UTF-8 序列；跨 chunk 的不完整序列继续使用原有状态机。密集转义不再逐字节搬动完整 Token，也不再反复调用 C 扫描极短片段。

初次扫描、按需字符串读取和增量诊断共享相关逻辑。未选字符串只校验，不生成完整解码副本；选中字段及 Schema 使用最多 4 KiB 的临时批次。普通长片段继续使用 C 内核。Lua 最终字符串拼装、公开接口和 ABI 保持不变，`scanner="legacy"` 继续可用。

**密集转义场景的内存 decode 从约 22.2 ms 降到 2.16 ms，约提速 10.3 倍；增量 decode 约提速 8.1 倍。正确性与既定兼容性策略通过。严格 RSS 门禁仍有 6/66 项未通过，宽容器独立进程性能仍有明显波动，不能宣称所有场景均无性能回退。**

## 环境与证据

- 前一版提交：`38343ff26ae7a97e40afdc1d5b35edd3697a9651`；工作分支：`feat/cjson-memory-scan`。
- Docker Linux ARM64，Rust 1.90.0，OpenResty LuaJIT；镜像 `lua-qjson-v06:restored-20261103`，实际摘要 `sha256:0b7b567601c1ec0b88c1ee6c81c7dea32867b60c97a5a230b7e28e436e70020f`。
- 前一版原生库：`b412598942943f483b97ddf8ef44dcdb05c6ecfd11ac34b494cd0ac2cf0fc193`。
- 本轮最终原生库：`8db0fd170c0ed52752f7288897337da9855549066c928169d2bf6e2a05c401ab`。性能、最终上游矩阵及最终内存矩阵均记录此指纹；新旧库分别冻结，避免重编译覆盖对照。
- 性能使用运行时 CJSON `2.1.0.11`；兼容矩阵现场编译固定 lua-cjson 提交 `617164a0fe3bb647128178f9caefb304b8573bb6`，分别记录其二进制指纹。
- JSON 结果包含逐次 CPU／wall 数据、原生配对数据、输入摘要、完整输出 oracle、兼容性统计及内存阶段数据。用户请求正文及完整输出回执仅保留在本地临时目录，未提交到仓库。

## 正确性验证

| 验证 | 本轮结果 |
| --- | --- |
| Rust release / 无默认 feature / test-panic | 493 / 493 / 494 passed |
| 全量 Lua | 949 passed |
| 新字符串循环及小窗口读取单元测试 | 6 passed，含属性测试、任意分块、错误位置及输出上限 |
| 独立 source 扫描回归 | 9 passed |
| OpenResty HTTP | 77 passed |
| JSONTestSuite | 318 个：95 valid、188 invalid、35 implementation-defined；文件及 17／65536-byte feed |
| Source stress | 500 valid + 500 mutated |
| Lua 属性测试 | 19 个测试；2,000 encode + 1,000×100 mutation steps |
| Clippy / Lua lint | 0 warnings；Lua 103 文件无错误 |
| C 普通片段内核 | ASan + UBSan + 保护页检查通过 |
| 安装验证 | SCM rock 安装成功；离开源码目录、取消 LD_LIBRARY_PATH，9 个输入／加载组合通过；许可证随包安装 |
| Miri 条件编译 | `--cfg miri` cargo check 通过；未运行 Miri 解释器 |

上游兼容矩阵覆盖 table／userdata，每种 9 个单元：lazy／eager／preload × memory／file／feed；每单元 164 个上游定义，每种输入另有 80 个 selective 用例。两种载体均 `accepted=true`、`harness_healthy=true`。`compatible=false` 表示身份标识、懒数组、userdata 载体等既有声明差异仍存在。LuaJIT 不适用的 Lua 5.3 integer 用例单列，不计为通过或失败。

新增回归覆盖转义键与重复键、Unicode 边界、严格／任意字节字符串、非法转义、Schema const、preload/eager、显式引用及 1～65536 字节输出窗口。独立审查无阻断问题；补齐内部 policy 的 scanner 传递后，重新执行最终构建的主门禁、兼容性和内存矩阵。

## 解码性能

每个输入／来源／加载组合使用新 OpenResty 进程，3 次预热、21 次交错测量，计时前执行两次 GC。文件读取、构造输入、Schema 编译及完整输出 oracle 在计时区外。每轮等长替换标记，输入不同；只计 decode。feed 包含 Lua 切片、feed 和 finish，仍保留增量诊断扫描。CJSON 对照始终为完整内存 decode，不是增量解析。

### 密集转义

输入 2,800,057 字节，包含短转义、反斜杠和中文。新旧冻结库进行三轮交错对照；表中是每轮 21 次 CPU 中位数的中位数，单位 ms。

| 输入 | 前一版 | 本轮 | 提速 | 同组 CJSON 完整内存 decode |
| --- | ---: | ---: | ---: | ---: |
| memory | 22.191 | 2.162 | 10.26× | 1.912 |
| feed | 36.379 | 4.471 | 8.14× | 1.922 |

memory 三轮前一版范围 21.749～22.350 ms，本轮 2.150～2.275 ms；feed 前一版 36.204～36.604 ms，本轮 4.368～4.550 ms。本轮 memory 约为同组 CJSON 的 1.13 倍，仍有约 13% 差距。

确实加载大字段的单组对照，preload 明确指定 `$.prompt`：

| 来源／加载 | 前一版 | 本轮 |
| --- | ---: | ---: |
| memory preload | 22.789 | 4.689 |
| memory eager | 31.034 | 4.701 |
| feed preload | 28.420 | 6.813 |
| feed eager | 36.758 | 6.723 |

加入字符串 minLength Schema 后，memory lazy／preload／eager 分别为 4.643／4.864／5.024 ms，feed 为 6.766／7.272／8.260 ms。CJSON 不执行 Schema，不能视为相同工作量比较。读取完整字段和最终编码仍可能创建 Lua 字符串，本轮没有将其所有权整体移到 Rust。

### 原长上下文与普通字符串

原请求 1,911,205 字节，本轮无 Schema：memory 从 1.440 降至 1.309 ms，feed 从 2.897 降至 2.815 ms。保留当前完整 Chat Facility Schema 的 5 个定义，本轮 memory lazy／preload／eager 为 1.601／1.729／1.959 ms，feed 为 2.969／3.008／3.324 ms。未精简 Schema；原 OpenAPI 7,014 字节，只机械改写引用位置，摘要保留在 JSON 中。

16 MiB 普通字符串 memory 从 10.951 到 10.865 ms，feed 从 22.364 到 22.288 ms。本轮主要收益来自密集转义，普通长字符串变化很小。

### 宽容器波动与证据边界

32,768 个标量／小对象的独立进程结果波动明显。固定 Docker 虚拟 CPU 0 后，三轮中位数比较仍显示小对象 memory 约慢 10.8%、feed 约慢 26.3%；另一次合成对照的该 feed 场景反而更快。这些结果均保留，虚拟 CPU 绑定不能固定物理宿主调度和频率。

为排除跨进程差异，另在同一 OpenResty 进程内通过两个 FFI handle 加载新旧冻结库，同一输入交错执行 63 对原生扫描。此实验不包含 Lua 对象加载和编码，配对耗时比中位数如下：

| 场景 | 本轮／前一版 |
| --- | ---: |
| 宽标量 memory | 1.011 |
| 宽标量 feed | 1.003 |
| 小对象 memory | 0.982 |
| 小对象 feed | 0.985 |

该结果未复现显著的原生循环回退，但不能据此证明完整 Lua 路径没有回退。以上均为隔离库验证，未执行 Kong 并发压测，不代表 HTTP 延迟、吞吐或 500 并发内存。

## 内存验证

沿用现有 fresh-process、无阶段间强制 GC 的严格 RSS 门禁，阈值不变：11 场景 × 3 来源 × 2 载体，共 66 对，**60 PASS、6 FAIL**。

失败均为 32,768 个标量字段：table 的 memory／file／feed 比值为 1.040／1.053／1.049；userdata 为 1.024／1.057／1.039。所有失败及 KiB 值在 JSON 中保留。32,768 个小对象及其他默认场景通过。此限制此前已存在，本轮没有解决最差情况下 RSS 不超过 CJSON 的总体目标。

另用固定随机种子生成 16 MiB 文本，257 个 64 KiB chunk 的摘要全部不同，避免重复字符串驻留掩盖原文成本。三种来源均验证完整输出，单请求 peak RSS（MiB）：

| 来源 | CJSON | LeanJSON | 门禁 |
| --- | ---: | ---: | --- |
| memory | 91.17 | 60.52 | PASS |
| file | 91.23 | 45.94 | PASS |
| feed | 91.20 | 45.72 | PASS |

该实验仍是单请求结果。保留原文的内存／增量模式不具有固定总 RSS，本轮没有实际运行 x86／macOS、Miri 解释器或 Kong 端到端验证。

## 复现入口

先在目标 Linux/OpenResty 环境构建，再执行主门禁：

```sh
make test
cargo test --locked --release --no-default-features
cargo test --locked --release --features test-panic
cargo clippy --locked --release --all-targets -- -D warnings
make lua-lint
scripts/verify-openresty.sh
cc -std=c99 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
  src/source/cjson_scan.c tests/cjson_scan_bounds.c -o /tmp/leanjson-scan-bounds
/tmp/leanjson-scan-bounds
```

新旧库必须放在独立 target volume 中，分别执行下列入口。每个自备输入须含标记 `0123456789abcdef`，脚本仅等长替换此标记：

```sh
python3 scripts/benchmark-memory-decode.py --image <image> \
  --target-volume <target-volume> --synthetic --trials 21 --output /tmp/decode-bench
python3 scripts/benchmark-memory-decode.py --image <image> \
  --target-volume <target-volume> --input /tmp/escaped.json \
  --loading preload eager --preload-path '$.prompt' --trials 21
python3 scripts/benchmark-memory-decode.py --image <image> \
  --target-volume <target-volume> --input /tmp/request.json \
  --schema /tmp/request-schema.json --loading lazy preload eager --trials 21
python3 scripts/verify-memory.py --image <image> \
  --target-volume <target-volume> --proxy-mode table --output-dir /tmp/memory-table
```

userdata 将载体参数改为 userdata。完整兼容矩阵需设置真实的 `CJSON_COMPAT_IMAGE`、`CJSON_COMPAT_IMAGE_ID`、`CJSON_COMPAT_TARGET_VOLUME`、`CJSON_COMPAT_REGISTRY_VOLUME`，并准备 cs_CZ locale：

```sh
python3 scripts/verify-cjson-compat.py --docker --strict --proxy-mode table \
  --locale-dir /tmp/cjson-locale --output /tmp/compat-table
python3 scripts/verify-cjson-compat.py --docker --strict --proxy-mode userdata \
  --locale-dir /tmp/cjson-locale --output /tmp/compat-userdata
```

原生配对实验的驱动源码与全部逐次数据保存在 JSON 的 `paired_native_comparison` 中；两个库路径须替换为各自冻结库，输入沿用合成宽容器。不要将该原生实验的数字当作完整 Lua decode 成本。
