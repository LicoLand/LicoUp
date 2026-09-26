# 工作流实现边界

Updated: 2026-09-25

[English](ASSISTANT-WORKFLOW-CONTROL.md) · [工作流模块](../modules/workflow.md)

[纯核心](../../crates/licoup-workflow/src/)编译、归约定义；
[运行时](../../crates/licoup-workflow-runtime/src/)通过端口接纳和驱动工作；
[存储](../../crates/licoup-workflow-store/src/)负责持久事务。纯核心不操作进程、网络或数据库。

用户 Graph 是运行时数据；登记 schema/提供者及执行器，不登记私有实例，不另写一份文档图。
运行状态来自观察和工具回调，沉默与耗时不能证明完成；Agent 自然回复不受格式约束。
先提交持久状态，再发送下游通知。

暂停、取消、脱离、删除的效果不同，必须保留授权、单写者接纳及幂等恢复。
执行端口变化须在同一完整 PR 中覆盖调用者和实现者。
[IR](../../crates/licoup-workflow/src/ir.rs)及[归约器](../../crates/licoup-workflow/src/machine.rs)
拥有当前行为，[Adaptive Flywheel](../functionality/ADAPTIVE-FLYWHEEL.zh-CN.md)解释用户配置。
运行 `npm run verify:workflow`；以 `npm run repo:state-machines -- --list` 查询登记，
并核对工具报告的配置迁移缺口。
