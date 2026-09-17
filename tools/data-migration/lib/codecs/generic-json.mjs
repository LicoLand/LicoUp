import path from "node:path";
import fs from "node:fs";
import {
  writeJsonAtomicSync,
  readJsonSync,
  isRegularFileSync,
  removeFileSync,
} from "../fs-atomic.mjs";
import { savePreservation, loadPreservation, clearPreservation } from "../preservation.mjs";

// Store-level schema versions mirror the native migration boundary
// (probe_json_schema/migrate_json_schema in client_state_migration.rs). These
// domains follow the CurrentOnly policy: an existing document without a
// schemaVersion is not admittable legacy state, it is unsupported shape.
// Version 0 therefore means "store absent"; downgrade removes the document
// and keeps its content in the preservation extension for re-upgrade.
const DOMAIN_CONFIGS = {
  "agent-tool-allowlist": {
    relativePath: path.join("client-state", "agent-tool-allowlists.json"),
    storeSchemaVersion: 1,
  },
  "current-view": {
    relativePath: path.join("client-state", "current-client-view.json"),
    storeSchemaVersion: 1,
  },
  "mobile-home-layout": {
    relativePath: path.join("client-state", "mobile-home-layout.json"),
    storeSchemaVersion: 2,
  },
  "skill-hub-preferences": {
    relativePath: path.join("client-state", "skill-hub-preferences.json"),
    storeSchemaVersion: 1,
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
    if (!content || typeof content !== "object" || Array.isArray(content)) {
      throw new Error(`unsupported_state_shape in ${domainId}`);
    }
    const version = Number(content.schemaVersion);
    if (content.schemaVersion === undefined) {
      throw new Error(`unsupported_state_shape in ${domainId}: schemaVersion missing`);
    }
    if (version === cfg.storeSchemaVersion) {
      return { version: 1, present: true };
    }
    if (Number.isInteger(version) && version > cfg.storeSchemaVersion) {
      throw new Error(`state_newer_than_binary in ${domainId}`);
    }
    throw new Error(`unsupported_state_shape in ${domainId}`);
  }

  function forward(dataRoot, fromVer, toVer) {
    if (fromVer === 0 && toVer === 1) {
      const storePath = getStorePath(dataRoot);
      if (!fs.existsSync(storePath)) {
        const preserved = loadPreservation(dataRoot, domainId);
        if (preserved && preserved.preservedData && Object.keys(preserved.preservedData).length > 0) {
          const doc = { ...preserved.preservedData, schemaVersion: cfg.storeSchemaVersion };
          writeJsonAtomicSync(storePath, doc);
          clearPreservation(dataRoot, domainId);
          return { converted: true, details: `restored ${domainId} from preservation extension at schemaVersion ${cfg.storeSchemaVersion}` };
        }
        return { converted: true, details: "store absent, no action required" };
      }
      return { converted: true, details: "store already current" };
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
      if (doc && typeof doc === "object" && !Array.isArray(doc)) {
        const { schemaVersion: _s, ...rest } = doc;
        if (Object.keys(rest).length > 0) {
          savePreservation(dataRoot, domainId, fromVer, toVer, rest, "Preserved document removed during downgrade (CurrentOnly domain has no legacy on-disk form)");
        }
        removeFileSync(storePath);
        return { converted: true, details: `removed ${domainId} store; contents preserved in recovery extension` };
      }
      removeFileSync(storePath);
      return { converted: true, details: "removed unreadable store document" };
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
