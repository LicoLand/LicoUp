# LicoUp Documentation

[Project](../README.md) · [简体中文项目入口](../README.zh-CN.md)

English is the normative language for shared technical facts. Files marked
Simplified Chinese are localized projections and link back to their English
authority.

## Project entry documents

- [Product goal and boundary](../PRODUCT.md) · [产品目标与边界](../PRODUCT.zh-CN.md)
- [Domain language](../CONTEXT.md)
- [Current status](STATUS.md) · [当前状态](STATUS.zh-CN.md)
- [Contributing](../CONTRIBUTING.md) · [参与贡献](../CONTRIBUTING.zh-CN.md)
- [Code of Conduct](../CODE_OF_CONDUCT.md)
- [Changelog](../CHANGELOG.md)
- [Governed release status](releases/README.md) ·
  [版本发布状态](releases/README.zh-CN.md)
- [Client promotion gates](releases/PROMOTION-GATES.md) ·
  [客户端分支晋升门禁](releases/PROMOTION-GATES.zh-CN.md)
- [Security](../SECURITY.md) · [安全](../SECURITY.zh-CN.md)
- [License](../LICENSE)

## Architecture

- [Architecture](architecture/README.md) · [架构](architecture/README.zh-CN.md)
- [Conversation vertical contract — Reactive State Binding](architecture/CONVERSATION-VERTICAL-CONTRACT.md)
- [Client-native interaction boundary](architecture/CLIENT-NATIVE-INTERACTION.md)
- [Client update and state migration](architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.md) ·
  [客户端更新与状态迁移](architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md)
- [Canonical Conversation domain](architecture/CONVERSATION-DOMAIN.md) · [统一 Conversation 领域架构](architecture/CONVERSATION-DOMAIN.zh-CN.md)
- [Agent adapters and runtime architecture](architecture/AGENT-ADAPTERS-ARCHITECTURE.md) · [智能体适配器架构规范](architecture/AGENT-ADAPTERS-ARCHITECTURE.zh-CN.md)
- [Rust infrastructure and boundary layer](architecture/RUST-INFRASTRUCTURE-LAYER.md) · [Rust 基础设施与对外交互层规范](architecture/RUST-INFRASTRUCTURE-LAYER.zh-CN.md)
- [Security and data boundaries](architecture/SECURITY-AND-DATA-BOUNDARY.md) · [安全架构与数据边界](architecture/SECURITY-AND-DATA-BOUNDARY.zh-CN.md)

## Functionality

- [Functionality index](functionality/README.md)
- [Client capability boundary](functionality/CLIENT-DESKTOP.md)
- [User guide](functionality/USER-GUIDE.md) ·
  [用户指南](functionality/USER-GUIDE.zh-CN.md)
- [Adaptive Flywheel strategies](functionality/ADAPTIVE-FLYWHEEL.md) ·
  [Adaptive Flywheel 策略](functionality/ADAPTIVE-FLYWHEEL.zh-CN.md)
- [Design system](functionality/DESIGN-SYSTEM.md)
- [Current retiring endpoint-protection Preview file handoff](functionality/ENDPOINT-PROTECTION-PREVIEW-FILE-HANDOFF.md)

## Protocols and artifact formats

- [Protocol index](protocols/README.md)
- [Lico Arc candidate station adapter](protocols/licoarc-station-adapter.md) ·
  [Lico Arc 候选通讯站 Adapter](protocols/licoarc-station-adapter.zh-CN.md)
- [Subagent MCP](protocols/subagent-mcp.md) ·
  [下属智能体 MCP](protocols/subagent-mcp.zh-CN.md)
- [Conversation MCP and canonical model](protocols/lico-conversation-mcp.md) ·
  [Conversation MCP 与统一模型](protocols/lico-conversation-mcp.zh-CN.md)
- [Lico Agent](protocols/lico-agent.md) ·
  [Lico Agent 中文说明](protocols/lico-agent.zh-CN.md)
- [Gateway runtime](protocols/gateway-runtime.md) ·
  [Gateway 运行时](protocols/gateway-runtime.zh-CN.md)
- [LLM Gateway](protocols/llm-gateway.md) ·
  [LLM Gateway 中文说明](protocols/llm-gateway.zh-CN.md)
- [Semantic conversation contract](protocols/semantic-conversation.md)
- [Client artifact verification receipts](protocols/client-artifact-verification-receipts.md)

## Platforms

- [macOS direct-distribution compliance](platforms/MACOS-DIRECT-DISTRIBUTION.md) ·
  [macOS 站外直发合规清单](platforms/MACOS-DIRECT-DISTRIBUTION.zh-CN.md)

## Operations and configuration

- [Runbook](RUNBOOK.md)
- [Parallel development map](parallel/PARALLEL-DEVELOPMENT-MAP.md) ·
  [并行开发地图](parallel/PARALLEL-DEVELOPMENT-MAP.zh-CN.md)
- [Compatibility](COMPATIBILITY.md) ·
  [兼容性](COMPATIBILITY.zh-CN.md)
- [Release packages](RELEASE-PACKAGES.md) ·
  [发布包结构](RELEASE-PACKAGES.zh-CN.md)
- [Entity configuration layout](ENTITY-CONFIG-LAYOUT.md)

`COMPATIBILITY.md` and its localization are generated projections. Their source
catalogs and update commands are stated in those files.

## Examples and decisions

- [Examples](examples/README.md)
- [CLI workflow examples](examples/CLI-WORKFLOWS.md)
- [Architecture decision records](adrs/README.md)
- [ADR 0001: PTY transport for CLI lanes](adrs/0001-pty-transport-for-cli-lanes.md)
- [ADR 0002: Conversation admission regime for running Agent dialogs](adrs/0002-conversation-admission-regime.md)
- [ADR 0003: Group-conversation Agent Profile](adrs/0003-group-conversation-agent-profile.md)
- [ADR 0004: Assistant-authored flexible workflows](adrs/0004-assistant-authored-flexible-workflows.md)
- [ADR 0005: Assistant auto-adaptation, diagnostics, and DeepSeek Harness](adrs/0005-assistant-auto-adaptation-and-deepseek-harness.md)
- [ADR 0006: Capability-aware parallel client regression](adrs/0006-capability-aware-parallel-regression.md)
- [ADR 0007: User-terminal Agent command identity](adrs/0007-user-terminal-agent-command-identity.md)
- [ADR 0008: Native Agent parser and conversation integrity](adrs/0008-native-agent-parser-and-conversation-integrity.md)
- [ADR 0009: Single Source of Truth Documentation Architecture and Domain Indexing](adrs/0009-single-source-of-truth-documentation-architecture.md) · [中文版](adrs/0009-single-source-of-truth-documentation-architecture.zh-CN.md)

Plans, proposals, work reports, raw audit material, caches, and build output are
not formal documents. They remain in ignored `docs/plans/`, `docs/reports/`,
`cache/`, and `build/`.
