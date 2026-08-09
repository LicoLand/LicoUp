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
均确认有效后，只运行一次必需的 Node 源码策略，以及真正受影响的技术通道。各通道彼此
独立并可并行；提交门禁不会构建或发布所有平台。

```bash
npm run client:gate:source
npm run client:gate:flutter         # 仅 Flutter 改动
npm run client:gate:rust            # 仅 Rust 改动
npm run client:gate:android         # 仅 Android 改动
npm run client:gate:dependencies    # 仅依赖权威文件改动
npm run client:gate:release-policy  # 仅发布策略改动
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

- 使用短句和常用词。
- 英文是规范的公开入口；每份持续维护的简体中文本地化文档都要链接回英文版本。
  两份根目录 README 中的共同产品事实必须同步更新。
- 数据流程难以只用文字解释时，使用简洁的 Mermaid 图。
- 产品文字应围绕多元、互联、开放、融合和用户控制。
- 把 `README.md` 作为产品对外页面，逐条检查其中的声明。
- 结构化计划保存在 `docs/plans/`。审计报告、临时方案及其他一次性文档统一保存在
  `docs/reports/`。这两个路径只在本地使用。
- 不要把本地技能或临时脚本加入仓库。

## 合并请求检查

创建发布候选 Pull Request 前，使用干净、已提交且命名为
`release-candidate/v<version>-<target>` 的分支，并在目标的真实平台运行唯一
本地预检：

```bash
npm run client:pr:preflight -- --base origin/nightly --target <target> --full-target
```

预检会对同一候选执行构建、签名、归档、安装、更新、回滚和真实启动，然后
写入被忽略且已脱敏的收据。pre-push Hook 只核验该收据，不会重复昂贵步骤。
收据缺失或失效时不得创建或更新发布候选 Pull Request。Required Checks
必须逐字为 `Branch flow`、`Commit identity`、`Client required` 和 `Auditor`。

- 改动只有一个清晰范围。
- 原生 CLI 或生成契约的改动，在同一改动内保持 Flutter 与 Rust 两侧一致。
- 完成迁移时，旧路径和旧名称已经删除。
- 新增或修改的测试只使用虚构并脱敏的数据。
- 公开文档有对应的中英文版本。
- 不包含敏感值或原始运行输出。
- 提交 Author 与 Committer 和当前 `gh` 账号一致，且没有第二署名、署名 trailer、
  Agent 身份或被绕过的 hook。

LicoUp 使用 `AGPL-3.0-or-later` 许可证。
