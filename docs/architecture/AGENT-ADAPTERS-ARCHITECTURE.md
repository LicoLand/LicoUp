# Agent adapter boundaries

Updated: 2026-09-25

[简体中文](AGENT-ADAPTERS-ARCHITECTURE.zh-CN.md) · [Runtime module](../modules/agent-runtime.md)

The core consumes one current semantic facade: send input, receive output, control
an admitted turn and resolve approval. Vendor RPC, ACP, MCP, HTTP/SSE and terminal
frames belong to adapters. Keep upstream-version handling there; do not maintain
parallel V1/V2 core contracts or vendor branches in Conversation or Flutter.
External protocol identifiers identify an adapter's wire format, not another core.

Approval describes the decision and its scope: one operation, a supported persistent
scope or a matching prefix, and the corresponding refusal. Never widen a one-time
approval into a persistent grant or simulate an unsupported scope. Preserve actual
capabilities and explicit unsupported results. Usage, pricing and model discovery
have separate owners; they do not enlarge the core send/receive contract.

[Runtime contracts](../../crates/licoup-agent-runtime/src/) and
[extension contracts](../../crates/licoup-extension-contracts/src/agent.rs) own their
executable fields. [Compatibility](../COMPATIBILITY.md) projects registered adapter
facts; do not maintain a second vendor/protocol matrix here.

Keep protocol parsing in each adapter, supervision in the host and durable history
in Conversation. Relay natural replies faithfully: no imposed reply format, no
completion guessed from silence, no silent replacement of an exact resume with a
new session. Respect the user's selected command and environment.

Designers use `npm run repo:impact -- --path <changed-path>` to inspect dependencies.
A vendor-specific change checks that adapter. A shared semantic or transport change
includes its consumers. Update both sides of a changed boundary within one complete
PR; keep shared files under one owner. Missing real validation is a warning, never
proof of support and not a blocker by itself. Run explicitly requested live targets
sequentially. `npm run repo:upstream` observes official source metadata; a page change
requires review and any unrelated protocol repair belongs in a separate Draft PR.
