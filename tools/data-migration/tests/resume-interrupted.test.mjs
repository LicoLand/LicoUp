import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { resume } from "../lib/resume.mjs";
import { convert } from "../lib/convert.mjs";
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

    // Seed data (raw array tab order is the valid legacy shape)
    writeJsonAtomicSync(path.join(stateDir, "agent-tab-order.json"), ["agent-1"]);

    // Compute a plan towards v0.3.0
    const p = plan(root, "v0.3.0");
    initJournal(root, p);

    // Simulate partial execution: commit the agent-tab-order step manually
    const tabCodec = getCodec("agent-tab-order");
    tabCodec.forward(root, 0, 1);
    markStepCommitted(root, "agent-tab-order", 1);

    // Confirm journal is in progress
    const beforeResumeJournal = openJournal(root);
    assert.equal(beforeResumeJournal.status, "in_progress");
    assert.equal(beforeResumeJournal.domains["agent-tab-order"].status, "committed");
    assert.equal(beforeResumeJournal.domains["workspace-manifest"].status, "pending");

    // Call resume
    const result = resume(root, { writersStopped: true });
    assert.equal(result.status, "success");

    // Agent tab order should have been detected as already committed
    const tabResumed = result.resumedSteps.find((s) => s.domainId === "agent-tab-order");
    assert.ok(tabResumed);
    assert.equal(tabResumed.status, "already_committed");

    // Workspace manifest (absent store) should have been resumed and committed
    const wsResumed = result.resumedSteps.find((s) => s.domainId === "workspace-manifest");
    assert.ok(wsResumed);
    assert.equal(wsResumed.status, "resumed_and_committed");

    // Credential custody stays pending authorization, marker untouched
    assert.ok(result.pendingAuthorizationDomains.includes("gateway-credential-custody"));
    assert.equal(
      fs.existsSync(path.join(stateDir, "migrations", "domain-state", "gateway-credential-custody.json")),
      false
    );

    // Journal must be finished and removed
    assert.equal(openJournal(root), null);

    // Ledger should be updated to target version
    const ledger = readJsonSync(path.join(stateDir, "migrations", "ledger.json"));
    assert.equal(ledger.highestAdmittedProductVersion, "0.3.0");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("convert refuses to run over an interrupted migration journal", () => {
  const root = createTempRoot();
  try {
    const stateDir = path.join(root, "client-state");
    ensureDirectorySync(stateDir);
    writeJsonAtomicSync(path.join(stateDir, "agent-tab-order.json"), ["agent-1"]);

    const p = plan(root, "v0.3.0");
    initJournal(root, p);

    assert.throws(() => convert(root, "v0.3.0", { writersStopped: true }), /migration_interrupted/);

    // Resume clears the interrupted state; a later convert applies nothing
    // new (credential custody stays pending authorization by design)
    const resumed = resume(root, { writersStopped: true });
    assert.equal(resumed.status, "success");
    const second = convert(root, "v0.3.0", { writersStopped: true });
    assert.equal(second.status, "success");
    assert.equal(second.convertedSteps.length, 0);
    assert.ok(second.pendingAuthorizationDomains.includes("gateway-credential-custody"));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
