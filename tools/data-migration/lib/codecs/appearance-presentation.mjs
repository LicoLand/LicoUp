import path from "node:path";
import fs from "node:fs";
import {
  writeJsonAtomicSync,
  readJsonSync,
  isRegularFileSync,
} from "../fs-atomic.mjs";
import { savePreservation, loadPreservation, clearPreservation } from "../preservation.mjs";

const DOMAIN_ID = "appearance-presentation";

export function getStorePath(dataRoot) {
  return path.join(dataRoot, "client-state", "appearance-preferences.json");
}

export function probe(dataRoot) {
  const storePath = getStorePath(dataRoot);
  if (!isRegularFileSync(storePath)) {
    return { version: 0, present: false };
  }
  const content = readJsonSync(storePath);
  if (content && typeof content === "object") {
    if (content.schemaVersion === 1) {
      return { version: 1, present: true };
    }
    if (content.schemaVersion === undefined) {
      return { version: 0, present: true };
    }
  }
  throw new Error(`unsupported_state_shape in ${DOMAIN_ID}`);
}

export function forward(dataRoot, fromVer, toVer) {
  if (fromVer === 0 && toVer === 1) {
    const storePath = getStorePath(dataRoot);
    if (!fs.existsSync(storePath)) {
      return { converted: true, details: "store absent, no action required" };
    }
    const doc = readJsonSync(storePath) || {};
    doc.schemaVersion = 1;
    const preserved = loadPreservation(dataRoot, DOMAIN_ID);
    if (preserved && preserved.preservedData) {
      Object.assign(doc, preserved.preservedData);
      clearPreservation(dataRoot, DOMAIN_ID);
    }
    writeJsonAtomicSync(storePath, doc);
    return { converted: true, details: "upgraded appearance-preferences to schemaVersion 1" };
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
      delete doc.schemaVersion;
      writeJsonAtomicSync(storePath, doc);
      return { converted: true, details: "downgraded appearance-preferences by removing schemaVersion" };
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
