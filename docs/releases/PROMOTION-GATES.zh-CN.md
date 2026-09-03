# 客户端分支晋升与 Apple 委托发布

[文档索引](../README.md) · [English authority](PROMOTION-GATES.md)

英文文档是规范事实来源。GitHub 默认分支继续保持为 `release`；默认分支与已验证
源码的晋升方向是两个独立概念。

| Pull Request 路径 | 必需聚合检查 | 证明的事实 |
| --- | --- | --- |
| 动作前缀分支 → `nightly` | `Client required` | Source policy 与改动实际涉及的 Flutter、Rust、Android 或依赖通道通过。 |
| `nightly` → `stable` | `Stable client` | macOS arm64 客户端只构建并安装一次，随后启动同一个已安装 App，并通过有界存活验证。 |
| `stable` → `release` | `Release ready` | 仅运行 Node 发布策略；不重复构建、安装、发布签名或公开发布客户端。 |

三个目标分支都要求 `Branch flow`、`Commit identity` 和 `Auditor`，并且只额外
要求各自入站路径拥有的聚合检查。三段都使用 merge commit。发布切分期间不得改动
Rulesets、Required Check 名称或默认分支。

预览或推进固定晋升链：

```sh
npm run client:promotion -- plan
npm run client:promotion -- advance --head nightly --base stable
npm run client:promotion -- advance --head stable --base release
```

晋升命令复用同一路径上已打开的 Pull Request，把检查绑定到精确 Head，并在首次拓扑
错误或检查失败时停止。`nightly` 继续接收下一批普通改动；一份快照切分后，不得把
更晚的 `nightly` 再并入同一轮正在进行的公开发布。

## Apple 委托发布

Nightly 与 Stable 是同一 LicoUp 身份的发布轨道。Nightly 从 `nightly` 使用
`tools/apple-release/macos-direct-arm64-nightly.json` 和固定的 `nightly` 预发布；
Stable 从 `release` 使用现有配置和不可变的 `v{version}` 标签。两者清单都绑定轨道
和准确的内嵌迁移前沿。Stable 必须不是预发布且版本严格更新；相同版本不会提供给
Nightly。参见[客户端更新与状态迁移](../architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md)。

同仓库 `stable` → `release` Pull Request 合并后，`client-source-release.yml`
只发布精确 merge commit 的源码。它验证第二父提交等于已接受的 stable head，并创建
`v{version}`、`LicoUp {version}`、`LicoUp-source-v{version}.tar.gz` 及其 `.sha256`。
Release 正文绑定 `apple-release-source:v1:{revision}`。该流程不构建、签名、公证或
上传二进制；重试保留公开标签与制品，只允许匹配的草稿补齐缺少的源码文件。

Apple Release 在现有干净仓库的 `release` 分支上使用
`tools/apple-release/macos-direct-arm64.json`，本地源码必须等于 `origin/release`。
全部产品适配器位于 `tools/scripts/macos-release/`：`gate-source.mjs`、
`gate-release-policy.mjs`、`build.mjs` 和 `write-update-manifest.mjs`。
依赖准备 `npm ci` 由引擎选择。构建适配器固定 stable 轨道并输出
`build/apps/desktop/runnable/macos/release/LicoUp.app`；更新适配器绑定标签、仓库和版本，
输出 `build/apple-release/LicoUp-update-manifest.json`。

引擎在精确 release 修订创建 `macos-release-candidate`，不创建提交或 Pull Request。
完成依赖准备和产品门禁后推送同一个候选，观察绑定精确 SHA、分支、工作流、run 和
attempt 的 `Branch flow`、`Commit identity`、`Auditor`、`Release ready` 成功作业后，
才允许构建或签名。缺少或运行中的检查持续等待同一个候选，没有取消截止时间；失败或
跳过均阻止发布。候选永不合回，仅在公开验证完成后清理。

强制 Apple 合规技能委托以下只读权威检查：

```sh
apple-release compliance check --project . --config tools/apple-release/macos-direct-arm64.json
```

提交前必须为未改变的会话取得 `PASS`。检查验证源码、元数据、工具链、两种 entitlement、
隐私、描述文件/证书、更新密钥及公证权限/队列，不执行发布。已有 `In Progress` 提交时
禁止新会话。真实 App/归档上传前仍须执行制品检查；构建与公证等待均无取消截止时间。

Apple Release 保留源码两项资产，只补充五项 macOS 资产：`LicoUp-macos-arm64.dmg`、
其 `.sha256`、`LicoUp-macos-arm64-update.zip`、其 `.sha256` 和
`LicoUp-update-manifest.json`。唯一公开 Release 因此包含七项不可变资产；冲突时停止，
绝不替换公开文件。

配置本机发布授权并检查发布运行：

```sh
npm run client:release:authority:configure
npm run client:release:status -- --job <job-id>
```

另有一条授权前置条件：配置前先把两把更新签名钥
（`LICO_UPDATE_OFFLINE_ROOT_KEY` 与 `LICO_UPDATE_ONLINE_SIGNING_KEY`，Ed25519
PEM）导出到环境变量，以便登记进 Keychain；之后可取消导出。缺少任意一把密钥的
运行会在预检阶段被拦截。

只有得到明确授权后才使用以下命令发起公开发布：

```sh
npm run client:release:macos:nightly:publish
npm run client:release:macos:publish
```

第一条命令从 `nightly` 更新固定的 Nightly 预发布；第二条命令从 `release` 发布不可变的
Stable 版本。

版本号与构建号取自冻结 `release` 修订上的版本文档。
`npm run client:release:macos -- --version <version> --build <build>` 仍是交互变体，
授权前会询问一次；显式传入的值必须与该文档完全一致。

唯一一次不可变授权之前只运行只读预检。授权后由 CLI 拉起 detached runner 执行发布，
无需安装任何服务。凭据始终留在各自安全存储中，保留的收据不得
包含凭据、账户身份、本机路径、原始输出或运行数据。tag、Release 草稿、公证结果或
已上传制品本身都不代表成功；终态还必须完成精确公开制品对账、匿名下载安装包、摘要
校验、安装与稳定启动。

最后一段晋升合并后自动发布源码。macOS 签名、公证及五项平台资产仍由单独授权的
Apple Release 操作完成。
