import path from "node:path";
import fs from "node:fs";
import {
  writeJsonAtomicSync,
  readJsonSync,
  isRegularFileSync,
} from "../fs-atomic.mjs";

const DOMAIN_ID = "mobile-relay";

export function getStorePath(dataRoot) {
  return path.join(dataRoot, "client-state", "mobile-relay", "config.json");
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
  // Mirrors the native boundary: schemaVersion 0/1 are valid legacy shapes,
  // a missing key is unsupported, and anything above the current store
  // schema is newer than this tool.
  if (content.schemaVersion === undefined) {
    throw new Error(`unsupported_state_shape in ${DOMAIN_ID}: schemaVersion missing`);
  }
  const version = Number(content.schemaVersion);
  if (version === 2) {
    return { version: 1, present: true };
  }
  if (version === 0 || version === 1) {
    return { version: 0, present: true };
  }
  if (Number.isInteger(version) && version > 2) {
    throw new Error(`state_newer_than_binary in ${DOMAIN_ID}`);
  }
  throw new Error(`unsupported_state_shape in ${DOMAIN_ID}`);
}

export function forward(dataRoot, fromVer, toVer) {
  if (fromVer === 0 && toVer === 1) {
    const storePath = getStorePath(dataRoot);
    if (!fs.existsSync(storePath)) {
      return { converted: true, details: "store absent, no action required" };
    }
    // The native v0/v1 -> v2 store migration is a schemaVersion stamp; all
    // other fields carry over unchanged.
    const doc = readJsonSync(storePath) || {};
    doc.schemaVersion = 2;
    writeJsonAtomicSync(storePath, doc);
    return { converted: true, details: "upgraded mobile-relay config to schemaVersion 2" };
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
    if (doc && typeof doc === "object") {
      doc.schemaVersion = 1;
      writeJsonAtomicSync(storePath, doc);
      return { converted: true, details: "downgraded mobile-relay config to schemaVersion 1" };
    }
    return { converted: true, details: "not an object, left as is" };
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
