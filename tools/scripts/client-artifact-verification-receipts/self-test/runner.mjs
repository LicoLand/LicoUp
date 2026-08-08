import { configRef } from "../constants.mjs";
import { selectedTargetIds } from "../cli.mjs";
import { assertReceiptPrivacy } from "../privacy.mjs";
import { buildCanonicalReceiptReport } from "../receipt/build.mjs";
import { requireValue } from "../util.mjs";
import {
  fixtureAndroid,
  fixtureDigest,
  fixtureLinux,
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
    "macos-arm64": fixtureDigest("2"),
    "android-arm64": fixtureDigest("3"),
    "linux-glibc-arm64": fixtureDigest("4"),
  };
  const evidenceArtifacts = {
    "macos-arm64": fixtureDigest("7"),
  };
  const invocationDigests = {
    "macos-arm64": fixtureDigest("a"),
    "android-arm64": fixtureDigest("b"),
    "linux-glibc-arm64": fixtureDigest("c"),
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
    "macos-arm64": inputFor("macos-arm64", fixtureMacos({
      sourceDigest, artifactDigest: evidenceArtifacts["macos-arm64"], productVersion, generatedAt,
      closureChallengeDigest,
      invocationNonceDigest: invocationDigests["macos-arm64"],
    })),
    "android-arm64": inputFor("android-arm64", fixtureAndroid({
      sourceDigest, artifactDigest: artifacts["android-arm64"], productVersion, generatedAt,
      closureChallengeDigest,
      invocationNonceDigest: invocationDigests["android-arm64"],
    })),
    "linux-glibc-arm64": inputFor("linux-glibc-arm64", fixtureLinux({
      sourceDigest, artifactDigest: artifacts["linux-glibc-arm64"], productVersion,
      generatedAt, closureChallengeDigest,
      invocationNonceDigest: invocationDigests["linux-glibc-arm64"],
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
    linuxValidator: () => ({ ok: true }),
  });

  const macOnly = build(["macos-arm64"]);
  requireValue(macOnly.ok && macOnly.receipts.length === 1,
    "self_test_single_target_failed");
  const allTargets = build(["macos-arm64", "android-arm64", "linux-glibc-arm64"]);
  if (schemaFixture) return allTargets;
  requireValue(allTargets.ok && allTargets.receipts.length === 3,
    "self_test_three_targets_failed");
  const androidOnly = build(["android-arm64"], { "android-arm64": readyInputs["android-arm64"] });
  requireValue(androidOnly.ok && androidOnly.selectedTargetIds.length === 1,
    "self_test_unselected_target_blocked");
  requireValue(androidOnly.githubReleaseReady === true &&
    androidOnly.nonBlockingDistributionGuidance.blocking === false,
  "self_test_distribution_guidance_blocked_github_release");

  const staleInputs = structuredClone(readyInputs);
  staleInputs["macos-arm64"].payload.generatedAt = new Date(
    closureStartedAtMs - config.maxClockSkewMs - 1,
  ).toISOString();
  requireValue(!build(["macos-arm64"], staleInputs).ok,
    "self_test_stale_evidence_accepted");
  const wrongArtifact = structuredClone(readyInputs);
  wrongArtifact["android-arm64"].artifactDigest = fixtureDigest("7");
  requireValue(!build(["android-arm64"], wrongArtifact).ok,
    "self_test_wrong_artifact_digest_accepted");
  const wrongSource = structuredClone(readyInputs);
  wrongSource["macos-arm64"].payload.sourceStateDigest = fixtureDigest("8");
  requireValue(!build(["macos-arm64"], wrongSource).ok,
    "self_test_wrong_source_digest_accepted");
  const wrongProducer = structuredClone(readyInputs);
  wrongProducer["android-arm64"].payload.verifier = "tools/scripts/unapproved-producer.mjs";
  requireValue(!build(["android-arm64"], wrongProducer).ok,
    "self_test_wrong_producer_accepted");
  const wrongTarget = structuredClone(readyInputs);
  wrongTarget["android-arm64"].payload.targetId = "macos-arm64";
  requireValue(!build(["android-arm64"], wrongTarget).ok,
    "self_test_wrong_target_accepted");
  const wrongVersion = structuredClone(readyInputs);
  wrongVersion["macos-arm64"].payload.receipts[0].productVersion = "9.9.9";
  requireValue(!build(["macos-arm64"], wrongVersion).ok,
    "self_test_wrong_version_accepted");
  const adhoc = structuredClone(readyInputs);
  adhoc["macos-arm64"].payload.receipts[0].signatureKind = "local-ad-hoc-codesign";
  requireValue(!build(["macos-arm64"], adhoc).ok,
    "self_test_adhoc_signature_accepted");
  const wrongChallenge = structuredClone(readyInputs);
  wrongChallenge["android-arm64"].payload.closureChallengeDigest = fixtureDigest("0");
  requireValue(!build(["android-arm64"], wrongChallenge).ok,
    "self_test_wrong_closure_challenge_accepted");
  const failedInvocation = structuredClone(readyInputs);
  failedInvocation["macos-arm64"].invocationExitCode = 1;
  requireValue(!build(["macos-arm64"], failedInvocation).ok,
    "self_test_failed_invocation_reused_old_green_report");
  const changedProducer = structuredClone(readyInputs);
  changedProducer["macos-arm64"].producerStable = false;
  requireValue(!build(["macos-arm64"], changedProducer).ok,
    "self_test_changed_producer_accepted");
  const wrongInvocationNonce = structuredClone(readyInputs);
  wrongInvocationNonce["android-arm64"].payload.invocationNonceDigest = fixtureDigest("f");
  requireValue(!build(["android-arm64"], wrongInvocationNonce).ok,
    "self_test_wrong_invocation_nonce_accepted");
  const duplicateInvocationNonce = structuredClone(readyInputs);
  duplicateInvocationNonce["android-arm64"].expectedInvocationNonceDigest =
    duplicateInvocationNonce["macos-arm64"].expectedInvocationNonceDigest;
  duplicateInvocationNonce["android-arm64"].payload.invocationNonceDigest =
    duplicateInvocationNonce["macos-arm64"].payload.invocationNonceDigest;
  let duplicateNonceRejected = false;
  try {
    build(["macos-arm64", "android-arm64"], duplicateInvocationNonce);
  } catch {
    duplicateNonceRejected = true;
  }
  requireValue(duplicateNonceRejected, "self_test_duplicate_invocation_nonce_accepted");
  const wrongBuild = structuredClone(readyInputs);
  wrongBuild["android-arm64"].payload.buildNumber = 8;
  requireValue(!build(["android-arm64"], wrongBuild).ok,
    "self_test_wrong_build_number_accepted");
  const wrongEntitlements = structuredClone(readyInputs);
  wrongEntitlements["macos-arm64"].payload.receipts[0].entitlementsMatch = false;
  requireValue(!build(["macos-arm64"], wrongEntitlements).ok,
    "self_test_wrong_entitlements_accepted");
  const wrongDistributionLineage = structuredClone(readyInputs);
  wrongDistributionLineage["macos-arm64"].artifactLineageReady = false;
  requireValue(!build(["macos-arm64"], wrongDistributionLineage).ok,
    "self_test_wrong_distribution_lineage_accepted");
  const debugApk = structuredClone(readyInputs);
  debugApk["android-arm64"].payload.apkBinaryFacts.debuggable = true;
  requireValue(!build(["android-arm64"], debugApk).ok,
    "self_test_debug_apk_accepted");
  const distributionMetadataChanged = structuredClone(readyInputs);
  distributionMetadataChanged["android-arm64"].payload.nonBlockingDistributionGuidance = {
    blocking: false,
    storeListingStatus: "planned",
  };
  requireValue(build(["android-arm64"], distributionMetadataChanged).ok,
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
      targets: "macos-arm64,",
      targetsSpecified: true,
    }, config);
  } catch {
    emptyTokenRejected = true;
  }
  requireValue(emptyTokenRejected, "receipt_explicit_empty_target_token_accepted");
  requireValue(JSON.stringify(selectedTargetIds({
    targets: "linux-glibc-arm64,macos-arm64",
    targetsSpecified: true,
  }, config)) === JSON.stringify(["macos-arm64", "linux-glibc-arm64"]),
  "receipt_target_authority_order_not_canonical");
  return { ok: true, caseCount: 28, privatePathsIncluded: false };
}
