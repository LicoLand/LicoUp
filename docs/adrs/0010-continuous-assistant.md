# ADR 0010: Conversation continuity ownership

Updated: 2026-09-25

[简体中文](0010-continuous-assistant.zh-CN.md)

Continuity records belong to Canonical Conversation. A provider session is a
replaceable execution binding; it does not own history, membership or permissions.
This separation lets native sessions change without creating a competing store of
user agreements or widening context access. The trade-off is explicit binding and
reconciliation between the durable owner and each runtime.

[Continuity boundaries](../architecture/CONTINUOUS-ASSISTANT.md) route to the
executable schema and implementation. Keep host state separate from the Agent's
natural reply. Changes include the affected producer and consumers together;
interface declarations alone do not establish operational capability.
