import path from "node:path";
import fs from "node:fs";
import {
  ensureDirectorySync,
  writeJsonAtomicSync,
  readJsonSync,
  removeFileSync,
} from "./fs-atomic.mjs";
import { PRESERVATION_SCHEMA } from "./catalog.mjs";

export function preservationDir(dataRoot) {
  return path.join(dataRoot, "client-state", "migrations", "preservation");
}

export function preservationPath(dataRoot, domainId) {
  return path.join(preservationDir(dataRoot), `${domainId}.json`);
}

export function indexPath(dataRoot) {
  return path.join(preservationDir(dataRoot), "index.json");
}

export function savePreservation(dataRoot, domainId, fromVersion, targetVersion, data, notes = "") {
  const dir = preservationDir(dataRoot);
  ensureDirectorySync(dir);

  const record = {
    schemaVersion: PRESERVATION_SCHEMA,
    domainId,
    fromVersion,
    targetVersion,
    savedAt: new Date().toISOString(),
    notes,
    preservedData: data,
  };

  const file = preservationPath(dataRoot, domainId);
  writeJsonAtomicSync(file, record);

  // Update index
  const indexFile = indexPath(dataRoot);
  const index = readJsonSync(indexFile) || {
    schemaVersion: PRESERVATION_SCHEMA,
    domains: {},
  };
  index.domains[domainId] = {
    fromVersion,
    targetVersion,
    savedAt: record.savedAt,
    notes,
  };
  writeJsonAtomicSync(indexFile, index);
  return record;
}

export function loadPreservation(dataRoot, domainId) {
  const file = preservationPath(dataRoot, domainId);
  return readJsonSync(file);
}

export function hasPreservation(dataRoot, domainId) {
  return fs.existsSync(preservationPath(dataRoot, domainId));
}

export function clearPreservation(dataRoot, domainId) {
  removeFileSync(preservationPath(dataRoot, domainId));
  const indexFile = indexPath(dataRoot);
  const index = readJsonSync(indexFile);
  if (index && index.domains && index.domains[domainId]) {
    delete index.domains[domainId];
    writeJsonAtomicSync(indexFile, index);
  }
}

export function listPreservations(dataRoot) {
  const indexFile = indexPath(dataRoot);
  const index = readJsonSync(indexFile);
  if (!index || !index.domains) {
    return [];
  }
  return Object.entries(index.domains).map(([domainId, meta]) => ({
    domainId,
    ...meta,
  }));
}
