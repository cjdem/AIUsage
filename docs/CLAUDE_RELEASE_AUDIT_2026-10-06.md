# Claude 发布前检查

检查时间：2026-10-06，基线 `7935fe0feac7bb8a30b4ba86f52e1e15f3f4cf90`，当前未提交改动。

当前状态：**初审六项缺陷及复审两项缺陷已修复，发布测试缺口已补齐，暂未发布。** 下文保留审查证据与各次复验结果。真实 Pro/Max 额度对照、双真实账号隔离和最终分发签名仍待验收。没有修改真实登录或代理配置。

## 初次审查结果

| 检查 | 结果 |
| --- | --- |
| QuotaBackend 全量测试 | 335 项通过，0 失败；Claude helper 测试已配置真实构建产物 |
| App 账号身份回归 | 67 项断言通过；正式保存/协调/隐藏/删除源码，系统存储替换为内存 |
| SwiftPM Release | 构建通过 |
| macOS App Release | 构建通过；临时 Bundle ID、ad-hoc 签名，非正式发布包 |
| 签名完整性 | `codesign --verify --deep --strict` 通过，不等于公证验收 |
| 工程与差异 | `plutil -lint`、`git diff --check` 通过 |
| 运行隔离 | 正式 App 和 5 个既有 QuotaServer 进程仍运行，未启动测试代理 |

检查包含所有已跟踪改动及新 Claude 服务、视图、订阅/Token/调用账本文件；无关的截图与 downloads 未修改。测试通过不覆盖下列新复现问题。

## 初次审查发现（已修复，原始证据）

### R1 / P1：调用账本缺少持久化事件身份，重扫会重复或漏计

位置：`QuotaBackend/Sources/QuotaBackend/CallAnalytics/ClaudeCallLedgerStore.swift:48-64`，`ClaudeCallEventSource.swift:137-139`。

账本按文件路径保存日聚合，重扫时保留旧计数残差，不保存工具调用 ID。`seenToolIDs` 只在单个文件的一次扫描内去重。

已复现：

- 同一响应跨午夜，先 UTC 后上海时区重启：调用数 **1 → 2**，落在两个日期。
- 子代理初次缺少 `.meta.json`，之后补上 Explore 类型并追加日志：调用数 **1 → 2**，同时保留 subagent 与 Explore。
- 复制同一 JSONL 为另一文件：Token 正确保持 1 条，调用数却为 **2**。
- 文件由 A+B 裁剪为 B+C：实际累计应为 **3**，账本仍为 **2**。
- 首次迁移只有旧日聚合、没有源日志，之后恢复该旧日志：调用数 **1 → 2**。固定的 legacyResidual 不再与恢复数据重新协调。

前三种重分类/复制和裁剪问题可以用稳定的会话/工具事件 ID 解决，日期与 agent 作为可更新属性。迁移前聚合没有事件 ID，不能宣称可精确去重；需要单独规定恢复后协调规则及不确定口径，不直接相加。

验收：上述场景连续刷新、重启后计数稳定；补齐 tool_result 只更新结果，不增加调用。旧聚合恢复场景不把可能重叠数据当作已确认新调用。

### R2 / P1：默认 Claude 配置与旧节点全量写入不兼容

位置：`AIUsage/ViewModels/ClaudeSettingsManager.swift:207-209`；调用路径为 `ProxyViewModel+ProxyServer.activateRuntime → ProxyRuntimeService.activateRuntime → writeFullSettings`。

连接弹窗允许选择现有 `~/.claude`。安装额度回传后，如果启用采用完整 settings 的旧节点，`writeFullSettings` 会把 statusLine 覆盖掉。隔离测试编译正式 ClaudeSettingsManager 与订阅 Connection/Provider：状态 **waiting → disconnected**，profile 仍登记为已安装。继续写第二节点并恢复备份，状态仍为 disconnected。

修复边界：保护当前仍属于 AIUsage 的 statusLine，不覆盖用户自行修改的命令；同时检查备份恢复。不能通过禁止用户选择现有目录绕开已支持的功能。

