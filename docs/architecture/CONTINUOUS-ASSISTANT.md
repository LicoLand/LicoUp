# Conversation continuity boundaries

Updated: 2026-09-25

[简体中文](CONTINUOUS-ASSISTANT.zh-CN.md) · [Conversation module](../modules/conversation.md)

Canonical Conversation owns durable history, membership and continuity records.
Runtime sessions are private bindings, not an alternative history or goal authority.
Child work uses admitted child Conversations and scoped parent grants; switching a
model never broadens a recipient's access. Context composition uses current grants
and revocation generations. A view detaching is not cancellation or deletion.

The executable bridge contract is
[conversation schema](../../schemas/client_bridge/conversation.json); its generated
Rust/Dart types are projections. The [continuity implementation](../../crates/licoup-conversation/src/continuity/)
owns admission, lifecycle, persistence ports and unsupported capability results.
An interface declaration does not establish that the corresponding automation works.

LicoUp shows the Agent's reply as the Agent produced it. Host state is derived from
observations and authorized operations; never require a reply schema to satisfy a
host record. Preserve unknown effects for reconciliation rather than retrying them
as though nothing happened.

Designers changing these boundaries must include Conversation, runtime and any
consuming UI/bridge owners. Verify through `npm run verify:conversation` and the
commands of affected consumers. List registered machines with
`npm run repo:state-machines -- --list`; do not copy state tables here.
