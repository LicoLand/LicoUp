# LicoUp architecture

Updated: 2026-09-25

[简体中文](README.zh-CN.md) · [Developer entry](../RUNBOOK.md)

LicoUp keeps endpoint work local. The client composes independent domains through
consumer-owned interfaces; remote transport is not a second authority for identity,
approval, work state or history.

| Layer | Owns | Dependency boundary |
| --- | --- | --- |
| Presentation | Views, interaction and resource rendering | Consumes projected contracts; no domain persistence or native RPC in widgets |
| Application and bridge | Use cases, generated DTOs and typed command routing | Composes domains; transport does not decide domain policy |
| Domain | Conversation, workflow, endpoint and catalog decisions | Depends on ports, not platform mechanisms |
| Infrastructure and platform | Storage, processes, network and OS key custody | Implements ports; does not redefine domain truth |

A domain is a vertical slice across these layers. See the [module guides](../RUNBOOK.md#module-guides)
for ownership, fixed checks and test directories; load only the relevant slice.

| Design question | Reference |
| --- | --- |
| Durable conversation ownership | [Conversation](CONVERSATION-DOMAIN.md) |
| Streaming, settlement and rendering | [Conversation projection](CONVERSATION-VERTICAL-CONTRACT.md) |
| Persistent Assistant work | [Continuity](CONTINUOUS-ASSISTANT.md) |
| Workflow definitions and execution | [Workflow control](ASSISTANT-WORKFLOW-CONTROL.md) |
| Rust/Dart contract | [Client-native boundary](CLIENT-NATIVE-INTERACTION.md) |
| Agent protocol adaptation | [Adapters](AGENT-ADAPTERS-ARCHITECTURE.md) |
| Endpoint trust and data transfer | [Security boundary](SECURITY-AND-DATA-BOUNDARY.md) |
| Extension admission | [Extensions](EXTENSION-PLATFORM.md) |
| Package composition | [Deployment profiles](DEPLOYMENT-PROFILES.md) |
| Local model facts | [Model registry](MODEL-REGISTRY.md) |
| Persistent format changes | [Migration](CLIENT-UPDATE-AND-STATE-MIGRATION.md) |

Executable schemas, registries and tests own detailed states and fields. This index
explains the dependency direction; it does not repeat module contracts or acceptance
results. Declared support is projected in [Compatibility](../COMPATIBILITY.md).
