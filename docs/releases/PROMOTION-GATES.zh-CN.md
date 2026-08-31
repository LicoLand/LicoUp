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

晋升就绪不等于公开发布。仓库流程终止于已验证的 `origin/release` 源码切分。
macOS Developer ID 的发布后流程通过
`tools/apple-release/macos-direct-arm64.json` 委托给本机 Apple Release 引擎。

委托发布运行从已授权的精确 `origin/release` revision 切出一个
`release-candidate/v{version}` 分支，等待其 Required Checks 通过，并从该候选
发布声明的公开 tag、Release 与五项制品契约。第五项资产是签名更新清单：由配置的
update 命令在构建期生成，随其余资产一并上传，并通过同样的公网未鉴权下载核验。
引擎永不改动 `nightly`、`stable`、`release`、Rulesets 或 Required Checks；其允许
执行的远端变更仅限已冻结的候选分支，以及声明的公开 tag、Release 与制品。

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
npm run client:release:macos:publish
```

版本号与构建号取自冻结 `release` 修订上的版本文档。
`npm run client:release:macos -- --version <version> --build <build>` 仍是交互变体，
授权前会询问一次；显式传入的值必须与该文档完全一致。

唯一一次不可变授权之前只运行只读预检。授权后由 CLI 拉起 detached runner 执行发布，
无需安装任何服务。凭据始终留在各自安全存储中，保留的收据不得
包含凭据、账户身份、本机路径、原始输出或运行数据。tag、Release 草稿、公证结果或
已上传制品本身都不代表成功；终态还必须完成精确公开制品对账、匿名下载安装包、摘要
校验、安装与稳定启动。

分支晋升绝不会启动发布运行，也不会创建或公开 GitHub Release、tag、资产、公证提交或
更新通道记录。
