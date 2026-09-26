# Conversation projection and settlement

Updated: 2026-09-25

[Conversation owner](CONVERSATION-DOMAIN.md) · [Presentation guide](../modules/presentation.md)

## Ownership

| Responsibility | Owner |
| --- | --- |
| Native wire interpretation | Protocol adapter |
| Durable conversation and membership | Conversation repository |
| Session/process execution | Agent runtime and native host |
| Lifecycle settlement | Conversation lifecycle authority consuming execution evidence |
| Snapshot and delta projection | Native projection owner |
| Display preparation and rendering | Presentation runtime and Flutter renderer |

Keep high-frequency streaming on the observation path. Receiving text does not
settle a turn, and losing a view does not cancel it. A single owner interprets the
execution evidence; transport, UI and competing listeners must not each synthesize
a different terminal result.

## Projection contract

Snapshots and ordered deltas describe the same conversation. Partition by canonical
conversation and membership identity; retain event identity through paging, streaming
and recovery. Refresh from a consistent snapshot when a projection needs recovery.
Flutter renders the resulting state and preserves view-local interaction context;
it does not manufacture business completion or substitute native session identifiers.

Keep preparation off the render path, reuse unchanged resources, and bound caches by
owned resources. Rendering preserves the Agent's natural output, tool activity and
artifacts; it cannot require a project-specific reply format.

## Control and settlement

Admit user controls through the owning use case. Distinguish a received command from
its observed effect. Native steer, safe-boundary follow-up, cancellation and recovery
must truthfully reflect the actual runtime capability and exact execution binding.
Do not fabricate successful intervention or silently substitute a different session.

The [state configuration](../../crates/licoup-conversation/resources/state-machines.json)
owns transition data. Public DTO schemas and executable tests own fields and behavior;
this document deliberately carries no parallel enum, transition table or sample
implementation. Verification commands are in the module guides.
