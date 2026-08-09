# LicoUp Compatibility

English (normative) · [简体中文](COMPATIBILITY.zh-CN.md) · [Documentation](README.md) · [Project](../README.md)

Product version: `0.1.0`

Generated sources: `tools/client-support-matrix.json`, `tools/client-release-targets.json`, `tools/client-version.json`, `crates/licoup-native/resources/agent-conversation-drivers.json`, `crates/licoup-native/resources/agent-native-capabilities.json`, and `crates/licoup-native/resources/agent-conversation-readiness.json`.

Update with `npm run client:support-matrix:sync`; verify with `npm run client:support-matrix:check`. Do not edit this projection by hand.

## Platform targets

A build target is not a support claim.

| Target | Build | GitHub Release eligible | Physical/device evidence | Store publication | Client | Peer encryption | Mobile relay |
| --- | --- | --- | --- | --- | --- | --- | --- |
| windows-x64 | available | not eligible | not claimed | not claimed | preview | preview | preview |
| windows-arm64 | unavailable | not eligible | not claimed | not claimed | unverified | unverified | unverified |
| macos-x64 | available | not eligible | not claimed | not claimed | supported | preview | preview |
| macos-arm64 | available | eligible | not claimed | not claimed | supported | preview | preview |
| linux-glibc-x64 | available | not eligible | not claimed | not claimed | preview | preview | preview |
| linux-glibc-arm64 | available | eligible | not claimed | not claimed | preview | preview | preview |
| linux-musl-x64 | available | not eligible | not claimed | not claimed | preview | preview | preview |
| linux-musl-arm64 | available | not eligible | not claimed | not claimed | preview | preview | preview |
| android-arm64 | available | eligible | not claimed | not claimed | supported | preview | preview |
| ios-simulator-arm64 | available | not eligible | simulator only | not claimed | supported | preview | preview |
| ios-arm64 | unavailable | not eligible | not claimed | not claimed | unverified | unverified | unverified |

## Meaning

- `supported` means the current target-specific client checks accept the feature; it does not imply distribution readiness.
- `preview` means the feature is still changing.
- `unverified` means there is no current support claim.
- `unsupported` means the feature must not be presented as available.
- `eligible` means a release operator may explicitly select that target; it does not mean any current release includes it.
- Feature status does not establish native-host, physical-device, biometric, hardware-custody, or cross-device evidence. Those claims remain `not claimed`; a simulator row proves only its simulator closure.
- Store publication is not claimed by this matrix and requires a separate channel-specific result.
- Peer content is encrypted by the sending client. Sensitive runtime data stays local.

## Agent adapter targets

This table projects the native driver inventory. Runtime protocol and capability fields remain owned by that inventory.
Lifecycle evidence columns describe whether the lane can emit a native receipt for that stage. `submitted` is always a local client fact. On each turn, the UI shows only receipts actually observed; unsupported or absent stages are skipped and are never inferred from a later response or terminal result.

| Agent ID | Driver mode | Readiness | Send enabled | Runtime protocol | Lane family | Exact resume | Streaming | Accepted evidence | Processing evidence | Responding evidence | Completed evidence | Native interrupt/steer |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| openclaw | conversation | unverified | no | openclaw-acp-stdio-jsonrpc | acp | yes | yes | yes | yes | yes | yes | no |
| claude-code | conversation | ready | yes | claude-code-cli-stream-json | stream-json | yes | yes | yes | yes | yes | yes | yes |
| codex | conversation | ready | yes | codex-app-server-stdio-jsonrpc | app-server | yes | yes | yes | yes | yes | yes | yes |
| antigravity | conversation | unverified | no | antigravity-cli-argv-hook-v1 | cli | yes | yes | yes | no | yes | yes | no |
| opencode | conversation | unverified | no | opencode-serve-http-v1 | serve-http | yes | yes | yes | no | yes | yes | no |
| copilot | conversation | unverified | no | copilot-acp-v1-stdio-ndjson | acp | yes | yes | yes | yes | yes | yes | no |
| kilo-code | conversation | unverified | no | kilo-code-serve-http-v1 | serve-http | yes | yes | yes | no | yes | yes | no |
| cursor | conversation | ready | yes | cursor-agent-cli-v1 | cli | yes | yes | yes | no | yes | yes | no |
| hermes | conversation | unverified | no | hermes-acp-stdio-jsonrpc | acp | yes | yes | yes | yes | yes | yes | no |
| kimi-code | conversation | unverified | no | kimi-code-acp-v1-stdio-ndjson | acp | yes | yes | yes | yes | yes | yes | no |
| pi | conversation | unverified | no | pi-rpc-stdio-jsonl | rpc | yes | yes | yes | yes | yes | yes | yes |
| lico-agent | conversation | unverified | no | lico-agent-rpc-stdio-jsonl | rpc | yes | yes | yes | yes | yes | yes | yes |

## Native capability inventory

This table is generated from the same native capability inventory used by the desktop runtime.

Classification rules:

- List only interfaces shipped by the agent. A LicoUp-managed bridge or `lico-llm-gateway` is not an agent-native capability.
- `CLI` is the ordinary command process. Protocol subcommands such as `acp`, `serve`, `web`, `gateway`, `app-server`, or RPC mode are separate, mutually exclusive running capabilities.
- `ACP`, `RPC`, and `App Server` are structured process protocols and do not imply a listening network port.
- `Local Server` is the agent's direct loopback API. `Web Server` additionally owns a browser UI or broader web control plane.
- `Gateway` is an intermediate reusable attachment layer between a client protocol process and the agent runtime. `TUI Gateway` is the Hermes remote/manual-VM specialization.
- Installed/detected means the owning executable can provide the capability. Running requires a matching process; a network server or network gateway also requires its own listener evidence.

| Agent ID | Native capabilities | Primary LicoUp lane | Primary transport | Listener | Role |
| --- | --- | --- | --- | --- | --- |
| openclaw | CLI, ACP, Gateway | acp | stdio ACP | loopback TCP | intermediate attach layer |
| claude-code | CLI | stream-json | stdio stream-json | none | direct process interface |
| codex | Desktop, CLI, App Server | app-server | stdio JSON-RPC | none | direct stdio App Server |
| antigravity | Desktop, CLI | cli | CLI process | none | direct process interface |
| opencode | CLI, Local Server | serve-http | loopback HTTP + SSE | loopback TCP | direct local agent API |
| copilot | CLI, ACP | acp | stdio ACP | none | direct process interface |
| kilo-code | CLI, Local Server | serve-http | loopback HTTP + SSE | loopback TCP | direct local agent API |
| cursor | Desktop, CLI | cli | CLI process | none | direct process interface |
| hermes | CLI, ACP, TUI Gateway | acp | stdio ACP | conditional remote only | direct ACP; TUI Gateway only for manual VM |
| kimi-code | CLI, ACP, Web Server | acp | stdio ACP | loopback TCP | direct control plane and Web UI |
| pi | CLI, RPC | rpc | stdio JSONL | none | direct process interface |
| lico-agent | CLI, RPC | rpc | stdio JSONL | none | direct process interface |

## Manual VM conversation transport

The desktop manual-target flow can bind OpenClaw or Hermes to a user-owned VM through system OpenSSH stdio and ACP. It requires existing strict host verification and noninteractive SSH authentication; LicoUp accepts no SSH password or private key. Conversation history uses ACP session list/load instead of guest filesystem access. This source transport does not by itself promote the adapter readiness or release send-enabled claims in the table above.
