# 客户端晋升边界

Updated: 2026-09-25

[文档索引](../README.md) · [English](PROMOTION-GATES.md)

英文版本为规范文本。GitHub 默认分支为 `release`；默认分支的选择与已验证源码
的晋升方向相互独立。

| 拉取请求边 | 必需汇总检查 | 建立的声明 |
| --- | --- | --- |
| action 前缀分支 → `nightly` | `Client required` | 源码策略以及受影响的 Flutter、Rust、Android 或依赖检查通过。 |
| `nightly` → `stable` | `Stable client` | 精确源码的稳定客户端验收契约通过。 |
| `stable` → `release` | `Release ready` | 精确源码的发布策略契约通过，但不声明外部发布已完成。 |

每条边都要求 `Branch flow`、`Commit identity` 和 `Auditor`。目标分支还要求其
入边对应的汇总检查。三条边都使用合并提交。一个拉取请求必须交付完整功能并
保持依赖方可用；未完成的协议或配置迁移不能合并。

按受影响模块运行仓库拥有的检查。发布工具发生变更时还需运行：

```sh
npm run client:gate:release-policy
npm run repo:version
npm run repo:version:test
```

版本源命令读取 `tools/release/source-version.json`，校验产品版本源、变更日志，
并在标签事件中校验精确的 `vMAJOR.MINOR.PATCH` 标签。它不负责制定发布计划、
维护验收状态、同步 GitHub Projects，也不授予发布权限。

公开源码与平台制品是不同声明。[包契约](../RELEASE-PACKAGES.zh-CN.md)定义公开
制品集合和验证收据。本地计划、进度报告、机器验收结果、签名状态和运营凭据
不得进入源码仓库。
