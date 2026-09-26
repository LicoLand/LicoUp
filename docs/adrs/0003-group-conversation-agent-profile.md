# ADR 0003: Group-conversation Agent Profile

Updated: 2026-09-25

Status: implemented · Current authority:
`crates/licoup-conversation/src/client_conversation/mod.rs`

## Decision

Each Agent Membership has one endpoint-local, revisioned Profile intent in its
Conversation. The Profile stores required and preferred capabilities, Skill
references, preferred model, preferred reasoning effort, preferred environment,
and the Membership's Assistant/member responsibility. It is not a station or
wire-protocol object.

Runtime availability, model price, model capability, Skill availability, and
environment readiness remain in their existing catalogs. A Profile references
intent; request-time snapshots resolve current facts and revalidate them before
admission. The Conversation store owns Profile persistence and revision updates.

## Trade-off

Keeping Profile intent per Membership gives each Agent a durable
conversation-scoped configuration without copying changing catalog facts into a
second authority. Keeping it endpoint-local prevents station state or native
Agent sessions from becoming the owner of user configuration.

The implemented Assistant designation and Profile use are defined by
[ADR 0004](0004-assistant-authored-flexible-workflows.md). Detailed fields,
limits, persistence, snapshots, and admission behavior remain owned by source
and tests.
