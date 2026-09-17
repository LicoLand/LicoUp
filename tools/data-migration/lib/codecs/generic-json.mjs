import path from "node:path";
import fs from "node:fs";
import {
  writeJsonAtomicSync,
  readJsonSync,
  isRegularFileSync,
} from "../fs-atomic.mjs";
import { savePreservation, loadPreservation, clearPreservation } from "../preservation.mjs";

const DOMAIN_CONFIGS = {
  "agent-tool-allowlist": {
    relativePath: path.join("client-state", "agent-tool-allowlists.json"),
    targetSchemaVersion: 1,
  },
  "current-view": {
    relativePath: path.join("client-state", "current-client-view.json"),
    targetSchemaVersion: 1,
  },
  "mobile-home-layout": {
    relativePath: path.join("client-state", "mobile-home-layout.json"),
    targetSchemaVersion: 1,
  },
  "skill-hub-preferences": {
    relativePath: path.join("client-state", "skill-hub-preferences.json"),
    targetSchemaVersion: 1,
  },
};

export function createGenericJsonCodec(domainId) {
  const cfg = DOMAIN_CONFIGS[domainId];
  if (!cfg) {
    throw new Error(`No generic JSON config for domain ${domainId}`);
  }

  function getStorePath(dataRoot) {
    return path.join(dataRoot, cfg.relativePath);
  }

  function probe(dataRoot) {
    const storePath = getStorePath(dataRoot);
    if (!isRegularFileSync(storePath)) {
      return { version: 0, present: false };
    }
    const content = readJsonSync(storePath);
    if (content && typeof content === "object") {
      const version = Number(content.schemaVersion);
      if (version === cfg.targetSchemaVersion || (domainId === "mobile-home-layout" && version >= 1)) {
        return { version: 1, present: true };
      }
      if (content.schemaVersion === undefined) {
        return { version: 0, present: true };
      }
    }
    throw new Error(`unsupported_state_shape in ${domainId}`);
  }

  function forward(dataRoot, fromVer, toVer) {
    if (fromVer === 0 && toVer === 1) {
      const storePath = getStorePath(dataRoot);
      if (!fs.existsSync(storePath)) {
        return { converted: true, details: "store absent, no action required" };
      }
      const doc = readJsonSync(storePath) || {};
      doc.schemaVersion = cfg.targetSchemaVersion;
      const preserved = loadPreservation(dataRoot, domainId);
      if (preserved && preserved.preservedData) {
        Object.assign(doc, preserved.preservedData);
        clearPreservation(dataRoot, domainId);
      }
      writeJsonAtomicSync(storePath, doc);
      return { converted: true, details: `upgraded ${domainId} to schemaVersion ${cfg.targetSchemaVersion}` };
    }
    throw new Error(`Unsupported forward migration edge for ${domainId}: ${fromVer} -> ${toVer}`);
  }

  function reverse(dataRoot, fromVer, toVer) {
    if (fromVer === 1 && toVer === 0) {
      const storePath = getStorePath(dataRoot);
      if (!fs.existsSync(storePath)) {
        return { converted: true, details: "store absent, no action required" };
      }
      const doc = readJsonSync(storePath);
      if (doc && typeof doc === "object") {
        delete doc.schemaVersion;
        writeJsonAtomicSync(storePath, doc);
        return { converted: true, details: `downgraded ${domainId} by removing schemaVersion` };
      }
      return { converted: true, details: "not an object, left as is" };
    }
    throw new Error(`Unsupported reverse migration edge for ${domainId}: ${fromVer} -> ${toVer}`);
  }

  function verifyPostcondition(dataRoot, targetVersion) {
    const result = probe(dataRoot);
    if (result.present && result.version !== targetVersion) {
      throw new Error(`migration_postcondition_failed: ${domainId} expected version ${targetVersion}, observed ${result.version}`);
    }
    return true;
  }

  return {
    domainId,
    getStorePath,
    probe,
    forward,
    reverse,
    verifyPostcondition,
  };
}
