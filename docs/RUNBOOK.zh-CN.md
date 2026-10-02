# LicoUp 开发者指南

Updated: 2026-10-01

[English](RUNBOOK.md) · [文档入口](README.md) · [参与贡献](../CONTRIBUTING.zh-CN.md) · [安全](../SECURITY.zh-CN.md)

`nightly` 是唯一的集成主干。产品改动通过[参与贡献](../CONTRIBUTING.zh-CN.md)所述的
Pull Request 进入；受保护晋升链从 `nightly` 出发，不接受直接开发提交。本指南说明
LicoUp 的边界与设计取舍；可执行事实归测试和配置。

## 先调查，再设计

完成所请求范围及其实际依赖的调查，才能编写计划、派发 Designer、提出里程碑划分、
讨论需求和设计取舍或修改项目。调查须核对规则、历史需求、当前生产路径、契约和
工程覆盖，分清已发布能力、部分实现、缺失接线、未验证行为及废弃提案。历史计划
中的完成标记不能代替当前源码依据；可查清的问题和证据冲突须先解决。

独立的只读调查可以并行，但主智能体须先汇总证据，再交给 Designer。交接包含目标、
现状依据、需求出处、依赖边界和真正需要维护者决定的问题。调查完成前，只询问完成
调查所缺的信息或访问条件，不让维护者批准猜测的划分，也不要求其重复可查到的事实。
缺少依据的部分如实记录，依赖该依据的设计保持待定。

调查结论写入既有私有工作记录，不另设永久报告或强制门禁。汇总完成后再讨论重要
取舍、形成设计，并在实现前取得必要批准。新证据与设计冲突时，先补查受影响范围，
不借此扩大交付目标。

## 需求讨论与里程碑边界

调查完成后，开发前讨论需求；影响范围、设计、契约、权限、依赖和完成条件的重要问题
须与维护者确认，记录决定及理由，并提供具体选项。计划草案和沉默都不表示批准。既定
目标内的普通实现选择和修复由实现者负责，无需反复确认。

选定一个有明确成果和停止条件的已批准里程碑，一次只推进一个。先解决本项遗留缺陷和
被替代路径，再扩充功能。里程碑内独立且已就绪的任务分配给不同执行者并并行推进；
保持依赖顺序，共享集成文件只有一个属主。达到批准的推进条件前，后续里程碑保持
不启动。完成当前里程碑工程交接就停止；显式的有限程序安排可以在当前里程碑通过评审
并记录交付后，授权继续推进下一个依赖已满足的里程碑，除此之外不得自动推进路线图。

静态源码审查须覆盖完整生产路径、受影响契约、数据属主、状态转移和失败恢复。完成
范围内修复及定向测试后，再执行最终确定性回归。测试通过不代替源码审查，静态审查也
不代替行为测试。实现缺口、工程检查失败和真实验收待确认项分别报告。

客户端打包、安装、真实数据迁移、启动及真实验收，由维护者指派的交付负责人针对
整合候选统一执行。模块实现者不自行操作已安装客户端；必要编译、合成单元测试、
契约测试和隔离集成测试仍属于工程开发。

## 智能体协作

以下角色规则适用于智能体；人类贡献者无需模拟智能体团队。

- 设计者从主智能体汇总的调查出发，在派发前识别所有受影响模块与边界。为每个模块
  指定不同执行者，并明确新建、修改、删除范围；契约变更必须包含生产者和消费者，
  共享文件只有一个属主。
- 模块执行者先阅读所属测试、配置和架构文档，只修改自己的范围；邻接契约需要变更时
  先反馈设计者。不修改其他属主的文件，也不回退他们的工作。独立模块工作可以并行。
- 复核者整合各模块提交，检查变更边界的两端，再验证完整功能。主智能体整理集成 PR。
  修正可以用后续提交；每个受影响模块至少有一个可归属提交。

用回归目录查询变更路径对应的已登记检查：

```sh
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
```

