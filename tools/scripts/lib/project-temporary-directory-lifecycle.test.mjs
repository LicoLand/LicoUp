import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  ProjectTemporaryDirectoryLifecycleError,
  removeCurrentProjectTemporaryDirectory,
  retireInactiveProjectTemporaryDirectories,
} from "./project-temporary-directory-lifecycle.mjs";

const uuid = "12345678-1234-4123-8123-123456789abc";

function runName(pid, timestamp = 1) {
  return `run-${pid}-${timestamp}-${uuid}`;
}

function parseRunOwnerPid(name) {
  const match = /^run-([1-9]\d*)-([1-9]\d*)-([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/u
    .exec(name);
  if (!match) return null;
  const pid = Number(match[1]);
  return Number.isSafeInteger(pid) ? pid : null;
}

function fixture() {
  return mkdtempSync(path.join(os.tmpdir(), "lico-temp-lifecycle-test-"));
}

function directory(root, name) {
  const target = path.join(root, name);
  mkdirSync(target);
  return target;
}

function lifecycleReason(operation, expected) {
  assert.throws(operation, (error) => {
    assert.ok(error instanceof ProjectTemporaryDirectoryLifecycleError);
    assert.equal(error.reason, expected);
    assert.equal(error.message.includes(path.sep), false);
    return true;
  });
}

test("retires only exact dead managed directories", () => {
  const root = fixture();
  try {
    const dead = runName(101);
    const live = runName(102);
    const current = runName(103);
    for (const name of [dead, live, current, "run-101-near-match", "cache"]) {
      directory(root, name);
    }
    const result = retireInactiveProjectTemporaryDirectories({
      root,
      parseOwnerPid: parseRunOwnerPid,
      currentNames: [current],
      isProcessAlive: (pid) => pid === 102,
    });
    assert.deepEqual(result, { scanned: 3, removed: 1 });
    assert.equal(existsSync(path.join(root, dead)), false);
    for (const name of [live, current, "run-101-near-match", "cache"]) {
      assert.equal(existsSync(path.join(root, name)), true, name);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("matching symlinks and symlink roots fail closed", () => {
  const root = fixture();
  const external = fixture();
  const rootLink = `${root}-link`;
  try {
    symlinkSync(external, path.join(root, runName(201)));
    lifecycleReason(
      () => retireInactiveProjectTemporaryDirectories({
        root,
        parseOwnerPid: parseRunOwnerPid,
        isProcessAlive: () => false,
      }),
      "temporary_directory_entry_invalid",
    );
    assert.equal(existsSync(external), true);

    symlinkSync(root, rootLink);
    lifecycleReason(
      () => retireInactiveProjectTemporaryDirectories({
        root: rootLink,
        parseOwnerPid: parseRunOwnerPid,
        isProcessAlive: () => false,
      }),
      "temporary_directory_root_invalid",
    );
  } finally {
    rmSync(rootLink, { force: true });
    rmSync(root, { recursive: true, force: true });
    rmSync(external, { recursive: true, force: true });
  }
});

test("ambiguous liveness and removal failures are typed", () => {
  const root = fixture();
  try {
    directory(root, runName(301));
    lifecycleReason(
      () => retireInactiveProjectTemporaryDirectories({
        root,
        parseOwnerPid: parseRunOwnerPid,
        isProcessAlive: () => null,
      }),
      "temporary_directory_liveness_unknown",
    );
    lifecycleReason(
      () => retireInactiveProjectTemporaryDirectories({
        root,
        parseOwnerPid: parseRunOwnerPid,
        isProcessAlive: () => false,
        removeDirectory: () => {
          throw new Error("synthetic removal failure");
        },
      }),
      "temporary_directory_removal_failed",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("current-run finalization removes only its exact owned directory", () => {
  const root = fixture();
  try {
    const current = runName(401);
    const sibling = runName(402);
    directory(root, current);
    directory(root, sibling);
    assert.equal(removeCurrentProjectTemporaryDirectory({
      root,
      name: current,
      parseOwnerPid: parseRunOwnerPid,
      expectedPid: 401,
    }), true);
    assert.equal(existsSync(path.join(root, current)), false);
    assert.equal(existsSync(path.join(root, sibling)), true);
    lifecycleReason(
      () => removeCurrentProjectTemporaryDirectory({
        root,
        name: sibling,
        parseOwnerPid: parseRunOwnerPid,
        expectedPid: 999,
      }),
      "temporary_directory_name_invalid",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
