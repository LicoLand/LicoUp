# LicoUp 产品

Updated: 2026-09-25

[English](PRODUCT.md) · [用户指南](docs/functionality/USER-GUIDE.zh-CN.md)

LicoUp 是开源、本地优先的人类与 Agent 会话客户端。它通过适配器连接用户选择的
Agent，会话归属、审批和受保护的本地数据由端点掌握。

贡献必须保留这些用户可见的边界：

- 原样展示 Agent 自身的回复，不强制回复格式，不因缺少结构而判为无效或空回复。
- 选择用户配置的 Agent 命令，不悄悄替换别名、包装器、参数和环境；用户显式选择优先。
- 当前用户操作需要资源时才请求操作系统权限；发现过程不启动未使用的 Agent，
  不触发无关权限弹窗。
- 保留会话历史、成员关系和明确授权；远程传输不拥有信任、明文、密钥、审批或本地操作。
- 厂商协议留在适配器，领域决策留在视图之外；核心可运行不等于兼容所有上游版本。

[模块文档](docs/RUNBOOK.zh-CN.md)维护开发边界和检查入口；
[兼容性](docs/COMPATIBILITY.zh-CN.md)由能力登记生成，
[状态说明](docs/STATUS.zh-CN.md)解释支持与验证结论的适用范围。
字段和状态转换以可执行源为准。

LicoUp 使用 [AGPL-3.0-or-later](LICENSE)。
