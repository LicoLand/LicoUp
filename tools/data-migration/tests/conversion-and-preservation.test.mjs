import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { convert } from "../lib/convert.mjs";
import { inspect } from "../lib/probe.mjs";
import {
  ensureDirectorySync,
  writeJsonAtomicSync,
  readJsonSync,
} from "../lib/fs-atomic.mjs";
import { loadPreservation } from "../lib/preservation.mjs";

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-conversion-test-"));
}

test("full bidirectional conversion with preservation and round-trip restore", () => {
  const root = createTempRoot();
  try {
    const stateDir = path.join(root, "client-state");
    ensureDirectorySync(stateDir);

    // 1. Seed legacy v0.1.0 data
    const projFile = path.join(stateDir, "agent-conversation-projections.json");
    writeJsonAtomicSync(projFile, {
      schemaVersion: 1,
      sessionsByAgent: {
        "agent-main": [
          {
            id: "sess-1",
            title: "First Conversation",
            messages: [
              { role: "user", content: "hello world" },
              { role: "assistant", content: "how can I help?" },
            ],
          },
        ],
      },
    });

    const tabFile = path.join(stateDir, "agent-tab-order.json");
    writeJsonAtomicSync(tabFile, ["agent-alpha", "agent-beta"]);

    const wsFile = path.join(root, ".licoup-workspace.json");
    writeJsonAtomicSync(wsFile, { name: "test-workspace" });

    const settingsFile = path.join(stateDir, "settings.json");
    writeJsonAtomicSync(settingsFile, { notifications: true });

    // 2. Convert to v0.3.0 (forward upgrade)
    const forwardResult = convert(root, "v0.3.0");
    assert.equal(forwardResult.status, "success");
    assert.equal(forwardResult.targetVersion, "0.3.0");
    assert.ok(forwardResult.convertedSteps.length > 0);

    // Verify v0.3.0 disk postconditions
    const updatedTab = readJsonSync(tabFile);
    assert.equal(updatedTab.schemaVersion, 1);
    assert.deepEqual(updatedTab.order, ["agent-alpha", "agent-beta"]);

    const updatedWs = readJsonSync(wsFile);
    assert.equal(updatedWs.schemaVersion, 1);

    const updatedSettings = readJsonSync(settingsFile);
    assert.equal(updatedSettings.schemaVersion, "v0.0.1:schema:definition-1");

    // Conversation store converted to SQLite
    const convDb = path.join(stateDir, "conversations", "conversations.sqlite3");
    const convMarker = path.join(stateDir, "conversations", "migration-v5.complete");
    assert.ok(fs.existsSync(convDb), "SQLite database must exist");
    assert.ok(fs.existsSync(convMarker), "Migration v5 completion marker must exist");
    assert.equal(fs.existsSync(projFile), false, "Legacy projection file must be cleaned up");

    // Verify ledger
    const ledgerPath = path.join(stateDir, "migrations", "ledger.json");
    const ledger = readJsonSync(ledgerPath);
    assert.equal(ledger.highestAdmittedProductVersion, "0.3.0");
    assert.equal(ledger.frontierId, "licoup-state-0.2.2");

    // 3. Mutate v0.3.0 store with extra feature to test preservation during downgrade
    updatedTab.customDisplayMetadata = { color: "#ff8800", pinned: true };
    writeJsonAtomicSync(tabFile, updatedTab);

    // 4. Downgrade to v0.1.0
    const reverseResult = convert(root, "v0.1.0");
    assert.equal(reverseResult.status, "success");
    assert.equal(reverseResult.targetVersion, "0.1.0");

    // Verify downgraded formats on disk
    const downgradedTab = readJsonSync(tabFile);
    assert.deepEqual(downgradedTab, ["agent-alpha", "agent-beta"]);

    const downgradedWs = readJsonSync(wsFile);
    assert.equal(downgradedWs.schemaVersion, undefined);

    const downgradedSettings = readJsonSync(settingsFile);
    assert.equal(downgradedSettings.schemaVersion, undefined);

    // Legacy projection recreated from SQLite
    assert.ok(fs.existsSync(projFile), "Legacy projection must be restored");
    const restoredProj = readJsonSync(projFile);
    assert.ok(restoredProj.sessionsByAgent);

    // Completion marker removed so v0.1.0 client can admit legacy state
    assert.equal(fs.existsSync(convMarker), false);

    // Verify preservation recorded extra tab metadata
    const preservedTab = loadPreservation(root, "agent-tab-order");
    assert.ok(preservedTab, "Preservation record must exist");
    assert.deepEqual(preservedTab.preservedData, {
      customDisplayMetadata: { color: "#ff8800", pinned: true },
    });

    // Ledger downgraded to 0.1.0 so older binary does not trip state_newer_than_binary
    const downgradedLedger = readJsonSync(ledgerPath);
    assert.equal(downgradedLedger.highestAdmittedProductVersion, "0.1.0");

    // 5. Upgrade back to v0.3.0 (round-trip test)
    const roundTripResult = convert(root, "v0.3.0");
    assert.equal(roundTripResult.status, "success");

    const roundTripTab = readJsonSync(tabFile);
    assert.equal(roundTripTab.schemaVersion, 1);
    assert.deepEqual(roundTripTab.order, ["agent-alpha", "agent-beta"]);
    assert.deepEqual(roundTripTab.customDisplayMetadata, {
      color: "#ff8800",
      pinned: true,
    });

    // Preservation record cleared after successful restore
    assert.equal(loadPreservation(root, "agent-tab-order"), null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
