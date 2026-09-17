import path from "node:path";
import {
  readJsonSync,
  isRegularFileSync,
} from "../fs-atomic.mjs";
import { DOMAIN_MARKER_SCHEMA } from "../catalog.mjs";

const DOMAIN_ID = "gateway-credential-custody";

// Credential custody moves require platform authentication and the platform
// owner's protected continuation. The independent tool must never fabricate
// this domain's marker: the native admission boundary answers the same edge
// with migration_authorization_required.
function authorizationRequired() {
  const err = new Error(
    `migration_authorization_required: ${DOMAIN_ID} requires the platform credential custody bridge`
  );
  err.code = "migration_authorization_required";
  return err;
}

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
    throw authorizationRequired();
  }
  throw new Error(`Unsupported forward migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function reverse(dataRoot, fromVer, toVer) {
  if (fromVer === 1 && toVer === 0) {
    throw authorizationRequired();
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
