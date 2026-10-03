# Client update and state migration

Updated: 2026-10-03

| Related document | Path | Authority |
| --- | --- | --- |
| Normative version | This document | Client update and data migration contracts |
| Localization | [简体中文](CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md) | Chinese projection |
| Documentation index | [Index](../README.md) | Navigation |
| Workflow control | [Assistant workflow control and compiler](ASSISTANT-WORKFLOW-CONTROL.md) | Target maintenance, node drainage and execution ownership |

LicoUp has one application identity, installed name, and data root. `nightly`
and `stable` are release tracks of that identity, not side-by-side apps or
distribution transports. Direct and app-store remain packaging transport
values.

## Conversion ownership and endpoints

The native migration owner converts the last published product's persisted format
to the planned release's format. The embedded frontier catalogue is the authority
for this single source/target pair; [Compatibility](../COMPATIBILITY.md) projects
it. A product release number is not necessarily the identifier its shipped binary
recorded. Preserve the recorded identifier and published step prefixes. A local
build or schema correction does not establish another supported release.

Store owners define physical schemas and conversions. Startup admission and the
standalone native tool use those owners, rather than separate format writers.
The standalone program is `crates/licoup-migrate`: one Rust binary that runs
without Node.js or an installed client. Release distribution must provide it as a
separately downloadable asset rather than a permanently bundled package. Its
verbs are `inspect`, `plan`, `convert`, `resume`, `export`, `import`, and
`rehearse`. Every invocation prints one JSON report and exits non-zero when the
run leaves work owed. `inspect` and `plan` are read-only; `convert`, `resume`,
`export`, and `rehearse` require the operator's `--writers-stopped` statement.

`export` and `import` reach the same Foundation full-data-root archive owner as
the installed client's `backup` command, so an archive written by either entry
point restores through the other and neither holds a second archive format.
`rehearse` drives the same owners over a disposable working root, reports every
stage it ran, and leaves the source untouched, so a conversion and both
plaintext container round trips can be proved before an authorized real-data
transition. The retired Node.js package is not retained as a converter,
compatibility entry point, or fallback. Retained repository diagnostics are
developer tools, not another supported conversion authority. There is no
arbitrary historical-target selection or downgrade conversion contract.

Import validates and extracts through Foundation, then prepares custody metadata,
owner-managed references and revision protections in its private staging payload.
These owner checks finish before any payload is published into the empty destination.
Physical staging paths are used only for verification; persisted references name the
final logical home. Foundation revalidates the bounded, no-follow payload and preserves
verified read-only protections during publication. One owner handles checked scratch
cleanup, publication rollback and directory synchronization. The entry point holds
selected-home writer coordination throughout. Multi-file publication is not a
crash-atomic activation transaction: an interrupted or incompletely rolled-back
destination is unverified, not a usable recovery. Preserve it for diagnosis and retry
from the unchanged source archive into a fresh empty home. Import never selects or
activates the recovered home.

For a release that provides the tool, `LicoUp-migrate-macos-arm64` is downloaded
on demand with its `.sha256` from that release and runs offline once obtained.
The local release catalogue stages the tool and checksum; that is not proof of
publication or availability from a released tag. Installing or updating the
client neither installs, replaces, nor removes the downloaded tool, and the
running client never selects a bundled migrator. Use a release whose declared
source and target match the required conversion. Replacing the executable does
not reset progress: conversion journals remain in the selected data root.

Both macOS publication profiles select the governed `independent-tool` and
`independent-tool-digest` pair. Their source is the separate release-tool build
output, never the app bundle. Apple Release owns Developer ID signing, independent
notarization, immutable materialization and public byte/checksum verification for
that pair. It does not run the migration tool as an acceptance probe. Source
configuration and synthetic checks do not establish published availability or
first-run operating-system acceptance; the corresponding owner contract must be
legitimately adopted before the governed release can consume it.

