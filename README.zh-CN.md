# Lico Arc

[English](README.md) · 简体中文

Lico Arc 是一个开源客户端。它把本机智能体和设备放进一个清晰的工作空间，
支持不同工具和工作方式，同时让用户始终掌握控制权。

## 设计理念

- **多元** — 支持不同的智能体、设备和本机环境。
- **互联** — 让本机智能体与可信设备自然连接。
- **开放** — 公开源代码、客户端协议和贡献方式。
- **融合** — 用一个简单的客户端体验连接不同工具。

## 主要能力

- 发现电脑上已经安装并受支持的智能体。
- 通过原生适配器新建和继续智能体对话。
- 管理本地技能、对话备份和用量视图。
- 通过 Secure Client Mesh 连接对端客户端。
- 面向 macOS、Windows、Linux、Android 和 iOS。使用平台或功能前，请先查看
  [支持状态](docs/releases/client-support-matrix.zh-CN.md)。

Lico Arc 仍处于早期 Alpha 阶段。可以构建或处于预览状态，不代表已经完整支持。

默认客户端不会加载可选的 LicoLite 协作能力。用户必须主动选择 GitHub 的不可变提交，
通过独立渠道导入其可信签名公钥，再手动安装并启用插件。本地部署还需要一次独立的手动
操作，并且只能启动固定、已签名的外部运行器。本仓库不捆绑该服务端运行器，因此只构建
Lico Arc 不能证明已经部署 LicoLite。安装、启用和启动都不等于授权对外传输数据；每个
将要离开设备的准确请求或本地文件都必须取得一次新的、受保护的用户确认。

## 隐私设计

敏感运行时数据留在设备上。默认客户端场景不会把本地路径、日志、对话历史、用量记录、
凭据或用户内容明文发送给服务端。可选的外部 MCP 请求只能发送本次用户直接确认中展示的
准确请求或选中文件；传输由 HTTPS 保护，但指定的外部服务可以读取用户明确批准的内容。

当你选择向另一个 Lico Arc 客户端发送消息或文件时，发送端会先在本机加密。
发送端使用选中且已经验证的对端密钥，接收端先校验数据包，再使用其中的内容。
Lico Arc 把中转端视为不可信环境，只向它发送密文和完成路由所需的最少信息；
客户端安全不依赖中转端的运行方式或承诺。

```mermaid
flowchart LR
    A["客户端 A<br/>本地数据"] --> B["用户确认<br/>一次对端传输"]
    B --> C["客户端 A 本机加密"]
    C --> D["不可信中转端<br/>密文 + 最少路由信息"]
    D --> E["客户端 B 解密"]
    E --> F["客户端 B<br/>本地数据"]
```

如果没有针对外部服务的准确确认，受保护的用户内容只能在用户确认后，以端到端密文形式
从一个客户端发给另一个客户端。

## 从源码构建

需要 Node.js 22 或 24、Flutter stable 和 Rust stable。

```bash
npm ci
npm run client:get
npm run client:analyze
npm run client:test
```

常见操作请阅读[用户指南](docs/USER-GUIDE.zh-CN.md)，组件和数据边界请阅读
[架构说明](docs/ARCHITECTURE.zh-CN.md)。

## 文档

- [User guide](docs/USER-GUIDE.md) · [用户指南](docs/USER-GUIDE.zh-CN.md)
- [Architecture](docs/ARCHITECTURE.md) · [架构](docs/ARCHITECTURE.zh-CN.md)
- [Support](docs/releases/client-support-matrix.md) ·
  [支持状态](docs/releases/client-support-matrix.zh-CN.md)
- [Security](SECURITY.md) · [安全](SECURITY.zh-CN.md)
- [Contributing](CONTRIBUTING.md) · [参与贡献](CONTRIBUTING.zh-CN.md)

## 许可证

Lico Arc 使用 `GPL-3.0-or-later` 许可证。详见 [LICENSE](LICENSE)。
