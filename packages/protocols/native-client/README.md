# packages/protocols/native-client

本目录记录 Node.js 服务端对 Rust native sidecar 与 desktop app 间接调用链暴露的上游协议。

下游客户端消费视角放在：

- `../../../crates/lico-client-native/`
- `../checkpoint`

checkpoint / 断点续传的服务端接收协议与服务端协议执行适配放在：

- `../checkpoint`

服务端发布-订阅协议放在：

- `../pubsub`

边界：

- Native sidecar 是客户端执行层，可以独立于 Flutter 前端调用这些协议。
- Desktop app 通过 native sidecar 或 daemon 间接使用这些协议。
- Node.js 服务端不关心调用来自 CLI 还是 GUI，只遵守稳定接口契约。
- 服务端协议是上游承诺，必须描述服务器接受什么、返回什么以及版本化迁移边界。

协议范围：

- bootstrap 与服务发现
- client check-in 与迁移状态
- upload session 创建、恢复和分块上传
- checkpoint 与 manifest
- job 创建、轮询、取消、删除和结果拉取
- result export 与 normalized documents 下载
- 服务端可用智能体注册表 `GET /api/agents`，返回脱敏 alias、模型提供方、调用模式和默认调用参数
- events / logs / runtime state 订阅

恢复语义：

- 客户端执行层必须 local-first。服务端不可达时，Flutter 前端仍可继续本地文件枚举、Mail 导入、本地知识索引查询和任务入队。
- 上传队列遇到连接拒绝、超时、DNS、临时 5xx/429 等网络型错误时，不进入终态 `failed`，而是进入 `waiting_server`。
- `waiting_server` 任务保留 checkpointId、manifestDigest、文件 hash、已接收 offset、upload session 和 job 引用；后台 worker 按指数退避自动重试。
- 用户手动 `retry` / `resume` 可以立即把可恢复任务重新放入 `queued`；`pause` / `cancel` 仍然优先于自动恢复。
- 客户端后台通过 `server.events.sync` 以 `/api/events` 的 cursor 接续服务端发布事件，并把事件写入本地事件日志；服务端宕机期间游标不前进，恢复后从上次 `nextCursor` 继续。

原则：

- CLI 和 GUI 不各自定义一套业务协议。
- 客户端执行能力必须能通过 CLI 直接调用。
- 服务端向客户端发布的内容必须进入 pub-sub topic。
- 破坏兼容的字段变更必须提供协议版本和迁移策略。
- `protocols` 记录对接报文格式、协议状态机和协议边界内执行适配。