Explicit maintenance requires stopped writers and a recoverable source. The short
startup `admission.lock` does not prove that runtime writers have stopped. The
standalone tool holds the client's selected-home exclusive process lease across
conversion, resume, export, import and rehearsal; a participating active writer
causes refusal rather than being stopped. The operator statement still covers
older clients and other writers outside that coordination. Preserve
the source before an authorized real-data transition and rehearse in a disposable
root; never use a live store to debug the target schema. Protected credentials
remain behind their platform custody and authorization boundary.

Conversion records per-domain progress. A committed store is authoritative over a
stale marker or journal, and recovery reconciles the completed step rather than
repeating it. There is no atomic transaction spanning all databases, files and
operating-system credential stores. Data-dependent conversion failures remain
forward-only `migration_step_failed` apply/retry work; a read-only structural
preflight does not certify every stored business value.

## Package-owned conversion declarations

A package that owns a persisted format says so in its own manifest. The optional
`conversion` declaration names the converter kind, the entry inside the package payload,
the published source formats the converter reads and the target format it produces. Only
one converter kind is published, `native-executable`: the package carries the program, and
a converter that needed an interpreter would borrow a runtime the package does not carry.
The field is absent from a package that owns no format — most packages convert nothing —
so an absent declaration is complete rather than empty; a package that was asked for a
conversion and declares none is refused, with its own id and the required source format
named and no private data in the report.

The declaration is validated structurally before anything runs, and each refusal names the
rule it broke: a non-native converter kind, an entry outside the package payload, an empty
source-format list, and a missing or malformed target format are separate stable codes.
[manifest schema](../../schemas/extensions/manifest.schema.json)
publishes the same fields, patterns and bounds, and the schema-agreement suite pins them
against the crate, so a third party validating against the schema is refused by the rules
the host applies.

The declaration and the authenticated release metadata name the same facts. A released
package carries a `licoup.package-release.v1` declaration whose `converter` object holds the
converter kind, entry, one source format and the target format, and the release index
publishes that object per package. The committed fixture under
`tests/fixtures/client_package_release/fixture-native-converter/` declares the same
converter in both documents, and its manifest lists the source format its release
declaration names.

The standalone tool reads the declaration instead of recognising formats it was compiled
with. `licoup-migrate`'s `converter` module takes the required pair from the client's
embedded frontier catalogue — the same single source/target pair startup admission uses —
reads a package manifest and answers which package owns that pair. Identification consults
no client version: which client builds may load a package (`compatibility`) and which
formats it owns are separate claims, so a package released for another client line still
owns its formats, and source support is never inferred from the version of the installed
old client. A package whose declared formats are not the required pair is refused even when
it carries a native converter, and the tool holds no table of package names or format
aliases. With a package root the tool also checks that the entry the manifest promises is a
file inside that root.

## Coordinated package conversion

The standalone tool coordinates one conversion from the package store to the converter and
back. Nothing converts the data except the package's own program: the tool selects, stages,
runs, verifies and records.

### Installed converter inventory

`licoup-migrate converters --package-store <root>` reads the installed versions the package
store records and reports each one's candidacy for the required pair. A package is a
**candidate** only when its own manifest declares the pair: the required source format is
one of the formats it publishes and the target format is exactly the required target. A
package that declares no conversion — most packages — is not a candidate, and neither is one
that declares another pair; both are reported with the refusal code that names the rule.
The package's compatibility list takes no part: which client builds may load a package is the
host's admission question, not the format question.

Selection is deterministic: the greatest installed version of the requested identity, or of
every candidate when none is named. Every candidate is listed either way, so an operator sees
the alternatives. When the caller supplies the signed release index, a candidate must also be
the payload the index publishes: both release-role signatures verify over the canonical
unsigned bytes, the entry agrees with the installed manifest about identity, version, entry,
kind and pair, and the digest and size the host recorded for the installed bytes are the
digest and size the index publishes. The index publishes one source format per package while
the manifest declares the list it reads, so the reconciliation is that the published source
is the required one and one the manifest declares. A candidate that is not the published
payload is refused rather than run.

### Converter protocol

