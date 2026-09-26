import path from "node:path";
import fs from "node:fs";
import { readJsonSync, isRegularFileSync } from "./fs-atomic.mjs";
import { DOMAIN_DEFINITIONS, DOMAIN_MARKER_SCHEMA, LEDGER_SCHEMA } from "./catalog.mjs";
import { getCodec } from "./codecs/index.mjs";
import { listPreservations } from "./preservation.mjs";
import { openJournal } from "./journal.mjs";
import { DATA_ROOT_REF, redactPublicValue } from "./public-output.mjs";

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

    // Effective authoritative version mirrors probe_domain on the native
    // side: a present store wins; an absent store falls back to the marker;
    // a legacy (version 0) store conflicts with an advanced marker.
    let effectiveVersion = 0;
    let conflict = null;
    if (storeProbe.error) {
      conflict = storeProbe.error;
    } else if (storeProbe.version > def.targetSchemaVersion) {
      conflict = `state_newer_than_binary: ${domainId} store version ${storeProbe.version}`;
    } else if (storeProbe.version > 0) {
      if (markerVersion !== null && markerVersion > storeProbe.version) {
        conflict = `unsupported_state_shape: ${domainId} marker v${markerVersion} ahead of store v${storeProbe.version}`;
      } else {
        effectiveVersion = storeProbe.version;
      }
    } else if (storeProbe.present) {
      if (markerVersion !== null && markerVersion > 0) {
        conflict = `unsupported_state_shape: ${domainId} legacy store conflicts with marker v${markerVersion}`;
      } else {
        effectiveVersion = 0;
      }
    } else {
      effectiveVersion = markerVersion !== null ? markerVersion : 0;
    }

    results[domainId] = {
      domainId,
      durability: def.durability,
      targetSchemaVersion: def.targetSchemaVersion,
      storeVersion: storeProbe.version,
      storePresent: storeProbe.present,
      // The store's own published shape, where a domain has more than one under
      // the same domain version. It is not a frontier version and never reaches
      // the ledger: it says what the file is, not what the admission admits.
      storeFormat: storeProbe.storeFormat ?? null,
      markerVersion: markerVersion,
      effectiveVersion,
      pendingAuthorization: Boolean(storeProbe.pendingAuthorization),
      error: conflict,
    };
  }
  return results;
}

export function inspect(dataRoot) {
  const ledger = readLedger(dataRoot);
  const domains = probeAllDomains(dataRoot);
  const journal = openJournal(dataRoot);
  const preservations = listPreservations(dataRoot);

  // The report is a public artifact: it identifies the root with the stable
  // `<data-root>` ref and carries no machine paths or echoed document values.
  // The probing above ran against the real root, so nothing is lost on disk.
  return redactPublicValue(
    {
      dataRoot: DATA_ROOT_REF,
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
    },
    dataRoot,
  );
}
