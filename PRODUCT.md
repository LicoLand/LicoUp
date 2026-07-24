# Product

English (normative) · [简体中文（本地化）](PRODUCT.zh-CN.md)

## Product North Star

LicoUp is intended to become an open-source, local-first interactive
ecosystem in which people, agents, service providers, and independent trust
parties interact under one governed trust fabric. The destination is neither a
social messaging product nor an agent marketplace: it is a durable, verifiable
interaction fabric for human and agent principals, entered through one secure
conversation experience. People, local agents, remote agents, and approved
service-backed agents meet in that conversation experience instead of separate
chat products. Infrastructure, provider selection, cryptography, and execution
details remain inspectable without becoming the primary navigation.

Platform adaptation is a release target, not a product capability gate.
Ecosystem capabilities are designed once, platform-neutrally; macOS, Windows,
Linux, Android, and iOS then adapt, verify, and publish through independent
per-platform release lanes. A capability becomes release-eligible on a platform
as soon as that platform's own physical evidence exists, without waiting for
the remaining platforms.

This section records the approved destination. It does not claim that every
capability is available today. The [compatibility matrix](docs/COMPATIBILITY.md)
and the current boundary below remain the authority for implemented and
verified support.

### Project family

Three independently maintained projects carry the ecosystem. LicoUp is the
client and remains the authority for keys, plaintext, and local effects.
LicoTower is the federation pillar: independently built and released relay
infrastructure that routes only opaque envelopes, coordinates bounded
service-side delivery, and holds no client cryptographic or trust authority.
LicoMesh is the optional platform pillar, owning the Provider Trust Kernel,
Operation Permission, and the plugin host; the default client experience never
depends on it.

### One conversation model

The long-term model has stable principals, endpoints, conversations,
memberships, and signed conversation events:

- Human direct messages and groups use the same encrypted, multi-device
  history. Signed handles and invitations support message requests, explicit
  group-history visibility, membership administration, replies, edits,
  retractions, reactions, threads, files, media, receipts, and notifications.
- The default `@Agent` interaction creates an on-demand Operation. Only the
  explicit question and user-selected context are disclosed. Its result enters
  the timeline as a caller-authorized `via Agent` event. Any external side
  effect remains a separate Operation and requires its own approval.
- An agent may instead join as a visible, revocable group member. Its history
  access follows the invitation policy. Its wake mode, budget, model provider,
  region, retention policy, and sponsor are disclosed so that continuous
  participation is an informed choice rather than a hidden background cost.
- Search is built after local decryption from a rebuildable encrypted-at-rest
  index. The service is never given plaintext merely to provide search.

The interaction model borrows the useful invitation, permission, message
request, and explicit bot-participation ideas of modern messaging products. It
does not inherit their server-readable trust model.

### Two-layer authority

Conversation durability uses two complementary authorities:

- The selected service provider is authoritative only for accepted ciphertext
  entries, their order, synchronization cursors, retention or deletion state,
  and verifiable receipts.
- LicoUp is authoritative for keys, decryption, plaintext meaning, authorship
  verification, and the user's local projection.

The client encrypts every event before egress. Each event has a separate
content-encryption key protected by the conversation key schedule, so selective
disclosure can reveal one event, its author proof, and its ledger-inclusion
proof without revealing a conversation epoch key.

An event is shown as sent only after ciphertext is durably stored in two
independent provider failure domains and a fixed Lico notary committee has
issued a majority receipt. Until then it remains in a durable local outbox.
Quota exhaustion blocks new uploads instead of silently evicting history.
Deletion uses a signed tombstone, a short recovery window, ciphertext
purging, and only irreversible integrity and audit facts afterward.

This division provides verifiable cloud history and recovery while preventing
the provider from reading user content. A regulator or other reviewer can
receive a user-created selective disclosure bundle, but cannot obtain plaintext
from the provider without the user's key material.

Recovery uses two of three independent factor classes: a user recovery secret,
a still-trusted device, and a guardian factor formed by any two of at least
three appointed guardians. An account service may authenticate a download of an
encrypted recovery capsule; it never receives the capability to decrypt it.

### Provider trust and federation

The client does not decide that a provider is trustworthy merely because an
endpoint is reachable. LicoMesh Core owns a general Provider Trust Kernel;
communication is its first profile. LicoUp consumes a signed, versioned,
expiry-aware directory, applies local admission policy, and displays the
resulting trust state.

Third-party providers progress through control of their domain and root key,
synthetic-data sandboxing, an open conformance suite, organization review, and
independent higher-assurance Trust Marks. Continuous probes can renew, degrade,
make read-only, or revoke a deployment. Appeals do not automatically restore
production eligibility. Public directory entries expose only the minimum
identity, revision, profile, issuer, evidence-digest, validity, and status
facts; raw operational and audit material remains controlled.

