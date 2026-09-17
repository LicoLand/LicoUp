import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { inspect } from "../lib/probe.mjs";
import { plan } from "../lib/plan.mjs";
import { ensureDirectorySync, writeJsonAtomicSync } from "../lib/fs-atomic.mjs";

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-plan-test-"));
}

test("inspect returns clean report on empty data root", () => {
  const root = createTempRoot();
  try {
    const report = inspect(root);
    assert.equal(report.ledger.present, false);
    assert.equal(report.hasPendingJournal, false);
    assert.equal(report.preservations.length, 0);

    for (const [dId, info] of Object.entries(report.domains)) {
      assert.equal(info.storePresent, false);
      assert.equal(info.storeVersion, 0);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("plan computes forward steps from empty root to latest", () => {
  const root = createTempRoot();
  try {
    const p = plan(root, "latest");
    assert.equal(p.direction, "upgrade");
    assert.equal(p.isNoOp, false);
    assert.ok(p.steps.length > 0);
    assert.equal(p.targetVersion, "0.3.0");

    // Adaptive flywheel has 2 steps from 0 to 2
    const flywheelSteps = p.steps.filter((s) => s.domainId === "adaptive-flywheel");
    assert.equal(flywheelSteps.length, 2);
    assert.equal(flywheelSteps[0].fromVersion, 0);
    assert.equal(flywheelSteps[0].toVersion, 1);
    assert.equal(flywheelSteps[1].fromVersion, 1);
    assert.equal(flywheelSteps[1].toVersion, 2);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("plan computes reverse steps from current root to legacy v0.1.0", () => {
  const root = createTempRoot();
  try {
    // Populate root with v0.3.0 stores
    const stateDir = path.join(root, "client-state");
    ensureDirectorySync(stateDir);

    writeJsonAtomicSync(path.join(stateDir, "agent-tab-order.json"), {
      schemaVersion: 1,
      order: ["agent-1"],
    });
    writeJsonAtomicSync(path.join(stateDir, "appearance-preferences.json"), {
      schemaVersion: 1,
      theme: "dark",
    });

    const p = plan(root, "v0.1.0");
    assert.equal(p.direction, "downgrade");
    assert.equal(p.targetVersion, "0.1.0");
    assert.ok(p.steps.length > 0);

    const tabStep = p.steps.find((s) => s.domainId === "agent-tab-order");
    assert.ok(tabStep);
    assert.equal(tabStep.fromVersion, 1);
    assert.equal(tabStep.toVersion, 0);

    assert.ok(p.preservationsPlanned.length > 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("plan refuses to convert stores the probe rejects as unsupported", () => {
  const root = createTempRoot();
  try {
    // An unversioned workspace manifest is unsupported shape (CurrentOnly),
    // never a legacy v0 document to be stamped.
    writeJsonAtomicSync(path.join(root, ".licoup-workspace.json"), { name: "corrupt" });
    assert.throws(() => plan(root, "v0.3.0"), /unsupported_state_shape/);
    assert.throws(() => plan(root, "v0.1.0"), /unsupported_state_shape/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