`licoup-migrate package-convert` (and `package-resume`) runs the selected entry as a bounded
native subprocess:

```text
<entry> --source <dir> --target <dir> \
        --source-format <identity> --target-format <identity> \
        --result <file> [--resume]
```

* `--source` is a staged copy of the data root. The converter reads it and must not write
  inside it.
* `--target` is the directory the converted result is produced in, and the process's working
  directory. It is never deleted by the tool, including across a resume.
* `--result` is where the converter writes a `licoup.package-conversion-result.v1` document:
  `schema`, `sourceFormat`, `targetFormat`, `complete` and an optional `convertedRecords`.
* `--resume` states that a previous invocation was interrupted and the target must be
  continued rather than started over.

The tool bounds what it did not write: captured output is capped and reported as truncated,
the result document is size-bounded and strictly shaped, the child runs in its own process
group so a stop reaches the whole tree, and the environment is reduced to the variables a
native program needs to start on the platform. There is no automatic execution deadline: an
elapsed time is not a user's decision, so a caller stops a run it no longer wants. The
converter may be a program of any size, but it must be a native executable inside the
package payload — a converter that borrows an interpreter is refused at declaration time, and
neither the tool nor the conversion reaches a network or needs an installed Agent, an old
package runtime, Node or Python.

Completion is the converter's own checked report, never its exit status alone: the process
must exit zero, the result document must be the documented one and name the required pair,
`complete` must be true, and the target must not be empty. Anything else leaves the run
unfinished and the tool's exit status non-zero. A converter that writes inside the source it
was given is refused, and the data root's digest is verified unchanged after every run: a
conversion stages a copy and never writes the source root.

### Interruption, resume and admission

The tool's existing run record owns the progress. The record is written into the caller's
working root, beside the staged copy and the target, and it names the package, its version,
the entry, the required pair, the digest of the installed payload the run was admitted under
and the digest of the source root as the run read it. Two steps are recorded: staging the
source copy and running the converter. Each is written before it is attempted and rewritten
after it settles, so an interruption is visible as an unsettled step instead of a claim.

An unsettled run is resumed, never restarted. A plain `package-convert` over a recorded
unsettled run is refused (`package_conversion_unfinished`) and names the resume; a resume
requires the same declared package, pair, payload digest and source digest, reuses an intact
staged copy instead of staging again, and asks the converter for `--resume` so the target it
already produced is continued. A settled run answers `alreadyCurrent` and is not converted a
second time. An interrupted or failed conversion is incomplete work, never a successful
migration.

Maintenance admission is asked before anything is staged. The tool reads the host's own
idle-admission decision (`domain/work_admission`) and refuses while this host still owns
unfinished local work (`maintenance_work_unfinished`) or while another maintenance operation
holds the close-admission barrier (`maintenance_admission_closed`), reporting the decision
and the blocking owners it read. The operator's `--writers-stopped` statement covers the
writers outside that coordination, exactly as it does for the client-owner verbs, and the
tool holds the client's selected-home exclusive process lease for the run.

An offline payload is imported through the package store's existing path:
`--payload` is bounded and preflighted by the store's own artifact admission, its content
digest is checked against the signed index when one was supplied, and the store's
`install_local_import` publishes it under the manifest identity and permission scope. An
already installed version with the same digest satisfies the import; a version whose
recorded digest differs is refused instead of replaced.

Not part of this contract: publishing a produced target back into the data root. The
standalone conversion produces a staged target and reports it; replacing an installed data
root is a separate, separately authorized act, and the tool never writes the source root it
read. The release index tool does not yet read the manifest `conversion` block when it
packages a payload, and its `converter.sourceFormat` is a single format while the manifest
declares a list; the reader reconciles the two and refuses a disagreement, so a release
whose two documents disagree cannot be converted.

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
by installing the same or a newer forward-capable candidate. It does not authorize
data downgrade.

## Startup admission

