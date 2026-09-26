# LicoUp Product

Updated: 2026-09-25

[简体中文](PRODUCT.zh-CN.md) · [User guide](docs/functionality/USER-GUIDE.md)

LicoUp is an open-source, local-first human–Agent conversation client.
It connects user-selected Agents through adapters and keeps conversation ownership,
approval and protected local data at the endpoint.

Contributions must preserve these user-visible boundaries:

- Show the Agent's own reply. LicoUp never asks the Agent for a format, and a reply
  is not invalid or empty because it has no imposed structure.
- Select the user's configured Agent command without silently replacing shell
  aliases, wrappers, arguments or environment. Explicit user selection wins.
- Request OS privacy access when the current user action needs the resource.
  Discovery must not launch unused Agents or cause unrelated permission prompts.
- Preserve conversation history, membership and explicit authorization. A remote
  transport does not own trust, plaintext, keys, approval or local effects.
- Keep native Agent protocols inside adapters and domain decisions outside views.
  A functioning core does not establish compatibility with every upstream version.

[Module guides](docs/RUNBOOK.md#module-guides) own development boundaries and checks.
[Compatibility](docs/COMPATIBILITY.md) is generated from the capability registries;
[Status](docs/STATUS.md) explains the limits of support and verification claims.
Detailed interface fields and state transitions belong to their executable sources.

LicoUp uses [AGPL-3.0-or-later](LICENSE).
