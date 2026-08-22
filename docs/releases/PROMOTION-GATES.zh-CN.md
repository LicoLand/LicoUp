# 客户端分支晋升与 Apple 权威发布

[文档索引](../README.md) · [English authority](PROMOTION-GATES.md)

英文文档是规范事实来源。GitHub 默认分支继续保持为 `release`；默认分支与已验证
源码的晋升方向是两个独立概念。

| Pull Request 路径 | 必需聚合检查 | 证明的事实 |
| --- | --- | --- |
| 动作前缀分支 → `nightly` | `Client required` | Source policy 与改动实际涉及的 Flutter、Rust、Android 或依赖通道通过。 |
| `nightly` → `stable` | `Stable client` | macOS arm64 客户端只构建并安装一次，随后启动同一个已安装 App，并通过有界存活验证。 |
| `stable` → `release` | `Release ready` | 仅运行 Node 发布策略，不重复构建、安装或签名；合并后自动打包并发布精确验收源码。 |

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

## 自动发布源码

同仓库的 `stable` → `release` Pull Request 合并后，立即触发
`.github/workflows/client-source-release.yml`。工作流检出精确 merge commit，证明其
第二父提交就是已验收的 `stable` head，从 `tools/client-version.json` 读取版本号，
生成 Git 源码归档与 SHA-256 摘要，并创建该版本唯一的 `v<version>` tag 与
`LicoUp <version>` Release，初始只发布：

- `LicoUp-source-v<version>.tar.gz`
- `LicoUp-source-v<version>.tar.gz.sha256`

该工作流不能构建、签名、公证或发布五项 Apple 制品，也不调用 Apple Release。
Apple Release 随后把五项 macOS 制品追加到同一个公开 Release，而不是创建第二个
tag 或 Release。校验、打包或上传失败会立即终止源码发布，并阻止后续客户端打包。
既有 tag/Release 身份会拒绝复用源码版本；源码发生变化必须使用新的产品版本号。

## Apple 委托发布

晋升就绪不等于公开发布。仓库流程终止于已验证的 `origin/release` 源码切分。
macOS Developer ID 的发布后流程通过
`tools/apple-release/macos-direct-arm64.json` 委托给权威 Apple Release CLI。

Apple Release 控制完整 macOS 发布状态机。其一次性
`macos-release-candidate` 分支指向已授权的精确 `origin/release` revision；
LicoUp 不准备独立候选提交，也不把候选分支合并进受保护分支。Apple Release 校验
Required Checks，并发布声明的 tag、Release 与精确五项制品契约。它永不改动
`nightly`、`stable`、`release`、Rulesets 或 Required Checks；允许的远端变更仅限
`v<version>` tag 与公开 Release 必须已由源码发布创建。Apple Release 允许的远端
变更仅限冻结的平台候选分支、向同一个 Release 追加声明的五项 macOS 制品，以及
公开验证后的平台候选分支清理。

LicoUp 的完整产品适配层隔离在 `tools/scripts/macos-release/`。Apple Release 规定
适配命令和制品契约；LicoUp 只准备自己的门禁、App 与更新清单，不拥有 Apple Release
服务或第二套编排路径。

可选的只读状态命令是：

```sh
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

分支晋升绝不会启动 Apple Release，也不会创建 Apple 专属 Release、Apple 制品、
公证提交或更新通道记录。它创建该版本唯一的源码优先 `v<version>` Release；各平台
发布器随后只向同一个 Release 追加自己拥有的制品。
