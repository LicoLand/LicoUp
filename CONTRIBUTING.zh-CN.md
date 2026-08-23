# 参与贡献

[English](CONTRIBUTING.md) · 简体中文 · [首页](README.zh-CN.md)

感谢你帮助 LicoUp。每次改动应只覆盖一个清晰的客户端功能、模块或流程，并且可以
独立检查和测试。

## 环境准备

源码策略只需要 Node.js 22 或 24。仅当受影响的技术通道需要时，才安装 Flutter、
Rust、Java 和 Android 工具链。

```bash
npm ci
```

开发过程中只运行与改动直接相关的最小检查。交付前运行对应模块的定向测试。所有改动
均确认有效后，只运行一次必需的 Node 源码策略，以及真正受影响的技术通道：Flutter、
Rust、Android 或依赖回归。各回归通道彼此独立并可并行。发布策略不是改动路径回归通道；
它只在 `stable` → `release` 晋升边执行，具体见
[客户端晋升权威](docs/releases/PROMOTION-GATES.zh-CN.md)。提交门禁不会构建或发布所有平台。

维护中的完整客户端回归是一张限并发依赖图：共享基础只运行一次，前端与后端重叠执行；
同级任务即使有失败也会全部收口，之后才进入接口联测、核心场景，以及按本机能力激活的
平台与 Agent 并行兼容性前沿。定向开发使用独立的
`client:regression:frontend`、`:backend` 和 `:integration` 入口。进入实时兼容性目标前，
使用 `client:regression:environment -- --platform <id>` 或 `--agent <id>` 做增量环境检查。
使用 `client:regression -- --retry-report build/reports/client-module-regression.json`
仅重派发失败证据，避免重复运行无关成功项。
一次共享清单/模式检查后，每个 Agent 的静态检查都独立调度；合并的
Node 测试通过匿名输入索引定位失败，因此单个 Agent 或测试文件不会连带整个
同级批次。

一旦主动启动完整回归，本次验证闭环就自动扩展到它暴露的全部问题。严禁在仍有已知
失败、陈旧快照、布局溢出、超时或偶发用例时交付。必须定位并修复权威实现，增加或收紧
定向回归；更新任何视觉快照前都要先检查实际差异。修复过程中只重跑受影响的测试切片；
所有问题清零后，再运行一次最终完整回归并要求全部通过。若外部条件确实阻止闭环，必须
停止并取得维护者的明确决定，不得把问题标记为“既有”或“超出范围”后继续交付。

```bash
npm run client:gate:source
npm run client:gate:flutter         # 仅 Flutter 改动
npm run client:gate:rust            # 仅 Rust 改动
npm run client:gate:android         # 仅 Android 改动
npm run client:gate:dependencies    # 仅依赖权威文件改动
```

产生构建输出的测试共用一个受管编译目标。构建使用期间，测试运行器会持有活动租约；无论
测试正常结束还是失败，都会把输出标记为可回收。可用以下命令查看状态或仅清理已标记且
未被使用的输出：

```bash
npm run client:artifacts:status
npm run client:artifacts:prune -- --dry-run
npm run client:artifacts:prune
```

清理操作绝不会删除 Cargo、Pub、Gradle、SDK 或工具链下载缓存，后续构建仍可复用已经
下载的依赖。未纳管的旧目标只会被报告，不会自动删除。测试异常退出后，结构完整的失效
租约会先经过保护宽限期，之后才进入可回收状态；格式错误或被篡改的记录始终关闭失败。

## 系统权限

只在当前用户操作真正需要某项系统隐私权限时才向操作系统申请。自动发现只探测 Agent
扫描路径清单，不得遍历 PATH、桌面、文稿、下载、图片、音乐、照片图库、媒体资料库、
网络宗卷或未使用的 Agent 存储。当前操作用不到的用途说明、entitlement 或插件不得随
包提供。

锁定依赖均已缓存时，可单独运行离线依赖审计
`npm run client:deps:audit:offline`。它不会带动未受影响的语言或平台通道。

## 提交身份与署名

每个提交必须有且仅有一个开发者身份。Git 的 `Author` 和 `Committer` 姓名及邮箱
必须与 GitHub CLI 当前认证的账号一致。克隆仓库后，以及每次 `gh auth` 切换账号
后，都必须安装并校验仓库策略：

```bash
npm run repo:identity:install
npm run repo:identity:verify
```

安装程序使用该账号规范的 GitHub noreply 地址，并启用仓库控制的 `pre-commit`、
`commit-msg` 和 `pre-push` hook。hook 会检查所有待推送提交，而不只是 `HEAD`。
策略文件缺失、被重定向、被修改、成为符号链接或不可执行时，一律关闭失败。严禁使用
`--no-verify`、修改 `core.hooksPath` 或以其它方式绕过门禁。

Agent 可以辅助开发者，但严禁替换、覆盖或抢占开发者署名。Agent 的姓名、邮箱或其它
联系方式不得作为 Author、Committer、共同作者、签署者、署名 trailer 或任何形似
身份的独立行进入提交。该规则适用于 Claude Code、Cursor、Codex、Copilot 以及所有
其它 Agent 或 bot。把人类代码归到 Agent 联系方式名下属于虚假身份信息和来源追溯
违规，本地 hook 与远程 Ruleset 都会拒绝。开发者必须亲自审查并接受改动后才能提交。

## 隐私规则