After resolving the raw data directory, the desktop lifecycle invokes native
state admission before loading the workspace, preferences, conversations,
Adaptive Flywheel, Mobile Relay, or another product-state consumer. Admission
locks the root, probes every domain under its declared startup scope, proves a contiguous plan, and persists the
product-version high-water before the first schema mutation. Each durable step
commits through an atomic file replacement or its owning database transaction;
the bounded ledger is updated only after its authoritative postcondition.
Conversation and Adaptive Flywheel SQLite metadata, workspace and presentation
documents, Mobile Relay configuration, and the remaining declared preference
documents are probed at their owning stores. Markers record reconciliation for
an absent store; they never substitute for probing an existing store. Optional feature failures
are returned in `unavailableFeatureDomainIds` without marking their data current or
replacing their files. The corresponding Flutter bootstrap steps preserve defaults
or leave the feature disabled. Core state failures remain fatal. Durability alone
does not make a feature a prerequisite; see the [startup policy](../RUNBOOK.md#startup-and-retained-data).

Before high-water, frontier or domain-marker advancement, SQLite admission checks
the complete retained owner layout: columns, nullability, defaults, primary and
unique keys, CHECK expressions, partial-index predicates, foreign-key actions,
collations and other write constraints. Definitions come from the actual owner
DDL. Older supported Conversation layouts are upgraded schema-only in memory and
compared to that full contract, not to a startup column subset. Workflow tables
created on demand may be absent; malformed existing tables are refused. The
released nullable-terminal producer variant remains valid. Unrecognized structural
definitions within the current owner are refused, not silently repaired or treated
as equivalent SQL. Unowned historical tables and incoming relations coexist without
being read or removed. Empty stores initialize normally; complete validated current
structures may reconstruct a missing version marker without replacing their rows.

The retained JavaScript evaluator uses the same owner DDL and structural upgrade
steps. SQLite inspection errors remain bounded per-domain refusals; they never
certify an unreadable store or erase sibling observations. Independent frozen
fixtures exercise native admission, real owner reads and writes, and the actual
diagnostic evaluator. Changed owner and fixture inputs select those existing
regression suites through the module catalogue.

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

Current domains are skipped and a rerun is a no-op. Core state ahead of the binary,
unknown core shapes, gaps, and incomplete or failed core steps refuse startup with a
stable privacy-safe error code. A committed step is reconciled and not replayed
after a crash. Durable user and security state is never silently reset.

The native build generates the update-handoff and Adaptive Flywheel artifact
state types and transitions from one declarative state-machine resource. The
handoff owner validates and persists the generated pending-to-claimed transition;
the strategy-store owner applies generated transitions through the existing
SQLite migration APIs. These modules own admission effects, while the generated
tables remain the transition authority.

The current admission implementation can recover by reinstalling the same
verified capable build or a newer signed build and retrying. It denies an older
binary after high-water advances. It does not lower metadata to let an older
binary open a newer store.

### Workflow store conversion

The current source advances the Adaptive Flywheel store from SQLite schema 2 to
3 and its admission frontier from 1 to 2. The existing migration owner materializes
historical implicit entry slots and effect routes once. Conversion and the schema
marker commit in one SQLite transaction. Only the actual released schema-2 layout
and current schema-3 layout are admitted; completed frontier-1 ledgers and markers
advance through the registered next step.

The conversion preserves revision and semantics identities, run snapshots,
command attempts, leases and grants. Immutable package bytes keep their original
digests; package verification validates that identity before applying historical
format interpretation. Ordinary compilation accepts canonical definitions and
does not rewrite them. This forward conversion does not establish another
historical compatibility format.

## Publication

Nightly publication is prepared from `nightly` under the fixed `nightly`
prerelease; Stable publication remains an immutable `v{version}` release from
`release`. Both profiles preserve `land.lico.licoup`, `LicoUp.app`, and the
shared root. A Stable promotion must be non-prerelease and strictly newer than
the last Stable and installed Nightly; a same-version Stable is not offered.
Publication validation compares SemVer precedence (build metadata cannot break
a tie), rejects a regressed migration frontier, and verifies the shared app
identity before signing.
