import * as releaseContract from "./secure-client-mesh-release-contract.mjs";
import {
  loadSecureClientRelayArtifacts,
  loadDigestBoundJsonInput
} from "./secure-client-relay-artifacts.mjs";

export * from "./secure-client-mesh-release-contract.mjs";
export * from "./secure-client-relay-artifacts.mjs";

export async function loadSecureClientContract() {
  const relayArtifacts = await loadSecureClientRelayArtifacts();
  return Object.freeze({
    ...releaseContract,
    relayArtifacts
  });
}

export { loadDigestBoundJsonInput };
