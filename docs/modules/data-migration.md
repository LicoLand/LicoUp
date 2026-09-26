# Data migration developer guide

Updated: 2026-09-26

[Developer entry](../RUNBOOK.md)

Read-only inspection is separate from explicit maintenance. The durable owner controls formats and migration admission. Preserve user data across interruption; failed work must not masquerade as a completed migration.

[Client Update And State Migration](../architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.md)

## Development and migration boundaries

Keep one current target schema. First exercise creation, reads, writes and reopening
with synthetic data in an explicitly isolated temporary data root. Every participating
process must resolve that root. Correct the target implementation in place and remove
the temporary data when the exercise ends; do not use a user's active store to debug
schema design.

Use the last published release as the fixed source and the planned next release as
the fixed destination. Product version selection follows release policy; a local
build, schema correction or failed attempt does not create another release endpoint.
Update the existing conversion directly, together with the durable owner and its
consumers. Do not retain a chain of unpublished development formats.

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
needs missing capability; do not establish a second schema authority. A
conversion, a resume and an export each require the operator's
`--writers-stopped` statement before they open the root, and a run that leaves a
domain owed exits non-zero instead of reporting a completed migration. At present the CLI accepts
`--data-root`, but canonical Conversation conversion is delegated to native admission;
the CLI alone does not execute the complete rehearsal. Real-client acceptance remains
the separate phase defined in [Closure](../CLOSURE.md).

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
licoup-migrate export --data-root <path> --archive <path>.zip|.tar.gz [--writers-stopped]
licoup-migrate import --archive <path> --target-root <empty directory>
```

`export` names the data root it captures; `import` names none, because its only
input is the archive and its destination is the empty `--target-root`.
`export` refuses without `--writers-stopped` and publishes nothing on refusal.
`import` requires an empty destination, verifies the archive manifest and every
member before publishing, and never replaces the active root. Both route to the
native owner in `crates/licoup-native/src/core/full_data_root_archive/`; the tool
does not archive or unpack anything itself. The container is inferred from the
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

Test directories: `crates/licoup-migrate/tests/`.
Keep new tests in the owning directory, grouped by behavior, not release milestone.

Read [Closure](../CLOSURE.md) when finishing the change.
