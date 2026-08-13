# LicoUp

LicoUp defines the language of a human-agent conversation client whose
endpoints retain control of protected content, trust, and local effects.

## Language

**User**:
The person who controls a LicoUp endpoint and authorizes trust, disclosure, and
local or external effects.
_Avoid_: account owner, tenant

**Agent**:
A software participant that can join or serve a Conversation through an
explicitly admitted interface.
_Avoid_: provider, hidden bot

**Endpoint**:
A client-controlled participant that holds identity and keys, executes a
pinned Lico Arc Protocol Line, and owns protected content, local approval, and
endpoint evidence.
_Avoid_: station account, relay client

**Conversation**:
The durable interaction context in which visible human and Agent participants
exchange authorized events. One-to-one and group chat are the same model; only
the admitted Membership set differs.
_Avoid_: provider thread, transport session

**Membership**:
One Human or Agent Principal's explicit participation, access, and lifecycle in
one Conversation.
_Avoid_: hidden runtime, implicit role

**Conversation Role**:
A named collaboration responsibility inside one Conversation, with an ordered
pool of eligible Agent Memberships and optional runtime preferences.
_Avoid_: hard-coded worker lane, global agent type

**Adaptive Flywheel**:
An ordered sequence of Conversation Roles resolved at run start from immutable
role and candidate snapshots. It has no built-in team topology.
_Avoid_: fixed workflow, global orchestration preset

**Local Agent Target**:
An Agent reached through a user-controlled local or explicitly configured
runtime interface.
_Avoid_: federated peer, hosted service

**Peer Endpoint**:
Another Endpoint selected as the recipient of an endpoint-protected transfer.
_Avoid_: station, gateway

**Endpoint Admission**:
The User's decision that an Endpoint, Agent, or local capability may
participate within the client boundary.
_Avoid_: federation membership, station compatibility

**Protected Transfer**:
Content protected for a named Peer Endpoint through conforming execution of a
pinned Lico Arc Protocol Line before it leaves the sender's endpoint boundary.
_Avoid_: HTTPS request, station message

**Station**:
An independently operated opaque-carriage service that every Endpoint assumes
may be malicious.
_Avoid_: trusted backend, peer endpoint

**Station Adapter**:
The client-owned boundary that submits and retrieves opaque Lico Arc envelopes
through one named station-facing contract and treats every station response as
untrusted input.
_Avoid_: translation gateway, station SDK

**Pinned Protocol Line**:
The exact versioned Lico Arc Protocol Line selected for conforming execution,
support, and interoperability verification.
_Avoid_: client-specific protocol, station product version

**Wire-Observable Protocol**:
The Lico Arc-owned Pairwise Protection, Generic Message, Reliable Exchange,
negotiation, and Transport Profile semantics that independent implementations
must match at the protocol boundary.
_Avoid_: client implementation detail, local custody policy

**Endpoint-Local Security State**:
Private keys, local Provider configuration, plaintext, conversation history,
backups, user trust, approvals, and local effects retained and controlled by
LicoUp.
_Avoid_: wire profile, station policy

**Station Signal**:
A station-provided receipt, lease, timestamp, queue state, acknowledgement, or
delivery claim that is only an operational hint.
_Avoid_: endpoint evidence, final receipt

**Official Network**:
A replaceable convenience entry operated under the same protocol and trust
rules as any compatible network.
_Avoid_: privileged trust root, mandatory backend

**External Operation**:
A user-approved action that discloses exact content to a named external
destination or produces an external effect.
_Avoid_: plugin permission, background authorization

**Gateway Runtime**:
The single local process that hosts the LLM Gateway layer and the Communication
Channel layer.
_Avoid_: separate Telegram gateway, dual sidecars for the same runtime

**LLM Gateway**:
The lower Gateway Runtime layer: loopback HTTP model-protocol routing and
credential handoff to upstream providers.
_Avoid_: messaging channel, Bot API poller

**Communication Channel**:
An upper Gateway Runtime messaging adapter that admits an external chat surface
into local Agent conversations. Telegram is the first channel.
_Avoid_: Lico Arc peer, independent Telegram gateway product

**Telegram channel**:
The Telegram Bot API Communication Channel inside the Gateway Runtime (paired
DMs, slash commands, conversation-lane bridge).
_Avoid_: Telegram Gateway, OpenClaw channel clone claim, Flutter long-poller

**Planning Metric**:
A snapshot-derived model price, capability, or value ratio used to predict and
plan model selection without reading current token usage or representing a
current bill.
_Avoid_: usage measurement, live charge, billing receipt

**Planning Ranking**:
An ordered set of Agent, Model, and Thinking options evaluated through one
comparable measurement path without exposing an internal value score.
_Avoid_: mixed-source score list, normalized-score API