The Lico official provider principal is an explicit privileged disaster-
recovery trust root and is exempt from third-party admission and Trust Mark
revocation. Its deployments, keys, nodes, and routes are still versioned,
rotatable, and health-gated. A failed official deployment stops receiving
traffic even though the built-in disaster-recovery identity remains.

Provider servers own their internal high availability and leader election.
The Lico notary committee confirms durable ledger checkpoints; it does not run
the provider's storage cluster or elect its leader. If a provider root is
compromised, migration starts from the last pre-revocation notarized checkpoint
and does not require the compromised provider to approve recovery.

### Delivery order

The existing client foundation is completed before the unified communication
portfolio becomes release-eligible: agent orchestration, workspace convergence,
adapter plugin management, the one-time project refactor, exact incremental
usage accounting, and bounded resource discipline close first. Communication
then proceeds through identity and encryption, provider-trust consumption,
ciphertext-ledger synchronization, human messaging, agent participation, and
recovery and selective disclosure. Platform acceptance then runs as five
independent per-platform release lanes: each platform proves the same frozen
corpus on its own physical evidence and publishes independently, so one
platform's release never waits for another's lane.

Real accounts, external authorization, production services, signing identities,
and physical devices are release evidence, not facts that can be inferred from
simulators or synthetic tests.

## Current Product Boundary

LicoUp is a local-first, open-source desktop and mobile client for discovering,
operating, and securely reaching a user's own agents. The client does not depend
on a LicoMesh installation for its default product experience.

The built-in foundation is limited to:

- a lightweight Rust task queue for bounded local work;
- an ACP adapter for local agent execution and encrypted remote relay;
- an MCP adapter for client-originated requests and response forwarding;
- platform adapters for macOS, Windows, Ubuntu, Android, and iOS.

## Current Product Scenarios

The default product exposes only these scenarios:

1. Concurrent desktop discovery of local agents from application registries,
   package managers, executable search locations, and other platform-owned
   locations, followed by a local cache registration.
2. Desktop conversations with local agents, including new conversations and
   exact continuation through an official native interface where available.
   When mid-turn injection is unavailable, the client may stream the active turn
   and start the next turn only after the native reply completes.
3. Desktop skill management across one or more agents: list, install, update from
   an explicitly configured mirror or GitHub repository, delete, and aggregate
   usage counts by time window.
4. Desktop conversation management: browse native conversations and back up all
   or keyword-selected conversations to a user-selected local directory.
5. Desktop token-usage reporting by agent or model, defaulting to the latest
   thirty days with a selectable time window.
6. Desktop-and-mobile end-to-end encrypted communication and mobile relay over
   the independently maintained LicoTower relay infrastructure, which can route
   only opaque envelopes and cannot decrypt payloads.

## Current Optional LicoMesh Collaboration

LicoMesh collaboration is not bundled into the default navigation or startup
path. It becomes available only after the user explicitly enables the capability
and installs its plugin from a user-selected GitHub source.

The optional plugin may provide two workflows:

- download LicoMesh for a user-controlled local deployment and let the user
  select the server feature/plugin set before installation;
- manually install selected LicoMesh MCP plugins into one or more selected local
  agents.

Neither workflow runs automatically. An MCP plugin operation involving a local
file requires a separate user approval for that exact file transfer.

## Current External Data Approval Contract

Local files, conversation content, configuration, diagnostics, paths, device
facts, agent history, and usage records stay local by default. Every operation
that transfers user or client information outside the current device must:

1. be initiated or directly approved by the user for that single operation;
2. show the destination, purpose, exact data or file scope, and affected agents;
3. remain cancellable until the external transfer is committed;
4. invalidate approval when the destination, scope, digest, or operation changes;
5. fail closed when approval is absent, expired, cancelled, or unverifiable.

Approval is never inferred from startup, a prior operation, a plugin being
enabled, an agent request, or a background schedule. A user pressing Send for an
explicitly addressed encrypted message authorizes only that message and target.

## Experience Principles

- Conversation first; infrastructure stays out of the primary navigation.
- Discovery is concurrent, bounded, cache-backed, and locally observable.
- Native-agent fidelity is required for every enabled conversation adapter.
- Provider process events are rendered as safe summaries; raw reasoning, tool
  arguments, credentials, native identifiers, and local paths stay hidden.
- Platform-owned biometrics and secure stores protect credentials and key
  material; the app never collects the system password itself.
- Accessibility targets WCAG AA contrast, clear focus, reduced-motion-safe
  transitions, and 44 px minimum touch targets.

## Current Readiness

Every agent adapter is accepted independently. A detected or history-readable
agent is not automatically a conversation-capable agent. Only adapters that pass
the canonical native-conversation parity contract may enable the normal
composer. Current platform and adapter projections are generated in
[`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) from the owning catalogs.

Development, ordinary verification, packaging, GitHub Release publication, and
platform-store publication are separate claims. Public artifacts disclose only
minimum consumer-verification metadata and never include user or client runtime
information.
