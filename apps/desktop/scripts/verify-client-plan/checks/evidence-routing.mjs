export async function checkEvidenceRouting({ assert, files, context }) {
  const { readJson, readSourceBundle, readText } = files;
  const { secureClientContract } = context;
const secureMeshEvidenceBundle = await readSourceBundle(
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle",
  ".mjs",
);
const secureMeshEvidenceRouteConfig = await readText("tools/scripts/config/secure-mesh-e2ee-evidence-routes.json");
const secureMeshEvidenceRouteConfigJson = await readJson("tools/scripts/config/secure-mesh-e2ee-evidence-routes.json");

for (const token of [
  "licomesh.secure-mesh.e2ee-evidence-routes.v2",
  "build/reports/secure-client-relay-mock-e2e.json",
  "build/reports/secure-mesh-physical-evidence-manifest.json",
  "pairwise/content crypto audit",
  "platform secret-store binding",
  "physical device matrix",
  "opaque relay protocol mock",
  "encrypted file handoff",
  "trust UX",
  "release proof bundle",
  "client:verify:secure-client-relay-mock-e2e",
  "client:verify:secure-mesh-physical-evidence-manifest"
]) {
  assert(secureMeshEvidenceRouteConfig.includes(token),
    `secure mesh evidence route config must preserve route token ${token}`);
}
assert(secureMeshEvidenceRouteConfigJson.diagnosticRefs?.relayMock ===
  "build/reports/secure-client-relay-mock-e2e.json",
  "secure mesh evidence route config must bind the client-owned relay Mock report");
assert(secureMeshEvidenceRouteConfigJson.routes?.["opaque relay protocol mock"]?.commands?.includes(
  "npm run client:verify:secure-client-relay-mock-e2e"
), "secure mesh evidence route config must execute the client-owned relay Mock");
assert(JSON.stringify(Object.keys(secureMeshEvidenceRouteConfigJson.routes || {})) ===
  JSON.stringify(secureClientContract.SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS),
  "secure mesh evidence route config must exactly match canonical client blockers");
const secureMeshEvidenceRouteHelper = await readText("tools/scripts/lib/secure-client-mesh-e2ee-route-plan.mjs");
for (const token of [
  "loadSecureClientMeshE2eeEvidenceRoutePlan",
  "loadSecureClientMeshE2eeDiagnosticRefs",
  "normalizeDiagnosticRefs",
  "relayMock",
  "normalizeSafeRef",
  "normalizeCommand",
  "normalizeCommandDescriptor",
  "assertNoLeak",
  "does not cover contract blockers",
  "contains non-contract blockers"
]) {
  assert(secureMeshEvidenceRouteHelper.includes(token),
    `secure mesh evidence route helper must preserve contract-bound route guard token ${token}`);
}
assert(!/const\s+evidenceRoutePlan\s*=\s*Object\.freeze/u.test(secureMeshEvidenceBundle),
  "secure mesh evidence bundle must load route plan from config instead of hardcoding it");
assert(Object.keys(secureClientContract.relayArtifacts.coreOperations).length === 5 &&
  Object.values(secureClientContract.relayArtifacts.coreOperations)
    .every((operation) => operation.method === "POST"),
  "secure client relay core contract must expose exactly five POST operations");
assert(secureClientContract.relayArtifacts.relayEnvelopeOuterFields.length === 6,
  "secure client relay core contract must expose exactly six outer envelope fields");
const secureClientRelayArtifactLoader =
  await readText("tools/scripts/lib/secure-client-relay-artifacts.mjs");
for (const token of [
  "SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST",
  "digestArtifactWithoutDeclaredDigest",
  "Secure Client Relay core operations",
  "Secure Client Relay outer envelope fields are not exact",
  "loadDigestBoundJsonInput"
]) {
  assert(secureClientRelayArtifactLoader.includes(token),
    `secure client relay artifact loader must keep strict validation token ${token}`);
}
const secureMeshAcpRelayBaseline =
  await readText("tools/scripts/client-secure-mesh-acp-relay-governed-baseline.mjs");
const secureMeshAcpRelayBaselineConfig =
  await readText("tools/scripts/config/secure-mesh-acp-relay-governed-baseline.json");
for (const token of [
  "loadDigestBoundJsonInput",
  "externalGatewayEvidence",
  "explicitGatewayReportPathRequired",
  "explicitGatewayReportDigestRequired",
  "adjacentServerCheckoutRequired: false"
]) {
  assert(secureMeshAcpRelayBaseline.includes(token) || secureMeshAcpRelayBaselineConfig.includes(token),
    `secure mesh ACP baseline must keep decoupled gateway evidence token ${token}`);
}
for (const token of [
  "createSecureClientMeshExternalEvidenceBundleTemplate",
  "createSecureClientMeshProductionReadiness",
  "SECURE_CLIENT_MESH_E2EE_EVIDENCE_BUNDLE_PATH",
  "SECURE_CLIENT_MESH_E2EE_EVIDENCE_READY_FIELD",
  "SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD",
  "SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_DIGESTS_FIELD",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "evaluateSecureClientMeshEvidenceRefReportReadiness",
  "secureClientMeshEvidenceAuthorityForBlocker",
  "loadSecureClientMeshE2eeEvidenceRoutePlan",
  "routeCoverage",
  "inspectEvidenceRef",
  "sha256Digest",
  "verifyBundle",
  "routeConfigRef",
  "relayMockReportRef",
  "clientOrAuditProvenanceAccepted",
  "sourceOfTruth"
]) {
  assert(secureMeshEvidenceBundle.includes(token),
    `secure mesh evidence bundle generator must keep contract-bound token ${token}`);
}
assert(!secureMeshEvidenceBundle.includes("contractReducerReady"),
  "secure mesh evidence bundle generator must not publish a contractReducerReady mirror field");
assert(!/canonicalVerifierAccepted|finalPathCanonicalVerifierAccepted/u.test(secureMeshEvidenceBundle),
  "secure mesh evidence bundle generator must not publish verifier acceptance mirror fields");
for (const token of [
  "readinessReduction",
  "--leak-scan-self-test",
  "--authority-proof-self-test",
  "--readiness-self-test",
  "--generate-authority-proof-template",
  "--authority-proof-template",
  "--trust-root",
  "--authority-trust-root",
  "SECURE_CLIENT_MESH_E2EE_AUTHORITY_TRUST_ROOT_ENV",
  "authorityProofTemplateForRoutes",
  "canonicalSecureClientMeshAuthorityProofPayload",
  "authorityProofPayloadDigest",
  "signingPreconditions",
  "evidence-report-not-ready-for-signing",
  "productionReadyClaimed: false",
  "attachSecureClientMeshEvidenceAuthorityProof",
  "tamperedSignedFixtureRejected",
  "privateKeyTrustRootRejected",
  "inTreeTrustRootRejected",
  "raw_secret_value",
  "Secure Client Mesh evidence leak scanner accepted raw secret material"
]) {
  assert(secureMeshEvidenceBundle.includes(token),
    `secure mesh evidence bundle generator must preserve single-source readiness reduction token ${token}`);
}
assert(!secureMeshEvidenceBundle.includes("[\"private_material\", /-----BEGIN|privateKey|sessionKey|rootKey|chainKey|messageKey/u]"),
  "secure mesh evidence bundle leak scanner must not flag safe privateKey* field names as raw key material");
const secureMeshEvidenceScopeConfig = await readText("tools/scripts/config/secure-mesh-e2ee-report-scope.json");
for (const token of [
  "licomesh.secure-mesh.e2ee-report-scope-config.v2",
  "build/reports/secure-mesh-pairwise-content-crypto-audit.json",
  "build/reports/secure-mesh-platform-secret-store-matrix.json",
  "build/reports/secure-mesh-physical-device-matrix.json",
	  "build/reports/secure-mesh-physical-evidence-manifest.json",
	  "build/reports/secure-client-relay-mock-e2e.json",
  "build/reports/secure-mesh-encrypted-file-handoff.json",
  "build/reports/secure-mesh-trust-ux.json",
	  "build/reports/secure-mesh-release-proof-bundle.json",
	  "external-client",
	  "scopeEvidenceFreshnessSeconds",
	  "clientRuntimeClaims",
	  "independentCryptoReviewClaims",
	  "relayProtocolClaims",
	  "independent-audit",
	  "platformSecretStoreClaims",
  "physicalDeviceClaims",
  "encryptedFileHandoffClaims",
  "trustUxClaims",
  "releaseArtifactClaims"
]) {
  assert(secureMeshEvidenceScopeConfig.includes(token),
    `secure mesh evidence scope config must preserve report-scope token ${token}`);
}
const secureMeshEvidenceScope = await readText("tools/scripts/lib/secure-client-mesh-e2ee-ref-report.mjs");
for (const token of [
  "createSecureClientMeshE2eeRefReportScope",
  "verifySecureClientMeshE2eeRefReportScopeSelfTest",
  "secure-mesh-e2ee-report-scope.json",
  "requiredSecureClientMeshEvidenceRefScopeClaims",
  "requiredSecureClientMeshEvidenceScopeClaimAuthorities",
  "claimAuthorities",
  "independentCryptoReviewClaims",
	  "independent-audit",
	  "independentAuditClaimRejectsExternalClient",
	  "completeRequiredClaimSetEnforced",
	  "scopeEvidenceFreshUntilEmitted",
	  "injectedScopeConfigSchemaGuarded",
	  "normalizeScopeConfig",
	  "missingConfiguredClaims",
	  "scopeEvidenceFreshnessSeconds",
	  "scopeEvidence",
	  "evidenceType",
	  "checkedAt",
	  "freshUntil",
	  "redacted: true"
]) {
  assert(secureMeshEvidenceScope.includes(token),
    `secure mesh evidence scope helper must preserve redacted external-client receipt token ${token}`);
}

}
