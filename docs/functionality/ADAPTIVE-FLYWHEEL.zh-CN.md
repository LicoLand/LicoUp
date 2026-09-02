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

## Assistant 临时运行

Assistant 编写的 Graph 是请求本地的不可变 run 对象，不是导入的目录策略。它只能绑定
同一 Conversation 中准确且活动的 Agent Membership，不能包含 script 或 runtime 资产。
Assistant facade 从既有权威派生 Profile 事实，先硬过滤再确定性排序候选，完成所有本地
可知检查，并在幂等键下持久准入前重新校验存储自有的 Membership 与 Profile 版本。

拒绝请求会返回有序的 `diagnostics` 列表。每项都有稳定 code 与 stage；可用时还包含
安全 JSON Pointer、受影响 Membership id，以及 actual/limit 数字事实。Assistant 因此可
直接修正 workflow 结构、资源限制、绑定、model、readiness、环境、Skill 与 Authority，
无需解析散文错误或重复产生效果。

准入后，actor 效果与单聊、群聊共用同一持久 Membership turn 及 Conversation
Event/Part 时间线。Assistant run 的效果或 drive 失败只结算一个 typed 终态结果并取消
尚未启动的 command；不会进入通用重试、Fallback 或 failure edge 路径。run 不存在按
经过时间推断终态的规则，也不会被改写。同一 Assistant 可以直接继续，或提交后续 Graph。

## Graph 契约

每个工作流在导入前都会按一份类型化转换契约编译。转换只能携带 `complete`、
`success`、`failure` 三种事件；任意字符串事件会被拒绝。效果状态（authorization、
actor、script、workset）必须声明完整的 `success` 与 `failure` 路由，且不能混入其他
事件族；终态没有出边。actor 与 workset 状态必须引用 required actor 绑定，每个 script
runtime 也必须有一个 required runtime 绑定。`pass` 与 `join` 各取一条无 guard 的
`complete` 边；`choice` 以无 guard 的兜底边
完成 `complete` 路由；`fork` 通过至少两条指向不同目标的无 guard `complete` 边扇出。

Guard 路由必须让每个有界 payload 恰好选中一条边。一个状态可以声明一个任意 guard 加
无 guard 兜底，或声明同一 payload 路径上规范值各不相同的多个 equality guard，同样
必须有无 guard 兜底。混合 guard 路径、`exists` guard 与 equality guard 混用、以及
缺少兜底边，都会在导入前被拒绝。

并行区域是结构化子集：每个 `fork` 恰好有一个匹配的 `join`；每条分支无环、单入口、
单出口、节点互不相交，且不含嵌套的 fork/join 或终态；每条分支进入 `join` 前有唯一
的前驱；不允许跨区域边。包含效果且位于结构化并行区域之外的循环仍然有效。
结构化区域外的 join 必须只有一个必然到达的前驱；初始 join，或由互斥 choice 路径
汇入的多前驱 join，会在导入时被拒绝。

workset 访问对空工作集与非空工作集都发出 `success`，并带一个规范化聚合 payload。
最后一个 item 失败时，run 停止准入依赖 item，等已运行的 fenced 命令结算后，只取
一次 `failure`，载荷使用最低的稳定 item/command 标识。空 workset 不形成效果边界，
因此 workset 的 `success` 路径不能构成自动循环；failure 回环，以及必经 actor、
authorization 或 script 效果的回环仍然有效。

限制在持久化准入时强制执行：一次 run 不会超过其声明的 `maxParallelism`，引擎级活跃
效果上限跨 run 生效，`maxAttempts` 对同一状态访问或 workset item 的完整重试与
fallback 候选谱系统一计数；新的一次状态访问会重置候选序位。可 fallback 的失败候选
会留在同一次访问中，直到对应的持久化 fallback 命令写入；重启恢复会从已持久化失败
中找到它，并且只写入一次。一次性效果 permit 发出前，store 会在同一个写事务中重新
校验当前授权摘要、lease owner 与尚未过期的 running lease。归约是确定性的：命令持有
稳定标识，并发结果按排序后的
顺序消费；重叠的 `context.*`、`worksets.*` 或候选隔离的可恢复会话贡献由最大的稳定
命令标识决定。因此，相同输入与结果集得到同一规范化快照。

在合成 entry/worker fixture 中，授权、actor 与 workset 状态各声明一条 `success` 与
一条 `failure` 边；`complete` 与 `blocked` 是没有出边的终态。

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

打开编辑器时，工作流角色与 Assistant 的已选 model 目录通过一次 target batch 加载。
Rust 复用既有有界发现 worker、同一份进程/环境快照和一次发现缓存提交；客户端不会为每个
角色分别启动扫描器或异步 runtime。

## 群聊启动

只有群聊显示策略胶囊；一对一 Conversation 不出现。

输入框上方的胶囊默认是**自动适配**。它表示 Assistant 的默认模式，不是内置策略。
选中已授权版本后显示策略名，并在输入框前放入
入口槽当前候选的 `@` 胶囊。选策略会把所有已绑定 Agent（含 Fallback 列表）加入该群
Membership，但不会启动 run。

Assistant 模式开启时，每次用户发送都通过与原生一对一对话相同的 Membership 作用域通道
寻址指定 Assistant。Assistant 可直接回复，也可使用工作流；这个选择不会替换对话通道。
steer、resume、cancel、事件与安全边界行为仍准确遵循所选 adapter 的原生能力。

第一条发送仍是 Conversation Event。原生寻址在持久 conversation sidecar 上启动
`strategy.run.start`（Graph 不拥有发送进程）。之后的发送仍是 Event：若 Membership
上有进行中的 PersistentTurn 则 steer；若 run 处于 Waiting 则 resume。叉掉胶囊只退出
策略模式，不取消已经在跑的 run。

`@mention` 只负责选出 Membership，与策略、Assistant、Subagent 共用同一套
PersistentTurn 流式 I/O，而不是第二套发送协议。Graph 的 actor 与 workset
效果作为对应 Membership 上的结构化 Event，走共享 conversation display。

导入包内容、绑定、授权与原生运行状态都保留在本地客户端状态。不要把原始策略输入、
本机路径、进程输出或智能体历史作为诊断信息公开。
