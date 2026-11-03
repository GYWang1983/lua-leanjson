# 基于 lua-qjson fork 的大请求体处理设计

> Historical design written before the rename. Original `qjson` paths, repository names, and upstream references are preserved. Current namespace and distribution details are in [LeanJSON rename](2026-11-01-leanjson-rename.md) and the [current source API](../file-source-api.md).

> 日期：2026-10-31。状态：独立库与原生 OpenResty 接口已实现；验证范围、实测结果和限制见[验收记录](https://github.com/GYWang1983/lua-leanjson/blob/33d00b522d87cc760f757404186488453ffcb498/docs/verification/openresty-json-source.md)。
> 已确定方向：fork `api7/lua-qjson`，在现有 Rust 内核和 LuaJIT 接口上扩展。
> 集成范围：独立 JSON 组件与原生 OpenResty；本次不对接 Kong，不修改 Gateway、Controller 或业务插件。
> 上游评估基线：`8e1b394e0dd0322bedae3a9fc87d15d8049a02ce`；个人 fork：`GYWang1983/lua-qjson`。
> 本文描述个人 fork 的实现与边界，不表示上游已经支持。增量输入已实现，字段查询在 finish 和完整校验后发布；尚不提供提前字段值或边上传边转发。

## 1. 目标与边界

保留调用方的字段访问方式，将大 JSON 的存储、按需读取、修改和输出集中在独立 JSON 组件中。通过原生 OpenResty 示例与集成测试验证请求体接收和输出，组件及其测试均不依赖 Kong。

目标：

- 读取 `model` 等少量业务字段时，不构造完整 Lua 对象树。
- 修改一个字段，不解码其兄弟字符串或容器；特别覆盖超长顶层 `prompt`、字符串形式的 `input` 和嵌套 `messages`。
- 多个修改分支共享不可变原文，各自修改互不影响；候选上游是它的一种应用场景。
- 输出使用有界片段，不为完整上游请求分配 Lua 字符串。
- 在上述能力稳定后，支持文件数据源和增量输入；增量输入不要求重写业务对象接口。

内存、已完成文件及文件暂存的增量输入均已实现，不能据此宣称解决了所有 OOM 或实现了边上传边转发。原始输入仍为内存字符串时，它仍占用请求大小对应的内存。文件输入完成后，索引、被业务明确读取的长字符串及新增值仍占用内存，不承诺所有 JSON 形状下常量内存。

OpenResty 示例在完整接收并校验 JSON 后才向测试上游发送请求。鉴权、路由、计费、JSON Schema 业务校验、故障迁移和异步任务均由使用组件的应用负责，不属于组件实现与验收范围。未来应用接入另行设计，不作为本次交付的前置条件。

## 2. 方案选择

| 方案 | 适用性 | 决策 |
| --- | --- | --- |
| fork lua-qjson | 已有 Rust 结构索引、Lua 代理、原文复用编码、FFI 和测试基础 | 用户选定 |
| 从 jsonsl 等增量 lexer 开始构建完整组件 | 输入流和位置识别契合，但需重新实现对象层与编码层 | 作为后续增量扫描器的技术参考，不在首批引入第二套内核 |
| 继续使用完整 lua-cjson 对象，仅减少分支复制 | 改动较小，但完整解码与完整编码仍存在 | 保留为正确性与性能对照基线 |

保留上游仓库历史和 Apache-2.0 许可证，fork 中将通用 JSON 能力与 OpenResty I/O 适配分开。修正代理行为等通用补丁尽量独立，便于后续同步上游；本次不自动创建上游 PR。

## 3. 上游实现与 OpenResty 接入边界

上游基线：

- `src/doc.rs` 的 `Document` 借用完整 `&[u8]`，持有结构位置索引；当前不能换成增长中的可移动缓冲区。
- `lua/qjson.lua` 的 `Doc._hold` 持有整个输入字符串。字符串取值通过 `ffi.string` 生成 Lua string。
- `lua/qjson/table.lua` 首次修改对象时调用 `ensure_object_order_state`，会解码同层标量；数组首次写入也会物化当前层。
- 原有编码器识别未修改原文，但最终返回完整字符串。
- 内部元数据和数组缓存需要审查：内部属性不能覆盖同名用户字段；缓存不能让后续赋值绕过 `__newindex`。

原生 OpenResty 的接入职责：

| 层次 | 接口或数据 | 实施职责 |
| --- | --- | --- |
| 接收已完成的请求体 | `ngx.req.read_body()`、`get_body_data()`、`get_body_file()` | 选择内存或文件 Source，文件不得重新聚合为完整字符串 |
| 对象访问与修改 | 独立的 `qjson` Lua API | 按需读取、修改分支、明确类型及物化边界 |
| 请求输出 | reader 与 `lua-resty-http` 的 body iterator | 分段发送、实际输出长度、错误与取消传播 |
| Nginx 配置 | 请求体缓冲、临时目录、Lua/FFI 搜索路径 | 提供可重复运行的原生 OpenResty 配置及构建示例 |
| 后续增量接收 | 支持的 `ngx.req.socket()` 路径 | 单一输入所有者、字段等待与取消；不支持的协议使用完整接收路径 |

组件以独立模块显式加载，不全局替换 OpenResty 自带 `cjson`。纯 JSON 操作不依赖 `ngx`；只有 OpenResty I/O 适配层与示例使用 `ngx` API。本次不改 `backend/kong` 或业务请求处理链路。

## 4. 对象、分支与修改语义

### 4.1 数据结构

```text
Document = 不可变 Source + 结构索引 + 校验状态
Branch   = Document 引用 + 独立的修改版本
Proxy    = Branch 引用 + 节点身份 + 私有子节点缓存
Writer   = 冻结的 Branch 快照 + 输出游标
```

原文位置使用零基半开区间 `[start, end)`；所有修改都引用原文坐标或稳定节点身份，不使用已输出数据的偏移。容器片段包括自身括号，值片段不包含父容器的逗号。

代理内部状态放在 side table 或不可与用户 key 冲突的内部存储中。用户可见 key/index 不存缓存，确保每次字段写入都可拦截。保持 `null` 与不存在的区别，保持空数组与空对象的区别。

OpenResty Lua 包装层统一复用 `cjson.null`，数组/对象通过库的类型接口识别，不能仅比较代理元表与 `cjson.array_mt`。目标 LuaJIT 构建需验证代理的 `pairs`、`ipairs`、`#` 元方法；`next`、`rawget`、`rawset` 不承诺透明兼容，组件提供对应的显式访问与遍历接口。`getmetatable` 仍返回真实代理元表，不伪装成普通数组元表。

现有 `uint32_t` cursor ABI 保持兼容；新增 Source/流式接口单独定义版本，不静默改变已有 FFI 结构布局。超出可表示位置必须显式报错，不允许截断或回绕。

### 4.2 修改与分叉

```lua
local body = qjson.decode(raw)
local first = qjson.fork(body)
local second = qjson.fork(body)
first.model = "provider-a"
second.model = "provider-b"
first._usage_tags = nil
```

- `qjson.fork` 固定分叉时的逻辑值。随后修改父分支或任一子分支均不影响其他分支。
- `set`、删除和子节点修改记录在独立 overlay 中，不读取未修改的兄弟值。
- 同一位置重复写入，以最后一次写入为准。`nil` 删除对象属性，`qjson.null` 写入 JSON null。
- 对父节点的替换/删除覆盖原有子节点在父树中的关联。已经取出的旧子代理仍代表旧对象，其后续修改不得重新写入新父节点。
- 显式跨分支复制使用 `qjson.fork` 或库的快照复制接口。普通 table、跨分支代理赋值的所有权必须由接口明确：本设计采用赋值时快照，不建立跨分支可变别名；在独立组件测试中覆盖这些行为，不能声称完全等同于任意 Lua table 引用语义。
- 原始数据与索引可共享；overlay 采用不可变版本或等价的写时复制。不得通过递归深复制原文实现分支隔离。

### 4.3 对象键与数组

完整文档模式的对象读取统一采用最后一个同名 key 的值。未修改对象可保留原文；修改该对象时建立成员位置索引，重复 key 合并，保留首次出现顺序和最终逻辑值。删除某 key 时删除其全部出现位置。若某上游路径要求消除全部重复键，使用明确的规范化输出选项，禁止路由与发送选择不同的有效值。

数组的替换、尾部追加、插入和删除使用逻辑元素身份与序列修改记录，不重写所有原文坐标。提供显式 `array_insert`、`array_remove`；不将 `arr[i] = nil` 擅自解释为移位删除。稀疏数组行为与现有编码选项做差分验证，尚未适配的数组操作必须在发布支持范围中明确列出。

## 5. 分段序列化

已实现的 reader 接口：

```lua
local reader = qjson.reader(branch, { chunk_size = 64 * 1024 })
local output_length = reader:length() -- 读取结构元数据计算，不拼接完整输出
local chunk, err = reader:next()     -- nil,nil 表示正常结束；nil,err 表示失败
```

`chunk_size` 是读取/输出工作缓冲，不是请求大小限制。新增接口可对普通 Lua 值和代理混合结构输出；`qjson.encode` 保留为明确生成完整字符串的兼容接口。

Writer 创建时固定逻辑快照。未修改片段按块复制；有修改的容器只重写必要结构，其他子节点仍引用原文。不能通过 `source:sub(完整子树)`、大数组 `table.concat` 或构建完整输出 table 来伪装分段写入。

Reader 构造只创建快照和所有权范围，不执行源 I/O；首次 `length()` 或 `next()` 才计算长度，文件读取阶段可以在 Lua 块间 yield。HTTP 适配器先注册具体 reader 的取消清理，再调用 `length()`。

Reader 提供幂等的 `close()`。正常 EOF、输出错误或主动关闭后进入终止状态，再次 `next()` 返回明确的 closed 状态错误；需要再次输出时创建新的 reader。Source 和 overlay 快照至少保持到 reader 关闭，终止时释放 reader 持有的引用；不得关闭仍被其他分支持有的共享 Source。垃圾回收仅作为遗漏关闭的兜底。

输出长度必须按实际编码字节计算，包括转义、插入、删除和重复键处理。首版只发送长度已知的完整文档，更新 `Content-Length`，不保留旧长度，不假设 HTTP 库自动生成 chunk framing。

Reader 的源读取/编码错误必须传播给调用方。取消、失败后停止输出并释放 reader；组件与 OpenResty 示例不自动重试上游请求。

OpenResty HTTP 示例的 iterator wrapper 必须单独保存 `reader_error`，遇错中止发送并关闭连接，不能把 `(nil, err)` 简化成正常 EOF。记录请求头发送状态、已交付发送器的字节数和失败阶段；交付字节数不冒充对端已接收字节数。一旦请求头可能发出，零 body 字节也不等于可安全重试。故障测试验证调用方收到明确失败、连接关闭、资源释放，不引入任何 Gateway 业务状态机。

## 6. 输入源与执行阶段

### 6.1 完整内存输入

沿用现有 `qjson.decode(string)`，优先验证 overlay、fork 和 writer。保留原文生命周期；FFI 返回的 scratch 指针在下一次取值前复制或消耗，不跨 yield 持有可失效指针。

此阶段可减少解码与编码的额外分配，但不等同于完整的大请求内存解决方案。

### 6.2 已完成的文件输入

新增 Source 适配：先由 `ngx.req.read_body()` 等待 Nginx 完成请求接收，再使用 `ngx.req.get_body_data()` / `ngx.req.get_body_file()` 选择内存或文件源。文件源分块推进扫描与校验，不能用 `read("*a")` 或等价操作将文件重新读成一个字符串。

Rust 核心只消费已就绪数据，遇到尚未提供的文件窗口返回 `NEED_READ(offset, length)`；I/O 适配器负责取回数据并恢复操作，不在 Rust FFI 内同步读取任意长度文件或回调 Lua 挂起。

L2 明确采用窗口供给协议：Source 适配器拥有 fd；Rust 保存文档身份、绝对偏移及恢复状态，不拥有 fd，不保留借来的 Lua chunk 指针跨 FFI 返回。适配器读取窗口后调用新的 `provide_window` 接口，核心在调用中消耗该块；跨块语法状态保存在有界的解析状态中，需要保留的小字段复制到自有存储。大字段的原文仍由 Source 保存。若窗口未覆盖请求范围则返回 `NEED_READ`；声明的文件长度内提前 EOF、I/O 错误为终止错误，正常扫描 EOF 必须通过显式 `finish` 确认。新旧 Document 实现可并存，不能将旧 `&[u8]` 原地改为会移动的窗口。

文件读取仍可能阻塞 worker：普通 `io.read`、Rust `pread`、`mmap` 均不自动等于异步 I/O。初始完成文件适配可以采用有界分块读取并在块间让出，但必须标注其同步 I/O 性质、测量冷缓存下的 worker 延迟。生产启用门槛是通过服务既有延迟目标；若不通过，先增加独立 I/O 后端，再启用此路径，不宣称仅分块即可消除磁盘阻塞。

Source 通过引用计数/等价所有权覆盖 Document、子代理、Fork 和 Writer。至少持有打开的文件句柄，不能仅依赖路径长期存在。原始 Nginx 文件不由库擅自删除；自建暂存文件在全部引用释放或请求取消后清理，保留必要的延迟清理机制。Source 用于请求内处理，不提供跨请求持久化机制。

OpenResty 示例必须显式配置 Nginx 请求体缓冲和磁盘临时目录。首轮验证以 `client_body_buffer_size=64k` 为可调实验值，非请求上限；检查大请求实际生成文件，小请求允许内存路径。暂存介质使用磁盘，不采用 tmpfs。通过并发上传实验确定临时磁盘预算；磁盘耗尽/读写失败明确终止，不能退化成无界内存缓存。相关参数进入示例配置和使用说明，不涉及 Kong 或 Kubernetes 部署配置。

### 6.3 持续增长的输入（已实现，finish 后查询）

`qjson.new_decoder(opts)` 提供 `feed(chunk)`、`finish()`、`abort(reason)`、`get(path)` 和幂等的 `close()`。原文进入可回读的文件暂存 Source，解析器记录绝对位置；不是向原来的借用切片直接追加数据。配置的 `temp_dir` 用于安全独占创建的暂存文件，在最终所有者释放时删除。

公开 Lua 查询状态为 `READY / NEED_INPUT / ABSENT / ERROR`。当前 decoder 在 `finish()` 完整校验成功前返回 `NEED_INPUT`，成功后才发布最终值或 `ABSENT`；`NEED_READ` 是 Rust 窗口协议的内部状态。重复键保持 last-wins，不能按第一个同名字段触发路由。尚未实现对象闭合即发布的提前查询。

Lua wrapper 在可 yield 的阶段等待输入推进；Rust 调用保持有界、不等待网络。原生 OpenResty `start_body` 的一个 producer 独占客户端输入，多个 `session:get` 等待者共享 decoder 和 semaphore。错误、显式关闭与取消唤醒全部等待者；pending/error 不会被当作缺失值。producer 仅调用一次 `finish` 并保存结果。

live socket 路径已在固定原生 OpenResty 版本上验证，仅支持 HTTP/1.1 + Content-Length 且无 Transfer-Encoding。HTTP/2 和 chunked 使用已完成请求体路径，并报告 fallback 原因。两种路径不混用 `ngx.req.socket` 与 `ngx.req.read_body`，也不轮询未完成的 Nginx 临时文件。文件读写仍是同步有界 I/O，块间 Lua yield 不等于异步磁盘后端。

OpenResty 示例在 EOF、finish 和完整 JSON 校验完成后才连接并发送测试上游。业务准入由调用方负责，组件不提前触发外部副作用。公开 API、所有权、错误返回及验证命令见[接口与验收记录](https://github.com/GYWang1983/lua-leanjson/blob/33d00b522d87cc760f757404186488453ffcb498/docs/verification/openresty-json-source.md)。

## 7. 仓库、构建与接入

- 独立 fork：`https://github.com/GYWang1983/lua-qjson`；保留 `upstream = api7/lua-qjson`。
- 实现、构建脚本、OpenResty 示例及测试均放在 fork 仓库内，不依赖本项目的 Kong 插件、配置文件或数据库。
- 示例构建固定 fork commit 和原生 OpenResty 镜像版本/摘要，不跟随移动的 `main` 或 `latest`。确切版本在实施计划中登记；设计基线不能冒充完成改造后的版本。
- 不替换 OpenResty 自带 `cjson`，通过 `require("qjson")` 显式使用派生组件。
- 在构建阶段编译 Rust 共享库，运行镜像以原生 OpenResty 为基础。提供最小 `nginx.conf`、Lua handler、测试上游和运行命令，不修改本项目的 Kong Dockerfile。
- 保留上游许可证和派生版本信息，校验目标架构、系统 ABI、FFI 符号和 Lua wrapper 版本一致；运行时不安装 Rust 工具链。
- Rust/Lua 库测试、原生 OpenResty HTTP 集成和性能实验分别报告。完整接收路径通过不代表 live socket 路径通过；本次结果不包含 Kong 或 Gateway 集成结论。

## 8. 实施里程碑与验收

| 里程碑 | 交付 | 完成条件 |
| --- | --- | --- |
| L1：库的修改与输出 | overlay、fork、代理状态隔离、reader；保持内存输入 | 改 model 不读取同层大字符串；分支隔离；嵌套修改与输出正确；输出不拼成完整字符串 |
| L2：文件 Source | 分块扫描/验证、可回读窗口、Source 生命周期 | 不把完整文件读入 Lua；长单字符串跨块验证正确；错误/取消无文件句柄泄漏；记录 I/O 延迟 |
| O1：原生 OpenResty 集成 | 内存/文件请求体入口、字段读取和修改示例、HTTP 分段输出 | 独立 OpenResty 实例完成端到端请求；对端收到正确 JSON 与字节长度；取消/错误正确释放资源；无需 Kong |
| L3/O2：增量输入 | 增长源、字段等待、受支持的 OpenResty HTTP 接入 | 各 token 边界切分正确；重复键契约已决定；断流唤醒；HTTP/2/chunked 完整接收路径正确；完整校验前未发送上游 |

O1 使用本地测试上游验证完整链路：接收 JSON → 读取少量字段 → 建立独立修改分支 → 修改/删除/新增字段 → 分段输出。以普通业务字段和大字符串为测试数据，不实现 LLM 协议转换、Provider Driver、路由或计费。

分别覆盖内存请求体与落盘请求体，验证实际经过对应 Source。测试上游逐块统计字节数或摘要，避免测试接收器的完整聚合掩盖被测进程内存表现；内容正确性另用独立的可解析结果比对。库支持范围外的操作必须显式报错或要求调用方显式物化，不能自动退回完整解码。

原生 OpenResty 验收覆盖畸形 JSON、读取失败、输出中断、客户端取消、上游关闭和并发请求；验证失败未被当作正常 EOF、没有自动重试、文件句柄与 Source 按所有权释放。输出允许无关空白差异，逻辑字段、值、类型必须一致。测试重复键的原文保留及规范化两种模式；HTTP 转发示例选用 last-wins 单键规范化输出，避免解析端对重复键采用不同语义。

L1 的发布验收只承诺三个可测不变量：修改 model 不物化兄弟大字符串，多分支不递归复制原文，reader 不拼接完整输出。只有 L2/O1 对应路径通过后，才报告原生 OpenResty 文件输入路径的进程峰值内存改善。首轮 O1 基于完整接收请求，不能宣传为边上传边转发。

库正确性用差分测试、上游 JSONTestSuite 和针对性属性测试验证：空对象/数组、null、Unicode/转义、重复键、任意分块、内部属性同名 key、先读后写数组、父节点替换、跨分支复制、多个 Fork 与 Writer 生命周期。

内存验收必须同时覆盖：嵌套长消息、顶层长 input、转义密集字符串、大量短元素、多个分支、并发请求和显式读取大字段。检查 Lua heap、Rust heap 与进程/容器 RSS，不能只把分配从 Lua 移到 Rust 后宣布完成。记录原文大小、索引大小、实际物化字节数、overlay 大小、输出最大 chunk、CPU、磁盘 I/O、worker 延迟及上游首字节时间；与同一 OpenResty 环境下的完整 `cjson.decode/encode` 对照，不预设无依据的提升倍数，并记录硬件、输入及并发条件。

已完成的 ARM64 原生实测见[验收记录与原始 JSONL](https://github.com/GYWang1983/lua-leanjson/blob/33d00b522d87cc760f757404186488453ffcb498/docs/verification/openresty-json-source.md#paired-local-measurements)：长字符串输入降低了 RSS，但增加了部分延迟和 CPU 开销；大量短对象输入的内存和吞吐明显退化，是当前发布边界，不能宣传为所有 JSON 形状都更快或更省内存。未提供准确接口的 Rust heap、结构索引和 overlay 分配计数明确记为 unavailable/null，不从 RSS 推算。

## 9. 参考

- [上游固定基线](https://github.com/api7/lua-qjson/tree/8e1b394e0dd0322bedae3a9fc87d15d8049a02ce)
- [上游 Lua 代理和编码器](https://github.com/api7/lua-qjson/blob/8e1b394e0dd0322bedae3a9fc87d15d8049a02ce/lua/qjson/table.lua)
- [上游 Rust Document](https://github.com/api7/lua-qjson/blob/8e1b394e0dd0322bedae3a9fc87d15d8049a02ce/src/doc.rs)
- [上游迁移指南](https://github.com/api7/lua-qjson/blob/8e1b394e0dd0322bedae3a9fc87d15d8049a02ce/docs/migrating-from-cjson.md)
- [OpenResty 请求体接口](https://github.com/openresty/lua-nginx-module/blob/v0.10.26/README.markdown#ngxreqsocket)
