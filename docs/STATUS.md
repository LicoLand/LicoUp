# LicoUp Status

English (normative) · [简体中文](STATUS.zh-CN.md) ·
[Documentation](README.md) · [Product](../PRODUCT.md)

This document is the authority for current LicoUp intent, implementation,
verification, release, support, and hosted-operation status. Repository
vocabulary is defined in [`CONTEXT.md`](../CONTEXT.md). Generated platform and
adapter support details remain authoritative in
[`COMPATIBILITY.md`](COMPATIBILITY.md).

## Intent

| Scope | Status | Meaning |
| --- | --- | --- |
| Human-agent secure conversation | approved destination | People and visible agents share one endpoint-controlled conversation experience. |
| Local-agent client | current first stage | The currently evidenced product stage focuses on local and explicitly configured agent conversations. |
| Provider-managed trusted history and history recovery | approved destination | Provider-managed cloud history is readable by default after provider authorization; client-side encryption is explicit opt-in, recovery covers retained available objects, and identity recovery remains separate. |
| Human messaging, federation, identity recovery, and multi-device continuity | planned | These remain product intent until independently implemented and verified. |
| Lico Arc endpoint Protocol Line | required future boundary | Stable wire-observable Pairwise Protection, Generic Message, Reliable Exchange, negotiation, and Transport Profile belong to a named Lico Arc Protocol Line. No Published Protocol Line is currently supported. |
| Lico Arc station-facing protocol | current candidate boundary | Lico Arc Protocol is the sole station-facing outer protocol; the active `devices` module connects through `licoarc-client` (`MailboxClient`) over the candidate `licoarc.mailbox.v1` subprotocol (`BadTower.js` candidate station). |
| Official network | planned convenience | It may become a replaceable default only after separate release and operation evidence exists. It receives no trust privilege. |

## Implementation

