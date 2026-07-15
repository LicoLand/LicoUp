# Product

## Register

product

## Users

Lico Arc is for personal mobile users who want to control the agents running on their own computers from an Android or iOS phone. They are usually holding the phone as an operation surface while the computer stays online elsewhere.

## Product Purpose

The product pairs a phone with a trusted desktop client through the relay backend, then presents the desktop's available agents as direct conversation targets. Success means a user can pair once, see the paired computer, choose an agent, and talk to it without managing relay internals, JSON payloads, runtimes, snapshots, or manual target creation.

## Brand Personality

Quiet, capable, direct. The interface should feel like a dependable mobile control app: familiar, compact, and focused on the conversation.

## Anti-references

Avoid technical control panels, repeated add buttons, exposed protocol details, JSON pairing, pull-and-start relay controls, mobile runtime management, activity snapshot dashboards, decorative robot icons, and bottom navigation that competes with the chat composer.

## Design Principles

- Conversation first: the main screen is for choosing an agent and talking to it.
- Progressive process disclosure: consecutive native-agent activity appears as one quiet, collapsed process item; activating it expands flat, safe operation summaries in place instead of creating a stack of technical cards or hiding the item. A second activation collapses the same item.
- Pairing is an entry action, not a permanent destination.
- Keep infrastructure invisible unless the user needs to fix something.
- Use standard mobile affordances for scan, paste token, refresh, send, and settings. Voice input is deferred and not part of the current product contract.
- Show device and agent state with small, readable status cues rather than persistent technical logs.
- Native-agent fidelity: every agent exposed as a conversation target must preserve the native agent's thread identity, effective settings, observable effects, errors, and rendered conversation. Detection or history import alone is not conversation support, and an adapter without release A/B evidence must not be presented as a best-effort chat target.
- Privacy-preserving detail: only provider-designated reasoning summaries and sanitized operation results may be disclosed. Raw chain-of-thought, tool arguments, metadata, credentials, session ids, and local paths remain hidden even when a process item is expanded.

## Service Readiness

Encrypted communication is a native Lico Arc capability. The authority for the Lico Arc custom end-to-end encryption protocol (Secure Client Mesh) is in this repository and does not depend on a relay or gateway server implementation; relays only carry opaque envelopes. Client release readiness is reduced only from client-owned protocol, cryptographic, platform, and exact-artifact evidence. Public gateway availability, server capacity, and server policy are accepted by the server release workflow and are not imported into this repository or used as client release gates. Client verification may use a protocol-conformant opaque relay peer without depending on the server implementation.

Source development and GitHub Release readiness are independent from platform
publisher identity and store-channel readiness. Production credentials,
notarization, store submission, store download, and store update or rollback
continuity affect only the named platform/store distribution claim. Their
absence is disclosed as `not ready for that platform/store`; it does not block
development, ordinary builds, client functionality, or an otherwise accepted
GitHub Release. Public artifacts carry only minimum consumer-verification
metadata: artifact identity, target/version, digest, signature or attestation,
and the public verification material required to validate it. No publisher
account, team/store identifier, stable certificate identity, credential,
private-key, custody, or private-channel metadata is part of the open-source
contract.

Native-agent conversation readiness is evaluated independently for every packaged target adapter. Only adapters that pass the canonical native-conversation parity contract may enable the normal message composer in a release build. Partial, blocked, failed, history-only, and unverified adapters remain explicitly labeled and do not count as supported. A client release may support any verified subset; full-inventory parity is a separate adapter-completeness goal, not a packaging prerequisite.

The canonical packaged set is Antigravity, Claude Code, Codex, Cursor, Copilot, Hermes, Kilo Code, Kimi Code, OpenClaw, OpenCode, and Pi. Conversation parity means that both directions—native creates then Arc resumes, and Arc creates then native resumes—preserve the real native session id, cwd and effective settings, ordered results and effects, safe event/tool/reasoning projection, errors, privacy boundaries, and cleanup. An adapter must pass three consecutive paired runs through the current release UI path, with every run covering both directions, before it can become `ready`.

The canonical driver inventory is projected from the desktop packaging registry. Sanitized live evidence is stored separately and reduced into the checked-in readiness resource; driver existence, capability probing, a local core-text run, and deterministic fake-child E2E are prerequisites only. They never establish live native parity by themselves. The current reducer-owned state is `0 ready / 0 failed / 2 blocked / 9 unverified`, so the release composer and `runtime.message.send` capability remain fail closed for all eleven packaged adapters while unrelated client packaging remains independently decidable. Only reducer-owned evidence may change this state.

## Accessibility & Inclusion

Target WCAG AA contrast, clear focus states, 44 px minimum touch targets, reduced-motion-safe transitions, and color-independent state labels for online, offline, pairing, ready, blocked, unverified, and error states.
