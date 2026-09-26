import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { RootLock, withRootLock } from "../lib/lock.mjs";
import { convert } from "../lib/convert.mjs";
import { resume } from "../lib/resume.mjs";
import { initJournal, journalPath, openJournal } from "../lib/journal.mjs";
import { plan } from "../lib/plan.mjs";
import { readJsonSync } from "../lib/fs-atomic.mjs";

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-lock-test-"));
}

test("root lock is exclusive between holders and released on completion", () => {
  const root = createTempRoot();
  try {
    const first = new RootLock(root).acquire();
    // A second holder is refused while the first holds the lock
    assert.throws(() => new RootLock(root).acquire(), /migration_lock_unavailable/);
    first.release();
    // After release, acquisition succeeds again
    const second = new RootLock(root).acquire();
    second.release();
    assert.equal(fs.existsSync(path.join(root, "client-state", "migrations", "data-migration.lock")), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("withRootLock releases the lock when the callback throws", () => {
  const root = createTempRoot();
  try {
    assert.throws(() => withRootLock(root, () => { throw new Error("boom"); }), /boom/);
    const again = new RootLock(root).acquire();
    again.release();
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("stale lock from a dead process is reclaimed", () => {
  const root = createTempRoot();
  try {
    const lockDir = path.join(root, "client-state", "migrations");
    fs.mkdirSync(lockDir, { recursive: true });
    // A finished child's pid is guaranteed to be dead
    const dead = spawnSync("node", ["-e", ""]);
    fs.writeFileSync(
      path.join(lockDir, "data-migration.lock"),
      JSON.stringify({ pid: dead.pid, acquiredAt: new Date().toISOString() }) + "\n"
    );
    const lock = new RootLock(root).acquire();
    lock.release();
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("tool lock never touches the native admission.lock file", () => {
  const root = createTempRoot();
  try {
    const lockDir = path.join(root, "client-state", "migrations");
    fs.mkdirSync(lockDir, { recursive: true });
    const admissionLock = path.join(lockDir, "admission.lock");
    fs.writeFileSync(admissionLock, "native-lock-content\n");
    const result = withRootLock(root, () => "ok");
    assert.equal(result, "ok");
    assert.equal(fs.readFileSync(admissionLock, "utf8"), "native-lock-content\n");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a real conversion needs the writers-stopped confirmation and writes nothing without it", () => {
  const root = createTempRoot();
  try {
    const stateDir = path.join(root, "client-state");
    fs.mkdirSync(stateDir, { recursive: true });
    fs.writeFileSync(
      path.join(stateDir, "agent-tab-order.json"),
      JSON.stringify(["agent-1"]),
      "utf8",
    );

    // The tool's lock only excludes other runs of this tool. A program that
    // never heard of it is the operator's responsibility to stop, so a real
    // conversion refuses until that statement is made.
    assert.throws(() => convert(root, "v0.3.0"), /maintenance_confirmation_required/);
    assert.throws(
      () => convert(root, "v0.3.0", { writersStopped: false }),
      /maintenance_confirmation_required/,
    );
    assert.equal(
      fs.existsSync(journalPath(root)),
      false,
      "a refused conversion must not have started a journal",
    );
    assert.equal(
      fs.existsSync(path.join(stateDir, "migrations", "ledger.json")),
      false,
      "a refused conversion must not have written a ledger",
    );

    // The preview path is read-only and needs no confirmation.
    assert.equal(convert(root, "v0.3.0", { dryRun: true }).status, "dry_run");

    // Resume is a write path too.
    initJournal(root, plan(root, "v0.3.0"), {
      maintenanceConfirmedAt: new Date().toISOString(),
    });
    assert.throws(() => resume(root), /maintenance_confirmation_required/);
    assert.ok(openJournal(root), "a refused resume leaves the journal for a confirmed one");

    const resumed = resume(root, { writersStopped: true });
    assert.equal(resumed.status, "success");
    assert.equal(openJournal(root), null, "a confirmed resume finishes the journal");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the journal records the operator's maintenance confirmation", () => {
  const root = createTempRoot();
  try {
    const confirmedAt = new Date().toISOString();
    initJournal(root, plan(root, "v0.3.0"), { maintenanceConfirmedAt: confirmedAt });
    const journal = readJsonSync(journalPath(root));
    assert.equal(journal.maintenanceConfirmedAt, confirmedAt);
    assert.equal(journal.status, "in_progress");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