验收：连接默认目录后，节点激活、切换和停用不会丢回传；订阅新会话与代理新会话仍按原认证隔离，其他设置和原状态栏保持。

### R3 / P1：新增响应 ID 集合导致主线程归档折叠退化

位置：`AIUsage/ViewModels/ProxyViewModel+UsageArchive.swift:39-43`；`AIUsage/Models/ProxyUsageArchive.swift:147`。

折叠循环复制 day/model 聚合、插入 responseMessageIds，再回写字典。随着集合增长，Swift copy-on-write 反复复制集合。该循环位于 ProxyViewModel 主线程，持久化周期和刷新前都会执行；后台编码不能消除这段主线程工作。

Release `-O` 隔离测试，编译正式 ProxyUsageArchive 聚合源码，用与正式循环同形的日/模型容器：

| 同日同模型请求 | 无响应 ID | 当前有响应 ID | 原地聚合验证 |
| --- | --- | --- | --- |
| 1,000 | 0.00072 s | 0.00315 s | 0.00037 s |
| 5,000 | 0.00268 s | 0.05875 s | 0.00078 s |
| 10,000 | 0.00254 s | 0.14690 s | 0.00144 s |
| 20,000 | 0.00454 s | **0.60205 s** | **0.00292 s** |

这是聚合组件实测，不是对正式 App 的 UI 卡顿录像。主线程调用位置由源码确认；随记录数增长的非线性耗时足以构成发布风险。原地聚合只在临时测试程序中验证，产品代码未改。

建议先使用字典原地修改，避免反复复制大型集合；不需要新增复杂缓存或持久化框架。验收需保留响应去重、费用冻结与刷新幂等，并复测多模型/多节点。

### R4 / P2：旧代理归档换时区后会被重复计入非代理

位置：`QuotaBackend/Sources/QuotaBackend/Providers/ClaudeProvider.swift:36-43`；`ClaudeProvider+ProxyArchive.swift:53-60`。

旧归档没有响应 ID、也没有原始时区。待确认规则只比较代理归档日键与当前时区重算的 JSONL 日键。UTC 23:30 的同一请求，代理归档保存在 1 月 2 日；换上海时区后 JSONL 落在 1 月 3 日，绕过待确认规则。

隔离实测：总 Token **15 → 30**，待确认 Token 为 **0**。费用仍为原代理费用，但合计/非代理 Token 错误。

验收：旧归档时区未知或跨日时，不将无法证明直连的记录纳入合计；有精确响应 ID 的记录仍正常去重。无需改写冻结费用。

### R5 / P2：合法大行被静默漏计

位置：`QuotaBackend/Sources/QuotaBackend/Providers/ClaudeUsageLedger.swift:72-81`，共享行读取器 `CallAnalyticsSupport.swift:50-111`。

扫描只保留每行前 4 MB，然后将截断片段交给完整 JSON 解析。超过限制的合法行解析失败，但文件 fingerprint 仍记录为扫描完成，也没有部分采集提示。

包含 5 MB 文本、合法 assistant ID/模型/usage 的合成行：应有 **1** 条 Token 记录，实际为 **0**。限制存在于旧调用扫描，但本轮新 Token 采集同样受到影响。

验收：大正文不影响必要字段提取，或至少明确报告未完整采集并允许重试；不能一边漏计一边显示完整统计。保持有界内存，不单纯无限增加行缓冲。

### R6 / P2：原状态栏不读 stdin 时 helper 会被 SIGPIPE 终止

位置：`QuotaBackend/Sources/QuotaBackend/ClaudeSubscription/ClaudeSubscriptionStatusLine.swift:60-65`。

使用本次 Release QuotaServer，原命令为 `printf 'original-output'; exit 7`。1 KB 输入保持退出码 7；128 KB 合法 JSON 输入时，原输出仍存在，但 helper **被 signal 13 终止**，没有保留退出码 7。

