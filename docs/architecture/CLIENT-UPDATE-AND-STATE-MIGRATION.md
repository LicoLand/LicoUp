# Client update and state migration

Updated: 2026-09-25

[简体中文](CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md) ·
[Architecture](README.md) · [Data migration](../modules/data-migration.md)

LicoUp has one application identity, installed name, and data root. `nightly`
and `stable` are release tracks of that identity, not side-by-side applications
or packaging transports. `direct` and `app-store` are packaging transport values.

## Independent migration CLI

The standalone Rust program in `crates/licoup-migrate/` provides `inspect`,
`plan`, `convert`, `resume`, `export`, and `import`. It builds and runs as one
binary and needs no Node.js runtime. It probes the actual stores and selects the
registered conversion path for the requested published target. `inspect` and
`plan` are read-only.

`convert`, `resume`, and `export` require `--writers-stopped`. The tool lock
excludes only other runs of this tool; it cannot stop an older client or another
writer that does not participate in that lock. Each domain commits and verifies
its own postcondition before its marker and journal advance. Recovery resumes
from the physical stores without repeating committed steps; the tool does not
claim one transaction across every database, file, and platform credential
store. A run that leaves a domain owed reports that domain and exits non-zero
instead of presenting the move as finished.

Unsupported shapes and unsafe downgrades fail before mutation. Preservation
records keep data that a supported older shape cannot express and merge it back
on a supported re-upgrade. Canonical Conversation moves and typed workflow-store
moves that require their owning domain are reported as pending native admission.
Protected credential custody is reported as pending platform authorization and is
never fabricated by the tool. The tool's own crate and the
[data migration guide](../modules/data-migration.md) own its current profile
table, conversion graph, command syntax, and exact limitations.

## Client update selection

The native artifact embeds its product version, release track, and immutable
state-migration frontier. Local development builds default to Nightly;
distributable builds provide the track explicitly. Selection uses SemVer:

- Nightly automatically accepts a strictly newer Nightly.
- Nightly may explicitly select a strictly newer Stable.
- Stable automatically accepts a strictly newer Stable.
- Stable never selects Nightly; equal and older versions are not eligible.

The signed manifest-v2 binds the target track and each release's exact migration
frontier. Human notes do not override those fields. If a manifest exists, its
signature verification is mandatory. Network and integrity errors remain
failures, and a new check clears its previous candidate before adopting a result.

Before replacement, native verification writes a claim bound to the selected
version, track, frontier, and artifact receipt. The replacement binary must match
that claim before migration admission. A claimed replacement recovers through
the same candidate or a newer forward-capable candidate. Supported explicit data
conversion is performed by the migration CLI.

## Startup admission

After resolving the data root, the desktop lifecycle invokes native admission
before loading product-state consumers. Admission locks the root, probes every
registered domain, proves a contiguous plan, and records the product-version
high-water before the first schema mutation. Each durable step commits through
an atomic file replacement or its owning database transaction; the migration
ledger advances only after the authoritative postcondition is present.

The `gateway-credential-custody` domain requires explicit platform-authorized
credential migration. Until its completion receipt exists, admission reports it
in `pendingAuthorizationDomainIds` and remains ready without opening the
Keychain. The `llm-gateway credentials migrate` operation owns that protected
step and reconciles the same migration ledger after completion.

Current domains are skipped and a rerun is a no-op. State ahead of the binary,
unknown shapes, gaps, and incomplete or failed steps keep startup closed with a
stable privacy-safe code. A committed step is reconciled after a crash instead
of replayed. Persistent user and security state is not silently reset.

The updater can recover by reinstalling the same verified capable build or a
newer signed build and retrying. It rejects an older binary after high-water
advances. For a target supported by the migration CLI, all writers must be
stopped and conversion must complete before the older client opens the data
root. Unsupported downgrade paths remain refused without mutation.

### Workflow store conversion

Native admission advances the Adaptive Flywheel store from SQLite schema 2 to 3
and its admission frontier from 1 to 2. The migration materializes historical
implicit entry slots and effect routes once; the conversion and schema marker
commit in one SQLite transaction. It preserves revision and semantics identities,
run snapshots, command attempts, leases, and grants. Ordinary compilation accepts
canonical definitions and does not rewrite them. The independent CLI reports
owner-only typed moves as pending native admission.

## Publication

Nightly publication is prepared from `nightly` under the fixed `nightly`
prerelease; Stable publication uses immutable `v{version}` releases from
`release`. Both preserve `land.lico.licoup`, `LicoUp.app`, and the shared data
root. Publication validation compares SemVer precedence, rejects a regressed
migration frontier, and verifies the shared application identity before signing.
