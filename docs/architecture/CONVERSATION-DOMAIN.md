# Canonical Conversation

Updated: 2026-09-26

[简体中文](CONVERSATION-DOMAIN.zh-CN.md) · [Module guide](../modules/conversation.md)

Canonical Conversation owns durable identities, memberships, events, turns and
continuity history. Native Agent sessions are private execution bindings, not public
conversation identities. The native host supplies platform effects and runtime ports;
the independent conversation crate owns durable records and transactional invariants.

One owner commits each lifecycle decision. Adapters report observed protocol signals;
workflow scheduling and Flutter projections consume those facts. They do not infer
completion from a quiet stream, a lost observer or an elapsed observation window.
Concurrency is constrained by the admitted runtime and membership, not a global UI
busy flag.

## Local conversation

The normal conversation surface selects a local Agent and creates a durable
conversation when the first input is submitted. Streamed replies must become
visible before terminal settlement. Continuation reuses the recorded native session
binding and canonical membership. Explicit stop applies to the active turn; later
input can start another turn in the same conversation. Reopening the client retains
history and its conversation identity. Synthetic checks cover the production
composition and persistence boundaries; live adapter acceptance remains separate.

## Persistence and visibility

Commit related durable updates together. Publish observation after durable state
changes, so recovery and the visible conversation cannot claim different outcomes.
Keep paging and filtering at the owning repository. Revoked sources and private held
inputs must not leak into human-visible events or another conversation.

Conversation operations preserve third-party Agent history. Product archive/reset
and native-session continuation are distinct operations; do not rewrite external
history to make a local projection appear consistent. Peer ingress preserves source
identity, provenance and conversation/membership scope.

## State and projection

The [transition configuration](../../crates/licoup-conversation/resources/state-machines.json)
is read during the crate build into immutable lookup tables. A local executor applies
those tables; changing the configuration requires rebuilding. This keeps transitions
constant-time without a second handwritten table or per-event parsing.

Invalid transitions leave state unchanged; terminal states are absorbing. Persistent
compare-and-set guards enforce commit ownership, rather than redefining transitions.
Tests in the module guide exercise lifecycle, storage and recovery.

## Local execution inspection

`agent.conversation.execution` observes one exact conversation, membership and
dispatch handle. Retained records preserve provenance and ordering; missing historic
payloads stay missing. Observation never steers, cancels or settles execution.
This local inspection stream is not an MCP capability or a public export: it can
contain private runtime content. Keep the ordinary transcript and external-transfer
boundaries intact, and expose only immutable projections to frontend widgets.

[Projection and settlement](CONVERSATION-VERTICAL-CONTRACT.md) explains the boundary
between native evidence and visible state. [Continuity](CONTINUOUS-ASSISTANT.md) covers
durable Assistant work; [workflow control](ASSISTANT-WORKFLOW-CONTROL.md) covers execution.
