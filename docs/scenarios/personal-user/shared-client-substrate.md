# Shared Client Substrate

Status: active personal-user usage-scenario substrate

Personal user scenarios share one client and sidecar substrate across desktop and mobile clients. Message, file, direct skill installation, skill sync, approval, update, and usage-metering flows reuse these primitives instead of creating one-off transports.

| Area | Required contract |
| --- | --- |
| Addressing | Stable `accountId`, `deviceId`, `endpointId`, target client kind, target agent id, and optional conversation id. Selectors show readable labels while storing opaque ids. |
| Trust | Device roster, endpoint trust state, fingerprint/QR/SAS helpers, key-change handling, and revoked endpoint fail-closed behavior are shared with Secure Client Mesh. Retained local evidence for the current trust/pairing surface is available at `build/reports/secure-mesh/device-verification-recovery/latest.json`. |
| Payload security | User message text, command body, approval detail, file name, MIME, relative path, destination directory, result body, and error detail stay inside encrypted payloads. |
| Delivery | Allowed transports are `cloud_relay`, `mobile_relay_compatibility`, `lan_direct`, `webrtc_data_channel`, and `loopback_local`. Unknown transport labels fail closed. |
| Conversation targeting | Each agent adapter exposes a read-only conversation index or targetable conversation handle, or explicitly reports that the target cannot be addressed. |
| Local execution | The local or receiving client owns local effects: forwarding a message, writing a file, installing a skill, resolving approval, or applying an update. |
| Activity | Clients record plan, send, receive, open/decrypt, local effect, result, failure, retry, and cancellation without secret material or plaintext payload leakage. |
| Usage metering | Token and traffic reports store aggregate metrics only. Process-metered bytes are labeled separately from historical estimates; unsupported platform meters return unavailable instead of zero. |
| Verification | Scenario verifiers include no-plaintext, no-prompt-retention, wrong-recipient, revoked-endpoint, replay, destination-boundary, adapter-capability, process-meter availability, and traffic-confidence checks where applicable. The Secure Mesh trust helper report is local evidence only and does not replace scenario E2E verification. |
