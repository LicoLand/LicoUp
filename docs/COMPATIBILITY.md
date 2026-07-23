# Lico Arc Compatibility

English (normative) · [简体中文](COMPATIBILITY.zh-CN.md) · [Documentation](README.md) · [Project](../README.md)

Product version: `0.0.1-alpha`

Generated sources: `tools/client-support-matrix.json`, `tools/client-release-targets.json`, `tools/client-version.json`, `crates/lico-client-native/resources/agent-conversation-drivers.json`, and `crates/lico-client-native/resources/agent-conversation-readiness.json`.

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

| Agent ID | Driver mode | Readiness | Send enabled | Runtime protocol | Lane family | Exact resume | Streaming | Native interrupt/steer |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| openclaw | conversation | unverified | no | openclaw-acp-stdio-jsonrpc | acp | yes | yes | no |
| claude-code | conversation | unverified | no | claude-code-cli-stream-json | stream-json | yes | yes | yes |
| codex | conversation | unverified | no | codex-app-server-stdio-jsonrpc | app-server | yes | yes | yes |
| antigravity | conversation | unverified | no | antigravity-cli-argv-hook-v1 | cli | yes | yes | no |
| opencode | conversation | unverified | no | opencode-serve-http-v1 | serve-http | yes | yes | no |
| copilot | conversation | unverified | no | copilot-acp-v1-stdio-ndjson | acp | yes | yes | no |
| kilo-code | conversation | unverified | no | kilo-code-serve-http-v1 | serve-http | yes | yes | no |
| cursor | conversation | unverified | no | cursor-agent-cli-v1 | cli | yes | yes | no |
| hermes | conversation | unverified | no | hermes-acp-stdio-jsonrpc | acp | yes | yes | no |
| kimi-code | conversation | unverified | no | kimi-code-acp-v1-stdio-ndjson | acp | yes | yes | no |
| pi | conversation | unverified | no | pi-rpc-stdio-jsonl | rpc | yes | yes | yes |
