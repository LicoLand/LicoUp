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
exchange authorized events.
_Avoid_: provider thread, transport session

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