目录选择只回答哪些已登记套件覆盖变更路径，它不等于完整影响图：未映射的路径必须
核对属主，受影响的生产者和消费者仍需人工检查，计划也不能作为依赖已覆盖的证据。

### 一个工作树只有一个写者

并行需要各自独立的工作树，而不是各自独立的意图。同一检出里的两个写者不只是 Git
冲突：它们会互相编译对方尚未完成的迁移，于是"绿灯"描述的是一棵从未存在过的树。
派发者也是写者——在别的智能体持有该检出的任务期间，派发者只能读和规划，不能改。

每个并行工作流使用自己的工作树：

```sh
git worktree add ../LicoUp-android feature/android-native
git worktree add ../LicoUp-ios feature/ios-native
```

`build/` 已被忽略，因此每个工作树自动拥有自己的 Cargo target 目录、夹具根、租约与
生成的报告，各自的验证只描述自己的改动。

文件集不相交时可以并行：改写 `crates/` 的交付与只写自己应用根的移动端交付不碰
同一批文件。共享文件时必须串行：两个都要改写 crate manifest 与模块接线（wiring）
的任务，无论主题多独立，都只能在一个树里一次一个。把它们排成"并行"的计划，并没有
真正排序。

完整回归的并发度由机器核数推导；本版本运行器不接受显式预算选项。当另一个工作树或
长时间构建共用这台主机时，只选择受影响的模块，不运行完整回归；报告结果时说明主机
被共用，因为同一条命令在同一台主机上、不同负载下是不同的测量。

## 环境准备与启动

工具链版本以清单为准。准备检出环境执行 `npm ci`、`npm run client:get`；明确指派的
客户端操作使用 `npm run client:run:macos` 或对应 Android/iOS 命令；准备环境不构成
启动客户端的授权。

## 设计边界

