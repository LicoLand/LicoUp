import path from "node:path";
import fs from "node:fs";
import {
  writeJsonAtomicSync,
  readJsonSync,
  isRegularFileSync,
} from "../fs-atomic.mjs";

const DOMAIN_ID = "client-state";
const STATE_SCHEMA_VERSION = "v0.0.1:schema:definition-1";

export const COLLECTIONS = [
  "settings",
  "targets",
  "target-discovery-cache",
  "pairings",
  "skills",
  "pins",
  "identities",
  "conversation-archive-profiles",
  "agent-usage-reports",
  "provider-quota-snapshots",
  "skill-usage",
  "collaboration-plugins",
  "local-server-assemblies",
  "local-server-assembly-cleanup",
  "local-server-assembly-transaction",
  "mcp-install-transactions",
];

export function getCollectionPath(dataRoot, collection) {
  return path.join(dataRoot, "client-state", `${collection}.json`);
}

export function probe(dataRoot) {
  let found = false;
  let legacy = false;

  for (const collection of COLLECTIONS) {
    const file = getCollectionPath(dataRoot, collection);
    if (!isRegularFileSync(file)) {
      continue;
    }
    found = true;
    const doc = readJsonSync(file);
    if (!doc || typeof doc !== "object") {
      throw new Error(`unsupported_state_shape in collection ${collection}`);
    }
    if (doc.schemaVersion === STATE_SCHEMA_VERSION) {
      // current
    } else if (doc.schemaVersion === undefined) {
      legacy = true;
    } else {
      throw new Error(`unsupported_state_shape: unexpected schema in ${collection}`);
    }
  }

  return {
    version: found && !legacy ? 1 : 0,
    present: found,
  };
}

export function forward(dataRoot, fromVer, toVer) {
  if (fromVer === 0 && toVer === 1) {
    let count = 0;
    for (const collection of COLLECTIONS) {
      const file = getCollectionPath(dataRoot, collection);
      if (!fs.existsSync(file)) {
        continue;
      }
      const doc = readJsonSync(file) || {};
      doc.schemaVersion = STATE_SCHEMA_VERSION;
      if (!doc.collection) {
        doc.collection = collection;
      }
      writeJsonAtomicSync(file, doc);
      count++;
    }
    return { converted: true, details: `upgraded ${count} collections to ${STATE_SCHEMA_VERSION}` };
  }
  throw new Error(`Unsupported forward migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function reverse(dataRoot, fromVer, toVer) {
  if (fromVer === 1 && toVer === 0) {
    let count = 0;
    for (const collection of COLLECTIONS) {
      const file = getCollectionPath(dataRoot, collection);
      if (!fs.existsSync(file)) {
        continue;
      }
      const doc = readJsonSync(file);
      if (doc && typeof doc === "object") {
        delete doc.schemaVersion;
        writeJsonAtomicSync(file, doc);
        count++;
      }
    }
    return { converted: true, details: `downgraded ${count} collections by removing schemaVersion` };
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
