# Product

## Product Boundary

Lico Arc is a local-first, open-source desktop and mobile client for discovering,
operating, and securely reaching a user's own agents. The client does not depend
on a LicoLite installation for its default product experience.

The built-in foundation is limited to:

- a lightweight Rust task queue for bounded local work;
- an ACP adapter for local agent execution and encrypted remote relay;
- an MCP adapter for client-originated requests and response forwarding;
- platform adapters for macOS, Windows, Ubuntu, Android, and iOS.

## Product Scenarios

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
6. Desktop-and-mobile end-to-end encrypted communication and mobile relay. Relay
   infrastructure can route only opaque envelopes and cannot decrypt payloads.

## Optional LicoLite Collaboration

LicoLite collaboration is not bundled into the default navigation or startup
path. It becomes available only after the user explicitly enables the capability
and installs its plugin from a user-selected GitHub source.

The optional plugin may provide two workflows:

- download LicoLite for a user-controlled local deployment and let the user
  select the server feature/plugin set before installation;
- manually install selected LicoLite MCP plugins into one or more selected local
  agents.

Neither workflow runs automatically. An MCP plugin operation involving a local
file requires a separate user approval for that exact file transfer.

## External Data Approval Contract

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

## Readiness

Every agent adapter is accepted independently. A detected or history-readable
agent is not automatically a conversation-capable agent. Only adapters that pass
the canonical native-conversation parity contract may enable the normal composer.
The current reducer summary is `0 ready / 0 failed / 2 blocked / 9 unverified`.

Development, ordinary verification, packaging, GitHub Release publication, and
platform-store publication are separate claims. Public artifacts disclose only
minimum consumer-verification metadata and never include user or client runtime
information.
