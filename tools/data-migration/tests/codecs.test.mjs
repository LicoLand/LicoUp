import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { getCodec } from "../lib/codecs/index.mjs";
import { ensureDirectorySync, writeJsonAtomicSync, readJsonSync } from "../lib/fs-atomic.mjs";

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-codec-test-"));
}

test("agent-tab-order bidirectional codec converts array and object", () => {
  const root = createTempRoot();
  try {
    const codec = getCodec("agent-tab-order");
    const file = codec.getStorePath(root);
    ensureDirectorySync(path.dirname(file));

    // Absence
    assert.deepEqual(codec.probe(root), { version: 0, present: false });

    // Legacy v0 array
    writeJsonAtomicSync(file, ["agent-a", "agent-b"]);
    assert.deepEqual(codec.probe(root), { version: 0, present: true });

    // Forward to v1
    codec.forward(root, 0, 1);
    codec.verifyPostcondition(root, 1);
    const v1Doc = readJsonSync(file);
    assert.equal(v1Doc.schemaVersion, 1);
    assert.deepEqual(v1Doc.order, ["agent-a", "agent-b"]);

    // Add extra property to test preservation
    v1Doc.extraConfig = { active: true };
    writeJsonAtomicSync(file, v1Doc);

    // Reverse to v0
    codec.reverse(root, 1, 0);
    codec.verifyPostcondition(root, 0);
    const v0Doc = readJsonSync(file);
    assert.deepEqual(v0Doc, ["agent-a", "agent-b"]);

    // Forward back to v1 (restores preserved extra)
    codec.forward(root, 0, 1);
    const restoredDoc = readJsonSync(file);
    assert.equal(restoredDoc.schemaVersion, 1);
    assert.deepEqual(restoredDoc.order, ["agent-a", "agent-b"]);
    assert.deepEqual(restoredDoc.extraConfig, { active: true });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("appearance-presentation bidirectional codec adds and removes schemaVersion", () => {
  const root = createTempRoot();
  try {
    const codec = getCodec("appearance-presentation");
    const file = codec.getStorePath(root);
    ensureDirectorySync(path.dirname(file));

    writeJsonAtomicSync(file, { theme: "dark" });
    assert.deepEqual(codec.probe(root), { version: 0, present: true });

    codec.forward(root, 0, 1);
    codec.verifyPostcondition(root, 1);
    const doc1 = readJsonSync(file);
    assert.equal(doc1.schemaVersion, 1);
    assert.equal(doc1.theme, "dark");

    codec.reverse(root, 1, 0);
    codec.verifyPostcondition(root, 0);
    const doc0 = readJsonSync(file);
    assert.equal(doc0.schemaVersion, undefined);
    assert.equal(doc0.theme, "dark");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("workspace-manifest bidirectional codec adds and removes schemaVersion", () => {
  const root = createTempRoot();
  try {
    const codec = getCodec("workspace-manifest");
    const file = codec.getStorePath(root);
    ensureDirectorySync(path.dirname(file));

    writeJsonAtomicSync(file, { workspaceId: "ws-123" });
    assert.deepEqual(codec.probe(root), { version: 0, present: true });

    codec.forward(root, 0, 1);
    codec.verifyPostcondition(root, 1);
    assert.equal(readJsonSync(file).schemaVersion, 1);

    codec.reverse(root, 1, 0);
    codec.verifyPostcondition(root, 0);
    assert.equal(readJsonSync(file).schemaVersion, undefined);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("client-state collections bidirectional codec handles collection objects", () => {
  const root = createTempRoot();
  try {
    const codec = getCodec("client-state");
    const settingsPath = codec.getCollectionPath(root, "settings");
    ensureDirectorySync(path.dirname(settingsPath));

    writeJsonAtomicSync(settingsPath, { autoSave: true });
    assert.deepEqual(codec.probe(root), { version: 0, present: true });

    codec.forward(root, 0, 1);
    codec.verifyPostcondition(root, 1);
    const doc1 = readJsonSync(settingsPath);
    assert.equal(doc1.schemaVersion, "v0.0.1:schema:definition-1");
    assert.equal(doc1.collection, "settings");
    assert.equal(doc1.autoSave, true);

    codec.reverse(root, 1, 0);
    codec.verifyPostcondition(root, 0);
    const doc0 = readJsonSync(settingsPath);
    assert.equal(doc0.schemaVersion, undefined);
    assert.equal(doc0.autoSave, true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("mobile-relay bidirectional codec preserves v2 station fields", () => {
  const root = createTempRoot();
  try {
    const codec = getCodec("mobile-relay");
    const file = codec.getStorePath(root);
    ensureDirectorySync(path.dirname(file));

    writeJsonAtomicSync(file, { schemaVersion: 1, relayEnabled: true });
    assert.deepEqual(codec.probe(root), { version: 0, present: true });

    codec.forward(root, 0, 1);
    codec.verifyPostcondition(root, 1);
    const doc1 = readJsonSync(file);
    assert.equal(doc1.schemaVersion, 2);

    doc1.stationBaseUrl = "https://station.local";
    writeJsonAtomicSync(file, doc1);

    codec.reverse(root, 1, 0);
    codec.verifyPostcondition(root, 0);
    const doc0 = readJsonSync(file);
    assert.equal(doc0.schemaVersion, 1);
    assert.equal(doc0.relayEnabled, true);
    assert.equal(doc0.stationBaseUrl, "https://station.local");

    codec.forward(root, 0, 1);
    const docRestored = readJsonSync(file);
    assert.equal(docRestored.schemaVersion, 2);
    assert.equal(docRestored.stationBaseUrl, "https://station.local");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
