import path from "node:path";
import fs from "node:fs";
import { readJsonSync, isRegularFileSync } from "./fs-atomic.mjs";
import { DOMAIN_DEFINITIONS, DOMAIN_MARKER_SCHEMA, LEDGER_SCHEMA } from "./catalog.mjs";
import { getCodec } from "./codecs/index.mjs";
import { listPreservations } from "./preservation.mjs";
import { openJournal } from "./journal.mjs";

export function getLedgerPath(dataRoot) {
  return path.join(dataRoot, "client-state", "migrations", "ledger.json");
}

export function getMarkerPath(dataRoot, domainId) {
  return path.join(dataRoot, "client-state", "migrations", "domain-state", `${domainId}.json`);
}

export function readLedger(dataRoot) {
  const file = getLedgerPath(dataRoot);
  if (!isRegularFileSync(file)) {
    return null;
  }
  const content = readJsonSync(file);
  if (content && content.schemaVersion === LEDGER_SCHEMA) {
    return content;
  }
  return null;
}

export function readMarker(dataRoot, domainId) {
  const file = getMarkerPath(dataRoot, domainId);
  if (!isRegularFileSync(file)) {
    return null;
  }
  const content = readJsonSync(file);
  if (content && content.schemaVersion === DOMAIN_MARKER_SCHEMA && content.domainId === domainId) {
    return content.authoritativeSchemaVersion;
  }
  return null;
}

export function probeAllDomains(dataRoot) {
  const results = {};
  for (const def of DOMAIN_DEFINITIONS) {
    const domainId = def.domainId;
    const codec = getCodec(domainId);
    let storeProbe = { version: 0, present: false };
    try {
      storeProbe = codec.probe(dataRoot);
    } catch (err) {
      storeProbe = { version: 0, present: false, error: err.message };
    }

    const markerVersion = readMarker(dataRoot, domainId);
    results[domainId] = {
      domainId,
      durability: def.durability,
      targetSchemaVersion: def.targetSchemaVersion,
      storeVersion: storeProbe.version,
      storePresent: storeProbe.present,
      markerVersion: markerVersion,
      pendingAuthorization: Boolean(storeProbe.pendingAuthorization),
      error: storeProbe.error || null,
    };
  }
  return results;
}

export function inspect(dataRoot) {
  const ledger = readLedger(dataRoot);
  const domains = probeAllDomains(dataRoot);
  const journal = openJournal(dataRoot);
  const preservations = listPreservations(dataRoot);

  return {
    dataRoot: path.resolve(dataRoot),
    inspectedAt: new Date().toISOString(),
    ledger: ledger
      ? {
          present: true,
          highestAdmittedProductVersion: ledger.highestAdmittedProductVersion,
          frontierId: ledger.frontierId,
          domainCount: Object.keys(ledger.domains || {}).length,
        }
      : {
          present: false,
          highestAdmittedProductVersion: "0.0.0",
          frontierId: null,
          domainCount: 0,
        },
    domains,
    hasPendingJournal: Boolean(journal && journal.status === "in_progress"),
    journal: journal || null,
    preservations,
  };
}
