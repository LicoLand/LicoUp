import path from "node:path";
import fs from "node:fs";
import {
  writeJsonAtomicSync,
  readJsonSync,
  isRegularFileSync,
} from "../fs-atomic.mjs";
import { DOMAIN_MARKER_SCHEMA } from "../catalog.mjs";

const DOMAIN_ID = "gateway-credential-custody";

export function getMarkerPath(dataRoot) {
  return path.join(dataRoot, "client-state", "migrations", "domain-state", `${DOMAIN_ID}.json`);
}

export function probe(dataRoot) {
  const markerPath = getMarkerPath(dataRoot);
  if (!isRegularFileSync(markerPath)) {
    return { version: 0, present: false };
  }
  const marker = readJsonSync(markerPath);
  if (marker && marker.schemaVersion === DOMAIN_MARKER_SCHEMA && marker.domainId === DOMAIN_ID) {
    return {
      version: marker.authoritativeSchemaVersion,
      present: true,
      pendingAuthorization: marker.authoritativeSchemaVersion === 0,
    };
  }
  return { version: 0, present: false };
}

export function forward(dataRoot, fromVer, toVer) {
  if (fromVer === 0 && toVer === 1) {
    const markerPath = getMarkerPath(dataRoot);
    writeJsonAtomicSync(markerPath, {
      schemaVersion: DOMAIN_MARKER_SCHEMA,
      domainId: DOMAIN_ID,
      authoritativeSchemaVersion: 1,
    });
    return { converted: true, details: "advanced gateway credential custody to version 1" };
  }
  throw new Error(`Unsupported forward migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function reverse(dataRoot, fromVer, toVer) {
  if (fromVer === 1 && toVer === 0) {
    const markerPath = getMarkerPath(dataRoot);
    writeJsonAtomicSync(markerPath, {
      schemaVersion: DOMAIN_MARKER_SCHEMA,
      domainId: DOMAIN_ID,
      authoritativeSchemaVersion: 0,
    });
    return { converted: true, details: "reverted gateway credential custody to version 0" };
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
