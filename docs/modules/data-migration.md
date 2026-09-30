# Data migration developer guide

Updated: 2026-09-27

[Developer entry](../RUNBOOK.md)

Read-only inspection is separate from explicit maintenance. The durable owner controls formats and migration admission. Preserve user data across interruption; failed work must not masquerade as a completed migration.

[Client Update And State Migration](../architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.md)

## Development and migration boundaries

Keep one current target schema. First exercise creation, reads, writes and reopening
with synthetic data in an explicitly isolated temporary data root. Every participating
process must resolve that root. Correct the target implementation in place and remove
the temporary data when the exercise ends; do not use a user's active store to debug
schema design.

### One version, one format

A stored format is identified by the product version of the release that writes it,
and by nothing else. There is no second versioning scheme: a build number is not a
format, and a store's internal schema counter is an implementation detail of that
store rather than a format identity or a version of its own.

Migration converts the previous release's format into the current release's format.
Exactly one such pair exists at a time, the frontier catalog declares it, and a root
that names any other format is refused as an unsupported source. A later release
replaces the pair with its own predecessor and itself; it never adds a third
endpoint, a compatibility branch, or a chain of intermediate formats.

Only a format an officially released version wrote may be read or converted. A stored
shape that no release shipped is refused as an unsupported shape rather than
upgraded, and no ladder arm or migration step is kept for it. Official releases carry
no in-release format conversion, and a development tree's intermediate state is not a
supported source.

An identifier a released build has already recorded is never renamed, because a
rename would change the identity an installed build holds. A name no release has
carried is not a format at all and is corrected rather than kept. Product version
selection follows release policy; a local build, a schema correction or a failed
attempt does not create another release endpoint. Update the existing conversion
directly, together with the durable owner and its consumers.

Before an authorized local-data migration, preserve a consistent, recoverable local
backup and rehearse the same conversion on a disposable copy. Keep the source backup
unchanged. Fix failures in the same conversion, then retry from that source or a valid
resume point without changing endpoints. Remove disposable copies after use; retain
the recovery backup until the data transition is confirmed. Unpublished snapshots
that contain user data require a bounded recovery mapping into the current target,
not another supported release profile or permanent compatibility implementation.

The migration tool is a standalone Rust program packaged and distributed as a
binary; it does not require a Node.js runtime on the user's machine. It is not
kept alongside a second implementation, and it must not depend on the client
checkout to run. Extend that program and the durable owner when this workflow
needs missing capability; do not establish a second schema authority. `convert`,
`resume`, `export` and `rehearse` each require the operator's `--writers-stopped`
statement before they open the root; `inspect` and `plan` are read-only and `import`
names no source root of its own, so those three never take the statement. A run that
leaves a domain owed exits non-zero instead of reporting a completed migration.
`rehearse` sequences the client's own owners — native admission for the conversion
and the native full-data-root archive owner for capture and restore — against a
disposable copy of the named root, so the tool alone never implements a conversion
or a container of its own. Real-client acceptance remains the separate phase defined
in [Closure](../CLOSURE.md).

## Local backup and restore boundary

Development backup exports must be unencrypted standard ZIP or TAR.GZ archives;
both formats must support import. Preserve the same data layout and restore
semantics in either container. Archive creation and extraction do not change the
database schema or create a release version. Keep the export/import interface
small; infer the container from the archive file instead of requiring a long
command sequence.

Capture the complete selected LicoUp data root, including its files and consistent
database contents. Coordinate writers before capture. Include application-owned
exportable secrets through their platform storage owner and honor required native
authorization. A non-exportable key must have an explicit recovery limitation;
an opaque handle alone is not a portable key backup. Report incomplete coverage
without printing secret values. Logs and redacted snapshots are not full backups.

Restore into a temporary destination first, keep extraction within that destination,
and verify the restored files, database reads and key availability before replacing
active state. Preserve the recoverable source until restoration is confirmed. Any
required schema conversion follows the fixed release migration above; importing an
archive must not create another development-format compatibility chain.

The migration CLI exposes the two commands this boundary requires:

```sh
licoup-migrate export --data-root <path> --archive <path>.zip|.tar.gz --writers-stopped
licoup-migrate import --archive <path> --target-root <empty directory>
```

`export` names the data root it captures; `import` names none, because its only
input is the archive and its destination is the empty `--target-root`.
`export` refuses without `--writers-stopped` and publishes nothing on refusal.
`import` requires an empty destination, verifies the archive manifest and every
member before publishing, and never replaces the active root. Both route to the
foundation owner in `crates/licoup-foundation/src/core/full_data_root_archive/`,
which `licoup-native` re-exports at its former `core::full_data_root_archive`
path for `licoup-migrate`; the tool does not archive or unpack anything itself.
The container is inferred from the
archive name, and both containers carry the same logical payload. `package` still
distributes the tool itself and is not a data backup. The snapshot and provider
history facilities remain separate capabilities, not full archive restore.

## Role responsibilities

**Design:** inspect source/destination formats and maintenance admission. If a shared contract changes,
include its producer and consumers; consult [conversation](conversation.md) or
[distribution](distribution.md) when that boundary is affected.

**Implement:** stay within assigned files; use the test directories below.
Escalate neighboring changes to their owner before editing them.

**Review:** check both sides of changed boundaries with `npm run repo:impact -- --path <changed-path>`,
then run this module's command and the affected consumer commands.

## Verification

Run `npm run verify:data-migration` from the repository root. Discover narrower registered
suites with `npm run client:regression:list`; test contents remain the authority.

Test directories: `crates/licoup-migrate/tests/`,
`crates/licoup-native/tests/local_recovery/` and
`crates/licoup-native/tests/full_data_root_archive/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
