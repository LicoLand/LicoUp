# Adaptive Flywheel 策略

[English（规范版本）](ADAPTIVE-FLYWHEEL.md) · 简体中文（本地化） · [功能索引](README.md)

Adaptive Flywheel 是 LicoUp 的本地策略目录与 Graph 执行运行时。策略是用户导入的
JSON 状态机 Graph，外加每个 actor 槽的有序候选链。一次运行是一次性流水线、带
分支的工作流，还是带回边的 Agent Loop，完全由 Graph 决定；引擎不会根据策略名称
推断拓扑，也不附带任何内置策略。

## 策略来源

目录初始为空。只有用户导入一个有界 ZIP 包之后，策略才会出现：

```text
workflow.json
scripts/
  可选辅助文件
```

`workflow.json` 必须位于包根目录，辅助文件只允许放在 `scripts/` 下。导入会先准备
并校验归档，再提交一个不可变版本。已提交版本不依赖原 ZIP，也不依赖它原来的本机路径。

引擎不会自动注册包、预留策略身份，也不会把厂商 Agent 编制写进产品树。中性槽位
标识如 `entry`、`worker-a` 是有效的；个人 Agent 编制只存在于用户导入的配置中。

## Graph 与执行

工作流文档声明元数据、资源上限、智能体/运行时/工作区绑定槽、可选工作集、初始状态、
状态与转换。恰好一个 actor 槽必须设置 `entry: true`；引擎不写死名为 scheduler 的槽。
状态类型覆盖路由、授权、智能体与脚本效果、依赖感知工作集，以及明确的终态。转换
回到较早状态就形成循环；无环 Graph 则保持为流水线。

运行执行效果前，所有必需槽位都必须绑定，并且必须授权该不可变策略版本的准确语义。
Adaptive Flywheel 对话框负责导入、有序胶囊绑定和授权。群聊选择器只列出已授权版本。

Python 与 Node 辅助脚本只使用设备上已经存在且通过验证的运行时；策略包不携带解释器。
授权可以撤销；新版本需要自己的绑定和授权。

每个 actor 槽可声明 Fallback 策略。额度、信用、速率限制、容量或耗尽类失败立刻换到
下一个序位候选。瞬时失败对同一候选重试到配置次数（默认两次）后再换人。换人一律新开
原生会话，并且只注入 predecessor locator：已准入的绝对 store 路径、原生会话 id、
来源类型，以及适配器已记录的 table/keyPrefixes。引擎不注入正文，也不跨厂商 resume。
公开回执只暴露 `fallbackFrom`、`fallbackTo`、失败类和尝试次数，不含路径。

Actor 的 JSON 输出可以把 `worksets.*` 与 `context` 合并进本次 run 的 input；guard
仍只看当次 payload。Actor 执行使用 run 工作目录；相对路径会被拒绝。

运行通过 reducer 写入持久化本地状态。客户端投影当前与相邻状态、允许操作、效果历史、
重试、取消、Fallback 回执，以及可见的阻塞或结果不确定状态。在 Graph 声明上限和引擎
硬上限之内，依赖已满足的工作前沿可以并发执行。

LicoUp 只持久化 Graph、绑定、run 与 locator 摘要。各 Agent 持有各自的原生对话。群聊
是人机入口和成员事件投影，不是第二份 transcript 仓库。已经退役的 Conversation 序号式
Flywheel 模型不会被读取或翻译。

## 桌面端流程

打开**智能体**，再打开 **Adaptive Flywheel**。

1. 导入策略 ZIP。空目录显示以导入为先的界面。
2. 用有序胶囊列表绑定每个 actor 槽，包括 Fallback 候选。
3. 需要查看流程时打开**工作流程**，查看真实的有向转换图；编辑区不再用状态卡片
   网格冒充流程图。
4. 保存绑定，并授权该不可变版本的准确语义。

Python 与 Node 运行时由后台自动检测和绑定，不提供用户选择框。Agent 选择器只展示
已检测到且具备可用 Conversation Driver 的目标；未适配或只是登记过的目标不会出现。
会话策略等实现细节也不再作为角色标注展示。

## 群聊启动

只有群聊显示策略胶囊；一对一 Conversation 不出现。

输入框上方的胶囊默认是**可选策略**。选中已授权版本后显示策略名，并在输入框前放入
入口槽当前候选的 `@` 胶囊。选策略会把所有已绑定 Agent（含 Fallback 列表）加入该群
Membership，但不会启动 run。

第一条发送把文本交给入口槽并执行 `strategy.run.start`，工作目录为群工作区。之后仅在
run 需要人输入时把发送交给入口槽的 sticky 会话；否则只发普通群消息。叉掉 `@` 胶囊
只退出策略模式，不取消已经在跑的 run。

未进策略模式的 `@mention` 仍走 DirectTurn，不启动 Graph。Graph 的 actor 与 workset
效果作为对应 Membership 上的结构化 Event，走共享 conversation display。

导入包内容、绑定、授权与原生运行状态都保留在本地客户端状态。不要把原始策略输入、
本机路径、进程输出或智能体历史作为诊断信息公开。
