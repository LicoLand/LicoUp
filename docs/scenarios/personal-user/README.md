# Personal User Scenarios

## Metadata / 元数据

- Last updated: 2026-07-15
- Status: Current scenario index
- Scope: Default local-first client scenarios, shared substrate, skill workflow, and encrypted file handoff within Secure Client Mesh.
- Staleness check: Reconciled with the canonical product-scope plan on 2026-07-15.

- `client-priority-scenarios.md` is the authority for agent discovery,
  conversation, skill management, conversation backup, token usage, encrypted
  mobile relay, and separately enabled LicoLite collaboration plugins.
- `shared-client-substrate.md` defines the bounded queue, ACP, MCP, platform,
  privacy, consent, and cryptographic substrate shared by those scenarios.
- `skill-installer.md` defines the user-approved GitHub skill install/update/
  delete workflow for one or more local agents.
- `mobile-e2ee-cross-device-file-handoff.md` defines explicit user-approved file
  transfer inside Secure Client Mesh; it is not an automatic synchronization
  service.

`PRODUCT.md` and `docs/plan/product-scope/Requirements.md` are upper constraints.
Scenario documents cannot add default navigation, background services, or an
implicit external data-transfer permission.
