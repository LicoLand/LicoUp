import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { resume } from "../lib/resume.mjs";
import { initJournal, markStepCommitted, openJournal } from "../lib/journal.mjs";
import { plan } from "../lib/plan.mjs";
import { ensureDirectorySync, writeJsonAtomicSync, readJsonSync } from "../lib/fs-atomic.mjs";
import { getCodec } from "../lib/codecs/index.mjs";

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-resume-test-"));
}

test("resume continues an interrupted conversion without repeating committed steps", () => {
  const root = createTempRoot();
  try {
    const stateDir = path.join(root, "client-state");
    ensureDirectorySync(stateDir);

    // Seed data
    writeJsonAtomicSync(path.join(stateDir, "agent-tab-order.json"), ["agent-1"]);
    writeJsonAtomicSync(path.join(root, ".licoup-workspace.json"), { name: "ws" });

    // Compute a plan towards v0.3.0
    const p = plan(root, "v0.3.0");
    const journal = initJournal(root, p);

    // Simulate partial execution: commit the workspace-manifest step manually
    const wsCodec = getCodec("workspace-manifest");
    wsCodec.forward(root, 0, 1);
    markStepCommitted(root, "workspace-manifest", 1);

    // Confirm journal is in progress
    const beforeResumeJournal = openJournal(root);
    assert.equal(beforeResumeJournal.status, "in_progress");
    assert.equal(beforeResumeJournal.domains["workspace-manifest"].status, "committed");
    assert.equal(beforeResumeJournal.domains["agent-tab-order"].status, "pending");

    // Call resume
    const result = resume(root);
    assert.equal(result.status, "success");

    // Workspace manifest should have been detected as already committed
    const wsResumed = result.resumedSteps.find((s) => s.domainId === "workspace-manifest");
    assert.ok(wsResumed);
    assert.equal(wsResumed.status, "already_committed");

    // Agent tab order should have been resumed and committed
    const tabResumed = result.resumedSteps.find((s) => s.domainId === "agent-tab-order");
    assert.ok(tabResumed);
    assert.equal(tabResumed.status, "resumed_and_committed");

    // Journal must be finished and removed
    assert.equal(openJournal(root), null);

    // Ledger should be updated to target version
    const ledger = readJsonSync(path.join(stateDir, "migrations", "ledger.json"));
    assert.equal(ledger.highestAdmittedProductVersion, "0.3.0");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
