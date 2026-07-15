#!/usr/bin/env node
import { createHash, generateKeyPairSync } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { loadSecureClientContract } from "./lib/secure-client-contract.mjs";
import {
  attachSecureClientMeshEvidenceAuthorityProof,
  loadSecureClientMeshAuthorityTrustRoot,
  verifySecureClientMeshEvidenceAuthorityProof
} from "./lib/secure-client-mesh-authority-proof.mjs";
import { loadSecureClientMeshE2eeEvidenceRoutePlan } from "./lib/secure-client-mesh-e2ee-route-plan.mjs";
import { verifySecureClientMeshE2eeRefReportScopeSelfTest } from "./lib/secure-client-mesh-e2ee-ref-report.mjs";
import { atomicWriteReportJson, resolveSafeReportPath } from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const argv = process.argv.slice(2);
const args = new Set(argv);
const strict = args.has("--strict");
const contractBindingCheck = args.has("--contract-binding-check");
const authorityProofSelfTest = args.has("--authority-proof-self-test");
const readinessSelfTest = args.has("--readiness-self-test");
const leakScanSelfTest = args.has("--leak-scan-self-test");
const generateAuthorityProofTemplate = args.has("--generate-authority-proof-template");

const leakPatterns = Object.freeze([
  ["local_path", /(?:^|["'\s])\/(?:Users|home|private|tmp|var\/folders)\/|[A-Za-z]:\\/u],
  ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
  ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
  ["device_identifier", /\b(?:UDID|ECID|Serial(?:Number)?|DeviceIdentifier)\s*[:=]\s*[A-Za-z0-9-]{8,}\b/u],
  ["pem_material", /-----BEGIN|-----END/u],
  ["raw_secret_value", /"(?:privateKey|privateKeyBase64url|signingKeyBase64url|sessionKey|rootKey|chainKey|messageKey|rawSecret|secretMaterial)"\s*:\s*"(?!redacted|\[redacted\])[^"]{8,}"/u]
]);

function argValue(flags) {
  for (let index = 0; index < argv.length; index += 1) {
    const item = String(argv[index] || "");
    for (const flag of flags) {
      if (item === flag) {
        const value = String(argv[index + 1] || "").trim();
        if (!value || value.startsWith("--")) throw new Error(`${flag} requires a path value`);
        return value;
      }
      if (item.startsWith(`${flag}=`)) {
        const value = item.slice(flag.length + 1).trim();
        if (!value) throw new Error(`${flag} requires a path value`);
        return value;
      }
    }
  }
  return "";
}

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function assertNoLeak(value, label) {
  const text = JSON.stringify(value);
  for (const [kind, pattern] of leakPatterns) {
    if (pattern.test(text)) throw new Error(`${label} contains sensitive data: ${kind}`);
  }
}

function sanitizeError(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/\/Users\/[^/\s"]+/gu, "<user-home>")
    .replace(/\/home\/[^/\s"]+/gu, "<user-home>")
    .replace(/\/private\/[^\s"]+/gu, "<local-path>")
    .replace(/Bearer\s+\S+/gu, "Bearer [redacted]")
    .replace(/\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]+\b/gu, "[redacted]")
    .slice(0, 600);
}

function normalizeSafeRef(value, label = "evidence ref") {
  const ref = String(value || "").trim().replaceAll("\\", "/");
  if (!ref || ref.startsWith("/") || ref.startsWith("file:") || /^https?:\/\//iu.test(ref) || ref.split("/").includes("..")) {
    throw new Error(`Invalid ${label}: ${ref || "<empty>"}`);
  }
  return ref;
}

function sha256Digest(text = "") {
  return `sha256:${createHash("sha256").update(String(text), "utf8").digest("hex")}`;
}

async function fileExists(ref) {
  try {
    return (await fs.stat(path.join(repoRoot, normalizeSafeRef(ref)))).isFile();
  } catch {
    return false;
  }
}

async function readReport(ref) {
  const normalized = normalizeSafeRef(ref);
  const text = await fs.readFile(path.join(repoRoot, normalized), "utf8");
  const report = JSON.parse(text);
  assertNoLeak(report, `${normalized} evidence report`);
  return { ref: normalized, text, report };
}

function routeCoverage(routePlan, blockers) {
  const canonical = new Set(blockers);
  const routeBlockers = Object.keys(routePlan);
  const unknownRouteBlockers = routeBlockers.filter((blocker) => !canonical.has(blocker));
  const missingRouteBlockers = blockers.filter((blocker) => !Object.hasOwn(routePlan, blocker));
  const duplicateRefs = [];
  const seen = new Set();
  for (const blocker of blockers) {
    for (const ref of routePlan[blocker]?.refs || []) {
      const key = `${blocker}\u0000${ref}`;
      if (seen.has(key)) duplicateRefs.push(ref);
      seen.add(key);
    }
  }
  if (unknownRouteBlockers.length > 0 || missingRouteBlockers.length > 0 || duplicateRefs.length > 0) {
    throw new Error("Secure Client Mesh evidence routes do not exactly cover the client-pinned blocker contract");
  }
  return {
    canonicalBlockerCount: blockers.length,
    routeBlockerCount: routeBlockers.length,
    missingRouteBlockers,
    unknownRouteBlockers,
    duplicateRefs
  };
}

function signingPreconditions(readiness) {
  return readiness.okAccepted === true &&
    readiness.schemaMatches === true &&
    readiness.sourceOfTruthAccepted === true &&
    readiness.redactionAccepted === true &&
    readiness.verifierAccepted === true &&
    readiness.generatedByAccepted === true &&
    readiness.checkedAtAccepted === true &&
    readiness.freshnessAccepted === true &&
    readiness.blockerSemanticsAccepted === true &&
    readiness.externalOrAuditGeneratedAccepted === true &&
    readiness.authorityProofRequired === true &&
    readiness.canonicalBlockerAccepted === true &&
    readiness.blockerMatches === true &&
    readiness.remainingGateCount === 0 &&
    readiness.missingRequiredReadyFields.length === 0 &&
    readiness.missingRequiredScopeClaims.length === 0 &&
    readiness.missingRequiredScopeEvidenceClaims.length === 0 &&
    readiness.missingRequiredScopeEvidenceAuthorityClaims.length === 0 &&
    readiness.missingRequiredScopeEvidenceCheckedAtClaims.length === 0 &&
    readiness.explicitNotReadyFields.length === 0;
}

async function inspectEvidenceRef(ref, blocker, contract, trustRoot) {
  if (!await fileExists(ref)) {
    return { ref, exists: false, ready: false, reason: "evidence-report-missing" };
  }
  try {
    const loaded = await readReport(ref);
    const proof = verifySecureClientMeshEvidenceAuthorityProof(loaded.report, blocker, trustRoot);
    const readiness = contract.evaluateSecureClientMeshEvidenceRefReportReadiness(
      loaded.report,
      blocker,
      { authorityProofVerification: proof }
    );
    return {
      ref: loaded.ref,
      exists: true,
      ready: readiness.ready === true,
      reason: readiness.ready ? "evidence-report-ready" : "evidence-report-not-ready",
      evidenceRefDigest: sha256Digest(loaded.text),
      blockerMatches: readiness.blockerMatches === true,
      schemaMatches: readiness.schemaMatches === true,
      redactionAccepted: readiness.redactionAccepted === true,
      freshnessAccepted: readiness.freshnessAccepted === true,
      blockerSemanticsAccepted: readiness.blockerSemanticsAccepted === true,
      clientOrAuditProvenanceAccepted: readiness.clientOrAuditProvenanceAccepted === true,
      authorityProofRequired: readiness.authorityProofRequired === true,
      authorityProofAccepted: readiness.authorityProofAccepted === true,
      missingRequiredReadyFields: readiness.missingRequiredReadyFields,
      missingRequiredScopeClaims: readiness.missingRequiredScopeClaims,
      missingRequiredScopeEvidenceClaims: readiness.missingRequiredScopeEvidenceClaims,
      remainingGates: readiness.remainingGates
    };
  } catch (error) {
    return {
      ref,
      exists: true,
      ready: false,
      reason: "evidence-report-unreadable",
      error: sanitizeError(error)
    };
  }
}

async function authorityProofTemplateForRoutes({ routeConfig, routePlan, contract, outputRef }) {
  const checkedAt = new Date().toISOString();
  const evidenceRefs = [];
  for (const blocker of contract.SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS) {
    const authority = contract.secureClientMeshEvidenceAuthorityForBlocker(blocker);
    for (const ref of routePlan[blocker].refs) {
      let details = { exists: false, readyForSigning: false, reason: "evidence-report-missing" };
      if (await fileExists(ref)) {
        try {
          const { text, report } = await readReport(ref);
          const readiness = contract.evaluateSecureClientMeshEvidenceRefReportReadiness(report, blocker);
          const hasAuthorityProof = Object.hasOwn(report, contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_PROOF_FIELD);
          details = {
            exists: true,
            evidenceRefDigest: sha256Digest(text),
            authorityProofPayloadDigest: sha256Digest(contract.canonicalSecureClientMeshAuthorityProofPayload(report)),
            hasAuthorityProof,
            readyForSigning: !hasAuthorityProof && signingPreconditions(readiness),
            reason: hasAuthorityProof
              ? "authority-proof-already-present"
              : signingPreconditions(readiness)
                ? "unsigned-evidence-report-ready-for-signing"
                : "evidence-report-not-ready-for-signing"
          };
        } catch (error) {
          details = { exists: true, readyForSigning: false, reason: "evidence-report-unreadable", error: sanitizeError(error) };
        }
      }
      evidenceRefs.push({
        blocker,
        ref,
        signingAuthorities: authority.evidenceAuthorities,
        requiredScopeClaims: contract.requiredSecureClientMeshEvidenceRefScopeClaims(blocker),
        requiredScopeClaimAuthorities: contract.requiredSecureClientMeshEvidenceRefScopeClaimAuthorities(blocker),
        commands: routePlan[blocker].commands,
        ...details,
        authorityProofTemplate: details.readyForSigning
          ? {
              schemaVersion: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_PROOF_SCHEMA_VERSION,
              sourceOfTruth: contract.SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
              algorithm: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_PROOF_ALGORITHM,
              authority: authority.evidenceAuthorities.length === 1
                ? authority.evidenceAuthorities[0]
                : "<external-client-or-independent-audit>",
              keyId: "<key-id>",
              payloadDigest: details.authorityProofPayloadDigest,
              signature: "<base64-ed25519-signature>"
            }
          : null
      });
    }
  }
  const template = {
    schemaVersion: "licolite.secure-mesh.e2ee-authority-proof-template.v1",
    sourceOfTruth: contract.SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    generatedBy: "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs#generate-authority-proof-template",
    generatedAt: checkedAt,
    checkedAt,
    report: outputRef,
    redacted: true,
    productionReadyClaimed: false,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    authorityProofField: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_PROOF_FIELD,
    authorityProofSchemaVersion: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_PROOF_SCHEMA_VERSION,
    authorityProofAlgorithm: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_PROOF_ALGORITHM,
    authorityTrustRoot: {
      schemaVersion: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_TRUST_ROOT_SCHEMA_VERSION,
      envKey: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_TRUST_ROOT_ENV,
      mustBeOutsideEvidenceRoot: true,
      privateKeyIncluded: false
    },
    routeConfig: {
      ref: routeConfig.configRef,
      schemaVersion: routeConfig.schemaVersion
    },
    evidenceRefs,
    summary: {
      refCount: evidenceRefs.length,
      existingRefCount: evidenceRefs.filter((entry) => entry.exists).length,
      missingRefCount: evidenceRefs.filter((entry) => !entry.exists).length,
      unsignedReadyForSigningRefCount: evidenceRefs.filter((entry) => entry.readyForSigning).length,
      alreadySignedRefCount: evidenceRefs.filter((entry) => entry.hasAuthorityProof).length,
      productionReadyClaimed: false
    },
    instructions: [
      "Keep signing keys outside the repository and outside build/reports.",
      "Sign only complete redacted client or independent-audit reports.",
      "Verify the signed reports with a public-key trust root outside the evidence root."
    ]
  };
  assertNoLeak(template, "secure mesh authority-proof template");
  return template;
}

function runLeakScanSelfTest() {
  assertNoLeak({ ok: true, redacted: true, secretStore: { keyMaterial: "redacted" } }, "safe fixture");
  let rawSecretRejected = false;
  try {
    assertNoLeak({ privateKeyBase64url: "raw-private-key-material-canary" }, "unsafe fixture");
  } catch {
    rawSecretRejected = true;
  }
  if (!rawSecretRejected) throw new Error("Secure Client Mesh evidence leak scanner accepted raw secret material");
  console.log(JSON.stringify({ ok: true, leakScanSelfTest: true }, null, 2));
}

async function runAuthorityProofSelfTest(contract) {
  const checkedAt = "2026-01-01T00:00:00.000Z";
  const freshUntil = "2999-01-01T00:00:00.000Z";
  const blocker = "platform secret-store binding";
  const authority = contract.SECURE_CLIENT_MESH_EVIDENCE_AUTHORITY.externalClient;
  const keyId = "secure-mesh-e2ee-authority-self-test";
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" });
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" });
  const trustRoot = {
    schemaVersion: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_TRUST_ROOT_SCHEMA_VERSION,
    sourceOfTruth: contract.SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    authorityKeys: [{
      authority,
      keyId,
      algorithm: contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_PROOF_ALGORITHM,
      publicKeyPem,
      trusted: true
    }]
  };
  const receipt = {
    ok: true,
    redacted: true,
    authority,
    evidenceType: "ephemeral-authority-proof-self-test",
    checkedAt,
    freshUntil
  };
  const unsigned = {
    ok: true,
    evidenceRefSchemaVersion: contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
    sourceOfTruth: contract.SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    blocker,
    verifier: "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs#authority-proof-self-test",
    generatedBy: "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs#authority-proof-self-test",
    checkedAt,
    freshUntil,
    productionReady: true,
    releaseReady: true,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    scope: { clientRuntimeClaims: true, platformSecretStoreClaims: true },
    scopeEvidence: { clientRuntimeClaims: receipt, platformSecretStoreClaims: receipt },
    summary: { checkedAt, freshUntil, remainingGates: [] }
  };
  const signed = attachSecureClientMeshEvidenceAuthorityProof(unsigned, { privateKeyPem, authority, keyId });
  const validProof = verifySecureClientMeshEvidenceAuthorityProof(signed, blocker, trustRoot);
  const validReadiness = contract.evaluateSecureClientMeshEvidenceRefReportReadiness(signed, blocker, {
    authorityProofVerification: validProof
  });
  const tampered = { ...signed, checkedAt: "2026-01-01T00:00:01.000Z" };
  const tamperedProof = verifySecureClientMeshEvidenceAuthorityProof(tampered, blocker, trustRoot);
  const privateKeyRootProof = verifySecureClientMeshEvidenceAuthorityProof(signed, blocker, {
    ...trustRoot,
    authorityKeys: [{ ...trustRoot.authorityKeys[0], publicKeyPem: privateKeyPem }]
  });
  const inTreeRoot = await loadSecureClientMeshAuthorityTrustRoot(
    path.join(repoRoot, "build/reports/secure-client-mesh-e2ee/authority-trust-root.json"),
    { evidenceRoot: repoRoot }
  );
  if (validProof.accepted !== true || validReadiness.ready !== true ||
    tamperedProof.accepted === true || privateKeyRootProof.accepted === true || inTreeRoot.accepted === true) {
    throw new Error("Secure Client Mesh authority-proof self-test failed");
  }
  console.log(JSON.stringify({
    ok: true,
    authorityProofSelfTest: true,
    validSignedFixtureAccepted: true,
    tamperedSignedFixtureRejected: true,
    privateKeyTrustRootRejected: true,
    inTreeTrustRootRejected: true
  }, null, 2));
}

async function runReadinessSelfTest(contract) {
  await verifySecureClientMeshE2eeRefReportScopeSelfTest({ contract });
  const states = contract.SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.map((blocker, index) => ({
    blocker,
    status: "passed",
    passed: true,
    evidenceRefs: [`build/reports/readiness-self-test-${index}.json`],
    [contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_DIGESTS_FIELD]: {
      [`build/reports/readiness-self-test-${index}.json`]: `sha256:${String(index).repeat(64).slice(0, 64)}`
    }
  }));
  const complete = contract.createSecureClientMeshProductionReadiness({
    [contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD]: states
  });
  const incomplete = contract.createSecureClientMeshProductionReadiness({
    [contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD]: states.map((state, index) =>
      index === 0 ? { ...state, status: "incomplete", passed: false } : state
    )
  });
  if (complete.productionReleaseReady !== true || incomplete.productionReleaseReady !== false) {
    throw new Error("Secure Client Mesh readiness reducer self-test failed");
  }
  console.log(JSON.stringify({
    ok: true,
    readinessSelfTest: true,
    exactCanonicalBlockerSetAccepted: true,
    incompleteBlockerRejected: true,
    scopeAuthorityRulesAccepted: true
  }, null, 2));
}

function verifyBundle(bundle, contract) {
  const states = bundle[contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD];
  const blockers = Array.isArray(states) ? states.map((state) => state.blocker) : [];
  const exactBlockerSet = blockers.length === contract.SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.length &&
    new Set(blockers).size === blockers.length &&
    contract.SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.every((blocker) => blockers.includes(blocker));
  const reduced = contract.createSecureClientMeshProductionReadiness({
    [contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD]: states
  });
  const accepted = bundle.schemaVersion === contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BUNDLE_SCHEMA_VERSION &&
    bundle.sourceOfTruth === contract.SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH &&
    exactBlockerSet &&
    reduced.productionReleaseReady === bundle[contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_READY_FIELD];
  return { accepted, exactBlockerSet, reducedProductionReleaseReady: reduced.productionReleaseReady };
}

const contract = await loadSecureClientContract();

if (leakScanSelfTest) {
  runLeakScanSelfTest();
  process.exit(0);
}
if (authorityProofSelfTest) {
  await runAuthorityProofSelfTest(contract);
  process.exit(0);
}
if (readinessSelfTest) {
  await runReadinessSelfTest(contract);
  process.exit(0);
}

const routeConfig = await loadSecureClientMeshE2eeEvidenceRoutePlan({
  canonicalBlockers: contract.SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS
});
const coverage = routeCoverage(routeConfig.evidenceRoutePlan, contract.SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS);

if (contractBindingCheck) {
  console.log(JSON.stringify({
    ok: true,
    sourceOfTruth: contract.SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    bundlePath: contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BUNDLE_PATH,
    evidenceRefReportSchemaVersion: contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
    readinessField: contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_READY_FIELD,
    blockerStatesField: contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD,
    evidenceRefDigestsField: contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_DIGESTS_FIELD,
    routeConfigRef: routeConfig.configRef,
    routeConfigSchemaVersion: routeConfig.schemaVersion,
    authorityProofTemplateRef: routeConfig.authorityProofTemplate.ref,
    relayMockReportRef: routeConfig.diagnosticRefs.relayMock,
    canonicalBlockerCount: coverage.canonicalBlockerCount,
    evidenceRouteMissingCount: coverage.missingRouteBlockers.length
  }, null, 2));
  process.exit(0);
}

if (generateAuthorityProofTemplate) {
  const outputRef = normalizeSafeRef(
    argValue(["--authority-proof-template", "--authority-proof-template-out"]) ||
      process.env.LICO_SECURE_CLIENT_MESH_E2EE_AUTHORITY_PROOF_TEMPLATE ||
      routeConfig.authorityProofTemplate.ref,
    "authority-proof template ref"
  );
  const template = await authorityProofTemplateForRoutes({
    routeConfig,
    routePlan: routeConfig.evidenceRoutePlan,
    contract,
    outputRef
  });
  const target = resolveSafeReportPath(repoRoot, outputRef);
  await fs.mkdir(path.dirname(target), { recursive: true });
  assertNoLeak(template, "secure mesh authority proof template");
  atomicWriteReportJson(repoRoot, outputRef, template);
  console.log(JSON.stringify({
    ok: true,
    authorityProofTemplateWritten: true,
    report: outputRef,
    ...template.summary
  }, null, 2));
  process.exit(0);
}

const trustRootRef = argValue(["--trust-root", "--authority-trust-root"]) ||
  process.env[contract.SECURE_CLIENT_MESH_E2EE_AUTHORITY_TRUST_ROOT_ENV];
const trustRoot = await loadSecureClientMeshAuthorityTrustRoot(trustRootRef, { evidenceRoot: repoRoot });
const template = contract.createSecureClientMeshExternalEvidenceBundleTemplate();
const templateStates = template[contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD];
const productionBlockerStates = [];

for (const templateState of templateStates) {
  const blocker = String(templateState.blocker || "").trim();
  const route = routeConfig.evidenceRoutePlan[blocker];
  const reports = [];
  for (const ref of route.refs) {
    reports.push(await inspectEvidenceRef(ref, blocker, contract, trustRoot));
  }
  const evidenceRefs = reports.filter((report) => report.exists).map((report) => report.ref);
  const readyEvidenceRefs = reports.filter((report) => report.ready).map((report) => report.ref);
  const evidenceRefDigests = Object.fromEntries(reports
    .filter((report) => report.evidenceRefDigest)
    .map((report) => [report.ref, report.evidenceRefDigest]));
  const passed = route.refs.length > 0 && readyEvidenceRefs.length === route.refs.length;
  productionBlockerStates.push({
    ...templateState,
    blocker,
    status: passed ? "passed" : evidenceRefs.length > 0 ? "incomplete" : "missing",
    passed,
    evidenceRefs,
    [contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_DIGESTS_FIELD]: evidenceRefDigests,
    readyEvidenceRefs,
    evidenceRefReports: reports,
    commands: route.commands
  });
}

const readiness = contract.createSecureClientMeshProductionReadiness({
  [contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD]: productionBlockerStates
});
const checkedAt = new Date().toISOString();
const bundle = {
  schemaVersion: contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BUNDLE_SCHEMA_VERSION,
  sourceOfTruth: contract.SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
  generatedBy: "tools/scripts/client-secure-mesh-e2ee-evidence-bundle.mjs",
  generatedAt: checkedAt,
  checkedAt,
  redacted: true,
  rawPrivateMaterialIncluded: false,
  rawPlaintextIncluded: false,
  rawPublicWireBytesIncluded: false,
  [contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_READY_FIELD]: readiness.productionReleaseReady,
  [contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BLOCKER_STATES_FIELD]: productionBlockerStates,
  contractBinding: {
    sourceOfTruth: contract.SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    routeConfigRef: routeConfig.configRef,
    routeConfigSchemaVersion: routeConfig.schemaVersion,
    canonicalBlockerCount: coverage.canonicalBlockerCount,
    relayMockReportRef: routeConfig.diagnosticRefs.relayMock
  },
  readinessReduction: readiness,
  diagnostics: {
    relayMockReportRef: routeConfig.diagnosticRefs.relayMock,
    physicalEvidenceManifestRef: routeConfig.diagnosticRefs.physicalEvidenceManifest,
    authorityTrustRootProvided: trustRoot.provided === true,
    authorityTrustRootAccepted: trustRoot.accepted === true
  }
};
assertNoLeak(bundle, "secure mesh e2ee evidence bundle");
const outputPath = resolveSafeReportPath(
  repoRoot,
  contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BUNDLE_PATH,
);
await fs.mkdir(path.dirname(outputPath), { recursive: true });
atomicWriteReportJson(
  repoRoot,
  contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BUNDLE_PATH,
  bundle,
);

const verification = verifyBundle(bundle, contract);
const summary = {
  ok: verification.accepted,
  report: contract.SECURE_CLIENT_MESH_E2EE_EVIDENCE_BUNDLE_PATH,
  productionReleaseReady: readiness.productionReleaseReady,
  sourceOfTruth: readiness.sourceOfTruth,
  canonicalBlockerCount: coverage.canonicalBlockerCount,
  blockedBlockerCount: readiness.productionBlockers.length,
  evidenceRouteMissingCount: coverage.missingRouteBlockers.length,
  relayMockReportRef: routeConfig.diagnosticRefs.relayMock,
  clientVerifierAccepted: verification.accepted
};
console.log(JSON.stringify(summary, null, 2));

if (strict && (readiness.productionReleaseReady !== true || verification.accepted !== true)) {
  process.exitCode = 1;
}
