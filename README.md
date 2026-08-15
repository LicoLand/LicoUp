<div align="center">

<img src="docs/assets/brand/readme-banner.svg" alt="LicoUp — orbit ice-cream cup brand banner" width="880">

**Create value with your agents.**

English (normative language) · [简体中文 (localized language)](README.zh-CN.md)

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue?style=flat-square)](LICENSE)
[![Version: 0.1.0-alpha](https://img.shields.io/badge/version-0.1.0--alpha-orange?style=flat-square)](docs/STATUS.md)
[![Platforms: macOS · Windows · Linux · Android · iOS](https://img.shields.io/badge/platforms-macOS_%C2%B7_Windows_%C2%B7_Linux_%C2%B7_Android_%C2%B7_iOS-24292f?style=flat-square)](docs/COMPATIBILITY.md)

</div>

## Introduction

LicoUp is an open-source, local-first agent collaboration client. Its current
evidenced stage focuses on local and explicitly configured agent conversations;
peer and cross-device capabilities remain Preview and are tracked in the
[status](docs/STATUS.md) and [compatibility matrix](docs/COMPATIBILITY.md).

The current endpoint-protection Preview encrypts an approved peer transfer on
the sender before station I/O and authenticates it at the receiver. The station
is treated as untrusted; this is not a stable Lico Arc Profile, published
protocol, hosted-network claim, or support declaration.

## Installation

No packaged release is published yet — build from source:

| Toolchain | Requirement |
| --- | --- |
| Node.js | 22 or 24 |
| Flutter | stable |
| Rust | stable |

```bash
npm ci
npm run client:get
npm run client:analyze
npm run client:test
```

> [!NOTE]
> LicoUp is in early alpha: a build target or preview feature is not a
> supported release. Check the [compatibility matrix](docs/COMPATIBILITY.md)
> before relying on a platform or feature.

## Perspective

Building a distributed collaboration network for the agentic era — where humans and agents across endpoints connect and create freely, while privacy and ownership remain firmly with the individual.

| Principle | Idea |
| --- | --- |
| **Diverse** | Work with different agents, devices, and local setups. |
| **Connected** | Move between local agents and trusted peer devices with less friction. |
| **Open** | Keep the source, client protocols, and contribution path visible. |
| **Integrated** | Give different tools one simple client experience. |

## Capabilities

| Capability | Description |
| --- | --- |
| **Multi-Agent Collaboration** | Work with local and explicitly configured agents; use only the peer and cross-device Preview capabilities currently declared in the compatibility matrix. |
| **Extending Agents** | Discover skills already present in local agent roots, inspect usage, and move a selected skill to the system Trash. LicoUp does not download, install, update, or synchronize skills. |
| **Seamless Chat with Agents** | Start native-fidelity conversations through the exact packaged agent interfaces currently declared ready in the compatibility matrix. |
| **Customized Workflow** | Define or import Adaptive Flywheel strategies for pipelines, branches, and bounded Agent Loops; immutable revisions bind roles to eligible agents, models, and reasoning effort before exact authorization. |
| **Privacy and Security** | Default local scenarios keep sensitive runtime data on the device. Approved peer transfers use the endpoint-protection Preview; approved external services can read only the exact content authorized for them — details in [Privacy concerns](#privacy-concerns). |

## Privacy concerns

**Local first.** Sensitive runtime data stays on the device. Default client
scenarios upload no local paths, logs, conversation history, usage records,
credentials, or plaintext user content.

**Endpoint-protected peer transfer (preview).** Content is encrypted with the
selected peer's keys before it leaves the device; the receiving endpoint
authenticates and verifies it before use. The station is untrusted — it
supplies no algorithms, keys, or security policy, and its receipts are only
delivery hints. Lico Arc owns the wire-observable protocol semantics; LicoUp
keeps private keys, plaintext, history, backups, trust, and approvals. The
current Preview is not a Lico Arc Profile and retires directly when a pinned
Lico Arc Protocol Line replaces it.

```mermaid
flowchart LR
    A["Client A<br/>local data"] --> B["User approves<br/>one peer transfer"]
    B --> C["Encrypt on Client A"]
    C --> D["Untrusted station<br/>Lico Arc ciphertext + minimum route"]
    D --> E["Decrypt on Client B"]
    E --> F["Client B<br/>local data"]
```

**Explicit external approval.** An optional external MCP request sends only
the exact request or selected files shown in a fresh direct approval, and the
named service can read that approved content. Without it, protected content
leaves the client only as an approved end-to-end-encrypted transfer to
another client.

## Documentation

| Topic | English | Simplified Chinese |
| --- | --- | --- |
| Index | [Documentation index](docs/README.md) | — |
| Domain language | [Context](CONTEXT.md) | — |
| Current status | [Status](docs/STATUS.md) | [当前状态](docs/STATUS.zh-CN.md) |
| User guide | [User guide](docs/functionality/USER-GUIDE.md) | [用户指南](docs/functionality/USER-GUIDE.zh-CN.md) |
| Architecture | [Architecture](docs/architecture/README.md) | [架构](docs/architecture/README.zh-CN.md) |
| Federation transport | [Lico Arc candidate station adapter](docs/protocols/licoarc-station-adapter.md) | [Lico Arc 候选通讯站 Adapter](docs/protocols/licoarc-station-adapter.zh-CN.md) |
| Compatibility | [Compatibility](docs/COMPATIBILITY.md) | [兼容性](docs/COMPATIBILITY.zh-CN.md) |
| Release packages | [Release packages](docs/RELEASE-PACKAGES.md) | [发布包结构](docs/RELEASE-PACKAGES.zh-CN.md) |
| Security | [Security](SECURITY.md) | [安全](SECURITY.zh-CN.md) |
| Contributing | [Contributing](CONTRIBUTING.md) | [参与贡献](CONTRIBUTING.zh-CN.md) |

[Product definition](PRODUCT.md) · [Changelog](CHANGELOG.md) ·
[Code of conduct](CODE_OF_CONDUCT.md) · Licensed under
[`AGPL-3.0-or-later`](LICENSE)
