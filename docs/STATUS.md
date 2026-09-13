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
| Lico Arc station-facing protocol | current candidate boundary | Lico Arc Protocol is the sole station-facing outer protocol; the current adapter pins the candidate `licoarc.relay.v1` line. |
| Official network | planned convenience | It may become a replaceable default only after separate release and operation evidence exists. It receives no trust privilege. |

## Implementation

| Capability | Status | Current source boundary |
| --- | --- | --- |
| Local-agent discovery and conversation | implemented in source | Desktop and native client code contains local and explicitly configured agent adapters and conversation flows. |
| Canonical Conversation backend | implemented in source | Rust owns one indexed SQLite/WAL authority for one-to-one and group Conversations, peer Human/Agent Memberships, the explicit Assistant designation, revisioned per-Membership Profile intent, structured Events/Parts, topology-neutral immutable Graph snapshots, and private runtime bindings. Generated Rust/Dart contracts and the group Conversation UI project the same closed facts. `conversation.clear` empties one group's Event history, archives intact Continuity children, and inserts a new Assistant Membership so later turns start a new native session; an in-flight turn or unfinalized Event refuses the write. |
| Assistant workflow and Subagent MCP | implemented in source | [Assistant workflows](functionality/USER-GUIDE.md) use the native CLI. The independent [Subagent MCP adapter](protocols/subagent-mcp.md) exposes the five subagent operations through that CLI. The persistent Conversation host remains the run, turn, and transcript owner. |
| Assistant adaptation and target loading | implemented in source, release evidence unverified | Group Automatic adaptation addresses the designated Assistant through the same Membership-scoped native lane as one-to-one chat. Adaptive Flywheel roles and Assistant model catalogs use one selected-target Rust batch with bounded discovery concurrency. DeepSeek Harness is packaged through its official SDK JSON-RPC carrier with only its declared native capabilities; readiness remains unverified. |
| Gateway Runtime (LLM + Communication Channel) | implemented in source | Single `lico-gateway` process hosts the LLM Gateway loopback layer and the Telegram Communication Channel (paired DMs, `/agent` `/session`, conversation lane). Verified readiness changes use partial hot-reload via `gateway inventory reload` / `inventory.sock` (new ready agents admitted; bindings/sessions preserved; no process restart). `llm-gateway` CLI remains an alias for lifecycle. DM-only channel; not verified against a live BotFather bot in release evidence. |
| Skill, local-agent history, backup, and usage surfaces | implemented in source | Local client modules exist for these first-stage workflows. |
| Trusted history and recovery core | tested provider-neutral core | The core covers provider authorization, the default-readable history path without a recovery-key call, explicit client-encryption opt-in, recovery of all retained available objects, unavailable-object handling, Station exclusion, and separation from identity recovery. Cloud login, vendor adapter, live sync, and UI wiring are not present. |
| Complete Lico Arc endpoint Protocol Line | not implemented | LicoUp currently has no Lico Arc-owned Pairwise Protection, Generic Message, Reliable Exchange, negotiation, or Transport Profile to execute. The candidate outer-envelope adapter below is not that complete endpoint line. |
| Endpoint protection | preview implementation pending direct retirement | Secure Client Mesh currently executes the client-specific `licomesh.*` endpoint profile for pairing, authenticated encryption, freshness and replay handling, and endpoint-authenticated results. It is not a Lico Arc Profile, carries no future interoperability promise, and is to be retired directly when a complete pinned Lico Arc Protocol Line replaces it. |
| Lico Arc outer envelope | candidate adapter implemented | The native core emits and strictly decodes the closed five-field `licoarc.relay.v1` envelope; its encrypted carrier binds the complete outer routing context as authenticated data. |
| Station transport | implemented in source | The client-owned BadTower transport adapter exposes only bounded lease, send, receive, and delete operations. Its responses are transport hints rather than endpoint evidence. |
| Retired client-specific station API | removed | The former client-specific station envelope/API, `/api/secure-mesh/v1` routes, service-session scopes, configuration, fixtures, and compatibility surface are not retained. This removal does not describe the still-current `licomesh.*` endpoint preview above. |
| BadTower candidate interoperability | locally verified | The direct Lico Arc adapter has completed the exact two-fresh-endpoint scenario through an actual BadTower candidate. This is not a product release or trusted integration. |
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
- Peer encryption and mobile relay remain `preview`; the matrix does not claim
  physical-device, biometric, hardware-custody, or released-platform evidence.
- Current `licomesh.*` endpoint evidence verifies only that preview
  implementation. The candidate outer-envelope acceptance does not promote it
  into a Lico Arc Profile or a stable compatibility surface.
- The current generated adapter matrix enables send for Codex and reports the
  other packaged adapters as unverified. Exact current rows remain owned by
  `COMPATIBILITY.md`.
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
| Product version metadata | `0.1.1` (build 2), owned by `tools/client-version.json` |
| Next governed release | none currently planned |
| Archived release history | none archived in the governed release plan; `CHANGELOG.md` records `0.1.1` (2026-08-14) and `0.1.0-alpha` (2026-07-25) entries; `git tag -l` lists only `v0.1.0` |
| GitHub Release publication | not claimed; no `v0.1.1` tag exists |
| Platform-store publication | not claimed |

The `0.1.1` version metadata and its CHANGELOG entry record a version-sources
synchronization, not a publication. A build target or GitHub Release eligibility
flag is not publication. Each platform build, physical/device verification,
GitHub Release, and store channel is an independent claim.

## Support

- Platform and adapter support is limited to the exact generated rows in
  `COMPATIBILITY.md`.
- `supported` means the named current checks accept that target; it does not
  mean distribution or store readiness.
- `preview` means the capability is changing and is not a stable
  interoperability claim.
- The Lico Arc Station Adapter and BadTower transport are locally verified
  candidate capabilities, not a stable support or distribution declaration.
- The current Secure Client Mesh endpoint profile has no future compatibility
  commitment and is not a supported substitute for a pinned Lico Arc Protocol
  Line.
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

1. the current Secure Client Mesh preview creates and verifies the protected
   payload;
2. the Lico Arc codec produces or accepts exactly the five candidate outer
   fields;
3. the BadTower adapter performs only bounded lease, send, receive, and delete
   transport operations; and
4. deletion occurs only after endpoint authentication, decryption, freshness,
   and replay checks succeed.

The retired client-specific station surface was removed in the same migration.
There is no permanent dual-wire mode or station translation gateway. The inner
`licomesh.*` endpoint preview remains present today and is
separately scheduled for direct retirement; it is not reported as already
removed.
