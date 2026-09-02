# Client update and state migration

[Documentation index](../README.md) · [简体中文](CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md)

LicoUp has one application identity, installed name, and data root. `nightly`
and `stable` are release tracks of that identity, not side-by-side apps or
distribution transports. Direct and app-store remain packaging transport
values.

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

Before replacement, native update verification writes a claim bound to the
selected version, target track, exact frontier, and artifact receipt. The new
binary must match that claim before migration admission; a mismatch blocks
before any state mutation. Once claimed, recovery installs the same or a newer
forward-capable candidate. No later binary-restore surface exists.

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

Current domains are skipped and a rerun is a no-op. State ahead of the binary,
unknown shapes, gaps, and incomplete or failed steps keep startup closed with a
stable privacy-safe error code. A committed step is reconciled and not replayed
after a crash. Durable user and security state is never silently reset.

Recovery is forward-only: reinstall the same verified capable build or a newer
signed build and retry admission. An older binary is denied after high-water
advances. There is no downgrade or post-launch app rollback path.

## Publication

Nightly publication is prepared from `nightly` under the fixed `nightly`
prerelease; Stable publication remains an immutable `v{version}` release from
`release`. Both profiles preserve `land.lico.licoup`, `LicoUp.app`, and the
shared root. A Stable promotion must be non-prerelease and strictly newer than
the last Stable and installed Nightly; a same-version Stable is not offered.
Publication validation compares SemVer precedence (build metadata cannot break
a tie), rejects a regressed migration frontier, and verifies the shared app
identity before signing.
