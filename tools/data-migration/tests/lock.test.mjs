import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { RootLock, withRootLock } from "../lib/lock.mjs";

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
