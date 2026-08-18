import { configRef } from "../constants.mjs";
import { selectedTargetIds } from "../cli.mjs";
import { assertReceiptPrivacy } from "../privacy.mjs";
import { buildCanonicalReceiptReport } from "../receipt/build.mjs";
import { requireValue } from "../util.mjs";
import {
  fixtureDigest,
  fixtureMacos,
} from "./fixtures.mjs";

export function runSelfTest(config, { schemaFixture = false } = {}) {
  const nowMs = Date.parse("2030-01-01T00:00:00.000Z");
  const generatedAt = new Date(nowMs - 1000).toISOString();
  const sourceDigest = fixtureDigest("1");
  const closureChallengeDigest = fixtureDigest("9");
  const closureStartedAtMs = nowMs - 2_000;
  const productVersion = "1.2.3";
  const artifacts = {
    "macos-direct-arm64": fixtureDigest("2"),
  };
  const evidenceArtifacts = {
    "macos-direct-arm64": fixtureDigest("7"),
  };
  const invocationDigests = {
    "macos-direct-arm64": fixtureDigest("a"),
  };
  const inputFor = (targetId, payload) => ({
    payload: { ...payload, invocationNonceDigest: invocationDigests[targetId] },
    artifactDigest: artifacts[targetId],
    artifactManifestDigest: config.targets[targetId].distributionManifestRef
      ? fixtureDigest("8")
      : "",
    artifactLineageReady: true,
    evidenceArtifactDigest: evidenceArtifacts[targetId] || "",
    evidenceProducerSourceDigest: fixtureDigest("5"),
    evidenceReportDigest: fixtureDigest("6"),
    invocationStartedAtMs: nowMs - 1_500,
    invocationExitCode: 0,
    producerStable: true,
    expectedInvocationNonceDigest: invocationDigests[targetId],
  });
  const readyInputs = {
    "macos-direct-arm64": inputFor("macos-direct-arm64", fixtureMacos({
      sourceDigest, artifactDigest: evidenceArtifacts["macos-direct-arm64"], productVersion, generatedAt,
      closureChallengeDigest,
      invocationNonceDigest: invocationDigests["macos-direct-arm64"],
    })),
  };
  const build = (ids, inputs = readyInputs) => buildCanonicalReceiptReport({
    config,
    selectedTargetIds: ids,
    productVersion,
    buildNumber: 7,
    sourceStateDigest: sourceDigest,
    targetInputs: inputs,
    nowMs,
    closureChallengeDigest,
    closureStartedAtMs,
    policyBindings: [
      { id: "receipt-config", ref: configRef, digest: fixtureDigest("d") },
      { id: "client-version", ref: "tools/client-version.json", digest: fixtureDigest("e") },
    ],
  });

  const selected = build(["macos-direct-arm64"]);
  requireValue(selected.ok && selected.receipts.length === 1,
    "self_test_single_target_failed");
  if (schemaFixture) return selected;

  const staleInputs = structuredClone(readyInputs);
  staleInputs["macos-direct-arm64"].payload.generatedAt = new Date(
    closureStartedAtMs - config.maxClockSkewMs - 1,
  ).toISOString();
  requireValue(!build(["macos-direct-arm64"], staleInputs).ok,
    "self_test_stale_evidence_accepted");
  const wrongArtifact = structuredClone(readyInputs);
  wrongArtifact["macos-direct-arm64"].evidenceArtifactDigest = fixtureDigest("9");
  requireValue(!build(["macos-direct-arm64"], wrongArtifact).ok,
    "self_test_wrong_artifact_digest_accepted");
  const wrongSource = structuredClone(readyInputs);
  wrongSource["macos-direct-arm64"].payload.sourceStateDigest = fixtureDigest("8");
  requireValue(!build(["macos-direct-arm64"], wrongSource).ok,
    "self_test_wrong_source_digest_accepted");
  const wrongProducer = structuredClone(readyInputs);
  wrongProducer["macos-direct-arm64"].payload.verifier = "tools/scripts/unapproved-producer.mjs";
  requireValue(!build(["macos-direct-arm64"], wrongProducer).ok,
    "self_test_wrong_producer_accepted");
  const wrongTarget = structuredClone(readyInputs);
  wrongTarget["macos-direct-arm64"].payload.receipts[0].targetId = "windows-x64";
  requireValue(!build(["macos-direct-arm64"], wrongTarget).ok,
    "self_test_wrong_target_accepted");
  const wrongVersion = structuredClone(readyInputs);
  wrongVersion["macos-direct-arm64"].payload.receipts[0].productVersion = "9.9.9";
  requireValue(!build(["macos-direct-arm64"], wrongVersion).ok,
    "self_test_wrong_version_accepted");
  const adhoc = structuredClone(readyInputs);
  adhoc["macos-direct-arm64"].payload.receipts[0].signatureKind = "local-ad-hoc-codesign";
  requireValue(!build(["macos-direct-arm64"], adhoc).ok,
    "self_test_adhoc_signature_accepted");
  const wrongChallenge = structuredClone(readyInputs);
  wrongChallenge["macos-direct-arm64"].payload.closureChallengeDigest = fixtureDigest("0");
  requireValue(!build(["macos-direct-arm64"], wrongChallenge).ok,
    "self_test_wrong_closure_challenge_accepted");
  const failedInvocation = structuredClone(readyInputs);
  failedInvocation["macos-direct-arm64"].invocationExitCode = 1;
  requireValue(!build(["macos-direct-arm64"], failedInvocation).ok,
    "self_test_failed_invocation_reused_old_green_report");
  const changedProducer = structuredClone(readyInputs);
  changedProducer["macos-direct-arm64"].producerStable = false;
  requireValue(!build(["macos-direct-arm64"], changedProducer).ok,
    "self_test_changed_producer_accepted");
  const wrongInvocationNonce = structuredClone(readyInputs);
  wrongInvocationNonce["macos-direct-arm64"].payload.invocationNonceDigest = fixtureDigest("f");
  requireValue(!build(["macos-direct-arm64"], wrongInvocationNonce).ok,
    "self_test_wrong_invocation_nonce_accepted");
  const wrongBuild = structuredClone(readyInputs);
  wrongBuild["macos-direct-arm64"].payload.receipts[0].buildNumber = 8;
  requireValue(!build(["macos-direct-arm64"], wrongBuild).ok,
    "self_test_wrong_build_number_accepted");
  const wrongEntitlements = structuredClone(readyInputs);
  wrongEntitlements["macos-direct-arm64"].payload.receipts[0].entitlementsMatch = false;
  requireValue(!build(["macos-direct-arm64"], wrongEntitlements).ok,
    "self_test_wrong_entitlements_accepted");
  const wrongDistributionLineage = structuredClone(readyInputs);
  wrongDistributionLineage["macos-direct-arm64"].artifactLineageReady = false;
  requireValue(!build(["macos-direct-arm64"], wrongDistributionLineage).ok,
    "self_test_wrong_distribution_lineage_accepted");
  const privacyKey = ["device", "Id"].join("");
  let privacyRejected = false;
  try {
    assertReceiptPrivacy({ ...selected, [privacyKey]: "fixture" });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected, "self_test_private_field_accepted");
  privacyRejected = false;
  try {
    const hostileCertificateDigestKey = ["certificate", "Identity", "Digest"].join("");
    assertReceiptPrivacy({ [hostileCertificateDigestKey]: fixtureDigest("f") });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected, "self_test_stable_signing_identity_accepted");
  const privateValue = ["", "Users", "fixture", "artifact"].join("/");
  privacyRejected = false;
  try {
    assertReceiptPrivacy({ ...selected, fixture: privateValue });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected, "self_test_private_value_accepted");
  let emptyTokenRejected = false;
  try {
    selectedTargetIds({
      targets: "macos-direct-arm64,",
      targetsSpecified: true,
    }, config);
  } catch {
    emptyTokenRejected = true;
  }
  requireValue(emptyTokenRejected, "receipt_explicit_empty_target_token_accepted");
  requireValue(JSON.stringify(selectedTargetIds({
    targets: "macos-direct-arm64",
    targetsSpecified: true,
  }, config)) === JSON.stringify([
    "macos-direct-arm64",
  ]),
  "receipt_target_authority_order_not_canonical");
  return { ok: true, caseCount: 20, privatePathsIncluded: false };
}
