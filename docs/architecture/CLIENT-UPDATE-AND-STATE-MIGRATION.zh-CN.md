# 客户端更新与状态迁移

Updated: 2026-09-25

[English](CLIENT-UPDATE-AND-STATE-MIGRATION.md) ·
[架构](README.zh-CN.md) · [数据迁移 CLI](../../tools/data-migration/README.md)

LicoUp 只有一个应用身份、安装名称和数据根目录。`nightly` 与 `stable` 是同一身份的
发布轨道，不是并行安装的应用或打包传输；`direct` 与 `app-store` 是打包传输值。

## 独立迁移 CLI

`tools/data-migration/` 下已实现的 Node.js 包提供 `inspect`、`plan`、`convert`、
`resume` 和 `package`。它探测实际存储，按指定的已发布目标选择登记的转换路径。
`inspect`、`plan` 和 `convert --dry-run` 只读。

`convert` 与 `resume` 要求 `--writers-stopped`。工具锁只能排除该工具的其它实例，
不能停止不参与这把锁的旧客户端或其它 writer。每个域先提交并验证自己的后置条件，
再推进 marker 与 journal。恢复按实际存储继续，不重复已提交步骤；工具不宣称跨所有
数据库、文件与平台凭据库的一次全局事务。

不支持的形状与不安全的降级会在修改前失败。已实现的保全记录保存受支持旧格式无法
表达的数据，并在受支持的再次升级中合并恢复。需要所属领域执行的 Canonical
Conversation 与类型化工作流存储迁移会报告为等待原生准入；受保护凭据托管会报告为
等待平台授权，工具不会伪造其完成状态。当前 Profile 表、转换图、命令语法及准确限制
以该包 README 为准。

## 客户端更新选择

原生制品内嵌产品版本、发布轨道和不可变状态迁移前沿。本地开发构建默认为 Nightly；
可分发构建显式提供轨道。选择使用 SemVer：

- Nightly 自动接受严格更新的 Nightly。
- Nightly 可以显式选择严格更新的 Stable。
- Stable 自动接受严格更新的 Stable。
- Stable 不选择 Nightly；相同和更旧版本不合格。

签名的 manifest-v2 绑定目标轨道和每个版本的准确迁移前沿，人工说明不能覆盖这些字段。
只要清单存在就必须验证签名。网络与完整性错误保持为失败；新的检查在采用结果前会清除
旧候选。

替换前，原生验证会写入绑定版本、轨道、前沿和制品回执的候选认领。新二进制必须在
迁移准入前匹配该认领。已认领的替换通过同一候选或更新且具备向前能力的候选恢复。
明确支持的数据转换由迁移 CLI 执行。

## 启动准入

桌面生命周期解析数据根后，会在加载任何产品状态消费者前调用原生准入。准入锁定数据
根，探测所有登记域，证明迁移链连续，并在第一次模式修改前记录产品版本高水位。每个
持久步骤通过原子文件替换或所属数据库事务提交；只有权威后置条件存在后才推进迁移账本。

`gateway-credential-custody` 域要求显式的平台授权凭据迁移。完成回执不存在时，准入在
`pendingAuthorizationDomainIds` 中报告该域，并保持就绪且不打开钥匙串。
`llm-gateway credentials migrate` 操作拥有这个受保护步骤，完成后对账同一份迁移账本。

当前域会跳过，再次运行不会修改。状态领先于二进制、未知形状、迁移缺口、步骤不完整
或失败都会关闭启动，并只返回稳定且不泄露隐私的错误码。崩溃后对账已提交步骤，不重复
执行；持久用户与安全状态不会被静默重置。

更新器可通过重新安装同一已验证且具备能力的构建，或安装更新的签名构建后重试恢复。
高水位推进后旧二进制会被拒绝。对于迁移 CLI 支持的目标，必须先停止全部 writer 并
完成转换，才能由旧客户端打开数据根；不支持的降级会保持无修改地拒绝。

### 工作流存储转换

原生准入将 Adaptive Flywheel 存储从 SQLite schema 2 升至 3，并将准入前沿从 1 升至
2。迁移一次性显式化历史隐式入口槽与效果路由；转换和 schema marker 在同一 SQLite
事务中提交。它保留 revision/semantics 身份、run 快照、命令 attempt、租约和授权。
普通编译只接受 canonical 定义，不改写定义。独立 CLI 会把只允许 owner 执行的类型化
迁移报告为等待原生准入。

## 发布

Nightly 从 `nightly` 分支准备并使用固定的 `nightly` 预发布；Stable 从 `release`
产生不可变的 `v{version}` 版本。两者都保留 `land.lico.licoup`、`LicoUp.app` 和共享
数据根。发布验证按 SemVer 优先级比较，拒绝迁移前沿回退，并在签名前校验共享应用身份。
