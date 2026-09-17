import path from "node:path";
import fs from "node:fs";
import {
  writeJsonAtomicSync,
  readJsonSync,
  isRegularFileSync,
} from "../fs-atomic.mjs";
import { savePreservation, loadPreservation, clearPreservation } from "../preservation.mjs";

const DOMAIN_ID = "agent-tab-order";

export function getStorePath(dataRoot) {
  return path.join(dataRoot, "client-state", "agent-tab-order.json");
}

export function probe(dataRoot) {
  const storePath = getStorePath(dataRoot);
  if (!isRegularFileSync(storePath)) {
    return { version: 0, present: false };
  }
  const content = readJsonSync(storePath);
  if (Array.isArray(content)) {
    return { version: 0, present: true };
  }
  if (content && typeof content === "object" && content.schemaVersion === 1) {
    return { version: 1, present: true };
  }
  throw new Error(`unsupported_state_shape in ${DOMAIN_ID}`);
}

export function forward(dataRoot, fromVer, toVer) {
  if (fromVer === 0 && toVer === 1) {
    const storePath = getStorePath(dataRoot);
    if (!fs.existsSync(storePath)) {
      return { converted: true, details: "store absent, no action required" };
    }
    const content = readJsonSync(storePath);
    let order = [];
    if (Array.isArray(content)) {
      order = content;
    } else if (content && typeof content === "object" && Array.isArray(content.order)) {
      order = content.order;
    }

    const doc = { schemaVersion: 1, order };
    // Restore preserved extras if any
    const preserved = loadPreservation(dataRoot, DOMAIN_ID);
    if (preserved && preserved.preservedData) {
      Object.assign(doc, preserved.preservedData);
      clearPreservation(dataRoot, DOMAIN_ID);
    }
    writeJsonAtomicSync(storePath, doc);
    return { converted: true, details: "upgraded agent tab order to schemaVersion 1" };
  }
  throw new Error(`Unsupported forward migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function reverse(dataRoot, fromVer, toVer) {
  if (fromVer === 1 && toVer === 0) {
    const storePath = getStorePath(dataRoot);
    if (!fs.existsSync(storePath)) {
      return { converted: true, details: "store absent, no action required" };
    }
    const content = readJsonSync(storePath);
    if (content && typeof content === "object" && !Array.isArray(content)) {
      const order = Array.isArray(content.order) ? content.order : [];
      const { schemaVersion: _s, order: _o, ...extra } = content;
      if (Object.keys(extra).length > 0) {
        savePreservation(dataRoot, DOMAIN_ID, fromVer, toVer, extra, "Preserved non-array metadata during downgrade");
      }
      writeJsonAtomicSync(storePath, order);
      return { converted: true, details: "downgraded agent tab order to raw array" };
    }
    return { converted: true, details: "already in array format" };
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
