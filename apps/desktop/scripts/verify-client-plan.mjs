#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loadSecureClientContract } from "../../../tools/scripts/lib/secure-client-contract.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const releaseBoundarySelfTestScripts = [
  "client:verify:release-artifact-io:self-test",
  "client:verify:source-state-digest:self-test",
  "client:verify:linux-tar-resource-bounds:self-test",
  "client:verify:android-apk-zip-facts:self-test",
  "client:verify:android-release-toolchain:self-test",
  "client:verify:review-signoff:self-test",
  "client:verify:release-target-evidence:self-test",
];
const requiredVerifierScripts = [
  "repo:client-boundary",
  "repo:local-info-hygiene",
  "repo:local-info-hygiene:self-test",
  "repo:workspace-cache-boundary",
  "client:verify",
  "client:verify:source",
  "client:version:check",
  "client:version:sync",
  "client:support-matrix:check",
  "client:support-matrix:sync",
  "client:verify:architecture",
  ...releaseBoundarySelfTestScripts,
  "client:verify:agent-conversation-parity",
  "client:verify:plan",
  "client:contracts:test",
  "client:native:smoke",
  "client:verify:update-release",
  "client:verify:windows-file-security",
  "client:runtime:package",
  "client:cli:vm:list",
  "client:cli:vm:prepare",
  "client:cli:vm:verify",
  "client:cli:vm:linux-product-bootstrap",
  "client:cli:vm:linux-product",
  "client:verify:agent-usage",
  "client:verify:android-physical-install-launch",
  "client:test:android:native",
  "client:verify:secure-client-relay-mock-e2e",
  "client:verify:secure-mesh-pairwise-content-audit",
  "client:verify:secure-mesh-platform-secret-store-matrix",
  "client:verify:secure-mesh-physical-device-matrix",
  "client:verify:secure-mesh-encrypted-file-handoff",
  "client:verify:secure-mesh-acp-relay-governed-baseline",
  "client:verify:secure-mesh-acp-archive-release-proof",
  "client:verify:secure-mesh-trust-ux:self-test",
  "client:verify:secure-mesh-trust-ux",
  "client:verify:secure-mesh-report-redaction",
  "client:verify:secure-mesh-report-redaction:self-test",
  "client:verify:secure-mesh-release-proof-bundle",
  "client:verify:secure-mesh-e2ee-evidence:contract-binding",
  "client:verify:secure-mesh-e2ee-evidence:authority-proof-self-test",
  "client:verify:secure-mesh-e2ee-evidence:readiness-self-test",
  "client:verify:secure-mesh-e2ee-evidence:leak-scan-self-test",
  "client:verify:secure-mesh-e2ee-evidence",
  "client:verify:macos-bundle"
];
const betterPlanEvidenceLedgerScripts = [
  "client:verify:better-plan-evidence-ledger",
  "client:verify:better-plan-evidence-ledger:report",
  "client:verify:better-plan-evidence-ledger:self-test"
];
const shellModules = ["Agents", "MCP Plugins", "Skill Hub", "Mobile Relay", "Runtime", "Settings"];

const failures = [];

function assert(condition, message) {
  if (!condition) {
    failures.push(message);
  }
}

