import path from "node:path";
import fs from "node:fs";
import {
  writeJsonAtomicSync,
  readJsonSync,
  isRegularFileSync,
  removeFileSync,
} from "../fs-atomic.mjs";
import { savePreservation, loadPreservation, clearPreservation } from "../preservation.mjs";

const DOMAIN_ID = "workspace-manifest";

// Mirrors the native boundary: probe_json_schema(..., 1, CurrentOnly). An
// existing manifest without schemaVersion is unsupported shape, not legacy;
// version 0 means "store absent". Downgrade removes the document and keeps
// its content in the preservation extension for re-upgrade.
export function getStorePath(dataRoot) {
  return path.join(dataRoot, ".licoup-workspace.json");
}

export function probe(dataRoot) {
  const storePath = getStorePath(dataRoot);
  if (!isRegularFileSync(storePath)) {
    return { version: 0, present: false };
  }
  const content = readJsonSync(storePath);
  if (!content || typeof content !== "object" || Array.isArray(content)) {
    throw new Error(`unsupported_state_shape in ${DOMAIN_ID}`);
  }
  if (content.schemaVersion === undefined) {
    throw new Error(`unsupported_state_shape in ${DOMAIN_ID}: schemaVersion missing`);
  }
  const version = Number(content.schemaVersion);
  if (version === 1) {
    return { version: 1, present: true };
  }
  if (Number.isInteger(version) && version > 1) {
    throw new Error(`state_newer_than_binary in ${DOMAIN_ID}`);
  }
  throw new Error(`unsupported_state_shape in ${DOMAIN_ID}`);
}

export function forward(dataRoot, fromVer, toVer) {
  if (fromVer === 0 && toVer === 1) {
    const storePath = getStorePath(dataRoot);
    if (!fs.existsSync(storePath)) {
      const preserved = loadPreservation(dataRoot, DOMAIN_ID);
      if (preserved && preserved.preservedData && Object.keys(preserved.preservedData).length > 0) {
        const doc = { ...preserved.preservedData, schemaVersion: 1 };
        writeJsonAtomicSync(storePath, doc);
        clearPreservation(dataRoot, DOMAIN_ID);
        return { converted: true, details: "restored workspace manifest from preservation extension" };
      }
      return { converted: true, details: "store absent, no action required" };
    }
    return { converted: true, details: "store already current" };
  }
  throw new Error(`Unsupported forward migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function reverse(dataRoot, fromVer, toVer) {
  if (fromVer === 1 && toVer === 0) {
    const storePath = getStorePath(dataRoot);
    if (!fs.existsSync(storePath)) {
      return { converted: true, details: "store absent, no action required" };
    }
    const doc = readJsonSync(storePath);
    if (doc && typeof doc === "object" && !Array.isArray(doc)) {
      const { schemaVersion: _s, ...rest } = doc;
      if (Object.keys(rest).length > 0) {
        savePreservation(dataRoot, DOMAIN_ID, fromVer, toVer, rest, "Preserved workspace manifest removed during downgrade (no legacy on-disk form)");
      }
      removeFileSync(storePath);
      return { converted: true, details: "removed workspace manifest; contents preserved in recovery extension" };
    }
    removeFileSync(storePath);
    return { converted: true, details: "removed unreadable store document" };
  }
  throw new Error(`Unsupported reverse migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function verifyPostcondition(dataRoot, targetVersion) {
  const result = probe(dataRoot);
  if (result.present && result.version !== targetVersion) {
    throw new Error(`migration_postcondition_failed: ${DOMAIN_ID} expected version ${targetVersion}, observed ${result.version}`);
  }
  return true;
}
