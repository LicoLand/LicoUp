import { configRef } from "../constants.mjs";
import { selectedTargetIds } from "../cli.mjs";
import { assertReceiptPrivacy } from "../privacy.mjs";
import { buildCanonicalReceiptReport } from "../receipt/build.mjs";
import { requireValue } from "../util.mjs";
import {
  fixtureAndroid,
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
    "android-direct-arm64-v8a": fixtureDigest("3"),
  };
  const evidenceArtifacts = {
    "macos-direct-arm64": fixtureDigest("7"),
  };
  const invocationDigests = {
    "macos-direct-arm64": fixtureDigest("a"),
    "android-direct-arm64-v8a": fixtureDigest("b"),
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
    "android-direct-arm64-v8a": inputFor("android-direct-arm64-v8a", fixtureAndroid({
      sourceDigest, artifactDigest: artifacts["android-direct-arm64-v8a"], productVersion, generatedAt,
      closureChallengeDigest,
      invocationNonceDigest: invocationDigests["android-direct-arm64-v8a"],
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

  const macOnly = build(["macos-direct-arm64"]);
  requireValue(macOnly.ok && macOnly.receipts.length === 1,
    "self_test_single_target_failed");
  const allTargets = build(["macos-direct-arm64", "android-direct-arm64-v8a"]);
  if (schemaFixture) return allTargets;
  requireValue(allTargets.ok && allTargets.receipts.length === 2,
    "self_test_multiple_targets_failed");
  const androidOnly = build(["android-direct-arm64-v8a"], { "android-direct-arm64-v8a": readyInputs["android-direct-arm64-v8a"] });
  requireValue(androidOnly.ok && androidOnly.selectedTargetIds.length === 1,
    "self_test_unselected_target_blocked");
  requireValue(androidOnly.githubReleaseReady === true &&
    androidOnly.nonBlockingDistributionGuidance.blocking === false,
  "self_test_distribution_guidance_blocked_github_release");

  const staleInputs = structuredClone(readyInputs);
  staleInputs["macos-direct-arm64"].payload.generatedAt = new Date(
    closureStartedAtMs - config.maxClockSkewMs - 1,
  ).toISOString();
  requireValue(!build(["macos-direct-arm64"], staleInputs).ok,
    "self_test_stale_evidence_accepted");
  const wrongArtifact = structuredClone(readyInputs);
  wrongArtifact["android-direct-arm64-v8a"].artifactDigest = fixtureDigest("7");
  requireValue(!build(["android-direct-arm64-v8a"], wrongArtifact).ok,
    "self_test_wrong_artifact_digest_accepted");
  const wrongSource = structuredClone(readyInputs);
  wrongSource["macos-direct-arm64"].payload.sourceStateDigest = fixtureDigest("8");
  requireValue(!build(["macos-direct-arm64"], wrongSource).ok,
    "self_test_wrong_source_digest_accepted");
  const wrongProducer = structuredClone(readyInputs);
  wrongProducer["android-direct-arm64-v8a"].payload.verifier = "tools/scripts/unapproved-producer.mjs";
  requireValue(!build(["android-direct-arm64-v8a"], wrongProducer).ok,
    "self_test_wrong_producer_accepted");
  const wrongTarget = structuredClone(readyInputs);
  wrongTarget["android-direct-arm64-v8a"].payload.targetId = "macos-direct-arm64";
  requireValue(!build(["android-direct-arm64-v8a"], wrongTarget).ok,
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
  wrongChallenge["android-direct-arm64-v8a"].payload.closureChallengeDigest = fixtureDigest("0");
  requireValue(!build(["android-direct-arm64-v8a"], wrongChallenge).ok,
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
  wrongInvocationNonce["android-direct-arm64-v8a"].payload.invocationNonceDigest = fixtureDigest("f");
  requireValue(!build(["android-direct-arm64-v8a"], wrongInvocationNonce).ok,
    "self_test_wrong_invocation_nonce_accepted");
  const duplicateInvocationNonce = structuredClone(readyInputs);
  duplicateInvocationNonce["android-direct-arm64-v8a"].expectedInvocationNonceDigest =
    duplicateInvocationNonce["macos-direct-arm64"].expectedInvocationNonceDigest;
  duplicateInvocationNonce["android-direct-arm64-v8a"].payload.invocationNonceDigest =
    duplicateInvocationNonce["macos-direct-arm64"].payload.invocationNonceDigest;
  let duplicateNonceRejected = false;
  try {
    build(["macos-direct-arm64", "android-direct-arm64-v8a"], duplicateInvocationNonce);
  } catch {
    duplicateNonceRejected = true;
  }
  requireValue(duplicateNonceRejected, "self_test_duplicate_invocation_nonce_accepted");
  const wrongBuild = structuredClone(readyInputs);
  wrongBuild["android-direct-arm64-v8a"].payload.buildNumber = 8;
  requireValue(!build(["android-direct-arm64-v8a"], wrongBuild).ok,
    "self_test_wrong_build_number_accepted");
  const wrongEntitlements = structuredClone(readyInputs);
  wrongEntitlements["macos-direct-arm64"].payload.receipts[0].entitlementsMatch = false;
  requireValue(!build(["macos-direct-arm64"], wrongEntitlements).ok,
    "self_test_wrong_entitlements_accepted");
  const wrongDistributionLineage = structuredClone(readyInputs);
  wrongDistributionLineage["macos-direct-arm64"].artifactLineageReady = false;
  requireValue(!build(["macos-direct-arm64"], wrongDistributionLineage).ok,
    "self_test_wrong_distribution_lineage_accepted");
  const debugApk = structuredClone(readyInputs);
  debugApk["android-direct-arm64-v8a"].payload.apkBinaryFacts.debuggable = true;
  requireValue(!build(["android-direct-arm64-v8a"], debugApk).ok,
    "self_test_debug_apk_accepted");
  const distributionMetadataChanged = structuredClone(readyInputs);
  distributionMetadataChanged["android-direct-arm64-v8a"].payload.nonBlockingDistributionGuidance = {
    blocking: false,
    storeListingStatus: "planned",
  };
  requireValue(build(["android-direct-arm64-v8a"], distributionMetadataChanged).ok,
    "self_test_distribution_guidance_blocked_github_release");
  const privacyKey = ["device", "Id"].join("");
  let privacyRejected = false;
  try {
    assertReceiptPrivacy({ ...macOnly, [privacyKey]: "fixture" });
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
    assertReceiptPrivacy({ ...macOnly, fixture: privateValue });
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
    targets: "android-direct-arm64-v8a,macos-direct-arm64",
    targetsSpecified: true,
  }, config)) === JSON.stringify([
    "macos-direct-arm64", "android-direct-arm64-v8a",
  ]),
  "receipt_target_authority_order_not_canonical");
  return { ok: true, caseCount: 28, privatePathsIncluded: false };
}