| Capability | Status | Current source boundary |
| --- | --- | --- |
| Local-agent discovery and conversation | implemented in source | Desktop and native client code contains local and explicitly configured agent adapters and conversation flows. |
| Canonical Conversation backend | implemented in source | Rust owns one indexed SQLite/WAL authority for one-to-one and group Conversations, peer Human/Agent Memberships, the explicit Assistant designation, revisioned per-Membership Profile intent, structured Events/Parts, topology-neutral immutable Graph snapshots, and private runtime bindings. Generated Rust/Dart contracts and the group Conversation UI project the same closed facts. Archiving a group Conversation cascades in one transaction to its whole Continuity child subtree and marks every member native session the group involved as archived, so browse catalogs stop surfacing them while the agents' own on-disk history is never deleted; with `reopen` the same transaction creates a fresh successor Conversation — same title, members, and Assistant profile, copied silently without member-churn events — and opens it with one plain `conversation-reset` notice, while the retired native transports are disconnected off the response path. The reserved default local group is the one exception: it can never stay archived, so an archive request resets it in place — children and member native sessions archived the same way, visible Event history cleared with the same in-flight refusal as `conversation.clear`, Assistant membership rotated, and one `conversation-reset` notice reopening the same active, pinned Conversation — so no successor or duplicate ever survives. `conversation.clear` remains for emptying one group's Event history in place; an in-flight turn or unfinalized Event refuses the write. |
| Assistant workflow and Subagent MCP | implemented in source | [Assistant workflows](functionality/USER-GUIDE.md) use the native CLI. The independent [Subagent MCP adapter](protocols/subagent-mcp.md) exposes the five subagent operations via the generic local MCP entrypoint (`licoup mcp stdio`) and optional `org.licoland.feature.mcp` service; `LicoUp-Plugins` (`codex-plugin`) is retired. The persistent Conversation host remains the run, turn, and transcript owner. |
| Pure workflow compiler and machine | implemented in source; targeted tests passed | `licoup-workflow` owns the existing definition, diagnostics, immutable compiler indexes and pure transition machine. Native import, preflight and execution consume it. Historical routing conversion stays at the data/package boundary with identity-preservation tests. Queue control, plan caching, successor handoff and distributed-binary verification remain pending; see [Workflow control](architecture/ASSISTANT-WORKFLOW-CONTROL.md). |
| Assistant adaptation and target loading | implemented in source, release evidence unverified | Group Automatic adaptation addresses the designated Assistant through the same Membership-scoped native lane as one-to-one chat. Acativa roles and Assistant model catalogs use one selected-target Rust batch with bounded discovery concurrency. DeepSeek Harness is packaged through its official SDK JSON-RPC carrier with only its declared native capabilities; readiness remains unverified. |
| Gateway Runtime (LLM + Communication Channel) | implemented in source | Single `licoup` process (`gateway run`) hosts the LLM Gateway loopback layer and the Telegram Communication Channel (paired DMs, `/agent` `/session`, conversation lane). Verified readiness changes use partial hot-reload via `gateway inventory reload` / `inventory.sock` (new ready agents admitted; bindings/sessions preserved; no process restart). `gateway` CLI drives lifecycle. DM-only channel; not verified against a live BotFather bot in release evidence. |
| Skill, local-agent history, backup, and usage surfaces | implemented in source | Local client modules exist for these first-stage workflows. |
| Trusted history and recovery core | tested provider-neutral core | The core covers provider authorization, the default-readable history path without a recovery-key call, explicit client-encryption opt-in, recovery of all retained available objects, unavailable-object handling, Station exclusion, and separation from identity recovery. Cloud login, vendor adapter, live sync, and UI wiring are not present. |
| Complete Lico Arc endpoint Protocol Line | not implemented | LicoUp currently has no Lico Arc-owned Pairwise Protection, Generic Message, Reliable Exchange, negotiation, or Transport Profile to execute. The candidate outer-envelope adapter below is not that complete endpoint line. |
| Endpoint protection | retired | The former client-specific `licomesh.*` Secure Client Mesh preview is removed. Devices sessions execute on the client-owned `licoarc-client` protocol line for pairing, authenticated encryption, freshness and replay handling. |
| Devices | implemented in source | The native `devices` domain owns desktop-to-desktop device enroll, pairing, session custody, and message exchange over `licoarc-client` (`MailboxClient` / `licoarc.mailbox.v1`) with `BadTower.js` as the active candidate station; the Desktop `devices` feature owns the client surface. |
| Lico Arc outer envelope | superseded in active `devices` | The earlier client-owned `licoarc.relay.v1` five-field adapter is superseded in the active `devices` runtime by `licoarc-client` over `licoarc.mailbox.v1`. |
| Station transport | implemented in source | The active `devices` module connects through `licoarc-client` to an explicitly configured `BadTower.js` (`licoarc.mailbox.v1`) candidate station. Its responses are transport hints rather than endpoint evidence. |
| Retired client-specific station API | removed | The former client-specific station envelope/API, `/api/secure-mesh/v1` routes, service-session scopes, configuration, fixtures, and compatibility surface are not retained. |
| BadTower candidate interoperability | locally verified (earlier candidate); active `BadTower.js` candidate unverified for release | An earlier bounded two-fresh-endpoint scenario passed against a BadTower candidate; the active `devices` module targets `BadTower.js` (`licoarc.mailbox.v1`) as a candidate station. Neither establishes a product release, stable support claim, or hosted operation. |
| Official network default | not configured | The client has no current default official-network station entry. |
| Continuous Assistant | implemented in source; real-model qualification unknown | Ordinary chat stays on the parent Canonical Conversation. Admitted durable work uses one child Conversation plus one parent timeline card at the creating Event sequence; parent-card executor badges are absent. A host-private persisted adoption policy (`offline` → `admitted_shadow` → `qualified_low_risk` → `expanded`) lives in the existing continuity schema. The real owner can enable or disable it through the trusted conversation use-case; disable blocks new automatic interpretation and dispatch but keeps Goals, history, active obligations, unknown effects, and manual recovery. Live evidence requires a stored owner-admitted evaluation session bound to an owner-admitted versioned corpus. The host producer iterates that corpus, invokes the bound admitted PersistentTurn on unlabeled case input, grades typed outputs against private expected actions, and binds collection receipts to the whole observation. The session and candidate `datasetVersion` carry the dataset id and the actual corpus digest. Missing, empty, or version-mismatched corpus fails before any native call. The collection claim becomes Unknown immediately before the first native invocation: pre-invoke failures stay NotExecuted and retryable; post-invoke failure keeps Unknown (not proof of no execution) and retry returns reconciliation. An owner re-admits a new session to reconcile; the existing evidence identity still blocks a second commit. An unbound runtime stays unavailable, and a hermetic observer is test-only. Recipe-generated scores are not production collection. Reload revalidates session, owner, collection receipts, and revocation. Archive or owner loss denies the next automatic admission in the same process. `expanded` is distinct qualified responsibilities, not raw stored-row count; synthetic imports do not count as admitted. TestEvidence cannot promote real-model qualification. Offline and admitted-shadow stages do not auto-dispatch even when adoption is enabled. Source delivery is complete for this mechanism; live or paid model qualification remains unknown. This is not a release claim and not mobile always-on. |

