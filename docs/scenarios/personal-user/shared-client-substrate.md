# Shared Client Substrate

Status: active personal-user usage-scenario substrate

Personal user scenarios share one client and sidecar substrate across desktop and mobile clients. Message, file, direct skill installation, skill sync, approval, update, and usage-metering flows reuse these primitives instead of creating one-off transports.

| Area | Required contract |
| --- | --- |
| Addressing | Stable `accountId`, `deviceId`, `endpointId`, target client kind, target agent id, and optional conversation id. Selectors show readable labels while storing opaque ids. |
| Trust | Device roster, endpoint trust state, fingerprint/QR/SAS helpers, key-change handling, and revoked endpoint fail-closed behavior are shared with Secure Client Mesh. Retained local evidence for the current trust/pairing surface is available at `build/reports/secure-mesh/device-verification-recovery/latest.json`. |
| Payload security | User message text, command body, approval detail, file name, MIME, relative path, destination directory, result body, and error detail stay inside encrypted payloads. |
| Delivery | Recognized transport labels are `cloud_relay`, `mobile_relay_pairwise`, `lan_direct`, `webrtc_data_channel`, and `loopback_local`; unknown labels fail closed. Production-advertised remote transports are limited to `cloud_relay` and `mobile_relay_pairwise` until LAN and WebRTC have verifier-backed production evidence. |
| Conversation targeting | Each packaged adapter may expose a read-only conversation index independently, but it may advertise `runtime.message.send` or enable a composer only after the CL-06 native-conversation parity reducer marks it `ready`. `partial`, `failed`, `blocked`, `unverified`, and `history-only` remain non-sendable. |
| Conversation drivers | The desktop packaging registry is the only permanent target authority and projects one canonical driver per packaged adapter. Current protocol families are Codex app-server; ACP for OpenCode, GitHub Copilot, Kilo Code, OpenClaw, and Hermes Agent; official stream-JSON for Claude Code and Cursor; and a fail-closed Antigravity driver until a public transport can keep prompt/session data out of argv. OpenClaw binds its native Gateway conversation through ACP `sessionKey` metadata. This protocol-family snapshot must not become a hand-maintained target registry. |
| Conversation readiness | Driver availability, version/capability probes, unit tests, and fake-child/synthetic E2E are prerequisite layers only. The canonical reducer requires CL-06 P-01..P-10 plus every applicable C-01..C-06 from real native-vs-Arc and release-UI evidence. No adapter is currently full `ready`, so the release substrate exposes no send-capable composer. |
| Local execution | The local or receiving client owns local effects: forwarding a message, writing a file, installing a skill, resolving approval, or applying an update. |
| Activity | Clients record plan, send, receive, open/decrypt, local effect, result, failure, retry, and cancellation without secret material or plaintext payload leakage. |
| Usage metering | Token and traffic reports store aggregate metrics only. Process-metered bytes are labeled separately from historical estimates; unsupported platform meters return unavailable instead of zero. |
| Verification | Scenario verifiers include no-plaintext, no-prompt-retention, wrong-recipient, revoked-endpoint, replay, destination-boundary, adapter-capability, process-meter availability, and traffic-confidence checks where applicable. The Secure Mesh trust helper report is local evidence only and does not replace scenario E2E verification. |

Acceptance-host availability is tracked separately from adapter readiness. OpenCode and GitHub Copilot currently have the prerequisites needed to schedule live A/B but remain `unverified`; the other pending live lanes lack the required CLI and/or authorized account, while documented protocol blockers continue to fail closed. These host conditions must never be promoted into the packaging registry or treated as parity evidence.
