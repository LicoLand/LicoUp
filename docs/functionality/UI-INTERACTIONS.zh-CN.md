# 用户界面交互状态机

| 版本 | 入口 |
| --- | --- |
| 规范版本 | [English](UI-INTERACTIONS.md) |
| 本地化 | 简体中文（本文） |

[UI-INTERACTIONS.json](UI-INTERACTIONS.json) 是行为依据：用户看见什么、在那里能做什么、
操作后应该看见什么。不包含 Flutter key、controller 名称、RPC 或后端状态。
[Flutter 适配层](../../apps/desktop/test/ui_state_machine/flutter_adapter.dart) 负责映射当前
控件和可见内容。内部重构更新适配层；有意改变产品行为时，评审并更新模型。

按钮选中不等于跳转成功，必须看到目标内容。例如：群聊返回上一级时，左侧恢复父列表，
右侧仍保留群聊。群聊切到设置再返回时，保留群聊、列表和成员面板上下文。
首次打开群聊时成员面板默认收起，通过右上角三点菜单显式展开。

## 本机运行

```bash
npm run client:test:ui -- --describe
npm run client:test:ui
npm run client:test:ui -- --seed 42 --steps 60
npm run client:test:ui -- --machine dashboard.conversation-journey --seed 42
npm run client:test:ui -- --profile --device macos --seed 42
```

只使用本机已有环境，其它设备由开发者安排，不因缺设备阻塞工作。Widget 模式在本机检查
窄、中、宽布局。Profile 模式目前在指定的本机目标上运行宽屏桌面界面，使用真实生产组件
和动画，以及合成服务、临时存储和模拟键盘，不发起真实 Agent 对话。引擎按应用活动
调度帧；测试 pump 只等待观察，不强制产生额外帧。此测试不验证操作系统输入法。
macOS 测试临时使用独立应用标识，可与已打开的个人数据应用并存，不修改正式
应用的打包设置。

`--steps` 控制随机探索长度，不是验收门槛。默认运行打印新种子，指定该种子可重复运行。
`--machine` 选择单个流程。失败操作序列可以直接重放，跳过前面的覆盖遍历：

```bash
npm run client:test:ui -- --machine dashboard.conversation-journey --replay list.back,group.open,group.menu,roster.toggle,group.menu,roster.toggle
```

每个流程只启动一次。先沿最短点击路径走过每条已声明转换，再从当前状态继续随机游走。
随机动作来自当前可见控件；声明存在的动作消失时，检查失败。点击之间不重置 controller，
也不要求所有动画结束才允许下一次点击。弹窗、搜索、滚动、返回和页面切换在同一段路径
中连续执行。记录包含两个阶段；重放时另行执行模型中的初始化操作。

## 覆盖范围

模型包含两种布局的主导航、窄屏菜单、桌面布局从功能面板打开功能到左侧面板、
重复点击 Dock 图标保持当前功能、左侧面板的展开与收起、全部设置目录，
以及有数据的 dashboard 连续路径：普通对话、群聊、父列表、搜索输入及结果跳转、取消
新建群聊、取消群聊操作、设置和功能页、刷新、上下滚动。滚动时消息必须实际移动，或已经
处于该方向的终点。合成数据提供长消息群聊及另一个空群聊。群聊操作菜单不是模态弹窗，
因此菜单打开时，仍把旁边可见的导航、列表、搜索、成员栏和滚动操作纳入转换。

这表示**已声明转换的覆盖**，不代表产品所有操作或无限操作序列已经全部测试。运行器还会
盘点已访问状态中可命中、可用的按钮，把当前状态没有对应转换的控件列为遗漏，包括没有
文字名称的按钮。这能帮助发现漏项；自定义手势、仅悬停显示的控件、系统界面、尚未访问
的页面仍需检查。不可用控件不参与随机选择。

已知尚未覆盖：其它对话行和原生会话选择、消息操作及执行详情、成员提及及助手配置、
成功的数据编辑操作、文件选择器、各功能专用表单、桌面 Dock 文件夹管理与分栏拖拽。
这些会作为
覆盖缺口呈现，不作为已通过转换。补齐时先在模型声明用户预期，再映射控件；不得从
controller 的变化推断正确目标，也不得把错误跳转写进模型来让检查通过。

不增加 CI 门禁、设备矩阵、后端 trace 服务或测试依赖。遵守
[验证范围](../../CONTRIBUTING.zh-CN.md#验证范围)。

## 看懂结果

最后一次运行在 `build/reports/ui-state-machine/` 写入完整 JSON 和简明 Markdown 报告，
文件前缀为 `widget` 或 `profile`。报告先按用户动作汇总，列出失败与最慢操作；JSON 保留
完整步骤。内容包括：

- 各流程已走过的不同转换数 / 模型声明数，明确区分完成、失败、未运行。
- 从哪里、做什么、应该到哪里、通过或失败、步骤及覆盖/随机/重放阶段。
- 随机种子、失败重放序列，以及当前状态遗漏的可见控件。
- Profile 模式下的响应时间、帧数、UI 和光栅最慢帧、可计算时的帧提交率、超过显示间隔的帧数。

响应时间从手势发送到目标内容已渲染，包含驱动开销；拖动也包含手势持续时间，不是物理
输入到屏幕发光的测量。按引擎帧时间戳将批量送达的采样归到实际操作。单帧操作不计算
帧率；缺少采样显示不可用，不冒充零。空闲界面无需持续满帧。Widget 的虚拟时间只用于
功能检查，不作性能结论。本机结果不替其它设备作保证。

## 实现位置

| 职责 | 文件 |
| --- | --- |
| 用户状态、动作、预期目标 | [UI-INTERACTIONS.json](UI-INTERACTIONS.json) |
| 模型检查与转换遍历，不导入 Flutter 或应用代码 | [model.dart](../../apps/desktop/test/ui_state_machine/model.dart) |
| 点击、输入、滚动及可见结果 | [flutter_adapter.dart](../../apps/desktop/test/ui_state_machine/flutter_adapter.dart) |
| 生产界面夹具、随机选择、重放及帧采样 | [runner.dart](../../apps/desktop/test/ui_state_machine/runner.dart) |
| 本机命令与可读报告 | [client-ui-state-machine.mjs](../../tools/scripts/client-ui-state-machine.mjs) |
| 功能入口 | [Widget tests](../../apps/desktop/test/ui_state_machine/ui_state_machine_test.dart) |
| 真实引擎入口 | [Integration test](../../apps/desktop/integration_test/ui_state_machine_test.dart) |