原因：同步向管道写入全部 stdin，原命令提前关闭读取端，SIGPIPE 在 Swift 错误捕获之前终止进程。一般 statusLine 输入较小，但当前接口接受至 2 MB，现有兼容保证不能覆盖该边界。

验收：原命令完整读取、仅读取部分或完全不读取 stdin，输出和退出码均符合约定；不启动服务，不新增 Token 持久化。

## 扫描性能：优化项，非内存泄漏证据

Release 数据：约 **203 MB / 10,000 条响应**，单个持续追加的会话文件。

排除合成文件构造的独立扫描进程结果：

- Token 冷扫描 **1.30 s**，未变化 **0.00085 s**，追加一条 **1.21 s**。
- 调用冷扫描 **1.20 s**，未变化 **0.00038 s**，追加一条 **1.21 s**。
- 最大常驻内存约 **33.7 MB**，无 swap；仅为本样本，不代表长时间运行无泄漏。

缓存确实能跳过不变文件，但新增一行后仍重读、完整解析整个文件；Token 有变化还重写全量账本。默认本地用量刷新为 30 秒，调用分析默认随全局刷新。建议在正确性修复后，给追加型文件保留扫描位置，裁剪/替换时回退重扫；避免为纯文本 assistant 全量反序列化正文。无需把所有历史记录常驻多份。

## 复现材料与剩余验收

临时目录：`/private/tmp/aiusage-release-audit.thOVzb`。

- `ClaudeAudit.swift`：调用重扫、复制/裁剪/恢复、时区、大行和扫描压测；直接链接本次 QuotaBackend 对象。
- `SettingsAudit.swift`：正式 ClaudeSettingsManager + Connection/Provider 的临时 HOME 测试。
- `StatusLineAudit.swift`：真实 Release helper 子进程的 stdout/退出码验证。
- `ProxyFoldAudit.swift`：正式聚合源码的 copy-on-write 对照，原地聚合方案只在诊断程序中。

`claude-audit-release` 的正确性复现每次创建新的 fixture 根目录，可直接重复运行；`--perf` 和 `--perf-read` 使用固定压测目录。Release 构建已有其他模块的 actor 隔离/本地化警告，本轮未把这些既有警告误判为 Claude 新缺陷。

真实 Pro/Max 额度与官方页面同时间对照、两个真实订阅账号隔离、正式签名/公证仍未完成。以上全部使用合成日志和临时配置，未发送付费模型请求。本轮没有发布、提交或修复产品代码。

## 优化与复验（2026-10-06）

本节覆盖后续获授权的源码修复，不改变上述初次审查事实。

| 修复 | 结果 |
| --- | --- |
| R1 调用身份 | schema 2 保存工具 ID、会话身份和绝对时间；复制/裁剪/时区变更/agent 补全不新增同一事件；迟到结果可跨文件与重启配对 |
| R1 旧数据迁移 | 原路径原子升级；迁移前恢复日志动态协调，迁移后新调用独立增加；残差显示“旧记录待确认”，不计算无身份残差的成功率/耗时 |
| R2 配置回传 | 正式 ClaudeSettingsManager 全量写入、切换与备份恢复保持 waiting；已断开备份不复活失效 wrapper，用户改过的状态栏保留 |
| R3 日聚合 | 正式 foldDaysIntoUsageArchive 原位更新；多节点/模型/家族、费用冻结和重复折叠幂等通过 |
| R4 时区 | 旧代理日期按 UTC−12 至 UTC+14 候选日核对；合计保持 15 Token，另有 15 Token 待确认，不双计 |
| R5 大行 | 流式白名单投影跳过正文、图片和无关参数；5 MB 大行正常入账；字段超限明确失败并可重试，尾行未完成不推进游标 |
| R6 状态栏 | 写端禁止 SIGPIPE；原命令不读、读部分或完整读 stdin 时输出和退出码保持；Release helper 的 128 KB 输入退出码为 7 |

