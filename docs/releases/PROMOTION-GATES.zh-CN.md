# 客户端分支晋升门禁

[文档索引](../README.md) · [English authority](PROMOTION-GATES.md)

英文文档是规范事实来源。GitHub 默认分支继续保持为 `release`；默认分支与代码的晋升方向是两个独立概念。

| Pull Request 路径 | 必需聚合检查 | 证明的事实 |
| --- | --- | --- |
| 临时分支 → `nightly` | `Client required` | Source policy 与改动实际涉及的 Flutter、Rust、Android 或依赖回归通过；此阶段不运行发布策略门禁。 |
| `nightly` → `stable` | `Stable client` | macOS ARM64 客户端在 `macos-15` 上只构建并安装一次，随后启动同一个已安装 App，并通过有界存活验证。 |
| `stable` → `release` | `Release ready` | 仅运行 Node 发布权威与发布就绪契约；不构建、不安装、不启动、不执行发布签名，也不发布客户端。 |

三个目标分支都继续要求 `Branch flow`、`Commit identity` 和 `Auditor`；每个分支只额外要求其入站晋升阶段拥有的聚合检查。

稳定性证明使用仓库普通的本地 ad-hoc 打包路径，不使用发布者身份、仓库凭据或公证密钥；已安装 App 与本地证明都不会进入后续发布流程。

晋升就绪不等于发布。`client:promotion -- train` 把一份已验证快照切到 `release`。
之后出现在 `nightly` 上的提交属于下一次切分，不是正在发布的版本。公开发布只来自
精确的 `origin/release`（干净的 detached worktree 并运行
`npm run client:release:macos:publish`，或
`.github/workflows/client-release.yml` 中需人工授权的工作流）。严禁从 `nightly`
或 `stable` 发布。

正在发布期间，`nightly` 保持开放，继续接受带动作前缀的普通 merge-commit Pull
Request。在当前发布成功或被明确放弃之前，不要再次运行 `nightly` → `stable` 或
`stable` → `release`。

## 可重复的晋升操作

以下命令只预览下一条合法路径，不修改 GitHub：

```sh
npm run client:promotion -- plan
```

当前动作前缀分支完成提交和本地验证后，可用一条命令推送该分支并依次推进三段 Pull
Request。命令会等待每个目标分支的必需检查，使用 merge commit，并在首次检查失败或
拓扑不合法时停止：

```sh
npm run client:promotion -- train
```

只恢复其中一段时，指定准确的来源和目标：

```sh
npm run client:promotion -- advance --head nightly --base stable
```

晋升命令绝不会触发 `.github/workflows/client-release.yml`。正式产物准备与发布继续作为
`release` 就绪后的独立、显式授权动作。
