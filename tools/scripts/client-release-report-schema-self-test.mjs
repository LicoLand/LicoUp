#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { stableReadFile } from "./lib/client-release-artifact-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const maxFixtureBytes = 16 * 1024 * 1024;

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

function readJson(ref) {
  return JSON.parse(stableReadFile(path.join(repoRoot, ref), {
    maxBytes: maxFixtureBytes,
  }).toString("utf8"));
}

function producerFixture(scriptRef) {
  const result = spawnSync(process.execPath, [scriptRef, "--schema-fixture"], {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    stdio: "pipe",
    timeout: 30_000,
    maxBuffer: maxFixtureBytes,
  });
  requireValue(result.status === 0, "schema_fixture_producer_failed");
  requireValue(Buffer.byteLength(result.stdout || "", "utf8") <= maxFixtureBytes,
    "schema_fixture_output_exceeded_bound");
  try {
    return JSON.parse(String(result.stdout || ""));
  } catch {
    throw new Error("schema_fixture_producer_output_invalid");
  }
}

function expectRejected(validate, fixture, code) {
  requireValue(validate(fixture) === false, code);
}

const ajv = new Ajv2020({
  allErrors: true,
  strict: true,
  allowUnionTypes: true,
  validateFormats: true,
});
addFormats(ajv);

const artifactSchema = readJson(
  "tools/scripts/config/client-artifact-verification-receipts-report.schema.json",
);
const acceptanceSchema = readJson(
  "tools/scripts/config/client-release-acceptance-report.schema.json",
);
const validateArtifact = ajv.compile(artifactSchema);
const validateAcceptance = ajv.compile(acceptanceSchema);
const artifactFixture = producerFixture(
  "tools/scripts/client-artifact-verification-receipts.mjs",
);
const acceptanceFixture = producerFixture(
  "tools/scripts/client-release-acceptance.mjs",
);

requireValue(validateArtifact(artifactFixture) === true,
  "artifact_receipt_real_producer_fixture_schema_mismatch");
requireValue(validateAcceptance(acceptanceFixture) === true,
  "release_acceptance_real_producer_fixture_schema_mismatch");

const missingRuntimeDigest = structuredClone(artifactFixture);
delete missingRuntimeDigest.receipts[0].runtimeExecutableDigest;
expectRejected(validateArtifact, missingRuntimeDigest,
  "artifact_receipt_schema_accepted_missing_runtime_digest");

const missingArtifactDependencies = structuredClone(artifactFixture);
delete missingArtifactDependencies.receipts[0].dependencies;
expectRejected(validateArtifact, missingArtifactDependencies,
  "artifact_receipt_schema_accepted_missing_dependencies");

const missingArtifactManifestDigest = structuredClone(artifactFixture);
delete missingArtifactManifestDigest.receipts[0].artifactManifestDigest;
expectRejected(validateArtifact, missingArtifactManifestDigest,
  "artifact_schema_accepted_missing_distribution_manifest_digest");

const missingFinalDependencies = structuredClone(acceptanceFixture);
delete missingFinalDependencies.inputIntegrity.reports[0].dependencies;
expectRejected(validateAcceptance, missingFinalDependencies,
  "acceptance_schema_accepted_missing_producer_dependencies");

const missingRuntimeBinding = structuredClone(acceptanceFixture);
delete missingRuntimeBinding.targetResults[0].artifactBinding.runtimeExecutableDigest;
expectRejected(validateAcceptance, missingRuntimeBinding,
  "acceptance_schema_accepted_missing_runtime_binding");

const missingEvidenceBinding = structuredClone(acceptanceFixture);
delete missingEvidenceBinding.targetResults[0].artifactBinding.artifactEvidenceReportDigest;
expectRejected(validateAcceptance, missingEvidenceBinding,
  "acceptance_schema_accepted_missing_evidence_binding");

const artifactExtraRoot = structuredClone(artifactFixture);
artifactExtraRoot.unrecognizedAuthority = true;
expectRejected(validateArtifact, artifactExtraRoot,
  "artifact_schema_accepted_extra_root_field");

const artifactExtraReceipt = structuredClone(artifactFixture);
artifactExtraReceipt.receipts[0].unrecognizedAuthority = true;
expectRejected(validateArtifact, artifactExtraReceipt,
  "artifact_schema_accepted_extra_receipt_field");

const artifactReadyContradiction = structuredClone(artifactFixture);
artifactReadyContradiction.receipts[0].consumerVerificationReady = false;
expectRejected(validateArtifact, artifactReadyContradiction,
  "artifact_schema_accepted_ready_signature_contradiction");

const artifactReportContradiction = structuredClone(artifactFixture);
artifactReportContradiction.receipts[0].ready = false;
artifactReportContradiction.receipts[0].blockers = ["fixture_blocker"];
expectRejected(validateArtifact, artifactReportContradiction,
  "artifact_schema_accepted_green_report_with_blocked_receipt");

const acceptanceExtraGate = structuredClone(acceptanceFixture);
acceptanceExtraGate.gateResults[0].unrecognizedAuthority = true;
expectRejected(validateAcceptance, acceptanceExtraGate,
  "acceptance_schema_accepted_extra_gate_field");

const acceptanceExtraTarget = structuredClone(acceptanceFixture);
acceptanceExtraTarget.targetResults[0].unrecognizedAuthority = true;
expectRejected(validateAcceptance, acceptanceExtraTarget,
  "acceptance_schema_accepted_extra_target_field");

const acceptanceReadinessContradiction = structuredClone(acceptanceFixture);
acceptanceReadinessContradiction.blockers = ["fixture_blocker"];
expectRejected(validateAcceptance, acceptanceReadinessContradiction,
  "acceptance_schema_accepted_green_report_with_blocker");

const acceptanceIntegrityContradiction = structuredClone(acceptanceFixture);
acceptanceIntegrityContradiction.inputIntegrity.policyInputsStable = false;
expectRejected(validateAcceptance, acceptanceIntegrityContradiction,
  "acceptance_schema_accepted_green_integrity_contradiction");

const missingArtifactPolicyBinding = structuredClone(artifactFixture);
missingArtifactPolicyBinding.policyBindings.pop();
expectRejected(validateArtifact, missingArtifactPolicyBinding,
  "artifact_schema_accepted_missing_policy_binding");

const reorderedAcceptancePolicy = structuredClone(acceptanceFixture);
reorderedAcceptancePolicy.inputIntegrity.policyBindings.reverse();
expectRejected(validateAcceptance, reorderedAcceptancePolicy,
  "acceptance_schema_accepted_reordered_policy_authority");

console.log(JSON.stringify({
  ok: true,
  draft: "2020-12",
  realProducerFixtureCount: 2,
  caseCount: 18,
  additionalPropertiesClosed: true,
  readinessConsistencyConditional: true,
  privatePathsIncluded: false,
}));