Release 正确性复验：时区切换 **1→1**、复制日志 **1**、迟到 Explore 类型 **1**、恢复旧日志 **1→1**、大行 **1 条**、A+B 改为 B+C **2→3**。还验证了仅补 `.meta.json` 不追加日志、共享父 sessionId 的两个子代理、裁剪后重启的会话身份、结果先恢复后工具日志恢复、schema 1 迁移和解析失败重试。

### 性能

同一约 203 MB / 10,000 响应文件，Release 独立扫描进程；追加时使用新的响应 ID，断言 Token 记录数增加 1，含账本写盘。

| 操作 | 初次审查 | 优化后 |
| --- | --- | --- |
| Token 冷扫 | 1.30 s | 1.10 s |
| Token 未变化 | 0.00085 s | 0.00116 s |
| Token 新增一条 | 1.21 s | **0.02787 s** |
| 调用冷扫 | 1.20 s | 1.17 s |
| 调用未变化 | 0.00038 s | 0.00091 s |
| 调用新增一条 | 1.21 s | **0.04306 s** |

新增一条后的扫描耗时分别降低约 98% 和 96%。原始正文不落盘；读取缓冲 256 KB、统计投影上限 1 MB。内存中保留统计身份，不保留会话正文。最大常驻内存 **44,810,240 B（约 42.7 MiB）**，无 swap；该结果只覆盖本样本，不代表长期运行无泄漏。

压测曾发现新读取器的临时 Foundation 对象累计，使常驻峰值约 441 MiB；已用行级和读块级释放边界修正，复测为上述约 42.7 MiB。该中间版本未发布。

编译正式日聚合函数及 store、仅替换日志与落盘边界：1k / 5k / 10k / 20k 请求耗时为 1.74 / 1.00 / 2.14 / **4.08 ms**。此前同形循环 20k 为约 602 ms。正式函数测试含日替换与存储调度；无 GUI 卡顿录像，不把组件耗时描述成整应用帧率。

### 回归与构建

- 新增 13 项定向边界测试；QuotaBackend 全量 **348 项通过，0 失败、0 跳过**，helper 测试使用构建产物。
- App 正式账号保存/协调/隐藏/删除逻辑 **67 项身份断言通过**，系统存储为隔离内存。
- SwiftPM 与 macOS App Release 最终构建通过；临时 Bundle ID、ad-hoc 签名，`codesign --verify --deep --strict` 通过。App 包内最终 Release helper 的 9 项订阅测试通过；不等于正式发布签名/公证验收。
- 工程 `plutil -lint` 和 `git diff --check` 通过。
- 测试仅使用临时配置、合成日志与独立 Bundle ID；正式 App 和原有 5 个 QuotaServer 未停止。

优化诊断程序仍在 `/private/tmp/aiusage-release-audit.thOVzb`：`claude-audit-optimized`、`settings-audit-optimized`、`statusline-audit-optimized`、`proxy-fold-production-optimized`。长期回归用例已纳入 `ClaudeUsageLedgerTests.swift` 与 `ClaudeSubscriptionTests.swift`，不依赖临时诊断文件。

剩余发布验收：真实 Pro/Max 首个窗口与官方页面对照、两个真实账号隔离、正式发布签名与公证。没有提交、打标签、发布或替换已安装应用。

## 复审修复与验收（2026-10-06）

复审发现两项 P1 和一项 P2。本节为获授权后的修复结果；原始复现见临时报告 `/private/tmp/aiusage-prerelease-review.4wrvyP/REVIEW.md`。

### R7 / P1：状态栏递归串接

profile.json 缺失或损坏时，旧版重连把 settings.json 中的 AIUsage wrapper 保存为原状态栏。helper 执行旧 wrapper 时又加载同一 profile，形成递归。隔离 Release helper 复现到三层后由诊断脚本主动阻止，退出码 91；没有在真实配置中触发。

