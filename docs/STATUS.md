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
| Human messaging, federation, recovery, notary, and multi-device history | planned | These remain product intent until independently implemented and verified. |
| Lico Arc endpoint Protocol Line | required future boundary | Stable wire-observable Pairwise Protection, Generic Message, Reliable Exchange, negotiation, and Transport Profile belong to a named Lico Arc Protocol Line. No Published Protocol Line is currently supported. |
| Lico Arc station-facing protocol | current candidate boundary | Lico Arc Protocol is the sole station-facing outer protocol; the current adapter pins the candidate `licoarc.relay.v1` line. |
| Official network | planned convenience | It may become a replaceable default only after separate release and operation evidence exists. It receives no trust privilege. |

## Implementation

| Capability | Status | Current source boundary |
| --- | --- | --- |
| Local-agent discovery and conversation | implemented in source | Desktop and native client code contains local and explicitly configured agent adapters and conversation flows. |
| Canonical Conversation backend | implemented in source | Rust owns one indexed SQLite/WAL authority for one-to-one and group Conversations, peer Human/Agent Memberships, the explicit Assistant designation, revisioned per-Membership Profile intent, structured Events/Parts, topology-neutral immutable Graph snapshots, and private runtime bindings. Generated Rust/Dart contracts and the group Conversation UI project the same closed facts. |
| Assistant workflow and Subagent MCP | implemented in source | Four closed Assistant tools expose Profile ranking plus execute/inspect/cancel for assistant-temporary workflows. The MCP-bound Agent must be the active designated Assistant Membership. Execute performs local preflight, returns ordered privacy-safe diagnostics with stable stages and request pointers, freezes exact Membership bindings and a route receipt before effects, and returns dynamic failure once without implicit retry. Direct `lico_subagent_*` operations remain separate; the persistent Conversation host is the sole run, turn, and transcript owner. |
| Assistant adaptation and target loading | implemented in source, release evidence unverified | Group Automatic adaptation addresses the designated Assistant through the same Membership-scoped native lane as one-to-one chat. Adaptive Flywheel roles and Assistant model catalogs use one selected-target Rust batch with bounded discovery concurrency. DeepSeek Harness is packaged through its official SDK JSON-RPC carrier with only its declared native capabilities; readiness remains unverified. |
| Gateway Runtime (LLM + Communication Channel) | implemented in source | Single `lico-gateway` process hosts the LLM Gateway loopback layer and the Telegram Communication Channel (paired DMs, `/agent` `/session`, conversation lane). Verified readiness changes use partial hot-reload via `gateway inventory reload` / `inventory.sock` (new ready agents admitted; bindings/sessions preserved; no process restart). `llm-gateway` CLI remains an alias for lifecycle. DM-only channel; not verified against a live BotFather bot in release evidence. |
| Skill, history, backup, and usage surfaces | implemented in source | Local client modules exist for these first-stage workflows. |
| Complete Lico Arc endpoint Protocol Line | not implemented | LicoUp currently has no Lico Arc-owned Pairwise Protection, Generic Message, Reliable Exchange, negotiation, or Transport Profile to execute. The candidate outer-envelope adapter below is not that complete endpoint line. |
| Endpoint protection | preview implementation pending direct retirement | Secure Client Mesh currently executes the client-specific `licomesh.*` endpoint profile for pairing, authenticated encryption, freshness and replay handling, and endpoint-authenticated results. It is not a Lico Arc Profile, carries no future interoperability promise, and is to be retired directly when a complete pinned Lico Arc Protocol Line replaces it. |
| Lico Arc outer envelope | candidate adapter implemented | The native core emits and strictly decodes the closed five-field `licoarc.relay.v1` envelope; its encrypted carrier binds the complete outer routing context as authenticated data. |
| Station transport | implemented in source | The client-owned BadTower transport adapter exposes only bounded lease, send, receive, and delete operations. Its responses are transport hints rather than endpoint evidence. |
| Retired client-specific station API | removed | The former client-specific station envelope/API, `/api/secure-mesh/v1` routes, service-session scopes, configuration, fixtures, and compatibility surface are not retained. This removal does not describe the still-current `licomesh.*` endpoint preview above. |
| BadTower candidate interoperability | locally verified | The direct Lico Arc adapter has completed the exact two-fresh-endpoint scenario through an actual BadTower candidate. This is not a product release or trusted integration. |
| Official network default | not configured | The client has no current default official-network station entry. |

Implementation in source does not establish verification, release, support, or
hosted operation.

## Verification

- The generated compatibility matrix is the current platform and adapter
  support projection.
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