领域决策、宿主副作用、传输和表现层分离；接口由消费者定义，UI 投影领域状态。
按职责命名模块；重构遵守已发布契约的明确支持义务。对于项目自有且尚未发布的代码，
遵循[开发状态规则](../AGENTS.md#development-state-and-corrections)，直接修正错误
契约，并同步修改生产者、消费者、测试和文档。已有实现不构成行为必须保留的依据。
新增行为前先解决所选功能范围内的遗留缺陷，删除被取代的路径，不为错误实现建立新的
兼容版本。

状态转移以配置为权威，由模块执行器读取；文档和手写分支不再各维护一份转移表。测试
针对配置断言行为。每台状态机须在 `tools/development/state-machines.json` 登记其配置、
执行器和所属验证，使报告和复核者能找到来源。登记表及其报告页只列出已登记来源，
不校验、不生成、也不执行状态机；编译和行为由所属测试验证——`crates/licoup-state-machine-codegen/tests/`
下的代码生成套件，以及所属模块的目录命令。只修改配置，不手改生成表。

## 模块属主与已登记检查

`tools/regression/` 下的回归目录负责模块选择和登记命令。`npm run client:regression:list`
列出模块；`docs/architecture/` 下的架构文档持有边界与设计契约。本版本不提供按模块
划分的开发者指南：修改模块前阅读所属测试、配置和架构文档。目录选择只回答变更路径
由哪些已登记套件覆盖；生产者和消费者仍需人工检查，未映射的路径应作为属主缺口报告。

## 开发与验证

运行所属模块的登记命令，例如：

```sh
npm run client:regression -- --module <module-id>
```

用 `npm run client:regression:list` 发现模块 id 和更细的既有套件。开发中只验证受
影响套件；共享语义或传输变更包含依赖消费者，适配器专属改动留在该适配器。使用
合成、脱敏的测试数据。未经显式要求，不启动真实 Agent 或在线服务。

交付前，将批准范围内的每项要求对应到生产实现和工程验证证据，补齐功能及实际接线，
不以一次成功演示缩小交付范围。区分实现缺口与实现完成但外部行为尚待真实确认的情况。

DSL 解析与语义、配置驱动的状态转移和守卫、调度、取消、存储和恢复，应通过真实属主
配合确定性输入、合成事件及隔离集成环境验证。模拟外部边界，不替换需要验证的生产
逻辑；覆盖受影响的实际应用组装，避免纯核心通过而应用未接通。

真实 Agent 对话和开发任务属于用户另行指定智能体执行的独立验收流程。实现者须先
完成全部无需此类调用的验证，再交付可构建、可在本地正常启动的客户端。交接时明确
仍需真实确认的具体事项并保留未验证状态，不自行调用 Agent 或派发真实验收任务来
替代工程工作。已授权的构建、安装、数据迁移和打开客户端不包含 Computer Use、读取
真实客户端界面或操作真实用户场景。完成要求的启动后停止，报告工具执行结果，不以
启动检查为名自行进入界面验收。

保持每项改动可独立验证。最终检查前阅读[收口指南](CLOSURE.md)，完成范围内修复和
源码审阅；所有编写者结束后再执行全量回归。缺少环境的检查保持未验证状态。

### 定向验证

列出维护中的回归模块并预览按变更选择的结果：

```bash
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
```

运行最小的所属模块：

```bash
npm run client:regression -- --module <module-id>
```

完整客户端回归是一张限并发分阶段依赖图：

```text
foundation -> (frontend || backend) -> integration -> scenarios -> compatibility
```

开发中使用独立阶段入口；排查平台或 Agent 运行时前使用独立探测：

```bash
npm run client:regression:frontend
npm run client:regression:backend
npm run client:regression:integration
npm run client:regression:environment -- --platform android
npm run client:regression:environment -- --agent codex
```

共享基础之后前端与后端并行；核心阶段收口后，本机可用的平台和 Agent 目标再并行。
缺少可选的宿主、SDK、设备或 Agent 可执行文件时记录为 `unverified`，不会变成假通过，
也不会使核心失败。Agent 静态校验先运行一份共享清单/模式契约，再分别运行各 Agent
独立契约，因此单个适配器损坏只影响它自己的实时分支。聚合的 Node 测试通过匿名数字
报告器把失败输入归属回模块 id；重试只选择失败成员，而不是整批。归属不完整时保持
`attribution-pending`。
每条命令记录墙钟时间和如实标注的已测量/不可用资源模式；Rust 另外记录 Cargo/libtest
原生计时事实，Flutter 将其 JSON 报告流归约为匿名计数和时长。报告私下写入
`build/reports/client-module-regression.json`，不含命令输出、路径、参数、环境值、
PID 或运行时负载。

只重派发失败、归属待定或阻塞的核心成员，以及失败的兼容性目标：

```bash
npm run client:regression -- \
  --retry-report build/reports/client-module-regression.json
```

常用定向检查：

| 变更 | 命令 |
| --- | --- |
| 公开文档与链接 | `npm run repo:docs` |
| 仓库隐私边界 | `npm run repo:local-info-hygiene` |
| 依赖目录边界 | `npm run repo:workspace-cache-boundary` |
| Flutter 源码 | `npm run client:analyze` |
| Flutter 行为 | `npm run client:test` |
| 原生客户端 | `npm run client:native:test` |
| 客户端契约 | `npm run client:contracts:test` |
| 架构边界 | `npm run client:verify:architecture` |
| 版本与生成兼容性 | `npm run client:version:check` |

所有定向检查通过后只运行一次 `npm run client:gate:source`，然后只运行受影响的
`client:gate:flutter`、`client:gate:rust`、`client:gate:android` 或
`client:gate:dependencies` 通道。这些回归通道相互独立，可以并行。发布策略只在
[`releases/PROMOTION-GATES.md`](releases/PROMOTION-GATES.md) 所述的 `stable` →
`release` 晋升边运行。源码策略只依赖 Node，不安装平台工具链，也不构成对在线服务、
运行时数据采集、设备安装、签名、发布或商店操作的授权。

### 静态架构指标

`npm run client:verify:architecture` 以架构棘轮阶段收尾，测量五项静态指标，
并输出用于里程碑检查结果的数值记录：

- 内核 Cargo 对可选能力 crate 的依赖；
- `licoup-native` 中 domain/platform 与 platform/domain 的跨层导入文件；
- 单一定义范围内 `licoup-native` 的 Rust 规模；
- 打包模块集合包含的可选能力；
- 源码已解析的开发工具落点，以及逐项审阅的运行时选择进程接口；保留各边界的身份、用途和来源。

精确范围、可选 crate 与打包属主映射、已有依据的开发工具例外表位于
`apps/desktop/scripts/client-architecture/ratchet/definitions.mjs`；每项指标同时
在验证报告的 `details.definition` 中输出其定义。Cargo 清单图使用固定版本的
`smol-toml` 开发依赖解析，按 Cargo 声明读取工作区继承、重命名与路径本地性。

进程边界明确分为：源码已解析的工具目标、逐项审阅的运行时选择接口，以及真实
分析失败。文件中出现的工具名称只是诊断线索，不是目标归属。
`ratchet/runtime-interfaces.mjs` 中的审阅清单绑定每个精确落点、实现/选择器/脚本
源码摘要和用途；它不是宽泛路径或工具例外，也不授予执行权限。配置与发现返回值
的来源摘要必须对应真实源码声明和选择操作，不能消除不相关的有限表达式不支持、
API 身份未解析、源码损坏、绑定缺失或 I/O 失败。

运行时接口仍计入 `processExecutionBoundaries`，并单独报告为
`reviewedRuntimeSelectedInterfaces`；已解析工具另计。字面量工具为零不代表没有
依赖或进程边界债务。可比较身份包含审阅用途、选择器与来源合同。源码或模板改变
会使原证明失效，必须重新审阅；新增、替换或重复落点不能沿用其他记录。清单不会
自动刷新。更新精确摘要或合同前必须审阅受影响源码及消费者，不能为了让指标可
枚举而限制合法运行时选择，也不能把有限范围的静态分析当作完整部署就绪证明。

Cargo 激活包含默认 feature、依赖的 feature 请求以及强弱转发；弱转发不激活
尚未启用的可选依赖。能力属主表必须完整解析，无法支持的表达式或本地图覆盖应
拒绝测量，而不是静默消除可选依赖债务。声明的二进制目标必须有源文件；自动
发现二进制遵守 `autobins`。

必需输入丢失、源码不可读、运行时接口未审阅或真实进程分析失败时，检查与报告均输出
`measurement-refused`。部分观察仍是诊断证据，但可比较数值记录为 null，不报告
或记录改善。不能推断未知可执行文件无害，也不得执行或探查外部 Agent 协议来
消除未知。已解析工具的审阅指纹保留字符串字面量字节并绑定精确工具集合；不得
用附近出现的名称给有意保留的动态接口强行指定工具类别。

已记录的数值和集合只能向改善方向移动。数值增加或集合新增成员会报告具体条目
并使检查失败；改善则通过并提示更新基线。首次可比较基线仅在完整整合候选上用
`node apps/desktop/scripts/verify-client-architecture.mjs --record-ratchet-baseline`
记录，写入 `apps/desktop/scripts/client-architecture/ratchet/baseline.json`，拒绝
不完整输入或提高已记录值。损坏、不可读的基线不能视作不存在；未记录基线按设计
使检查失败。安装体积、全新最小安装后的进程、监听端口与登录项属于另行指派的
已安装候选证据，不在这里测量。

### 诊断失败检查

1. 只重跑失败的定向命令，不重跑完整套件。
2. 在假定编译器输出过期前检查 `npm run client:artifacts:status`。
3. 用 `npm run client:regression -- --changed-from <ref> --dry-run` 确认模块归属。
4. 日志和原始输出留在本地。留存证据只记录稳定错误码、仓库相对路径、计数和不可逆摘要。
5. 若失败需要设备、凭据、网络服务、安装程序或发布权限，先停止并报告该前置条件，
   不得继续执行有副作用的命令。

## 执行指派的 Agent 对话验收

只有维护者指派的交付负责人在整合后的普通 Release 候选上执行真实验收。先记录候选
身份，停止所有已安装写者，为同一选定数据根创建一致、可恢复的备份，包括应用自有的
加密文件。平台持有的密钥保持原位，不读取、不导出。

让候选的正常启动准入处理选定数据根，然后再打开可变存储。若引导准入失败，停止验收
并向维护者记录候选的有界错误证据。常规验收不需要单独的公开只读状态检查命令，也不
需要手动调用准入命令。

使用四个已配置目标——Codex、Cursor、Antigravity 和 DeepSeek Harness——及其在
[维护的选型配置](../tools/scripts/config/agent-conversation-verification-models.toml)
中的确切模型、提供方和独立思考档位。Cursor 和 Antigravity 不使用单独的思考档位；
Antigravity 选定的模型已经标识其档位。

通过 CUA 在同一数据根上依次运行四个目标。每个模型只提交一次纯文本 `Hi`，接受其
实际回复，不要求格式。只保留候选身份、所选模型/提供方/档位、提交与回复状态和结果；
不保留对话历史或回复内容。

## 构建客户端或发布包

平台构建命令产生可运行的客户端构建输出：

```bash
npm run client:package:plan
npm run client:build -- --platform macos
npm run client:build -- --platform windows
npm run client:build -- --platform linux
npm run client:build -- --platform android
```

`client:build` 是唯一的客户端构建入口。它在每次构建后清理未激活的编译器输出和临时
Flutter 构建缓存，同时保留平台安装程序使用的已暂存可运行/打包输出。

要规划一个或多个确切的本地发布包，使用共享选择器：

```bash
npm run client:release:plan -- --target macos-direct-arm64
npm run client:release:plan -- \
  --targets macos-direct-arm64,android-direct-arm64-v8a
```

同一选择器也被 `client:release:build`、`client:release:stage` 和
`client:release:verify` 接受。规范包叶写入 `build/releases/<version>/<package-target>/`；
不创建通用外层归档。本地构建不是正式发布制品；正式制品来自精确接受的
`origin/release` 来源，由明确授权的发布负责人产出，并绑定来源、包目标、不可变摘要
和生成元数据。

## 恢复本地生成状态

打包命令自动移除自己当前的暂存目录，并在下次运行开始前，让所属进程已停止的、
确属项目自有的旧暂存名退休。它们不处理可运行 bundle、`build/releases/<version>/<package-target>/`、
旧名称或未知名称、依赖缓存、SDK、工具链、用户数据、已安装应用或工作树。不安全的
条目和清理失败会让打包流程停在稳定的 `flutter-clean-build-*` 或 `release-package-*`
阶段，而不暴露本地路径。

由仓库生命周期管理的编译器输出可在回收前预览：

```bash
npm run client:artifacts:prune -- --dry-run
```

核对确切的受管目标后再运行：

```bash
npm run client:artifacts:prune
```

生命周期不得删除依赖下载、SDK、包管理器缓存或活动编译器输出。`build/` 与 `cache/`
保存可复现的本地资产，绝不能作为正式发布的唯一来源。

## 校验发布来源

强制且无副作用的来源策略是：

```bash
npm run client:gate:source
```

当产品版本、目标目录、支持目录或原生驱动清单变化时，必须刷新并校验生成的兼容性
投影：

```bash
npm run client:support-matrix:sync
npm run client:support-matrix:check
```

在设备上安装或启动、使用受保护平台身份、访问在线服务、创建发布制品或通过渠道发布
的命令，都是单独的需操作者授权的动作。其成功不能从源码或包构建推断。

仓库分支训练不发布。发布后的 macOS 公开发布由 Apple Release 从精确接受的
`origin/release` 来源委托执行，不能改动仓库源码或受保护分支。规范目标与输出模型见
[发布包结构](RELEASE-PACKAGES.zh-CN.md)。同源草稿可以续用；已公开的 Release 不得
扩展或改动。损坏的公开资产需要纠正构建或新版本。

## 文档

只保留外部贡献者和用户必须知道的设计取舍、模块边界、用法和固定命令。引用权威，
不重复测试断言、状态表、脚本实现和动态验收结论。只描述已经实现的能力和现行规则；
实现移除时同步删除对应说明，不把提案写成当前行为。

每份维护的 Markdown 文档须有 `Updated: YYYY-MM-DD`。修改内容时更新日期；生成文档
仅在源内容变化时更新内容日期。日期不证明正确，也不得用批量改日期伪装内容审核。
`npm run repo:docs` 检查必需的公开文件、索引覆盖、语言配对和链接目标。交付收口时
仍须人工审阅含义与时效。

修改文档前运行：

```bash
lico-dev context <changed-path>
```

公开文档布局以 [`docs/README.md`](README.md) 为索引。架构、功能、协议、示例和已采纳
的 ADR 留在各自目录。计划和报告留在被忽略的 `docs/plans/`、`docs/reports/`；生成或
运行时资产留在被忽略的 `build/`、`cache/`。

移动公开文档时，须在同一次改动内更新旧路径与新路径、主索引、交叉链接、双语映射、
生成器、测试、回归目录、打包/发布引用和忽略规则。删除旧条目和重复事实源。迁移
期间做一次性搜索，不保留旧路径缺失检查作为永久门禁。

本地工作流、状态机和架构页面从维护中的报告来源显式生成：

```bash
node tools/development/reports.mjs
node tools/development/reports.mjs --better-plan <local-source>
```

输出留在被忽略的 `build/reports/`。第二种形式为私有规划工作区增加一个显式选择的
只读 Better Plan 投影。报告是英文，不随客户端分发，不运行检查或 Agent，也不是执行
权威；详见[工作流与报告来源](../tools/development/workflows/README.md)。

交付前运行：

```bash
npm run repo:docs
npm run repo:local-info-hygiene
```

正式文档只陈述已经实现并验证的行为。需求、未来设计、进展、检查点、原始审计输出和
未验证结论留在本地计划或报告材料中。

### Continuous Assistant 语料收集 Unknown

语料收集 claim 在首次原生调用前转为 `NotExecuted`，即将首次原生调用时转为
`Unknown`。`Unknown` 不能证明尚未执行。同一会话再次收集只返回对账，不会重派。

出现 `Unknown` 后，由 owner 重新准入新会话继续。已有证据身份仍阻止同一候选二次
提交。调用前失败保持 `NotExecuted` 并释放 claim。缺少运行时（或其他与语料无关的
原因）修复后可在同一会话重试。缺少或已变更的语料需要 owner 签发绑定该语料的新评估
会话；恢复完全相同的原始语料后，原会话才可以重试。

### 推进作者 README 更新

README 快速通道是作者自有的正向维护能力，用于快速修正不准确、过期或不合适的公开
文档，不是漏洞或 CI 绕过。其维护名单由 `tools/scripts/config/readme-fast-files.json`
定义；清单本身是隐式成员。

更新清单时，允许的文件是旧清单、新清单和清单本身的并集。作者因此可以在同一次提交
中增删名单资源。不属于该并集的文件、不可读清单或不确定分类，自动改用普通流程。

只有 Auditor 会扫描新增和修改的 blob 是否含敏感信息。其他必需检查保持原名称并快速
返回，不检查 README 的措辞、语言、链接、格式、声明或产品正确性。Agent 行为由
`lico-client-development` 技能约束，不由仓库门禁、测试或 Ruleset 约束。

从 `nightly` 开始 `docs/readme-refresh`，只修改清单和旧/新成员，并通过普通的带动作
前缀 Pull Request 合并。改动随后与其他已接受工作走同一条受保护晋升链。
