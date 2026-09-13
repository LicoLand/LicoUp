# Client update and state migration

[Documentation index](../README.md) · [简体中文](CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md)

LicoUp has one application identity, installed name, and data root. `nightly`
and `stable` are release tracks of that identity, not side-by-side apps or
distribution transports. Direct and app-store remain packaging transport
values.

## Independent migration CLI

Data migration is an independently distributed capability. Its CLI belongs in
a separate Node.js repository with its own version, downloadable artifacts, and
release workflow. Users can install, run, upgrade, and uninstall it regardless
of the installed client version, including when the client cannot start or is
not installed. Uninstalling the tool preserves application data and recovery
records.

The tool must support conversion from any published data version to the current
version, and from a newer version to any published older target. Historical
format readers, writers, and composable upgrade and downgrade steps remain
available across tool releases. The source is determined from the actual
stores; the requested target selects its published data contract. Neither the
running client nor its embedded migration frontier limits that selection.

A downgrade must produce data the target client can actually open. Data that
the older format cannot represent must remain recoverable in preserved
extensions, with representation differences reported explicitly; silently
dropping it or merely restoring an old backup does not complete conversion of
the current data. Admission metadata changes only after the target stores meet
their postconditions. Editing a version marker alone cannot authorize an older
client to read newer data.

The Node.js CLI coordinates version conversion; protected credentials remain
behind the platform's native custody and authorization boundary. Any required
native helper ships with the independent tool and must not depend on an
installed client. Tool publication is separate from client publication and
preserves downloads and conversion definitions for historical versions.

These are design requirements for the independent tool; it has not yet been
implemented. The following sections describe the current client's updater and
admission implementation. Their forward-update restrictions do not define the
independent CLI's supported source or target versions.

## Client update selection

The native artifact embeds its product version, release track, and immutable
state-migration frontier. A local development build defaults to Nightly;
distributable builds provide the track explicitly. Update selection compares
SemVer precedence only:

- Nightly automatically accepts a strictly newer Nightly.
- Nightly may explicitly select a strictly newer Stable.
- Stable automatically accepts a strictly newer Stable.
- Stable never selects Nightly; equal and older versions are never eligible.

The signed manifest-v2 binds the target track and each release's exact
migration frontier. Human migration notes are descriptive only. The caller
cannot override the running version, running track, frontier, or migration
steps.

A successful check of the canonical public Stable release can establish that
its version is equal to or older than the running version even when that
release has no update manifest. This is a published-version observation only:
it carries no verified key, artifact or replacement receipt. A missing manifest
for a newer, unknown or Nightly version is reported as unavailable metadata.
If a manifest is present, its signed verification remains mandatory regardless
of the release tag. Network and integrity failures remain failures; a stale
cache cannot conceal a failed verification. Starting a new check clears any
previous candidate receipt before adopting its result.

Before replacement, native update verification writes a claim bound to the
selected version, target track, exact frontier, and artifact receipt. The new
binary must match that claim before migration admission; a mismatch blocks
before any state mutation. The current updater recovers a claimed replacement
by installing the same or a newer forward-capable candidate. Explicit data
downgrade belongs to the independent migration CLI defined above.

## Startup admission

After resolving the raw data directory, the desktop lifecycle invokes native
state admission before loading the workspace, preferences, conversations,
Adaptive Flywheel, Mobile Relay, or another product-state consumer. Admission
locks the root, probes every domain, proves a contiguous plan, and persists the
product-version high-water before the first schema mutation. Each durable step
commits through an atomic file replacement or its owning database transaction;
the bounded ledger is updated only after its authoritative postcondition.
Conversation and Adaptive Flywheel SQLite metadata, workspace and presentation
documents, Mobile Relay configuration, and the remaining declared preference
documents are probed at their owning stores. Markers record reconciliation for
an absent store; they never substitute for probing an existing store.

The `gateway-credential-custody` domain is a protected continuation of this
frontier. macOS roots without a completed custody receipt report it in
`pendingAuthorizationDomainIds` and remain ready; admission never opens the
Keychain. An empty data directory cannot prove that no legacy Keychain items
exist. The explicit `llm-gateway credentials migrate`
operation completes the protected work described in
[credential custody](../protocols/llm-gateway.md#credential-custody), then writes
its completion marker and reconciles the same migration ledger. Failed or
cancelled work remains pending. The custody operation holds a separate lock,
so a native approval dialog does not block unrelated startup admission.

Current domains are skipped and a rerun is a no-op. State ahead of the binary,
unknown shapes, gaps, and incomplete or failed steps keep startup closed with a
stable privacy-safe error code. A committed step is reconciled and not replayed
after a crash. Durable user and security state is never silently reset.

The current admission implementation can recover by reinstalling the same
verified capable build or a newer signed build and retrying. It denies an older
binary after high-water advances. Supporting explicit downgrade requires the
independent CLI to convert the stores and establish target-compatible admission
state before the older client opens them; that integration remains to be built.

## Publication

Nightly publication is prepared from `nightly` under the fixed `nightly`
prerelease; Stable publication remains an immutable `v{version}` release from
`release`. Both profiles preserve `land.lico.licoup`, `LicoUp.app`, and the
shared root. A Stable promotion must be non-prerelease and strictly newer than
the last Stable and installed Nightly; a same-version Stable is not offered.
Publication validation compares SemVer precedence (build metadata cannot break
a tie), rejects a regressed migration frontier, and verifies the shared app
identity before signing.