修复：现有 profile 解码失败明确停止，不覆盖备份；识别本配置的旧 wrapper，已有可读备份时沿用原命令，不再包裹 wrapper；没有备份或属于其他配置时保持 settings 不变并提示恢复。helper 对错误旧 profile 中的回传原命令直接拒绝执行。用户恢复正常 statusLine 后可以重新连接。

回归覆盖缺失/损坏元数据、旧 wrapper 恢复、停用后手动恢复旧 wrapper、正常原命令及退出码、旧 profile 执行保护。新增三项订阅测试，原有行为保持。

### R8 / P1：删除或清理后历史费用与身份丢失

复审实测同日两节点：删除一个后再次折叠，费用 $0.002→$0.001、代理 Token 30→15，响应 ID 消失；对应 JSONL 被误判为 Non-Proxy。

修复：在删除节点、单节点清空、全部清空、过期裁剪前冻结将移除的聚合。日桶新增可选 retainedModels 和 retainedRequestIds；models 始终是完整总量，后端无需相加新字段，旧 v1 桶解码为空冻结区。保留费用、Token、surface/session 维度与响应身份。后续实时日志按日重算后合入冻结贡献；恢复的已冻结请求按 ID 跳过，重复清理不重复加账。保留身份跨日键与节点存在状态匹配。

身份集合在加载/清理时维护，正常刷新不重新构造全历史 Set。Release -O 组件实测：20,000 条实时日志折叠 **4.03 ms**；冻结 20,000 条 **11.43 ms**；保留 20,000 条后新增一条重算 **1.72 ms**。按 App 的 MainActor 默认隔离编译复测分别约 **5.94 / 13.92 / 1.94 ms**，后台编码运行正常。这是组件结果，不是 GUI 帧率。

新增持久回归 `scripts/run_proxy_usage_archive_regression.sh`，直接编译正式折叠函数和归档 store，替换日志入口及 HOME。同模型/不同模型均覆盖删除、重复冻结、恢复旧分片、继续请求、单节点清理、全部清理、重新读盘、旧 schema、维度与正式 ClaudeProvider 去重。冻结前后费用不变，不出现 Non-Proxy 误分类。

### R9 / P2：最终 helper 未参与发布测试

发布 CI 在最终 ZIP 解压、签名/布局核验后，将 AIUSAGE_TEST_CLAUDE_HELPER 指向解压的 Contents/Helpers/QuotaServer，执行全部 ClaudeSubscriptionTests；另加入归档保留回归。路径无效会导致实际执行失败，不再靠缺失变量跳过。

本地复验采用隔离 arm64/ad-hoc Release App 的 ZIP，解压后 deep/strict 签名完整性通过，解压 helper 的 **12 项订阅测试全部通过、0 跳过**。这验证新步骤的行为，不等于 GitHub Actions 已运行或正式 Universal 分发包验收。

### 最终检查

- QuotaBackend 全量 **351 项通过，0 失败、0 跳过**，使用修复后的 App 包内 Release helper。
- 正式账号保存/协调/隐藏/删除逻辑 **67 项身份断言通过**，隔离存储。
- macOS Release 构建退出码 0；最终源码时间早于产物，签名完整性及 ZIP 解压 helper 测试通过。
- 归档保留回归同模型/不同模型均通过，旧模型桶可解码；shell syntax、发布 YAML、工程 lint 与 git diff --check 通过。
- 既有其他模块 actor 隔离/本地化警告仍存在；未在本轮扩展为全项目重构。归档使用现有 Swift 5 后台编码路径，按正式默认隔离的组件运行已验证。
- 正式 App 697 及原有五个 QuotaServer 1083/1100/1108/1111/3571 一直运行。没有修改真实账号、登录、代理配置，没有付费模型调用、提交或发布。

本轮诊断及构建日志：`/private/tmp/aiusage-claude-hardening.9zjJGa`。剩余发布验收仍为真实额度对照、双真实账号与最终分发包/稳定签名；原始日志已在修复前永久丢失的历史不能从聚合推回。
