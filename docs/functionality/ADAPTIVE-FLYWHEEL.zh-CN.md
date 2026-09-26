# Adaptive Flywheel 策略

Updated: 2026-09-25

[English](ADAPTIVE-FLYWHEEL.md) · [功能](README.md)

Adaptive Flywheel 导入用户编写的 JSON Graph，将 actor 槽绑定到有序 Agent 候选。
拓扑由 Graph 决定，名称不选择内置流程；策略目录初始为空，不分发可执行工作流图。

## 策略包与权威

导入根目录包含 `workflow.json`、可选辅助文件位于 `scripts/` 的 ZIP。校验后生成不可变
修订；效果执行前须绑定必要槽位并授权这一修订。变更修订后重新绑定、授权。
辅助脚本使用设备已有的受支持运行时，包内不携带解释器。

[定义类型](../../crates/licoup-workflow/src/ir.rs)和
[编译器](../../crates/licoup-workflow/src/compile.rs)拥有字段与 Graph 验证规则。
运行实例属于用户数据；不另写转移表、守卫规则或测试断言。
[工作流模块](../modules/workflow.md)维护实现边界及 `npm run verify:workflow`；
`npm run repo:state-machines -- --list` 查询提供者登记。

## 桌面操作

1. 打开 **Agents → Adaptive Flywheel**，导入策略 ZIP。
2. 为 actor 槽绑定有序候选与所需回退。
3. 打开 **Workflow** 检查有向转移图。
4. 保存绑定并授权不可变修订。

只有群会话显示策略胶囊。选择已授权修订会接纳绑定 Agent 为成员，不启动执行，
不改写 Assistant 配置；Assistant 配置与工作流绑定分别保存。关闭 Assistant 影响
后续直接派发，停止进行中的轮次须使用显式取消；独立工作流不会因此取消。

## Agent 使用

内置 [LicoUp 指南](../../crates/licoup-native/resources/licoup-guide/SKILL.md)解释现有
会话、委派和工作流工具。加载技能不授予执行权限，也不选择开发流程或模型预设；
能力以当前目录和已接纳成员配置为准。

通知只含标识，不携带执行者正文、私有路径或工具输出，不取代会话历史。Agent 回复
保持自然形式。回退与恢复保留明确的会话绑定及授权；静态 Graph 验证不证明真实 Agent 可用。
