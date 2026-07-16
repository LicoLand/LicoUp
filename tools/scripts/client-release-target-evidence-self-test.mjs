#!/usr/bin/env node
import {
  androidPlatformCryptoEvidenceReady,
  releaseCliTargetEvidenceReady,
} from "./lib/client-release-target-evidence.mjs";
import {
  ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT,
} from "./lib/secure-mesh-physical-report-coverage.mjs";

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

const digest = (value) => `sha256:${value.repeat(64)}`;
const cli = {
  schemaVersion: "licolite.secure-mesh.release-cli-proof-report.v1",
  verifier: "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
  ok: true,
  platform: "macos",
  artifactKind: "release-cli-binary",
  sourceStateDigest: digest("a"),
  cliArtifactDigest: digest("b"),
  redacted: true,
  rawPrivateMaterialIncluded: false,
  rawPlaintextIncluded: false,
  rawPublicWireBytesIncluded: false,
  summary: {
    releaseCliProofReady: true,
    statusReady: true,
    commandExecuteReady: true,
    commandReplayRejected: true,
    filePolicyReady: true,
    fileRouteReady: true,
    fileReceiveDestinationReady: true,
    fileReceiveConfirmationReady: true,
    trustPolicyReady: true,
  },
};
const cliExpected = {
  platform: "macos",
  sourceStateDigest: digest("a"),
  runtimeExecutableDigest: digest("b"),
};
requireValue(releaseCliTargetEvidenceReady(cli, cliExpected), "valid_cli_rejected");
requireValue(!releaseCliTargetEvidenceReady(
  { ...cli, cliArtifactDigest: digest("c") }, cliExpected,
), "wrong_cli_digest_accepted");
requireValue(!releaseCliTargetEvidenceReady(
  { ...cli, summary: { ...cli.summary, commandReplayRejected: false } }, cliExpected,
), "cli_replay_gap_accepted");

const androidSummary = Object.fromEntries([
  "ok",
  "platformCryptoAcceptanceReady",
  "platformCustodyContractReady",
  "platformAuthorizationContractReady",
  "rustFfiActionContractReady",
  "mlsMemberRemoveReleaseActionReady",
  "unknownReleaseActionsFailClosed",
].map((key) => [key, true]));
androidSummary.nativeTestClassCount =
  ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT;
androidSummary.privatePathsIncluded = false;
const android = {
  schemaVersion: "licolite.secure-mesh.android-platform-crypto-acceptance.v1",
  verifier: "tools/scripts/client-android-native-tests.mjs",
  ok: true,
  platform: "android",
  summary: androidSummary,
  redacted: true,
  rawPrivateMaterialIncluded: false,
  rawPlaintextIncluded: false,
  rawPublicWireBytesIncluded: false,
};
requireValue(androidPlatformCryptoEvidenceReady(android),
  "valid_android_rejected");
requireValue(!androidPlatformCryptoEvidenceReady({
  ...android,
  summary: {
    ...androidSummary,
    nativeTestClassCount:
      ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT - 1,
  },
}), "wrong_android_test_matrix_accepted");
requireValue(!androidPlatformCryptoEvidenceReady({
  ...android,
  summary: { ...androidSummary, mlsMemberRemoveReleaseActionReady: false },
}), "android_ffi_action_gap_accepted");

console.log(JSON.stringify({ ok: true, caseCount: 6 }));
