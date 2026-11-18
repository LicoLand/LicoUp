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

test("workspace-manifest codec treats absence as v0 and preserves on downgrade", () => {
  const root = createTempRoot();
  try {
    const codec = getCodec("workspace-manifest");
    const file = codec.getStorePath(root);

    // Absence is the only valid v0 state (CurrentOnly policy)
    assert.deepEqual(codec.probe(root), { version: 0, present: false });

    // An existing document without schemaVersion is unsupported, not legacy
    ensureDirectorySync(path.dirname(file));
    writeJsonAtomicSync(file, { workspaceId: "ws-corrupt" });
    assert.throws(() => codec.probe(root), /unsupported_state_shape/);
    fs.rmSync(file);

    // Forward on absent store is a no-op
    codec.forward(root, 0, 1);
    assert.equal(fs.existsSync(file), false);

    // Current document written by a capable client
    writeJsonAtomicSync(file, { schemaVersion: 1, workspaceId: "ws-123" });
    assert.deepEqual(codec.probe(root), { version: 1, present: true });

    // Downgrade removes the document and preserves its content
    codec.reverse(root, 1, 0);
    codec.verifyPostcondition(root, 0);
    assert.equal(fs.existsSync(file), false);

    // Re-upgrade restores the preserved content
    codec.forward(root, 0, 1);
    codec.verifyPostcondition(root, 1);
    const restored = readJsonSync(file);
    assert.equal(restored.schemaVersion, 1);
    assert.equal(restored.workspaceId, "ws-123");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("mobile-home-layout codec uses store schemaVersion 2", () => {
  const root = createTempRoot();
  try {
    const codec = getCodec("mobile-home-layout");
    const file = codec.getStorePath(root);
    ensureDirectorySync(path.dirname(file));

    assert.deepEqual(codec.probe(root), { version: 0, present: false });

    // schemaVersion 1 is not a valid current or legacy shape
    writeJsonAtomicSync(file, { schemaVersion: 1, tiles: [] });
    assert.throws(() => codec.probe(root), /unsupported_state_shape/);

    // schemaVersion 2 is current
    writeJsonAtomicSync(file, { schemaVersion: 2, tiles: ["a"] });
    assert.deepEqual(codec.probe(root), { version: 1, present: true });

    // Newer than the tool
    writeJsonAtomicSync(file, { schemaVersion: 3, tiles: [] });
    assert.throws(() => codec.probe(root), /state_newer_than_binary/);
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

    // A document without schemaVersion is unsupported, not legacy
    writeJsonAtomicSync(file, { relayEnabled: true });
    assert.throws(() => codec.probe(root), /unsupported_state_shape/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