- 严禁提交秘密、本地路径、用户内容、账户数据、设备信息、日志或原始运行时报告。
- 测试数据必须是合成数据并完成脱敏。测试框架可以公开，真实用户和系统数据不能公开。
- 敏感数据留在客户端。对端内容离开发送端前必须完成加密。
- 不得增加把用户内容或运行时数据发送给服务端的通用路径。
- 任何允许的对外传输都必须要求一次新的用户直接确认，并准确绑定目标、用途、范围和
  内容摘要。

## 原生接口一致性

Flutter 客户端与 Rust 原生核心共享两类接口：

- 生成的契约类型：由 `schemas/client_bridge/` 中的单一 schema 生成到 Dart
  （`apps/desktop/lib/src/contracts/generated/*.g.dart`）和 Rust
  （`crates/licoup-native/src/ffi/generated/*.rs`）。
- 原生 CLI 命令面（`licoup.stdio.v1` 帧与一次性参数）。Rust 侧在
  `crates/licoup-native/src/ffi/commands/` 通过 `admitted_params` 接纳参数；
  Flutter 侧在 `apps/desktop/lib/src/platform/native_client/` 发送参数。

打包后的 App 自带 sidecar；不重新打包前，运行中的 App 会一直使用旧的原生二进制。
任何原生接口改动后都要重新打包并验证客户端。

## 文档规则

- **严格单一事实源（SSOT）**：每个架构模型、协议规范、功能机制或平台规则只能有一份权威拥有文档（详见 [ADR 0009](docs/adrs/0009-single-source-of-truth-documentation-architecture.zh-CN.md)）。其他文档需引用该权威文档，严禁在多处复制或改写同一事实。
- **概述文档精简与细分领域索引**：顶层概述文档（如架构、协议、功能主文档）保持高层抽象，不堆砌底层细节，通过结构化索引表格链接至专属细分文档。
- **跨文档引用表格化**：所有文档顶部的关联引用（规范版本、本地化版本、产品定义等）一律采用 Markdown 表格形式列出。
- **语言与同步**：英文是规范的公开入口（Normative）；每份持续维护的简体中文本地化文档都要链接回英文版本。两份根目录 README 中的共同产品事实必须同步更新。
- 使用短句和常用词。数据流程难以只用文字解释时，使用简洁的 Mermaid 图。
- 产品文字应围绕多元、互联、开放、融合和用户控制。设计理念与顶层承诺归入 `PRODUCT.md`。
- 把 `README.md` 作为产品对外页面，逐条检查其中的声明。
- 结构化计划保存在 `docs/plans/`。审计报告、临时方案及其他一次性文档统一保存在 `docs/reports/`。这两个路径只在本地使用。
- 不要把本地技能或临时脚本加入仓库。

## 维护的模型与定价表

每个维护中的模型、Agent、基准、能力表和定价表都只有一个当前的已提交权威来源。
表的新鲜度只使用非空 ISO 日期字段 `last_updated`；不得增加表级
`schema_version`、`catalog_version`、`as_of`、`snapshot_date`，也不得保留并行或
带版本的副本。发布前必须复核每个官方 HTTPS 来源、刷新日期，并删除已经停止提供的
行。当前目录旁不得保留生成文件或兼容定价来源。

## 切分到 `release`，再委托公开发布

`nightly` 是持续开放的集成分支。产品改动通过带动作前缀的普通 Pull Request 合入，
一份已接受快照再通过 merge commit 从 `nightly` 晋升到 `stable`，最后晋升到
`release`。

项目必须完成 100 次独立发布后，才能把任何构建提升到 `1.0.0` 线。每一个 1.0
之前的发布都保留自己的不可变版本、候选证据和制品收据；被跳过或被替换的候选不
计入发布次数。

完成切分后，可以从精确的 `origin/release` revision 使用
`npm run client:release:macos` 委托 macOS 发布后流程。服务先运行只读预检；唯一一次
不可变授权冻结来源与公开安装包契约。委托服务不会创建源码候选、合并 Pull Request，
也不会改动受保护晋升链。

## 合并请求检查

产品改动、重构、迁移、发布工具、Workflow、Ruleset、身份策略和 Auditor 策略必须
分别通过普通 Pull Request 完成。产品改动进入 `nightly`，并且只通过固定的受保护
晋升链完成切分。公开发布是独立操作，只能来自精确接受的 `origin/release` 来源，
由 Apple Release 负责。

远程构建成功、晋升合并、Workflow 成功或生成草稿都不代表发布成功。只有重新下载
最终公开制品、验证绑定的来源和摘要、按公开路径安装、确认稳定启动并验证公开更新
链路后，才能宣布成功。草稿公开前可以对账；一旦公开，tag、来源 revision 和资产集
不可变。损坏的公开 Release 必须先获得明确批准的纠正发布计划，并使用新的已验证
来源及新构建号或版本；严禁原地替换资产。

- 改动只有一个清晰范围。
- 原生 CLI 或生成契约的改动，在同一改动内保持 Flutter 与 Rust 两侧一致。
- 完成迁移时，旧路径和旧名称已经删除。
- 新增或修改的测试只使用虚构并脱敏的数据。
- 公开文档有对应的中英文版本。
- 不包含敏感值或原始运行输出。
- 提交 Author 与 Committer 和当前 `gh` 账号一致，且没有第二署名、署名 trailer、
  Agent 身份或被绕过的 hook。

LicoUp 使用 `AGPL-3.0-or-later` 许可证。
