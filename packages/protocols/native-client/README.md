# packages/protocols/native-client

本目录记录 LicoArc Flutter 客户端、Rust native library 与本机智能体之间的稳定协议边界。

实现入口：

- `../../../crates/lico-client-native/src/core/task_queue.rs`：有界本机任务队列。
- `../../../crates/lico-client-native/src/platform/runtime_adapters.rs`：智能体会话适配注册表。
- `../../../crates/lico-client-native/src/core/mcp.rs`：与服务实现无关的 MCP JSON-RPC 报文适配。
- `../../../crates/lico-client-native/src/core/secure_mesh_acp.rs`：Secure Client Mesh 上的 ACP 承载。

协议范围：

- 并发发现本机智能体及其原生配置。
- 通过智能体官方 ACP、app-server、RPC 或 CLI 通道新建、续接和回显对话。
- 构造、校验和编码单条 MCP 请求、通知与响应；转发响应必须消费与请求和目的端精确绑定的一次性用户批准。
- 在 Secure Client Mesh 内承载经过端到端加密的 ACP 命令和结果。
- macOS、Windows、Ubuntu、Android 与 iOS 的平台桥接只实现各自平台职责，不复制业务协议。

边界原则：

- 默认能力不绑定任何 LicoMesh 地址、令牌、服务发现文件或后台服务。
- 可选协作只注册 `collaboration` 手动生命周期命令；默认状态查询不读取插件，GitHub 安装计划必须绑定来源与 SHA-256 摘要，插件包不得包含可执行文件或指令。
- CLI、Flutter 与移动桥接复用同一组 Rust 协议模型，不各自创建报文变体。
- 本机路径、配置、对话和统计保留在客户端拥有的存储中。
- 任何把用户信息或文件发送到本机之外的动作都必须由用户针对本次动作、具体目的端和具体范围直接确认；取消、范围不匹配或批准缺失时失败关闭。
- 可选协作能力属于用户主动安装的外部插件，不进入默认包，也不改变上述边界。