Implementation in source does not establish verification, release, support, or
hosted operation.

## Verification

- The generated compatibility matrix is the current platform and adapter
  support projection.
- The trusted history and recovery core is tested in a provider-neutral
  harness. Its default-readable path does not call a recovery key. It has no
  cloud login, vendor adapter, live sync, or UI wiring, so those integrations
  have no current verification claim. Identity preparation and atomic commit
  are exercised through a strict synthetic caller-owned port; no LicoArc SDK
  or runtime identity-recovery adapter is wired.
- Devices peer sessions carry no physical-device, biometric,
  hardware-custody, or released-platform evidence; the matrix does not claim
  them.
- The candidate outer-envelope acceptance does not promote Devices sessions
  into a stable compatibility surface.
- The current generated adapter matrix (`tools/agent-conversation-readiness.json`,
  projected in `COMPATIBILITY.md`) reports `0/13` adapters verified: all 13
  packaged adapters are currently `unverified` with send disabled
  (`sendEnabled: false`), even where adapter implementations are present in
  source, until real CLI verification proof is recorded. Exact current rows
  remain owned by `COMPATIBILITY.md`.
- A bounded real-station acceptance used two freshly initialized endpoints
  with separate client state, the candidate Lico Arc bundle, and an actual
  BadTower process. It verified a protected command and authenticated result
  round trip, exact five-field envelopes, absence of endpoint plaintext from
  station-visible storage, rejection of non-conformant envelopes, and the
  non-authoritative meaning of station hints.
- The acceptance proves only the named local candidate and scenario. It does
  not publish Lico Arc Protocol, release LicoUp or BadTower, establish platform
  support, or prove a hosted network is operating.

## Release

| Dimension or channel | Status |
| --- | --- |
| Product version metadata | `0.3.0` (build 3), owned by `tools/client-version.json` |
| Next governed release | `0.3.0`, unreleased delivery candidate; its `CHANGELOG.md` entry is unreleased |
| Archived release history | `CHANGELOG.md` records the unreleased `0.3.0` entry above published entries; `git tag -l` lists `v0.1.0`, `v0.1.1`, `v0.1.2`, `v0.2.0`, and `v0.2.1`; the last published release is `v0.2.1` (2026-09-11) |
| GitHub Release publication | `v0.2.1` (2026-09-11); no `v0.3.0` tag exists |
| Platform-store publication | not claimed |

The `0.3.0` version metadata and its CHANGELOG entry record the planned next
release, not a publication. A build target or GitHub Release eligibility
flag is not publication. Each platform build, physical/device verification,
GitHub Release, and store channel is an independent claim.

## Support

- Platform and adapter support is limited to the exact generated rows in
  `COMPATIBILITY.md` (currently `macos-arm64` client `supported` and `devices`
  `preview`, other available desktop build targets `preview`, and
  `windows-arm64` `unverified`; `0/13` agent adapters verified).
- `supported` means the named current checks accept that target; it does not
  mean distribution or store readiness.
- `preview` means the capability is changing and is not a stable
  interoperability claim.
- The Lico Arc Station Adapter and BadTower transport are locally verified
  candidate capabilities, not a stable support or distribution declaration.
- The retired Secure Client Mesh endpoint profile was never a Published
  Protocol Line; no support claim survives its removal.
- Provider-managed history has no current cloud-provider support claim beyond
  the provider-neutral core. History recovery does not bypass provider access
  or recreate unavailable objects, and it makes no mandatory notary or
  endpoint-evidence promise.
- No current support claim exists for a Published Lico Arc Protocol Line, a
  released BadTower station, or an official network.

## Operation

No official LicoUp network is configured or claimed as currently operating.
Static sites, DNS, source code, and an empty or configurable `stationBaseUrl`
field do not establish operation.

## Station-transport closure

The current implementation is one direct client-owned path:

1. the Devices endpoint session on `licoarc-client` creates and verifies the
   protected payload;
2. `licoarc-client` (`MailboxClient`) communicates over the candidate
   `licoarc.mailbox.v1` subprotocol against an explicitly configured
   `BadTower.js` candidate station;
3. the station performs only opaque mailbox transport operations, whose
   responses remain untrusted hints; and
4. acknowledgment and settlement occur only after endpoint authentication,
   decryption, freshness, and replay checks succeed.

The retired client-specific station surface and the `licomesh.*` endpoint
preview were removed in the same migration. There is no permanent dual-wire
mode or station translation gateway.
