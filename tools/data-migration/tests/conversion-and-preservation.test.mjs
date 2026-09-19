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

    const settingsFile = path.join(stateDir, "settings.json");
    writeJsonAtomicSync(settingsFile, { notifications: true });

    // 2. Convert to v0.3.0 (forward upgrade)
    const forwardResult = convert(root, "v0.3.0");
    assert.equal(forwardResult.status, "success");
    assert.equal(forwardResult.targetVersion, "0.3.0");
    assert.ok(forwardResult.convertedSteps.length > 0);

    // Credential custody is never fabricated by the tool; it is reported as
    // pending authorization like the native admission boundary does.
    assert.ok(forwardResult.pendingAuthorizationDomains.includes("gateway-credential-custody"));
    const gatewayMarker = path.join(stateDir, "migrations", "domain-state", "gateway-credential-custody.json");
    assert.equal(fs.existsSync(gatewayMarker), false);

    // Verify v0.3.0 disk postconditions
    const updatedTab = readJsonSync(tabFile);
    assert.equal(updatedTab.schemaVersion, 1);
    assert.deepEqual(updatedTab.order, ["agent-alpha", "agent-beta"]);

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

    // A current-client workspace manifest (CurrentOnly domain: no legacy form)
    const wsFile = path.join(root, ".licoup-workspace.json");
    writeJsonAtomicSync(wsFile, { schemaVersion: 1, name: "test-workspace" });

    // 4. Downgrade to v0.1.0
    const reverseResult = convert(root, "v0.1.0");
    assert.equal(reverseResult.status, "success");
    assert.equal(reverseResult.targetVersion, "0.1.0");

    // Verify downgraded formats on disk
    const downgradedTab = readJsonSync(tabFile);
    assert.deepEqual(downgradedTab, ["agent-alpha", "agent-beta"]);

    // CurrentOnly domains have no legacy on-disk form: the document is
    // removed and its content preserved in the recovery extension
    assert.equal(fs.existsSync(wsFile), false);
    const preservedWs = loadPreservation(root, "workspace-manifest");
    assert.ok(preservedWs, "Workspace manifest preservation record must exist");
    assert.deepEqual(preservedWs.preservedData, { name: "test-workspace" });

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

    // Workspace manifest restored from the preservation extension
    const roundTripWs = readJsonSync(wsFile);
    assert.equal(roundTripWs.schemaVersion, 1);
    assert.equal(roundTripWs.name, "test-workspace");
    assert.equal(loadPreservation(root, "workspace-manifest"), null);

    // Preservation record cleared after successful restore
    assert.equal(loadPreservation(root, "agent-tab-order"), null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
