// Development backup command surface.
//
// The archive itself belongs to the native owner; these cases freeze the tool's
// own contract: supported containers are inferred from the file name, the writer
// statement is explicit, and a missing target root is refused before any call.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  exportBackup,
  importBackup,
  isNativeCliAvailable,
  isSupportedArchiveName,
  nativeCliPath,
} from "./index.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const cli = path.join(repoRoot, "tools", "data-migration", "bin", "cli.mjs");

function tempDir(name) {
  // The archive owner refuses a destination below a symlinked ancestor, and the
  // system temporary directory is reached through one, so resolve it first.
  const base = fs.realpathSync(os.tmpdir());
  return fs.mkdtempSync(path.join(base, `licoup-backup-${name}-`));
}

test("the container is inferred from the archive name and nothing else", () => {
  assert.equal(isSupportedArchiveName("complete.zip"), true);
  assert.equal(isSupportedArchiveName("complete.tar.gz"), true);
  assert.equal(isSupportedArchiveName("complete.tgz"), true);
  assert.equal(isSupportedArchiveName("COMPLETE.ZIP"), true);
  assert.equal(isSupportedArchiveName("complete.rar"), false);
  assert.equal(isSupportedArchiveName("complete"), false);
  assert.equal(isSupportedArchiveName(""), false);
});

test("an unsupported container is refused before the native owner is called", () => {
  const work = tempDir("container");
  assert.throws(
    () => exportBackup({ dataRoot: work, archivePath: path.join(work, "complete.rar") }),
    /backup_container_unsupported/,
  );
  assert.throws(
    () => importBackup({ archivePath: path.join(work, "complete.rar"), targetRoot: work }),
    /backup_container_unsupported/,
  );
});

test("a missing target root is refused rather than guessed", () => {
  const work = tempDir("target");
  assert.throws(
    () => importBackup({ archivePath: path.join(work, "complete.zip") }),
    /backup_target_root_required/,
  );
});

test("the CLI documents both verbs", () => {
  const proc = spawnSync(process.execPath, [cli, "--help"], { encoding: "utf8" });
  assert.equal(proc.status, 0, proc.stderr);
  assert.match(proc.stdout, /licoup-migrate export/);
  assert.match(proc.stdout, /licoup-migrate import/);
  assert.match(proc.stdout, /--writers-stopped/);
  assert.match(proc.stdout, /--target-root/);
});

test("the CLI refuses an unsupported container without touching the data root", () => {
  const work = tempDir("cli");
  const dataRoot = path.join(work, "root");
  fs.mkdirSync(dataRoot, { recursive: true });
  fs.writeFileSync(path.join(dataRoot, "keep.txt"), "untouched");

  const proc = spawnSync(
    process.execPath,
    [cli, "export", "--archive", path.join(work, "complete.rar"), "--data-root", dataRoot],
    { encoding: "utf8" },
  );
  assert.notEqual(proc.status, 0);
  assert.match(proc.stderr, /backup_container_unsupported/);
  assert.equal(fs.readFileSync(path.join(dataRoot, "keep.txt"), "utf8"), "untouched");
  assert.equal(fs.existsSync(path.join(work, "complete.rar")), false);
});

test("the native owner round-trips a synthetic root when the client is built", (t) => {
  if (!isNativeCliAvailable()) {
    t.skip(`native CLI not compiled at ${nativeCliPath()}`);
    return;
  }
  const work = tempDir("roundtrip");
  const dataRoot = path.join(work, "root");
  fs.mkdirSync(path.join(dataRoot, "client-state", "conversations"), { recursive: true });
  fs.writeFileSync(
    path.join(dataRoot, "client-state", "conversations", "conversations.sqlite3"),
    "SQLite format 3\0synthetic",
  );
  fs.writeFileSync(
    path.join(dataRoot, "client-state", "llm-api-key-inventory.json"),
    '{"providers":["synthetic-exportable"]}',
  );

  const archive = path.join(work, "complete.tar.gz");
  const exported = exportBackup({ dataRoot, archivePath: archive, writersStopped: true });
  assert.equal(exported.status, "exported");
  assert.equal(exported.coverage, "complete");
  assert.equal(exported.container, "tar.gz");
  assert.equal(fs.existsSync(archive), true);

  const target = path.join(work, "restored");
  const imported = importBackup({ archivePath: archive, targetRoot: target });
  assert.equal(imported.status, "imported");
  assert.equal(
    fs.readFileSync(
      path.join(target, "client-state", "conversations", "conversations.sqlite3"),
      "utf8",
    ),
    "SQLite format 3\0synthetic",
  );

  // Without the writer statement the owner refuses and writes nothing.
  const refusedArchive = path.join(work, "refused.zip");
  assert.throws(
    () => exportBackup({ dataRoot, archivePath: refusedArchive, writersStopped: false }),
    /archive_writers_running/,
  );
  assert.equal(fs.existsSync(refusedArchive), false);
});