function sanitize(text) {
  return String(text || "")
    .replace(/\/Users\/[^/\s"]+/gu, "<user-home>")
    .replace(/Bearer\s+\S+/gu, "Bearer [redacted]")
    .replace(/\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]+\b/gu, "[redacted]")
    .slice(0, 1000);
}

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function readJson(relativePath) {
  return JSON.parse(await readText(relativePath));
}

function linesContaining(source, token) {
  return source
    .split(/\r?\n/)
    .map((line, index) => ({ line, number: index + 1 }))
    .filter((item) => item.line.includes(token));
}

const packageJson = await readJson("package.json");
const scripts = packageJson.scripts || {};
assert(packageJson.private === false, "package.json must identify the open-source client repository");
assert(packageJson.license === "GPL-3.0-or-later", "package.json must use GPL-3.0-or-later");
const scriptNamesByCommand = new Map();
for (const [scriptName, command] of Object.entries(scripts)) {
  if (typeof command !== "string") {
    continue;
  }
  const normalizedCommand = command.trim();
  const scriptNames = scriptNamesByCommand.get(normalizedCommand) || [];
  scriptNames.push(scriptName);
  scriptNamesByCommand.set(normalizedCommand, scriptNames);
}
for (const scriptNames of scriptNamesByCommand.values()) {
  assert(
    scriptNames.length === 1,
    `package.json scripts must use one canonical name per command: ${scriptNames.join(", ")}`
  );
}
for (const scriptName of requiredVerifierScripts) {
  assert(Boolean(scripts[scriptName]), `package.json must define ${scriptName}`);
}
for (const scriptName of betterPlanEvidenceLedgerScripts) {
  assert(Boolean(scripts[scriptName]), `package.json must define ${scriptName}`);
}
assert(
  scripts["client:verify:plan"]?.includes("client:verify:better-plan-evidence-ledger:report"),
  "client:verify:plan must run the staged Better Plan evidence ledger report without claiming strict readiness"
);
for (const scriptName of [
  "repo:client-boundary",
  "repo:local-info-hygiene",
  "repo:local-info-hygiene:self-test",
  "repo:workspace-cache-boundary",
  "client:version:check",
  "client:version:sync",
  "client:get",
  "client:package:plan",
  "client:runtime:package",
  "client:cli:vm:list",
  "client:cli:vm:prepare",
  "client:cli:vm:verify",
  "client:cli:vm:linux-product-bootstrap",
  "client:cli:vm:linux-product",
  "client:run:macos",
  "client:icon:macos",
  "client:build:macos",
  "client:verify:macos-bundle",
  "client:build:linux",
  "client:build:windows",
  "client:build:android",
  "client:install:macos",
  "client:analyze",
  "client:test",
  "client:native:test"
]) {
  assert(Boolean(scripts[scriptName]), `package.json must define ${scriptName}`);
}
const verifyRunner = await readText("tools/run-client-verify.mjs");
assert(verifyRunner.includes("client:verify:better-plan-evidence-ledger:self-test"),
  "tools/run-client-verify.mjs must exercise the Better Plan evidence ledger self-test");
const betterPlanEvidenceLedger = await readText("tools/scripts/client-better-plan-evidence-ledger.mjs");
const betterPlanEvidenceLedgerHelper =
  await readText("tools/scripts/lib/better-plan-evidence-ledger.mjs");
for (const token of [
  "--report-only",
  "--self-test",
  "evaluateBetterPlanEvidenceLedger",
  "!reportOnly && !report.ready"
]) {
  assert(betterPlanEvidenceLedger.includes(token),
    `Better Plan evidence ledger CLI must keep staged gate token ${token}`);
}
for (const token of [
  "free_text_only_evidence",
  "missing_evidence_refs",
  "evidence_file_digest_mismatch",
  "unsafe_evidence_file_path",
  "evidence_command_failed",
  "privacy_leak",
  "duplicate_evidence_ref",
  "dangling_checkpoint_ref",
  "dangling_evidence_file_ref"
]) {
  assert(betterPlanEvidenceLedgerHelper.includes(token),
    `Better Plan evidence ledger helper must keep fail-closed check ${token}`);
}
const clientToolchainRunner = await readText("tools/scripts/client-toolchain-runner.mjs");
for (const token of [
  "runPreparedCommand",
  "Online flutter pub get failed; retrying with the locked local cache.",
  "isFlutterPubGet(prepared.args)",
  "prepared.args.includes(\"--offline\")",
  "[...prepared.args, \"--offline\"]",
  "delete offlineEnv.PUB_HOSTED_URL"
]) {
  assert(clientToolchainRunner.includes(token),
    `client toolchain runner must preserve locked-cache pub get fallback token ${token}`);
}
for (const scriptName of [
  "repo:client-boundary",
  "repo:local-info-hygiene",
  "repo:local-info-hygiene:self-test",
  "repo:workspace-cache-boundary",
  "client:version:check",
  "client:verify:plan",
  "client:verify:architecture",
  ...releaseBoundarySelfTestScripts,
  "client:verify:agent-conversation-parity",
  "client:verify:agent-usage",
  "client:test:android:native",
  "client:verify:secure-client-relay-mock-e2e",
  "client:verify:secure-mesh-pairwise-content-audit",
  "client:verify:secure-mesh-platform-secret-store-matrix",
  "client:verify:secure-mesh-physical-device-matrix",
  "client:verify:secure-mesh-encrypted-file-handoff",
  "client:verify:secure-mesh-acp-relay-governed-baseline",
  "client:verify:secure-mesh-acp-archive-release-proof",
  "client:verify:secure-mesh-trust-ux:self-test",
  "client:verify:secure-mesh-trust-ux",
  "client:verify:secure-mesh-report-redaction",
  "client:verify:secure-mesh-report-redaction:self-test",
  "client:verify:secure-mesh-release-proof-bundle",
  "client:verify:secure-mesh-e2ee-evidence:contract-binding",
  "client:verify:secure-mesh-e2ee-evidence:authority-proof-self-test",
  "client:verify:secure-mesh-e2ee-evidence:readiness-self-test",
  "client:verify:secure-mesh-e2ee-evidence:leak-scan-self-test",
  "client:verify:secure-mesh-e2ee-evidence",
  "client:contracts:test",
  "client:runtime:package",
  "client:analyze",
  "client:test",
  "client:native:test",
  "client:native:smoke"
]) {
  assert(verifyRunner.includes(scriptName), `tools/run-client-verify.mjs must include ${scriptName}`);
}
for (const scriptName of releaseBoundarySelfTestScripts) {
  assert(verifyRunner.includes(scriptName),
    `tools/run-client-verify.mjs must include ${scriptName}`);
}
assert(!verifyRunner.includes('["npm", ["run", "client:verify:client-release-acceptance"]]'),
  "default client verification must not invoke the side-effecting release reducer");
assert(scripts["client:verify:github-release"]?.includes(
  "client-github-release-acceptance.mjs"),
"explicit GitHub release must invoke the artifact-only reducer");
assert(scripts["client:verify:product-line-security"]?.includes(
  "client-release-acceptance.mjs"),
"product-line security must invoke the full evidence reducer");

const clientBoundaryVerifier = await readText("tools/verify-client-boundary.mjs");
const clientBoundaryConfig = await readText("tools/scripts/config/secure-mesh-client-boundary.json");
const clientBoundaryConfigJson = await readJson("tools/scripts/config/secure-mesh-client-boundary.json");
const clientBoundaryConfigHelper = await readText("tools/scripts/lib/secure-mesh-client-boundary-config.mjs");
for (const token of [
  "loadSecureMeshClientBoundaryConfig",
  "enforceConfiguredClientBoundary",
  "clientBoundarySummary",
  "clientBoundary: clientBoundarySummary",
  "ruleAllowsToken",
  "sourceChecks"
]) {
  assert(clientBoundaryVerifier.includes(token),
    `client boundary verifier must keep config-driven boundary token ${token}`);
}
assert(clientBoundaryVerifier.includes("await enforceConfiguredClientBoundary(await loadSecureMeshClientBoundaryConfig())"),
  "client boundary verifier must load and enforce the client boundary config");
for (const token of [
  "licolite.secure-mesh.client-boundary-config.v1",
  "flutter-gui-no-secure-mesh-backend-implementation",
  "dart-services-are-bridges-not-protocol-implementations",
  "dart-method-channel-confined-to-platform-bridge",
  "rust-native-core-has-no-flutter-ui-dependency",
  "android-activity-does-not-own-payload-crypto",
  "android-platform-auth-does-not-collect-lock-screen-password",
  "android-mobile-relay-bridge-does-not-send-raw-e2ee-json",
  "ios-mobile-relay-bridge-does-not-send-raw-e2ee-json",
	  "rust-core-owns-secure-mesh-payload-crypto",
	  "rust-core-owns-secure-mesh-pairwise-state",
	  "handshake_transcript_hash",
	  "initiator_key_confirmed",
	  "pairwise_key_confirmation",
	  "rust-mobile-ffi-forbids-raw-payload-crypto-actions",
  "android-forbids-raw-payload-ffi-actions",
  "android-bridge-uses-system-device-auth",
  "android-bridge-uses-opaque-mobile-relay-secret-store-handle",
  "macos-rust-secret-store-uses-single-system-auth-context",
  "macos-user-presence-proof-uses-single-system-auth-context",
  "MacosAuthorizationContext",
  "kSecUseAuthenticationContext",
  "SecretStoreAuthorizationSession",
  "begin_authorized_session",
  "set_secret_with_session",
  "ios-bridge-uses-keychain-and-local-auth",
  "ios-bridge-uses-single-system-auth-context"
]) {
  assert(clientBoundaryConfig.includes(token),
    `client boundary config must preserve frontend/backend split token ${token}`);
}
assert(Array.isArray(clientBoundaryConfigJson.rules) &&
  clientBoundaryConfigJson.rules.length >= 6 &&
  Array.isArray(clientBoundaryConfigJson.sourceChecks) &&
  clientBoundaryConfigJson.sourceChecks.length >= 11,
  "client boundary config must define scan rules and source checks");
for (const token of [
  "loadSecureMeshClientBoundaryConfig",
  "normalizeSafeRootRef",
  "normalizeSafeSourceRef",
	  "normalizeRules",
	  "normalizeAllowedMatches",
	  "normalizeSourceChecks",
	  "normalizeOptionalTokenList",
	  "const forbiddenTokens = normalizeOptionalTokenList",
	  "must define tokens or forbidden tokens",
	  "assertNoLeak",
  "rules must have unique ids",
  "source checks must have unique ids"
]) {
  assert(clientBoundaryConfigHelper.includes(token),
    `client boundary config helper must keep safety token ${token}`);
}

const secureMeshEvidenceBundle = await readText("tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs");
const secureMeshEvidenceRouteConfig = await readText("tools/scripts/config/secure-mesh-e2ee-evidence-routes.json");
const secureMeshEvidenceRouteConfigJson = await readJson("tools/scripts/config/secure-mesh-e2ee-evidence-routes.json");
const secureClientContract = await loadSecureClientContract();
for (const token of [
  "licolite.secure-mesh.e2ee-evidence-routes.v2",
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
  "licolite.secure-mesh.e2ee-report-scope-config.v2",
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
const secureMeshReportRedaction = await readText("tools/scripts/client-secure-mesh-report-redaction-verify.mjs");
const secureMeshReportRedactionConfig = await readText("tools/scripts/config/secure-mesh-report-redaction.json");
const secureMeshReportRedactionConfigJson = await readJson("tools/scripts/config/secure-mesh-report-redaction.json");
for (const token of [
  "licolite.secure-mesh.report-redaction-config.v1",
  "secure-mesh-report-redaction.json",
  "secure-mesh-release-input-report-redaction.json",
  "requiredRefs",
  "optionalRefs",
  "deferredGraphRefs",
  "build/reports/secure-mesh-pairwise-content-crypto-audit.json",
  "build/reports/secure-mesh-android-platform-crypto-acceptance.json",
  "build/reports/secure-client-relay-mock-e2e.json",
  "build/reports/secure-mesh-physical-evidence-manifest.json",
  "build/reports/secure-mesh-release-cli-proof-macos.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-release-cli-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-adaptive-custody-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-package-update-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-vm-package-receipt.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-node-matrix.json",
  "build/reports/secure-client-mesh-e2ee/authority-proof-template.json",
  "build/reports/secure-client-mesh-e2ee-evidence-bundle.json"
]) {
  assert(secureMeshReportRedactionConfig.includes(token),
    `secure mesh report redaction config must keep physical/mobile coverage token ${token}`);
}
assert(Array.isArray(secureMeshReportRedactionConfigJson.modes?.default?.requiredRefs) &&
  secureMeshReportRedactionConfigJson.modes.default.requiredRefs.length === 19,
  "secure mesh report redaction config must scan the default E2EE evidence graph");
assert(Array.isArray(secureMeshReportRedactionConfigJson.modes?.releaseProofInputs?.requiredRefs) &&
  secureMeshReportRedactionConfigJson.modes.releaseProofInputs.requiredRefs.length === 9,
  "secure mesh report redaction config must scan release proof input reports");
assert(secureMeshReportRedactionConfigJson.modes?.releaseProofInputs?.deferredGraphRefs?.includes(
  "build/reports/secure-mesh-release-proof-bundle.json"
), "secure mesh report redaction config must defer release proof bundle recursion for release-input mode");
assert(secureMeshReportRedactionConfigJson.modes?.default?.optionalRefs?.includes(
  "build/reports/secure-client-mesh-e2ee/authority-proof-template.json"
), "secure mesh report redaction config must scan the optional authority-proof template in default mode");
assert(secureMeshReportRedactionConfigJson.modes?.releaseProofInputs?.optionalRefs?.includes(
  "build/reports/secure-client-mesh-e2ee/authority-proof-template.json"
), "secure mesh report redaction config must scan the optional authority-proof template in release-input mode");
const secureMeshReportRedactionConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-report-redaction-config.mjs");
for (const token of [
  "loadSecureMeshReportRedactionConfig",
  "normalizeSafeReportRef",
  "assertNoLeak",
  "Duplicate Secure Mesh redaction",
  "must not scan verifier output reports as required input"
]) {
  assert(secureMeshReportRedactionConfigHelper.includes(token),
    `secure mesh report redaction config helper must keep safety token ${token}`);
}
for (const token of [
  "loadSecureMeshReportRedactionConfig",
  "selectedReportRefs",
  "selectedOptionalReportRefs",
  "selectedDeferredGraphRefs",
  "reportRefPattern",
  "collectLinkedReportRefs",
  "runSelfTest",
  "selfTestReady",
  "graphDerivedRefs",
  "graphDerivedReportCount",
  "scannedRefDigests",
  "scannedRefDigestCount",
  "redactionRunId",
  "redactionRunIdPresent",
  "deferredGraphRefs",
  "deferredGraphRefCount",
  "missingRefs.length === 0",
  "adb_device_listing",
  "labeled_device_identifier",
  "identity-or-local-string-field"
]) {
  assert(secureMeshReportRedaction.includes(token),
    `secure mesh report redaction verifier must keep physical/mobile report coverage token ${token}`);
}
function assertContractBoundEvidenceReport(relativePath, blockerLabel) {
  const source = fs.readFile(path.join(repoRoot, relativePath), "utf8");
  return source.then((text) => {
    for (const token of [
      "loadSecureClientContract",
      "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
      "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
      blockerLabel,
      "contractBinding",
      "generatedBy",
      "checkedAt",
      "reportLeakScan",
      "rawPrivateMaterialIncluded",
      "rawPlaintextIncluded",
      "rawPublicWireBytesIncluded"
    ]) {
      assert(text.includes(token), `${relativePath} must keep contract-bound token ${token}`);
    }
    assert(!text.includes("blockerStatus"),
      `${relativePath} must not publish blockerStatus; use diagnosticStatus for non-authoritative local diagnostics`);
    assert(text.includes("diagnosticStatus"),
      `${relativePath} must expose diagnosticStatus only as a non-authoritative local diagnostic`);
  });
}
const pairwiseContentAudit = await readText("tools/scripts/client-secure-mesh-pairwise-content-audit.mjs");
const pairwiseContentAuditConfig =
  await readText("tools/scripts/config/secure-mesh-pairwise-content-audit.json");
const pairwiseContentAuditConfigJson =
  await readJson("tools/scripts/config/secure-mesh-pairwise-content-audit.json");
for (const token of [
  "licolite.secure-mesh.pairwise-content-audit-config.v2",
  "build/reports/secure-mesh-pairwise-content-crypto-audit.json",
  "build/reports/secure-mesh-pairwise-content-vector-corpus.json",
  "build/reports/secure-mesh-pairwise-content-review-signoff.json",
  "LICO_SECURE_MESH_PAIRWISE_CONTENT_SIGNOFF",
  "sourceChecks",
  "nativeTestFilters",
  "client-relay-mock-covers-opaque-wire-adversarial-semantics",
  "client-relay-contract-pin-validates-exact-operation-and-envelope-sets",
  "mobile_relay_pairwise_rejects_relay_asserted_prekey_trust_state",
  "mobile_relay_pairwise_rejects_intro_signed_prekey_mismatch",
  "mobile_relay_pairwise_rejects_reused_remote_one_time_prekey",
  "SecureMeshRemotePreKeyUse",
  "secure_mesh_pairwise_remote_prekey_uses",
	  "record_remote_prekey_use",
	  "pairwise-authenticated-ratchet-is-restart-safe",
	  "handshake_transcript_hash",
	  "initiator_key_confirmed",
	  "pairwise_key_confirmation",
	  "pending_sending_ratchet",
	  "prepare_sending_ratchet_for_send",
	  "store_skipped_message_keys_until",
	  "secure_mesh_pairwise_dh_ratchet_reply_auto_rotates_after_remote_ratchet",
	  "secure_mesh_pairwise_dh_ratchet_preserves_old_chain_in_flight_messages",
	  "secure_mesh_pairwise_dh_ratchet_skip_limit_fails_closed_without_state_advance",
	  "secure_mesh_pairwise_pending_authenticated_ratchet_survives_restart",
	  "secure_mesh_pairwise_stale_and_replayed_relay_acks_do_not_advance_ratchet",
	  "secure_mesh_pairwise_revoked_session_fail_closed_for_seal_and_open",
	  "mls-product-policy-bindings-and-kt-signed-checkpoints",
	  "key-transparency-signed-checkpoints-non-authorizing-hash-chain",
	  "lifecycle-service-actions-require-pairwise-or-mls-envelopes",
	  "authorize_hashed_directory_view",
	  "seal_lifecycle_service_action_pairwise",
	  "mobile-ffi-forbids-raw-payload-crypto-actions",
  "includeBodyBase64url",
  "acp-envelope-aad-covers-protected-payload-binding",
  "acp-plaintext-protected-payload-relay-is-not-a-production-path",
  "static-endpoint-only-payload-cli-route-is-absent",
  "encode_acp_envelope_aad",
  "LCOSM-ACP-AAD-v1",
  "reject_plaintext_acp_protected_payload_relay",
  "secure_mesh_acp_envelope_aad_has_stable_digest_vector"
]) {
  assert(pairwiseContentAuditConfig.includes(token),
    `pairwise/content audit config must keep report token ${token}`);
}
assert(Array.isArray(pairwiseContentAuditConfigJson.reviewSignoff?.envKeys) &&
  pairwiseContentAuditConfigJson.reviewSignoff.envKeys.length === 1,
  "pairwise/content audit config must define the review signoff override env key");
assert(Array.isArray(pairwiseContentAuditConfigJson.sourceChecks) &&
  pairwiseContentAuditConfigJson.sourceChecks.length >= 18 &&
  Array.isArray(pairwiseContentAuditConfigJson.nativeTestFilters) &&
  pairwiseContentAuditConfigJson.nativeTestFilters.length >= 30,
  "pairwise/content audit config must define digest-bound source checks and native test filters");
const pairwiseContentAuditConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-pairwise-content-audit-config.mjs");
for (const token of [
  "loadSecureMeshPairwiseContentAuditConfig",
  "normalizeSafeReportRef",
  "normalizeSafeSourceRef",
  "normalizeEnvKeys",
  "normalizeSourceChecks",
  "normalizeNativeTestFilters",
  "assertNoLeak",
  "must use distinct report refs",
  "source checks must have unique ids",
  "native test filters must be unique",
  "review signoff must not overwrite verifier outputs"
]) {
  assert(pairwiseContentAuditConfigHelper.includes(token),
    `pairwise/content audit config helper must keep safety token ${token}`);
}
for (const token of [
  "loadSecureMeshPairwiseContentAuditConfig",
  "pairwiseContentAuditConfig",
  "reportPath = pairwiseContentAuditConfig.reportOutput",
  "vectorCorpusPath = pairwiseContentAuditConfig.vectorCorpusOutput",
  "reviewSignoffPath = pairwiseContentAuditConfig.reviewSignoffRef",
  "--generate-signoff-template",
  "vectorCorpusSnapshotRefForCorpus",
  "loadVectorCorpusSnapshot",
  "vectorCorpusSnapshotReport",
  "reviewSignoffTemplateForCorpus",
  "licolite.secure-mesh.pairwise-content-review-signoff-template.v2",
  "reviewSignoffTemplatePresent",
  "reviewSignoffTemplateDigestMatched",
  "reviewSignoffTemplateSnapshotPresent",
  "reviewSignoffTemplateSnapshotDigestMatched",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "contractBinding",
  "secure_mesh_pairwise_pc_pc_command_result_relay_round_trip",
  "secure_mesh_pairwise_mobile_pc_command_result_relay_round_trip",
  "secure_mesh_pairwise_pc_mobile_command_result_relay_round_trip",
  "secure_mesh_pairwise_mobile_mobile_command_result_relay_round_trip",
  "secure_mesh_pairwise_cli_desktop_command_result_relay_round_trip",
  "secure_mesh_pairwise_client_local_runtime_command_result_relay_round_trip",
  "secure_mesh_sesame_multi_device_fanout_uses_independent_pairwise_envelopes_and_ack_purge",
  "mobile_relay_file_key_envelope_hides_attachment_key_and_opens_file_after_decrypt",
  "mobile_relay_file_key_envelope_metadata_boundary_is_exhaustive",
  "mobile FFI raw payload key/body actions are absent",
  "runCargoTestFilter",
  "tampered_mobile_relay_command_envelope_is_rejected_before_execution",
  "replayed_mobile_relay_command_envelope_does_not_execute_twice",
  "rfc9162_inclusion_and_consistency_paths_are_logarithmic_and_exact",
  "secure_mesh_mls_product_forged_sender_and_typed_kt_member_add",
  "licolite.secure-mesh.pairwise-content-review-signoff.v2",
  "nativeTestFiltersDigest",
  "sourceCheckIdsDigest",
  "independentCryptographicReviewComplete: null",
  "releaseOwnerSignoffComplete: null",
  "approved_for_release_gate",
  "createSecureClientMeshE2eeRefReportScope",
  "reportRef: reportPath",
  "PC/Android/iPhone/CLI/runtime endpoint-kind command/result relay matrix",
  "Sesame-style multi-device fanout with independent pairwise envelopes"
]) {
  assert(pairwiseContentAudit.includes(token) || pairwiseContentAuditConfig.includes(token),
    `pairwise/content audit evidence report/config must keep contract-bound token ${token}`);
}
assert(pairwiseContentAudit.includes("sourceChecks = Object.freeze(pairwiseContentAuditConfig.sourceChecks)") &&
  pairwiseContentAudit.includes("nativeTestFilters = Object.freeze(pairwiseContentAuditConfig.nativeTestFilters)") &&
  !pairwiseContentAudit.includes("const sourceChecks = Object.freeze([") &&
  !pairwiseContentAudit.includes("const nativeTestFilters = Object.freeze(["),
  "pairwise/content audit must load source checks and native filters from config instead of hardcoding inline arrays");
for (const token of [
  "const reportPath = \"build/reports/secure-mesh-pairwise-content-crypto-audit.json\"",
  "const vectorCorpusPath = \"build/reports/secure-mesh-pairwise-content-vector-corpus.json\"",
  "process.env.LICO_SECURE_MESH_PAIRWISE_CONTENT_SIGNOFF",
  "\"build/reports/secure-mesh-pairwise-content-review-signoff.json\""
]) {
  assert(!pairwiseContentAudit.includes(token),
    `pairwise/content audit must load configured evidence ref instead of hardcoding ${token}`);
}
const secureClientRelayMockE2e =
  await readText("tools/scripts/client-secure-client-relay-mock-e2e.mjs");
const secureClientRelayMock =
  await readText("tools/scripts/lib/secure-client-relay-mock.mjs");
const secureClientRelayMockReport =
  await readText("tools/scripts/lib/secure-client-relay-mock-e2e-report.mjs");
for (const token of [
  "licolite.secure-client-relay.client-acceptance-report.v1",
  "licolite.secure-client-relay.mock-e2e-report.v1",
  "opaque relay protocol mock",
  "evidenceRefSchemaVersion",
  "productionReady: mock.ok === true",
  "releaseReady: mock.ok === true",
  "exactFiveOperationsObserved",
  "exactSixOuterFieldsObserved",
  "replayRejected",
  "staleLeaseRejected",
  "ackIdempotencyVerified",
  "plaintextAbsentFromServerVisibleWire",
  "wireBytesMeasured"
]) {
  assert(secureClientRelayMockE2e.includes(token),
    `secure client relay Mock E2E must keep protocol fact ${token}`);
}
for (const token of [
  "loadSecureClientRelayArtifacts",
  "exactKeys(envelope, outerFields",
  "secure_mesh_replay_rejected",
  "secure_mesh_stale_lease",
  "maxMailboxEntries",
  "maxMailboxBytes"
]) {
  assert(secureClientRelayMock.includes(token),
    `secure client relay Mock must keep bounded protocol behavior ${token}`);
}
for (const token of [
  "secureClientRelayMockE2eReady",
  "operationCount === 5",
  "outerEnvelopeFieldCount === 6",
  "plaintextAbsentFromServerVisibleWire === true"
]) {
  assert(secureClientRelayMockReport.includes(token),
    `secure client relay Mock report reducer must keep strict fact ${token}`);
}
const encryptedFileHandoff = await readText("tools/scripts/client-secure-mesh-encrypted-file-handoff.mjs");
const encryptedFileHandoffConfig =
  await readText("tools/scripts/config/secure-mesh-encrypted-file-handoff.json");
const encryptedFileHandoffConfigJson =
  await readJson("tools/scripts/config/secure-mesh-encrypted-file-handoff.json");
const encryptedFileHandoffConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-encrypted-file-handoff-config.mjs");
for (const token of [
  "loadSecureMeshEncryptedFileHandoffConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "encryptedFileHandoffConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "sourceChecks = Object.freeze(encryptedFileHandoffConfig.sourceChecks)",
  "nativeTestFilters = Object.freeze(encryptedFileHandoffConfig.nativeTestFilters)",
  "reportPath = physicalReportRefs.encryptedFileHandoff",
  "physicalReportRefs.androidPlatformCrypto",
  "physicalReportRefs.relayMock",
  "physicalReportRefs.macosReleaseCliProof",
  "physicalReportRefs.ubuntuReleaseCliProof",
  "physicalReportRefs.windowsImplementation",
  "loadAndroidPlatformCryptoEvidence",
  "loadRelayMockEvidence",
  "secureClientRelayMockE2eReady",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "encrypted file handoff",
  "contractBinding",
  "secure_mesh_file_key_wraps_through_pairwise_session_before_file_open",
  "secure_mesh_file_key_wraps_out_of_order_and_revocation_fails_closed",
  "mobile_relay_file_key_envelope_hides_attachment_key_and_opens_file_after_decrypt",
  "mobile_relay_file_key_envelope_metadata_boundary_is_exhaustive",
  "secure_mesh_file_handoff_proof_reseals_distinct_ciphertext_for_multiple_recipients",
  "multiRecipientEndpointSpecificResealProofReady",
  "releaseBuiltDesktopMatrixSatisfied",
  "releaseBuiltDesktopWindowsLocalBlockersCleared",
  "androidPlatformCryptoReady",
  "relayMockReady",
  "plaintextAbsentFromRelayVisibleWire",
  "relayAckIdempotencyVerified",
  "shared Rust endpoint-specific reseal proof for every recipient"
]) {
  assert(encryptedFileHandoff.includes(token) || encryptedFileHandoffConfig.includes(token),
    `encrypted file handoff evidence report/config must keep contract-bound token ${token}`);
}
assert(!encryptedFileHandoff.includes("const sourceChecks = Object.freeze([") &&
  !encryptedFileHandoff.includes("const nativeTestFilters = Object.freeze(["),
  "encrypted file handoff must load source checks and native filters from config instead of hardcoding inline arrays");
for (const token of [
  "licolite.secure-mesh.encrypted-file-handoff-config.v1",
  "sourceChecks",
  "nativeTestFilters",
  "file-transfer-state-tracks-resume-ack-and-purge",
  "mobile-relay-file-key-envelope-uses-pairwise-transport-with-opaque-relay-wire",
  "android-platform-crypto-acceptance-covers-custody-authorization-and-ffi"
]) {
  assert(encryptedFileHandoffConfig.includes(token),
    `encrypted file handoff config must keep token ${token}`);
}
assert(Array.isArray(encryptedFileHandoffConfigJson.sourceChecks) &&
  encryptedFileHandoffConfigJson.sourceChecks.length >= 11 &&
  Array.isArray(encryptedFileHandoffConfigJson.nativeTestFilters) &&
  encryptedFileHandoffConfigJson.nativeTestFilters.length >= 21,
  "encrypted file handoff config must define source checks and native test filters");
for (const token of [
  "loadSecureMeshEncryptedFileHandoffConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "normalizeNativeTestFilters",
  "assertNoLeak",
  "source checks must have unique ids"
]) {
  assert(encryptedFileHandoffConfigHelper.includes(token),
    `encrypted file handoff config helper must keep safety token ${token}`);
}
for (const token of [
  "const reportPath = \"build/reports/secure-mesh-encrypted-file-handoff.json\"",
  "const report = \"build/reports/secure-mesh-android-platform-crypto-acceptance.json\"",
  "const report = \"build/reports/secure-client-relay-mock-e2e.json\"",
  "report: \"build/reports/secure-mesh-release-cli-proof-macos.json\"",
  "report: \"build/client-cli-vm/ubuntu-arm64/secure-mesh-release-cli-proof.json\"",
  "const report = \"build/reports/secure-mesh-windows-implementation.json\""
]) {
  assert(!encryptedFileHandoff.includes(token),
    `encrypted file handoff must load configured evidence ref instead of hardcoding ${token}`);
}
const e2eeEvidenceBundle = await readText("tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs");
for (const token of [
  "inspectEvidenceRef",
  "verifySecureClientMeshEvidenceAuthorityProof",
  "authorityProofRequired",
  "authorityProofAccepted",
  "clientOrAuditProvenanceAccepted",
  "missingRequiredScopeClaims",
  "missingRequiredScopeEvidenceClaims",
  "freshUntil",
  "relayMockReportRef",
  "productionBlockerStates",
  "readinessReduction",
  "authorityTrustRootProvided",
  "authorityTrustRootAccepted"
]) {
  assert(e2eeEvidenceBundle.includes(token),
    `secure mesh e2ee evidence bundle must keep current contract diagnostic token ${token}`);
}
const platformSecretStoreMatrix = await readText("tools/scripts/client-secure-mesh-platform-secret-store-matrix.mjs");
const platformSecretStoreMatrixConfig =
  await readText("tools/scripts/config/secure-mesh-platform-secret-store-matrix.json");
const platformSecretStoreMatrixConfigJson =
  await readJson("tools/scripts/config/secure-mesh-platform-secret-store-matrix.json");
const platformSecretStoreMatrixConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-platform-secret-store-matrix-config.mjs");
const secureMeshSecretStoreRustSource =
  await readText("crates/lico-client-native/src/platform/secure_mesh_secret_store.rs");
const mobileRelayRustSource = await readText("crates/lico-client-native/src/domain/mobile_relay.rs");
for (const token of [
  "loadSecureMeshPlatformSecretStoreMatrixConfig",
  "platformSecretStoreMatrixConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "reportPath = physicalReportRefs.platformSecretStore",
  "androidPlatformCryptoCoverage",
  "androidInstallLaunchCoverage",
  "macosPlatformCryptoCoverage",
  "ubuntuPlatformCryptoCoverage",
  "rustCryptographyAcceptanceReady",
  "hostClientCryptographyAcceptance",
  "loadSecureClientContract",
  "contractBinding"
]) {
  assert(platformSecretStoreMatrix.includes(token) || platformSecretStoreMatrixConfig.includes(token),
    `platform secret-store matrix must keep current client cryptography token ${token}`);
}
assert(platformSecretStoreMatrix.includes("platformSecretStoreMatrixConfig.sourceChecks.map(evaluateSourceCheck)") &&
  platformSecretStoreMatrix.includes("platformSecretStoreMatrixConfig.nativeTestFilters.map(runNativeTest)") &&
  !platformSecretStoreMatrix.includes("const sourceChecks = Object.freeze([") &&
  !platformSecretStoreMatrix.includes("const nativeTestFilters = Object.freeze(["),
  "platform secret-store matrix must load source checks and native filters from config instead of hardcoding inline arrays");
for (const token of [
  "licolite.secure-mesh.platform-secret-store-matrix-config.v2",
  "sourceChecks",
  "nativeTestFilters",
  "android-platform-crypto-report-is-current",
  "android-keystore-policy-is-platform-native",
  "android-authenticator-uses-system-biometric-or-device-credential",
  "ios-callback-abi-keychain-handle-and-raw-json-ban-exists",
  "ios-bridge-rust-secret-store-callback-wiring-exists",
  "ios-secret-store-callback-uses-single-system-authorization-context",
  "ios-local-auth-user-presence-proof-exists",
  "macos-keychain-proof-is-client-owned-and-redacted",
  "platform-matrix-consumes-current-client-cryptography-reports",
  "physicalReportRefs.androidPlatformCrypto",
  "hostClientCryptographyAcceptance"
]) {
  assert(platformSecretStoreMatrixConfig.includes(token),
    `platform secret-store matrix config must keep token ${token}`);
}
assert(Array.isArray(platformSecretStoreMatrixConfigJson.sourceChecks) &&
  platformSecretStoreMatrixConfigJson.sourceChecks.length >= 13 &&
  Array.isArray(platformSecretStoreMatrixConfigJson.nativeTestFilters) &&
  platformSecretStoreMatrixConfigJson.nativeTestFilters.length >= 10,
  "platform secret-store matrix config must define source checks and native test filters");
for (const token of [
  "objc2_local_authentication::{LAContext, LAPolicy}",
  "MacosAuthorizationContext",
  "setInteractionNotAllowed",
  "context.setInteractionNotAllowed(!request.allow_interaction())",
  "evaluatePolicy_localizedReason_reply",
  "block2::RcBlock::new",
  "system_authorization_attempt_count",
  "system_authorization_completed",
  "canEvaluatePolicy_error(LAPolicy::DeviceOwnerAuthentication)",
  "if request.allow_interaction() {",
  "secure mesh macOS user-presence authorization is unavailable",
  "with_capability_report",
  "SecurityCapability::AppleKeychain",
  "SecurityCapability::DataProtectionKeychain",
  "SecurityCapability::OsUserPresence",
  "SecurityCapability::DeviceCredential",
  "kSecUseDataProtectionKeychain",
	  "kSecUseAuthenticationContext",
	  "SecAccessControl::create_with_protection",
	  "ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly",
	  "kSecAccessControlUserPresence",
	  "single_system_authorization_context_verified",
	  "secure mesh native secret store read failed for",
	  "must implement session-aware reads",
	  "must implement session-aware writes",
	  "must implement session-aware deletes",
	  "record_secret_store_operation",
	  "consumed_operation_count",
	  "authorization_batch_within_budget",
	  "app_password_prompt_used: false"
	]) {
  assert(secureMeshSecretStoreRustSource.includes(token),
    `Rust macOS platform secret store must preserve system LocalAuthentication token ${token}`);
}
for (const token of [
  "RuntimeSecretContext",
  "MobileRelaySecretStoreAuthBatch",
  "shared_authorization_session",
  "if self.session.is_none()",
  "self.session = Some(store.begin_authorized_session",
  "mobile_relay_pairwise_operation_with_runtime_secret_context",
  "authorizationBatchPromptBudgetReady",
  "authorization_batch_operation_count",
  "authorization_batch_consumed_operation_count",
  "authorization_batch_remaining_operation_count",
  "\"operationCount\"",
  "\"consumedOperationCount\"",
  "\"remainingOperationCount\"",
  "authorizationBatchWithinBudget",
  "system_authorization_attempt_count == 1",
  "system_authorization_completed",
  "!app_password_prompt_used",
  "!app_credential_prompt_used",
  "e2ee_status_requires_single_system_authorization_prompt_budget"
]) {
  assert(mobileRelayRustSource.includes(token),
    `Mobile Relay runtime secrets must reuse one system authorization batch token ${token}`);
}
for (const token of [
  "loadSecureMeshPlatformSecretStoreMatrixConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "normalizeNativeTestFilters",
  "assertNoLeak",
  "source checks must have unique ids",
  "native test filters must be unique"
]) {
  assert(platformSecretStoreMatrixConfigHelper.includes(token),
    `platform secret-store matrix config helper must keep safety token ${token}`);
}
for (const token of [
  "const reportPath = \"build/reports/secure-mesh-platform-secret-store-matrix.json\"",
  "const windowsImplementationReportPath = \"build/reports/secure-mesh-windows-implementation.json\"",
  "\"build/client-cli-vm/ubuntu-arm64/mobile-relay-secret-store-self-test.json\"",
  "\"build/reports/secure-mesh-release-cli-proof-macos.json\"",
  "\"build/reports/secure-mesh-macos-keychain-user-presence-proof.json\"",
  "\"build/client-cli-vm/ubuntu-arm64/secure-mesh-release-cli-proof.json\"",
  "\"build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-adaptive-custody-proof.json\"",
  "\"build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-package-update-proof.json\"",
  "evidenceCommands: [\"npm run client:verify:architecture\"]",
  "\"npm run client:cli:vm:verify -- --distro ubuntu\""
]) {
  assert(!platformSecretStoreMatrix.includes(token),
    `platform secret-store matrix must load configured evidence ref instead of hardcoding ${token}`);
}
const physicalDeviceMatrix = await readText("tools/scripts/client-secure-mesh-physical-device-matrix.mjs");
const physicalDeviceMatrixConfig =
  await readText("tools/scripts/config/secure-mesh-physical-device-matrix.json");
const physicalDeviceMatrixConfigJson =
  await readJson("tools/scripts/config/secure-mesh-physical-device-matrix.json");
const physicalDeviceMatrixConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-physical-device-matrix-config.mjs");
for (const token of [
  "loadSecureMeshPhysicalDeviceMatrixConfig",
  "physicalDeviceMatrixConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "physicalEvidenceConfig.reportOutput",
  "reportPath = physicalReportRefs.physicalDeviceMatrix",
  "relayMockCoverage",
  "androidPlatformCryptoCoverage",
  "deriveMatrix",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "physical device matrix",
  "contractBinding"
]) {
  assert(physicalDeviceMatrix.includes(token) || physicalDeviceMatrixConfig.includes(token),
    `physical device matrix evidence report must keep contract-bound token ${token}`);
}
assert(physicalDeviceMatrix.includes("physicalDeviceMatrixConfig.sourceChecks.map(evaluateSourceCheck)") &&
  physicalDeviceMatrix.includes("physicalDeviceMatrixConfig.physicalMatrix.map((entry)") &&
  !physicalDeviceMatrix.includes("const sourceChecks = Object.freeze([") &&
  !physicalDeviceMatrix.includes("const physicalMatrix = Object.freeze(["),
  "physical device matrix must load source checks and physical scenarios from config instead of hardcoding inline arrays");
assert(physicalDeviceMatrix.includes("validateSecureMeshTrustUxV2Report") &&
  physicalDeviceMatrix.includes("trustContract.contractReady"),
  "physical device matrix must consume the Trust UX v2 contract fail-closed");
for (const token of [
  "licolite.secure-mesh.physical-device-matrix-config.v2",
  "sourceChecks",
  "physicalMatrix",
  "pairing-and-trust",
  "command-result",
  "file-handoff",
  "relay-protocol",
  "android-platform-crypto-acceptance-is-client-owned-and-redacted",
  "client-relay-mock-exercises-pinned-opaque-protocol",
  "physical-evidence-config-links-current-client-reports",
  "physical-evidence-manifest-consumes-relay-and-platform-crypto"
]) {
  assert(physicalDeviceMatrixConfig.includes(token),
    `physical device matrix config must keep token ${token}`);
}
assert(Array.isArray(physicalDeviceMatrixConfigJson.sourceChecks) &&
  physicalDeviceMatrixConfigJson.sourceChecks.length >= 9 &&
  Array.isArray(physicalDeviceMatrixConfigJson.physicalMatrix) &&
  physicalDeviceMatrixConfigJson.physicalMatrix.length >= 5,
  "physical device matrix config must define source checks and physical scenarios");
const physicalDeviceMatrixSourceCheckIds = new Set(
  physicalDeviceMatrixConfigJson.sourceChecks.map((check) => check.id)
);
for (const id of [
  "android-platform-crypto-acceptance-is-client-owned-and-redacted",
  "ios-client-tests-shared-rust-crypto-lifecycle",
  "client-relay-mock-exercises-pinned-opaque-protocol",
  "physical-evidence-config-links-current-client-reports",
  "physical-device-matrix-consumes-relay-and-platform-crypto"
]) {
  assert(physicalDeviceMatrixSourceCheckIds.has(id),
    `physical device matrix config must keep current client-owned source check ${id}`);
}
for (const token of [
  "loadSecureMeshPhysicalDeviceMatrixConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "normalizePhysicalMatrix",
  "assertNoLeak"
]) {
  assert(physicalDeviceMatrixConfigHelper.includes(token),
    `physical device matrix config helper must keep token ${token}`);
}
assert(!/const\s+(?:reportRefs|linkedReports)\s*=\s*Object\.freeze/u.test(physicalDeviceMatrix),
  "physical device matrix must load linked reports from the v2 physical evidence config");
const physicalEvidenceManifest = await readText("tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs");
const physicalEvidenceConfig = await readText("tools/scripts/config/secure-mesh-physical-evidence.json");
const physicalEvidenceConfigJson = await readJson("tools/scripts/config/secure-mesh-physical-evidence.json");
for (const token of [
  "licolite.secure-mesh.physical-evidence-config.v2",
  "build/reports/secure-mesh-physical-evidence-manifest.json",
  "build/reports/secure-mesh-android-platform-crypto-acceptance.json",
  "build/reports/secure-client-relay-mock-e2e.json",
  "build/reports/android-physical-install-launch.json",
  "build/client-cli-vm/ubuntu-arm64/mobile-relay-secret-store-self-test.json",
  "build/reports/secure-mesh-release-cli-proof-macos.json",
  "build/reports/secure-mesh-macos-keychain-user-presence-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-release-cli-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-adaptive-custody-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-package-update-proof.json",
  "build/reports/secure-mesh-platform-secret-store-matrix.json",
  "build/reports/secure-mesh-physical-device-matrix.json",
  "build/reports/secure-mesh-encrypted-file-handoff.json",
  "build/reports/secure-mesh-trust-ux.json",
  "build/reports/secure-mesh-windows-implementation.json",
  "build/reports/client-update-release-channel.json",
  "freshnessWindows",
  "androidPlatformCryptoSeconds",
  "evidenceCommands",
  "npm run client:verify:secure-client-relay-mock-e2e",
  "npm run client:test:android:native",
  "npm run client:build:android",
  "node tools/scripts/client-android-physical-install-launch.mjs --install --launch --apk build/apps/desktop/android/release/app-release.apk",
  "npm run client:verify:mobile-simulator-closure:ios",
  "npm run client:verify:secure-mesh-macos-keychain-user-presence",
  "npm run client:verify:secure-mesh-release-cli-proof",
  "npm run client:verify:macos-bundle",
  "npm run client:verify:windows-file-security",
  "npm run client:verify:secure-mesh-windows-implementation",
  "npm run client:cli:vm:verify -- --distro ubuntu",
  "npm run client:cli:vm:linux-product -- --distro ubuntu",
  "npm run client:verify:secure-mesh-linux-adaptive-custody",
  "npm run client:verify:secure-mesh-linux-package-update"
]) {
  assert(physicalEvidenceConfig.includes(token),
    `physical evidence config must keep linked report token ${token}`);
}
assert(Object.keys(physicalEvidenceConfigJson.linkedReports || {}).length === 17,
  "physical evidence config must define every linked physical evidence input report");
assert(Object.keys(physicalEvidenceConfigJson.evidenceCommands || {}).length === 5,
  "physical evidence config must define every platform evidence command list");
assert(Object.keys(physicalEvidenceConfigJson.freshnessWindows || {}).length === 1 &&
  Number.isInteger(physicalEvidenceConfigJson.freshnessWindows.androidPlatformCryptoSeconds),
  "physical evidence config must define the Android platform crypto freshness window");
assert((physicalEvidenceConfigJson.evidenceCommands?.android || []).includes("npm run client:test:android:native") &&
  (physicalEvidenceConfigJson.evidenceCommands?.android || []).includes("npm run client:verify:secure-client-relay-mock-e2e") &&
  (physicalEvidenceConfigJson.evidenceCommands?.android || []).includes("node tools/scripts/client-android-physical-install-launch.mjs --install --launch --apk build/apps/desktop/android/release/app-release.apk") &&
  !(physicalEvidenceConfigJson.evidenceCommands?.android || []).some((command) =>
    command.includes("app-debug.apk")),
  "physical evidence config must expose Android release install/launch and reject debug physical receipts");
assert((physicalEvidenceConfigJson.evidenceCommands?.ios || []).includes("npm run client:verify:mobile-simulator-closure:ios") &&
  (physicalEvidenceConfigJson.evidenceCommands?.ios || []).includes("npm run client:verify:secure-client-relay-mock-e2e"),
  "physical evidence config must expose iOS client simulator and relay Mock commands");
assert((physicalEvidenceConfigJson.evidenceCommands?.macos || []).includes("npm run client:verify:secure-mesh-macos-keychain-user-presence") &&
  (physicalEvidenceConfigJson.evidenceCommands?.linux || []).includes("npm run client:verify:secure-mesh-linux-adaptive-custody") &&
  (physicalEvidenceConfigJson.evidenceCommands?.windows || []).includes("npm run client:verify:secure-mesh-windows-implementation"),
  "physical evidence config must expose platform secret-store and adaptive custody evidence commands");
const physicalEvidenceConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-physical-evidence-config.mjs");
for (const token of [
  "loadSecureMeshPhysicalEvidenceConfig",
  "requiredLinkedReportKeys",
  "requiredEvidenceCommandKeys",
  "normalizeSafeReportRef",
  "normalizeEvidenceCommands",
  "normalizeEvidenceCommand",
  "normalizeFreshnessWindows",
  "normalizeFreshnessWindowSeconds",
  "requiredFreshnessWindowKeys",
  "assertNoLeak",
  "must not link its own output as an input report",
  "contains unknown linked report keys",
  "is missing linked report keys",
  "contains unknown evidence command keys",
  "is missing evidence command keys",
  "evidence command list must not be empty",
  "freshness window keys"
]) {
  assert(physicalEvidenceConfigHelper.includes(token),
    `physical evidence config helper must keep safety token ${token}`);
}
for (const token of [
  "freshnessWindows",
  "linkedReportFreshness",
  "evaluateFreshness",
  "linkedReportFreshnessReady",
  "linkedReportFreshnessStaleOrInvalidCount",
  "androidPlatformCryptoFreshnessReady",
  "relayProtocolMockReady",
  "androidPlatformCryptoAcceptanceReady",
  "mlsMemberRemoveReleaseActionReady",
  "relayMockCoverage",
  "androidPlatformCryptoCoverage",
  "client-owned relay Mock protocol acceptance"
]) {
  assert(physicalEvidenceManifest.includes(token),
    `physical evidence manifest must keep linked-report freshness token ${token}`);
}
const androidInstallLaunchVerifier =
  await readText("tools/scripts/client-android-physical-install-launch.mjs");
const androidMainActivity =
  await readText("apps/desktop/android/app/src/main/kotlin/com/liko/arc/MainActivity.kt");
const androidSecureMeshSecretStore =
  await readText("apps/desktop/android/app/src/main/kotlin/com/liko/arc/SecureMeshAndroidSecretStore.kt");
const androidSecureMeshUserAuthenticator =
  await readText("apps/desktop/android/app/src/main/kotlin/com/liko/arc/SecureMeshAndroidUserAuthenticator.kt");
const androidAuthBoundarySources = [
  androidMainActivity,
  androidSecureMeshSecretStore,
  androidSecureMeshUserAuthenticator
].join("\n");
const iosSecureMeshBridge =
  await readText("apps/desktop/ios/Runner/SecureMeshIosBridge.swift");
const iosSecureMeshSecretStore =
  await readText("apps/desktop/ios/Runner/SecureMeshIosBridge+SecretStore.swift");
for (const token of [
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "reportPath = physicalReportRefs.androidInstallLaunch"
]) {
  assert(androidInstallLaunchVerifier.includes(token),
    `Android install/launch verifier must derive its report ref from config token ${token}`);
}
for (const token of [
  "SecureMeshAndroidUserAuthenticator(this)",
  "secureMeshAndroidUserAuthenticator.request(params)",
  "secureMeshAndroidUserAuthenticator.status()",
  "secureMeshAndroidUserAuthenticator.onActivityResult(requestCode, resultCode)",
  "private fun runNativeSecureMeshJsonObject",
  "secureMeshAndroidSecretStore.captureMobileRelaySecretsFromNativeResponse(responseJson)"
]) {
  assert(androidMainActivity.includes(token),
    `Android MainActivity must delegate Secure Mesh platform work through separated modules token ${token}`);
}

for (const token of [
  "class SecureMeshAndroidUserAuthenticator",
  "KeyguardManager",
  "createConfirmDeviceCredentialIntent",
  "startActivityForResult(prompt, REQUEST_CODE)",
  "systemCredentialPromptAvailable",
  "systemCredentialPromptStarted",
  "systemCredentialPromptCompleted",
  "systemCredentialPromptResultCodePresent",
  "systemCredentialPromptResultCode",
  "systemCredentialPromptResult",
  "systemCredentialPromptReusedFromPendingRequest",
  "pendingLatch",
  "userActionRequired",
	  "credentialEntrySurface",
	  "android_system_credential_prompt",
	  "systemCredentialPromptReusedFromPendingRequest",
	  "appCredentialPromptUsed",
		  "appPasswordPromptUsed",
		  "physicalUserPresenceRequired",
		  "systemAuthenticationOnly",
		  "appLockScreenCredentialCollection",
		  ".put(\"systemAuthenticationOnly\", true)",
		  ".put(\"appLockScreenCredentialCollection\", false)",
		  ".put(\"appCredentialPromptUsed\", false)",
		  ".put(\"appPasswordPromptUsed\", false)",
	  "keyMaterialExported",
  "bodyRedacted"
]) {
  assert(androidSecureMeshUserAuthenticator.includes(token),
    `Android Secure Mesh authentication must use a dedicated system credential module token ${token}`);
}
for (const forbidden of [
  "lockScreenPassword",
  "screenPassword",
	  "devicePasswordInput",
	  "EditText",
	  "TextInputEditText",
	  "TextField",
	  "OutlinedTextField",
	  "BasicTextField",
		  "PasswordTransformationMethod",
		  "PasswordVisualTransformation",
		  "KeyboardType.Password",
		  "TYPE_TEXT_VARIATION_PASSWORD",
		  "TYPE_NUMBER_VARIATION_PASSWORD",
		  "numberPassword",
		  "textPassword",
		  "lockScreenPin",
		  "devicePin",
		  "pinCode",
		  "setInputType",
		  "inputType",
		  ".put(\"appCredentialPromptUsed\", true)",
		  ".put(\"appPasswordPromptUsed\", true)",
		  ".put(\"appLockScreenCredentialCollection\", true)",
		  "\"appCredentialPromptUsed\" to true",
		  "\"appPasswordPromptUsed\" to true",
		  "\"appLockScreenCredentialCollection\" to true",
		  "appCredentialPromptUsed = true",
		  "appPasswordPromptUsed = true",
		  "appLockScreenCredentialCollection = true"
]) {
  assert(!androidAuthBoundarySources.includes(forbidden),
    `Android Secure Mesh authentication must not collect lock-screen credentials in app via ${forbidden}`);
}
for (const token of [
  "class SecureMeshAndroidSecretStore",
  "secureMeshAndroidSecretStoreSet",
  "secureMeshAndroidSecretStoreGet",
  "secureMeshAndroidSecretStoreDelete",
  "selectedMobileRelayCustody",
  "SecureMeshAndroidKeyPolicyStrategy.candidates",
  "AndroidCustodySelection.MemoryOnly",
  "secureMeshAndroidCapabilityProbeJson",
  "setUserAuthenticationRequired(true)",
  "setUserAuthenticationParameters",
  "AUTH_DEVICE_CREDENTIAL",
  "AUTH_BIOMETRIC_STRONG",
  "ANDROID_MOBILE_RELAY_SECRET_STORE_KEY_ALIAS",
  "android-mobile-relay-secrets",
  "mobileRelayE2eeSecretStore",
  "rawJsonSecretOverridesUsed"
]) {
  assert(androidSecureMeshSecretStore.includes(token),
    `Android Secure Mesh secret-store backend must live in SecureMeshAndroidSecretStore.kt token ${token}`);
}
for (const forbiddenToken of [
  "overrides.put(\"pcToken\"",
  "overrides.put(\"mobileToken\"",
  "overrides.put(\"pairedDevices\""
]) {
  assert(!androidSecureMeshSecretStore.includes(forbiddenToken),
    `Android Secure Mesh secret-store overrides must use opaque handles instead of raw token JSON via ${forbiddenToken}`);
}
for (const forbiddenToken of [
  "overrides[\"pcToken\"]",
  "overrides[\"mobileToken\"]",
  "overrides[\"pairedDevices\"]"
]) {
  assert(!iosSecureMeshSecretStore.includes(forbiddenToken),
    `iOS Secure Mesh secret-store overrides must use opaque handles instead of raw token JSON via ${forbiddenToken}`);
}

for (const token of [
  "androidKeyStoreStatus",
  "writeAndroidSecureStoreRecord",
  "ANDROID_SECURE_STORE_KEY_ALIAS",
  "ANDROID_SECURE_STORE_AAD_MAGIC",
  "ANDROID_SECURE_STORE_PLAINTEXT_MAGIC",
  "KeyGenerator.getInstance",
  "Cipher.getInstance(ANDROID_SECURE_STORE_CIPHER)",
  "setUserAuthenticationRequired(true)",
  "AUTH_DEVICE_CREDENTIAL",
  "AUTH_BIOMETRIC_STRONG",
  "selectedMobileRelayCustody",
  "capabilityProbe",
  "restartSemantics"
]) {
  assert(androidSecureMeshSecretStore.includes(token),
    `Android Secure Mesh KeyStore implementation must live in SecureMeshAndroidSecretStore.kt token ${token}`);
}
for (const forbiddenToken of [
  "fun secureMeshAndroidSecretStoreSet",
  "fun secureMeshAndroidSecretStoreGet",
  "fun secureMeshAndroidSecretStoreDelete",
  "fun ensureAndroidMobileRelaySecretStoreKey",
  "ANDROID_MOBILE_RELAY_SECRET_STORE_KEY_ALIAS",
  "ANDROID_MOBILE_RELAY_SECRET_KIND",
  "android-mobile-relay-secrets",
  "filesDir.absolutePath\n        )"
]) {
  assert(!androidMainActivity.includes(forbiddenToken),
    `MainActivity must delegate Mobile Relay secret-store backend instead of defining ${forbiddenToken}`);
}

for (const forbiddenToken of [
  "fun androidKeyStoreStatus",
  "fun ensureAndroidSecureStoreKey",
  "fun androidSecretKeyRequiresUserAuthentication",
  "fun androidEndpointSigningKeyRequiresUserAuthentication",
  "fun applyAndroidUserAuthenticationPolicy",
  "fun androidDeviceCredentialIsConfigured",
  "fun ensureAndroidEndpointSigningKey",
  "fun androidEndpointSigningEntry",
  "fun signAndroidEndpointChallenge",
  "fun writeAndroidSecureStoreProof",
  "fun writeAndroidSecureStoreRecord",
  "fun writeAndroidSecureStoreRecordToFile",
  "fun readAndroidSecureStoreProbeRecord",
  "fun readAndroidSecureStoreRecordFromFile",
  "buildAndroidSecureStoreAad",
  "encodeAndroidSecureStorePlaintext",
  "decodeAndroidSecureStorePlaintext",
  "ANDROID_ENDPOINT_SIGNING_KEY_ALIAS",
  "ANDROID_SECURE_STORE_KEY_ALIAS",
  "ANDROID_SECURE_STORE_AAD_MAGIC",
  "ANDROID_SECURE_STORE_PLAINTEXT_MAGIC",
  "KeyPairGenerator.getInstance",
  "KeyGenerator.getInstance",
  "Cipher.getInstance(ANDROID_SECURE_STORE_CIPHER)",
  "Signature.getInstance(ANDROID_ENDPOINT_SIGNING_ALGORITHM)"
]) {
  assert(!androidMainActivity.includes(forbiddenToken),
    `MainActivity must delegate Android KeyStore implementation details to SecureMeshAndroidSecretStore.kt instead of defining ${forbiddenToken}`);
}
for (const token of [
  "ANDROID_AUTHENTICATED_PAIRWISE_RUNTIME_STATUS",
  "authenticatedPairwiseV2RuntimeReady",
  "runtimeStatusRedacted",
  "rawPayloadExportSurfaceAbsent",
  "objectContainsAnyKeyOrValue",
  "validateAndroidCapabilityProbe",
  "validateAndroidCapabilityMeasurements",
  "summarizeAndroidCapabilityStore",
  "androidCustodyReady",
  "adaptiveAuthorizationReady"
]) {
  assert(androidInstallLaunchVerifier.includes(token),
    `Android install/launch evidence must preserve redacted pairwise v2 runtime token ${token}`);
}
for (const token of [
  "classifyAndroidAdbPhysicalDevice",
  "classifyAndroidGetpropPhysicalDevice",
  "androidPhysicalDeviceProof",
  "androidAdbTransportAuthorized",
  "androidPhysicalDeviceProofReady",
  "androidDeviceClass",
  "androidGetpropProbeReady",
  "androidEmulatorSignalCategories",
  "androidPhysicalSignalCategories",
  "androidGetpropMissingFields",
  "androidGetpropAmbiguousFields",
  "rawGetpropIncluded",
  "rawDeviceIdentifiersIncluded",
  "ro.kernel.qemu",
  "ro.boot.qemu",
  "ro.build.characteristics",
  "ro.hardware",
  "ro.boot.hardware",
  "ro.product.model",
  "ro.build.fingerprint",
  "androidPhysicalDeviceProofMissingFields",
  "androidPhysicalDeviceProofWeakProofFields"
]) {
  assert(androidInstallLaunchVerifier.includes(token),
    `Android install/launch verifier must preserve non-emulator device proof token ${token}`);
}
for (const token of [
  "mobileRelaySecretStoreContractReady",
  "androidCustodyReady",
  "adaptiveAuthorizationReady",
  "rawJsonSecretOverridesUsedPresent",
  "rawJsonSecretOverridesUnknown",
  "applicationAuthorizationGrantRequired",
  "custodyStrategy",
  "restartSemantics",
  "enabledCapabilities"
]) {
  assert(androidInstallLaunchVerifier.includes(token),
    `Android install/launch verifier must preserve Mobile Relay secret-store schema token ${token}`);
}
for (const forbiddenToken of [
  "lockScreenPassword",
  "screenLockPassword",
  "devicePassword",
  "deviceCredentialPassword",
	  "devicePasswordInput",
	  "userEnteredPassword",
	  "appLockPassword",
	  "EditText",
	  "TextInputEditText",
	  "TextField",
	  "OutlinedTextField",
	  "BasicTextField",
		  "PasswordTransformationMethod",
		  "PasswordVisualTransformation",
		  "KeyboardType.Password",
		  "TYPE_TEXT_VARIATION_PASSWORD",
		  "TYPE_NUMBER_VARIATION_PASSWORD",
		  "numberPassword",
		  "textPassword",
		  "lockScreenPin",
		  "devicePin",
		  "pinCode",
		  "setInputType",
		  "inputType",
	  ".put(\"appCredentialPromptUsed\", true)",
	  ".put(\"appPasswordPromptUsed\", true)",
	  "\"appCredentialPromptUsed\" to true",
	  "\"appPasswordPromptUsed\" to true",
	  "appCredentialPromptUsed = true",
	  "appPasswordPromptUsed = true"
	]) {
  assert(!androidAuthBoundarySources.includes(forbiddenToken),
    `Android Secure Mesh authentication must not collect lock-screen credentials in-app via ${forbiddenToken}`);
}
for (const token of [
  "iosCallbackAuthContextAttachedToAllOperations",
  "sharedSystemAuthorizationContextRequired",
  "sharedSystemAuthorizationContextAvailable",
  "systemAuthorizationAttemptCount",
  "systemAuthorizationCompleted",
  "authorizationBatchPromptBudgetReady",
  "authorizationBatchOperationCount",
  "authorizationBatchConsumedOperationCount",
  "authorizationBatchRemainingOperationCount",
  "authorizationBatchWithinBudget",
  "allowableReuseDurationSeconds",
  "authenticationReuseWindowConfigured"
]) {
  assert(iosSecureMeshBridge.includes(token),
    `iOS Secure Mesh bridge must preserve single system authorization batch token ${token}`);
}
const linuxPackageUpdateProof =
  await readText("tools/scripts/client-secure-mesh-linux-package-update-proof.mjs");
const macosUserPresenceProof =
  await readText("tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs");
const linuxAdaptiveCustodyProof =
  await readText("tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs");
const linuxVmPackageReceipt =
  await readText("tools/scripts/client-secure-mesh-linux-vm-package-receipt.mjs");
const linuxNodeMatrix =
  await readText("tools/scripts/client-secure-mesh-linux-node-matrix.mjs");
const linuxNodeLifecycle =
  await readText("tools/scripts/lib/secure-mesh-linux-node.mjs");
const linuxEvidenceSchema =
  await readText("tools/scripts/lib/secure-mesh-linux-evidence.mjs");
const linuxNodeDockerfile =
  await readText("apps/desktop/docker/secure-mesh-node.Dockerfile");
const releaseCliProof =
  await readText("tools/scripts/client-secure-mesh-release-cli-proof.mjs");
for (const [source, relativePath, tokens] of [
  [
    linuxVmPackageReceipt,
    "tools/scripts/client-secure-mesh-linux-vm-package-receipt.mjs",
    [
      "validateLinuxVmPackageReceipt",
      "expectedSourceDigest",
      "installedFromArchive",
      "signatureVerified",
      "publicKeyFingerprint",
      "x11_virtual_display",
      "exactCapabilitySchema"
    ]
  ],
  [
    linuxNodeMatrix,
    "tools/scripts/client-secure-mesh-linux-node-matrix.mjs",
    [
      "LinuxClientNode",
      "validateLinuxNodeMatrixReport",
      "publicOperationsOnly",
      "noSharedSecretVolume",
      "restartRequiresRePairRekey",
      "exchangeSecureCommand"
    ]
  ],
  [
    linuxNodeLifecycle,
    "tools/scripts/lib/secure-mesh-linux-node.mjs",
    [
      "--read-only",
      "--tmpfs",
      "portableDataDir",
      "restartRpc",
      "rpcStopped",
      "this.removed"
    ]
  ],
  [
    linuxEvidenceSchema,
    "tools/scripts/lib/secure-mesh-linux-evidence.mjs",
    [
      "validateCapabilityReport",
      "reportLeakScan",
      "runtimeIdentityIncluded",
      "dbusOrObjectDataIncluded",
      "rawPlaintextIncluded",
      "rawCiphertextIncluded",
      "rawSecretsIncluded"
    ]
  ],
  [
    linuxNodeDockerfile,
    "apps/desktop/docker/secure-mesh-node.Dockerfile",
    ["USER 65534:65534", "COPY client ${CLIENT_ROOT}", "WORKDIR ${CLIENT_ROOT}", "lico-client"]
  ]
]) {
  for (const token of tokens) {
    assert(source.includes(token), `${relativePath} must preserve Linux product proof token ${token}`);
  }
}
for (const [source, relativePath, tokens] of [
  [
    linuxPackageUpdateProof,
    "tools/scripts/client-secure-mesh-linux-package-update-proof.mjs",
    [
      "loadSecureMeshPhysicalEvidenceConfig",
      "physicalEvidenceConfig",
      "physicalReportRefs",
      "defaultReportPath = physicalReportRefs.ubuntuLinuxPackageUpdateProof"
    ]
  ],
  [
    macosUserPresenceProof,
    "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
    [
      "loadSecureMeshPhysicalEvidenceConfig",
      "physicalEvidenceConfig",
      "physicalReportRefs",
      "defaultReportPath = physicalReportRefs.macosUserPresenceProof"
    ]
  ],
  [
    linuxAdaptiveCustodyProof,
    "tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs",
    [
      "loadSecureMeshPhysicalEvidenceConfig",
      "physicalEvidenceConfig",
      "physicalReportRefs",
      "defaultReportPath = physicalReportRefs.ubuntuLinuxAdaptiveCustodyProof"
    ]
  ],
  [
    releaseCliProof,
    "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
    [
      "loadSecureMeshPhysicalEvidenceConfig",
      "physicalEvidenceConfig",
      "physicalReportRefs",
      "defaultReleaseCliReportPath",
      "physicalReportRefs.macosReleaseCliProof",
      "physicalReportRefs.ubuntuReleaseCliProof"
    ]
  ]
]) {
  for (const token of tokens) {
    assert(source.includes(token),
      `${relativePath} must derive default report refs from physical evidence config token ${token}`);
  }
}
for (const [source, relativePath, token] of [
  [
    linuxPackageUpdateProof,
    "tools/scripts/client-secure-mesh-linux-package-update-proof.mjs",
    "const defaultReportPath = \"build/reports/secure-mesh-linux-package-update-proof.json\""
  ],
  [
    macosUserPresenceProof,
    "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
    "const defaultReportPath = \"build/reports/secure-mesh-macos-keychain-user-presence-proof.json\""
  ],
  [
    linuxAdaptiveCustodyProof,
    "tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs",
    "const defaultReportPath = \"build/reports/secure-mesh-linux-adaptive-custody-proof.json\""
  ],
  [
    releaseCliProof,
    "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
    "const defaultReportPath = \"build/reports/secure-mesh-release-cli-proof.json\""
  ]
]) {
  assert(!source.includes(token),
    `${relativePath} must load configured default report ref instead of hardcoding ${token}`);
}
for (const token of [
  "appPasswordPromptUsed",
  "payload.appCredentialPromptUsed !== true",
  "payload.appPasswordPromptUsed !== true",
  "singleAuthorizationContextCreated",
  "singleAuthorizationContextSharedByOperations",
  "promptBudgetSatisfied",
  "zeroBackgroundPrompts",
  "noAutomaticAuthorizationRetry",
  "interactiveWorkflowSelected",
  "interactiveAuthorizationSucceeded",
  "interactiveAuthorizationAttemptCount = 1",
  "options.interactive === true",
  "kSecUseAuthenticationContext",
  "maximumInteractiveAuthorizationAttemptsPerProof: 1",
  "reduceCapabilityFacts",
  "validateCapabilityReport",
  "standardKeychainAvailable",
  "dataProtectionKeychainAvailable",
  "userPresenceOperationSupported",
  "secureEnclaveOperationSupported",
  "falseEnhancementClaimRejected"
]) {
  assert(macosUserPresenceProof.includes(token),
    `macOS user-presence proof must keep single system authorization diagnostic token ${token}`);
}
for (const token of [
  "capabilityReport",
  "enabledCapabilities",
  "custodyStrategy",
  "exactCapabilitySetValid",
  "safeOsStoreAvailable",
  "standardKeychainAvailable",
  "dataProtectionKeychainAvailable",
  "userPresenceOperationSupported",
  "secureEnclaveOperationSupported",
  "singleSystemAuthorizationContextVerified",
  "macosAdaptiveCustodyReady",
  "macosEnabledCapabilities",
  "macosPromptBudgetSatisfied",
  "macosZeroBackgroundPrompts",
  "macosAppPasswordPromptUsed"
]) {
  assert(platformSecretStoreMatrix.includes(token),
    `platform secret-store matrix must keep macOS adaptive capability token ${token}`);
}
assert(!/const\s+reportRefs\s*=\s*Object\.freeze/u.test(physicalEvidenceManifest),
  "physical evidence manifest must load report refs from config instead of hardcoding them");
for (const token of [
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "relayMockCoverage",
  "androidPlatformCryptoCoverage",
  "relayProtocolMockReady",
  "androidPlatformCryptoAcceptanceReady",
  "physicalEvidenceChainReady",
  "releaseEvidenceReady",
  "reportLeakScan"
]) {
  assert(physicalEvidenceManifest.includes(token),
    `physical evidence manifest must keep current client evidence token ${token}`);
}
const trustUx = await readText("tools/scripts/client-secure-mesh-trust-ux.mjs");
const trustUxConfig = await readText("tools/scripts/config/secure-mesh-trust-ux.json");
const trustUxConfigJson = await readJson("tools/scripts/config/secure-mesh-trust-ux.json");
const trustUxConfigHelper = await readText("tools/scripts/lib/secure-mesh-trust-ux-config.mjs");
const trustUxReducer = await readText("tools/scripts/lib/secure-mesh-trust-ux-reducer.mjs");
const clientReleaseAcceptance = await readText("tools/scripts/client-release-acceptance.mjs");
const clientReleaseAcceptanceConfig = await readJson("tools/scripts/config/client-release-acceptance.json");
for (const token of [
  "loadSecureMeshTrustUxConfig",
  "trustUxConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "reportPath = physicalReportRefs.trustUx",
  "physicalReportRefs.androidPlatformCrypto",
  "androidPlatformTrustEvidence",
  "physical-peer-trust-not-proven",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "trust UX",
  "contractBinding"
]) {
  assert(trustUx.includes(token) || trustUxConfig.includes(token),
    `trust UX evidence report/config must keep contract-bound token ${token}`);
}
assert(trustUx.includes("sourceChecks,") &&
  trustUx.includes("nativeTestFilters,") &&
  trustUx.includes("productTestTargets,") &&
  trustUx.includes("expectedMobileNativeTrustActions") &&
  !trustUx.includes("const sourceChecks = Object.freeze([") &&
  !trustUx.includes("const nativeTestFilters = Object.freeze([") &&
  !trustUx.includes("const expectedMobileNativeTrustActions = Object.freeze(["),
  "trust UX must load source checks, native filters, and mobile trust actions from config instead of hardcoding inline arrays");
for (const token of [
  "licolite.secure-mesh.trust-ux-config.v2",
  "sourceChecks",
  "nativeTestFilters",
  "productTestTargets",
  "apps/desktop/test/mobile_relay_service_test.dart",
  "apps/desktop/test/secure_mesh_panel_test.dart",
  "expectedMobileNativeTrustActions",
  "trust-helper-provides-cross-signing-sas-qr-and-key-change-policy",
  "pub fn sign_device_trust_record",
  "pub fn verify_device_trust_record_json",
  "secure_mesh_device_trust_record_signature_binds_peer_and_expiry",
  "android-release-channel-allows-shared-rust-trust-actions",
  "ios-client-tests-shared-rust-trust-lifecycle",
  "client-release-plan-keeps-trust-and-client-crypto-gates-open",
  "selected-target-trust-reducer-is-v2-and-fail-closed",
  "secure_mesh.deviceTrust.verifyQr"
]) {
  assert(trustUxConfig.includes(token),
    `trust UX config must keep token ${token}`);
}
assert(Array.isArray(trustUxConfigJson.sourceChecks) &&
  trustUxConfigJson.sourceChecks.length >= 11 &&
  Array.isArray(trustUxConfigJson.nativeTestFilters) &&
  trustUxConfigJson.nativeTestFilters.length >= 7 &&
  Array.isArray(trustUxConfigJson.productTestTargets) &&
  trustUxConfigJson.productTestTargets.length >= 2 &&
  Array.isArray(trustUxConfigJson.expectedMobileNativeTrustActions) &&
  trustUxConfigJson.expectedMobileNativeTrustActions.length >= 6,
  "trust UX config must define source checks, native test filters, and expected mobile native trust actions");
for (const token of [
  "loadSecureMeshTrustUxConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "normalizeNativeTestFilters",
  "normalizeProductTestTargets",
  "normalizeExpectedMobileNativeTrustActions",
  "assertNoLeak",
  "source checks must have unique ids"
]) {
  assert(trustUxConfigHelper.includes(token),
    `trust UX config helper must keep safety token ${token}`);
}
for (const token of [
  "licolite.secure-mesh.trust-ux-report.v2",
  "SECURE_MESH_TRUST_UX_SELECTED_TARGETS",
  "SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS",
  "SECURE_MESH_TRUST_UX_PRODUCT_TEST_ID",
  "reduceSecureMeshTrustUxReadiness",
  "validateSecureMeshTrustUxV2Report",
  "embeddedAndroidPhysicalTrustReady",
  "productionClaimSuppressed",
  "unknownAuthorityFieldsAbsent",
  "runSecureMeshTrustUxReducerSelfTest"
]) {
  assert(trustUxReducer.includes(token),
    `trust UX v2 reducer must keep fail-closed token ${token}`);
}
assert(trustUx.includes("reduceSecureMeshTrustUxReadiness") &&
  trustUx.includes("runSecureMeshTrustUxReducerSelfTest") &&
  trustUx.includes("runProductTests(productTestTargets)") &&
  trustUx.includes("productTestResults"),
  "trust UX producer must use the reproducible v2 reducer and expose its self-test");
assert(clientReleaseAcceptance.includes("validateSecureMeshTrustUxV2Report") &&
  clientReleaseAcceptance.includes("androidPlatformCryptoEvidenceReady") &&
  clientReleaseAcceptance.includes("selected_android_platform_crypto_evidence_not_ready") &&
  clientReleaseAcceptance.includes("selected_ios_${SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS}") &&
  clientReleaseAcceptance.includes("includeUnknownAuthorityField"),
  "client release acceptance must consume Trust UX v2 and keep unsupported iOS outside the physical trust gate");
assert(clientReleaseAcceptanceConfig.reports?.trust?.schemaVersion ===
    "licolite.secure-mesh.trust-ux-report.v2" &&
  clientReleaseAcceptanceConfig.reports?.trust?.producer ===
    "tools/scripts/client-secure-mesh-trust-ux.mjs",
  "client release acceptance config must bind the canonical Trust UX v2 producer");
assert(!trustUx.includes("const reportPath = \"build/reports/secure-mesh-trust-ux.json\""),
  "trust UX must load its report ref from the physical evidence config");
const releaseProofBundle = await readText("tools/scripts/client-secure-mesh-release-proof-bundle.mjs");
const releaseProofConfig = await readText("tools/scripts/config/secure-mesh-release-proof.json");
const releaseProofConfigJson = await readJson("tools/scripts/config/secure-mesh-release-proof.json");
for (const token of [
  "licolite.secure-mesh.release-proof-config.v1",
  "build/reports/secure-mesh-release-proof-bundle.json",
  "build/reports/client-update-release-channel.json",
  "build/reports/secure-mesh-physical-device-matrix.json",
  "build/reports/android-physical-install-launch.json",
  "build/reports/secure-mesh-physical-evidence-manifest.json",
  "build/reports/secure-mesh-windows-implementation.json",
  "build/reports/secure-mesh-release-input-report-redaction.json",
  "build/reports/secure-client-relay-mock-e2e.json",
  "build/reports/secure-mesh-pairwise-content-crypto-audit.json",
  "build/reports/secure-mesh-platform-secret-store-matrix.json",
  "build/reports/secure-mesh-android-platform-crypto-acceptance.json",
  "verifierCommands",
  "freshnessWindows",
  "androidPhysicalInstallLaunchSeconds",
  "sourceChecks",
  "client-update-release-channel",
  "client-secure-mesh-physical-evidence-manifest",
  "client-secure-mesh-report-redaction",
  "tests/verify-client-update-release-channel.mjs",
  "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
  "tools/scripts/client-secure-mesh-report-redaction-verify.mjs",
  "--release-proof-inputs",
  "LICO_SECURE_MESH_REDACTION_RUN_ID"
]) {
  assert(releaseProofConfig.includes(token),
    `release proof config must keep input report token ${token}`);
}
assert(Object.keys(releaseProofConfigJson.inputReports || {}).length === 10,
  "release proof config must define every release proof input report");
assert(Object.keys(releaseProofConfigJson.verifierCommands || {}).length === 3,
  "release proof config must define every release proof verifier command");
assert(Array.isArray(releaseProofConfigJson.sourceChecks) &&
  releaseProofConfigJson.sourceChecks.length >= 14,
  "release proof config must define source checks");
const releaseProofConfigHelper = await readText("tools/scripts/lib/secure-mesh-release-proof-config.mjs");
for (const token of [
  "loadSecureMeshReleaseProofConfig",
  "requiredInputReportKeys",
  "requiredVerifierCommandKeys",
  "normalizeSafeReportRef",
  "normalizeVerifierCommands",
  "normalizeVerifierCommand",
  "normalizeVerifierScript",
  "normalizeVerifierArg",
  "normalizeFreshnessWindows",
  "normalizeFreshnessWindowSeconds",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "renderVerifierCommand",
  "assertNoLeak",
  "must not include its own output as an input report",
  "contains unknown input report keys",
  "is missing input report keys",
  "contains unknown verifier command keys",
  "is missing verifier command keys",
  "verifier command ids must be unique",
  "source checks must have unique ids",
  "freshness window keys",
  "report redaction verifier must receive the configured redaction run id env"
]) {
  assert(releaseProofConfigHelper.includes(token),
    `release proof config helper must keep safety token ${token}`);
}
assert(releaseProofBundle.includes("sourceChecks = Object.freeze(releaseProofConfig.sourceChecks)") &&
  !releaseProofBundle.includes("const sourceChecks = Object.freeze(["),
  "release proof bundle must load source checks from config instead of hardcoding inline arrays");
assert(!/const\s+(?:updateReleaseReportPath|physicalMatrixReportPath|reportRedactionReportPath)\s*=/u.test(releaseProofBundle),
  "release proof bundle must load report refs from config instead of hardcoding them");
assert(!releaseProofBundle.includes("report?.ready === true"),
  "release proof bundle must not accept top-level ready as a replacement for releaseEvidenceReady");
for (const token of [
  "const commandArgs = [\"tests/verify-client-update-release-channel.mjs\"]",
  "const commandArgs = [\"tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs\"]",
  "tools/scripts/client-secure-mesh-report-redaction-verify.mjs\",\n    \"--release-proof-inputs\"",
  "command: \"node tests/verify-client-update-release-channel.mjs\"",
  "command: \"node tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs\"",
  "command: \"node tools/scripts/client-secure-mesh-report-redaction-verify.mjs --release-proof-inputs\""
]) {
  assert(!releaseProofBundle.includes(token),
    `release proof bundle must load configured verifier command instead of hardcoding ${token}`);
}
for (const token of [
  "loadSecureMeshReleaseProofConfig",
  "releaseProofConfig",
  "releaseProofConfig.verifierCommands",
  "runConfiguredVerifier",
  "verifierCommand.script",
  "reportRedactionVerifierCommand.runIdEnv",
  "summarizeReleaseInputFreshness",
  "evaluateReportFreshness",
  "releaseInputFreshness.ready === true",
  "verifierCommandCount",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "release proof bundle",
  "releaseInputIntegrity",
  "schema_or_source_mismatch",
  "schemaVersion",
  "evidenceRefSchemaVersion",
  "sourceOfTruth",
  "generatedBy",
  "reportLeakScan",
  "rawMaterialFlags",
  "contractBinding",
  "releaseProofRedactionRunId",
  "redactionRunIdMatched",
  "digestManifestExact",
  "scannedRefDigestsCurrent",
  "summarizeClientRelayCryptoInputs",
  "runClientRelayCryptoInputsReadinessSelfTest",
  "clientRelayCryptoInputs",
  "releaseInputRedactionCoversClientRefs",
  "relayMockExactFiveOperationsReady",
  "relayMockExactSixOuterFieldsReady",
  "relayMockReplayRejected",
  "relayMockStaleLeaseRejected",
  "relayMockAckIdempotencyReady",
  "relayMockPlaintextWireReady",
  "relayMockWireBytesSemanticsReady",
  "rustCryptoReportReady",
  "rustCryptoNativeTestsReady",
  "rustCryptoVectorCorpusReady",
  "rustCryptoReviewReady",
  "platformCryptoReportReady",
  "androidPlatformCryptoReportReady",
  "completeEvidenceAccepted",
  "invalidOperationCountRejected",
  "invalidOuterFieldCountRejected",
  "rawRustPlaintextRejected",
  "rawAndroidPrivateMaterialRejected",
  "legacyPlatformCryptoSchemaRejected",
  "physicalMatrixContractReadiness.ready === true",
  "physicalMatrixContractReadinessReady",
  "physicalEvidenceManifestContractReadiness.ready === true",
  "physicalEvidenceManifestContractReadinessReady",
  "runReleaseProofContractReadinessSelfTest",
  "forgedPhysicalMatrixSummaryReadyRejected",
  "forgedPhysicalEvidenceManifestSummaryReadyRejected",
  "androidPhysicalInstallLaunchLocalReadyDiagnosticOnly",
  "bundleDiagnosticOk"
]) {
  assert(releaseProofBundle.includes(token),
    `release proof bundle evidence report must keep contract-bound token ${token}`);
}
const windowsImplementation =
  await readText("tools/scripts/client-secure-mesh-windows-implementation.mjs");
const windowsImplementationConfig =
  await readText("tools/scripts/config/secure-mesh-windows-implementation.json");
const windowsImplementationConfigJson =
  await readJson("tools/scripts/config/secure-mesh-windows-implementation.json");
const windowsImplementationConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-windows-implementation-config.mjs");
for (const token of [
  "loadSecureMeshWindowsImplementationConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "windowsImplementationConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "reportPath = physicalReportRefs.windowsImplementation",
  "sourceChecks = Object.freeze(windowsImplementationConfig.sourceChecks)",
  "physicalEvidenceConfig"
]) {
  assert(windowsImplementation.includes(token),
    `Windows implementation must keep configured physical evidence ref token ${token}`);
}
assert(!windowsImplementation.includes("const sourceChecks = Object.freeze(["),
  "Windows implementation must load source checks from config instead of hardcoding inline arrays");
for (const token of [
  "licolite.secure-mesh.windows-implementation-config.v1",
  "sourceChecks",
  "windows-x64-builder-is-target-bound-and-arm64-fails-closed",
  "windows-pe-verifier-parses-machine-type",
  "windows-bundle-verifier-binds-source-digest-and-pe-facts",
  "windows-native-secret-store-is-credential-manager-backed",
  "windows-native-smoke-proves-secret-lifecycle-and-redaction",
  "windows-file-security-uses-owner-only-native-acl"
]) {
  assert(windowsImplementationConfig.includes(token),
    `Windows implementation config must keep token ${token}`);
}
assert(Array.isArray(windowsImplementationConfigJson.sourceChecks) &&
  windowsImplementationConfigJson.sourceChecks.length >= 5,
  "Windows implementation config must define source checks");
assert(windowsImplementationConfigJson.sourceChecks.every((check) =>
  check.file !== ".github/workflows/client-release.yml"),
"Windows local implementation closure must not depend on GitHub Release channel selection");
for (const token of [
  "loadSecureMeshWindowsImplementationConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "assertNoLeak",
  "source checks must have unique ids"
]) {
  assert(windowsImplementationConfigHelper.includes(token),
    `Windows implementation config helper must keep safety token ${token}`);
}
assert(!windowsImplementation.includes(
  "const reportPath = \"build/reports/secure-mesh-windows-implementation.json\""
), "Windows implementation must load configured evidence ref instead of hardcoding its report path");
await Promise.all([
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-pairwise-content-audit.mjs",
    "pairwise/content crypto audit"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-platform-secret-store-matrix.mjs",
    "platform secret-store binding"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-physical-device-matrix.mjs",
    "physical device matrix"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
    "physical device matrix"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-client-relay-mock-e2e.mjs",
    "opaque relay protocol mock"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-encrypted-file-handoff.mjs",
    "encrypted file handoff"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-trust-ux.mjs",
    "trust UX"
  ),
  assertContractBoundEvidenceReport(
    "tools/scripts/client-secure-mesh-release-proof-bundle.mjs",
    "release proof bundle"
  )
]);
for (const relativePath of [
  "tools/scripts/client-secure-mesh-windows-implementation.mjs",
  "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs"
]) {
  const text = await readText(relativePath);
  assert(!text.includes("blockerStatus"),
    `${relativePath} must not publish blockerStatus; diagnosticStatus is the only non-authoritative support-report status field`);
}
const bindingCheck = spawnSync(process.execPath, [
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  "--contract-binding-check"
], {
  cwd: repoRoot,
  env: process.env,
  encoding: "utf8",
  shell: false
});
assert(bindingCheck.status === 0,
  `secure mesh evidence bundle generator contract-binding check failed: ${sanitize(bindingCheck.stderr || bindingCheck.stdout)}`);
let bindingCheckReport = {};
try {
  bindingCheckReport = JSON.parse(bindingCheck.stdout || "{}");
} catch (error) {
  assert(false, `secure mesh contract-binding check did not emit JSON: ${sanitize(error)}`);
}
assert(bindingCheckReport.ok === true, "secure mesh contract-binding check must return ok=true");
assert(typeof bindingCheckReport.sourceOfTruth === "string" && bindingCheckReport.sourceOfTruth.length > 0,
  "secure mesh contract-binding check must identify a source of truth");
assert(typeof bindingCheckReport.evidenceRefReportSchemaVersion === "string" &&
  bindingCheckReport.evidenceRefReportSchemaVersion.length > 0,
  "secure mesh contract-binding check must identify the evidence ref report schema");
assert(typeof bindingCheckReport.authorityProofTemplateRef === "string" &&
  bindingCheckReport.authorityProofTemplateRef.length > 0,
  "secure mesh contract-binding check must identify the configured authority-proof template ref");
assert(Number(bindingCheckReport.evidenceRouteMissingCount || 0) === 0,
  "secure mesh evidence route plan must cover every contract blocker");
const scopeSelfTestModule = await import(pathToFileURL(
  path.join(repoRoot, "tools/scripts/lib/secure-client-mesh-e2ee-ref-report.mjs")
).href);
assert(typeof scopeSelfTestModule.verifySecureClientMeshE2eeRefReportScopeSelfTest === "function",
  "secure mesh scope helper must expose a per-claim authority self-test");
const scopeSelfTestReport = await scopeSelfTestModule.verifySecureClientMeshE2eeRefReportScopeSelfTest({
  contract: secureClientContract
});
assert(scopeSelfTestReport.ok === true &&
  scopeSelfTestReport.perClaimAuthoritiesAccepted === true &&
  scopeSelfTestReport.completeRequiredClaimSetEnforced === true &&
  scopeSelfTestReport.scopeEvidenceFreshUntilEmitted === true &&
  scopeSelfTestReport.independentAuditClaimRejectsExternalClient === true &&
  scopeSelfTestReport.injectedScopeConfigSchemaGuarded === true,
  "secure mesh scope helper must accept per-claim authorities, enforce complete required claim sets, emit scope freshUntil, reject external-client authority for independent audit claims, and schema-check injected configs");
const authorityProofSelfTest = spawnSync(process.execPath, [
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  "--authority-proof-self-test"
], {
  cwd: repoRoot,
  env: process.env,
  encoding: "utf8",
  shell: false
});
assert(authorityProofSelfTest.status === 0,
  `secure mesh evidence bundle authority-proof self-test failed: ${sanitize(authorityProofSelfTest.stderr || authorityProofSelfTest.stdout)}`);
let authorityProofSelfTestReport = {};
try {
  authorityProofSelfTestReport = JSON.parse(authorityProofSelfTest.stdout || "{}");
} catch (error) {
  assert(false, `secure mesh authority-proof self-test did not emit JSON: ${sanitize(error)}`);
}
assert(authorityProofSelfTestReport.ok === true &&
  authorityProofSelfTestReport.validSignedFixtureAccepted === true &&
  authorityProofSelfTestReport.tamperedSignedFixtureRejected === true &&
  authorityProofSelfTestReport.privateKeyTrustRootRejected === true &&
  authorityProofSelfTestReport.inTreeTrustRootRejected === true,
  "secure mesh authority-proof self-test must accept valid signatures and reject tampered reports, private-key trust roots, and in-tree trust roots");
const authorityProofTemplateRef = "build/tmp/secure-mesh-authority-proof-template-plan-self-test.json";
const authorityProofTemplate = spawnSync(process.execPath, [
  "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  "--generate-authority-proof-template",
  "--authority-proof-template",
  authorityProofTemplateRef
], {
  cwd: repoRoot,
  env: process.env,
  encoding: "utf8",
  shell: false
});
assert(authorityProofTemplate.status === 0,
  `secure mesh evidence bundle authority-proof template generation failed: ${sanitize(authorityProofTemplate.stderr || authorityProofTemplate.stdout)}`);
let authorityProofTemplateReport = {};
try {
  authorityProofTemplateReport = JSON.parse(authorityProofTemplate.stdout || "{}");
} catch (error) {
  assert(false, `secure mesh authority-proof template generator did not emit JSON: ${sanitize(error)}`);
}
const authorityProofTemplatePayload = await readJson(authorityProofTemplateRef);
assert(authorityProofTemplateReport.ok === true &&
  authorityProofTemplateReport.authorityProofTemplateWritten === true &&
  authorityProofTemplateReport.report === authorityProofTemplateRef &&
  authorityProofTemplateReport.productionReadyClaimed === false &&
  authorityProofTemplatePayload.schemaVersion === "licolite.secure-mesh.e2ee-authority-proof-template.v1" &&
  authorityProofTemplatePayload.redacted === true &&
  authorityProofTemplatePayload.productionReadyClaimed === false &&
  authorityProofTemplatePayload.rawPrivateMaterialIncluded === false &&
  authorityProofTemplatePayload.rawPlaintextIncluded === false &&
  authorityProofTemplatePayload.rawPublicWireBytesIncluded === false &&
  authorityProofTemplatePayload.authorityTrustRoot?.privateKeyIncluded === false &&
  Array.isArray(authorityProofTemplatePayload.evidenceRefs) &&
  authorityProofTemplatePayload.evidenceRefs.every((entry) =>
    entry.exists !== true || /^sha256:[a-f0-9]{64}$/u.test(String(entry.evidenceRefDigest || ""))
  ) &&
  authorityProofTemplatePayload.evidenceRefs.every((entry) =>
    entry.readyForSigning !== true ||
      (entry.hasAuthorityProof === false &&
        /^sha256:[a-f0-9]{64}$/u.test(String(entry.authorityProofPayloadDigest || "")) &&
        entry.authorityProofTemplate?.privateKeyIncluded !== true)
  ) &&
  authorityProofTemplatePayload.evidenceRefs.some((entry) =>
    entry.readyForSigning === false && entry.authorityProofTemplate === null
  ),
  "secure mesh authority-proof template generator must write a redacted non-ready template with digest-bound external evidence refs, no private key material, and no ready-for-signing flag on incomplete reports");

const architecture = await readText("docs/functionality/CLIENT-DESKTOP.md");
const testFramework = await readText("docs/RUNBOOK.md");
const readme = await readText("README.md");
const packaging = await readJson("apps/desktop/packaging.modules.json");
const driverInventory = await readJson(
  "crates/lico-client-native/resources/agent-conversation-drivers.json",
);
const adapterReadiness = await readJson(
  "crates/lico-client-native/resources/agent-conversation-readiness.json",
);
const readinessSummary = adapterReadiness.summary || {};
const readinessSummaryText = `${readinessSummary.ready} ready / ${readinessSummary.failed} failed / ${readinessSummary.blocked} blocked / ${readinessSummary.unverified} unverified`;
for (const documentationPath of [
  "apps/desktop/README.md",
  "docs/USAGES.md",
  "docs/functionality/CLIENT-DESKTOP.md",
  "docs/plan/client-release/Evidence.md",
  "docs/scenarios/personal-user/client-priority-scenarios.md",
]) {
  const documentation = await readText(documentationPath);
  assert(
    documentation.includes(readinessSummaryText),
    `${documentationPath} must copy the current reducer-owned adapter readiness summary`,
  );
}
const adapterIds = packaging.modules?.["target-adapters"]?.targetAdapters || [];
const driverIds = driverInventory.drivers?.map((driver) => driver.agentId) || [];
assert(adapterIds.length > 0 && new Set(adapterIds).size === adapterIds.length &&
  JSON.stringify([...adapterIds].sort()) === JSON.stringify([...driverIds].sort()),
"packaging and canonical driver inventory must contain the exact same adapters");
const firstTargets = [];
for (const adapterId of adapterIds) {
  const renderAdapter = await readJson(
    `apps/desktop/assets/agent-render-adapters/${adapterId}.json`,
  );
  const displayName = String(renderAdapter.displayName || "").replace(/ - (?:CLI|Desktop)$/u, "");
  assert(displayName.length > 0, `render adapter ${adapterId} must define a display name`);
  firstTargets.push(displayName);
}

for (const target of firstTargets) {
  assert(architecture.includes(target), `CLIENT_ARCHITECTURE must include target ${target}`);
}
for (const moduleName of shellModules) {
  assert(architecture.includes(moduleName), `CLIENT_ARCHITECTURE must include module ${moduleName}`);
}
for (const scriptName of requiredVerifierScripts) {
  assert(testFramework.includes(scriptName) || readme.includes(scriptName),
    `RUNBOOK or README must document ${scriptName}`);
}
assert(readme.includes("Lico-Arc is the open-source repository"),
  "README must describe Lico-Arc as the open-source client repository");
assert(readme.includes("Gateway-facing work stays in `LicoLite/LicoLite`"),
  "README must keep the repository ownership boundary explicit");
assert(readme.includes("GPL-3.0-or-later"),
  "README must document the canonical open-source license");

const protocolLines = linesContaining(architecture, "protocol_deferred");
assert(protocolLines.length > 0, "CLIENT_ARCHITECTURE must preserve protocol_deferred boundary language");
for (const item of protocolLines) {
  assert(!/\bdone\b|已完成|完成落地/.test(item.line), `CLIENT_ARCHITECTURE must not mark protocol_deferred as done at line ${item.number}`);
}

assert(packaging.packageProfile === "lico-client", "packaging.modules.json must default to lico-client profile");

if (failures.length > 0) {
  console.error(JSON.stringify({ ok: false, failures }, null, 2));
  process.exit(1);
}

console.log(JSON.stringify({
  ok: true,
  verifierScripts: requiredVerifierScripts,
  targets: firstTargets,
  modules: shellModules,
  protocolDeferredReferences: protocolLines.length
}, null, 2));
