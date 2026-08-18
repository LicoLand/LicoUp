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

晋升就绪不等于公开发布。仓库流程终止于已验证的 `origin/release` 源码切分。
macOS Developer ID 的发布后流程通过
`tools/apple-release/macos-direct-arm64.json` 委托给本机 Apple Release 服务。

委托发布服务从已授权的精确 `origin/release` revision 切出一个
`release-candidate/v{version}` 分支，准备锁定的版本提交，通过其 Required
Checks 后合并该候选分支，并从该候选发布声明的公开 tag、Release 与四项制品
契约。它永不改动 `nightly`、`stable`、`release`、Rulesets 或 Required Checks；
其允许执行的远端变更仅限已冻结的候选分支、其合并，以及声明的公开 tag、
Release 与制品。

安装或检查本机服务：

```sh
npm run client:release:service:install
npm run client:release:service:configure
npm run client:release:service:status
npm run client:release:status -- --job <job-id>
```

只有得到明确授权后才使用以下命令发起公开发布：

```sh
npm run client:release:macos -- --version <version> --build <build>
```

唯一一次不可变授权之前只运行只读预检。凭据始终留在各自安全存储中，保留的收据不得
包含凭据、账户身份、本机路径、原始输出或运行数据。tag、Release 草稿、公证结果或
已上传制品本身都不代表成功；终态还必须完成精确公开制品对账、匿名下载安装包、摘要
校验、安装与稳定启动。

分支晋升绝不会启动该服务，也不会创建或公开 GitHub Release、tag、资产、公证提交或
更新通道记录。
