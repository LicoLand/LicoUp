import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  createReleaseInvocationNonce,
  releaseInvocationEnvironment,
  releaseInvocationNonceDigest,
} from "../../lib/release-closure-challenge.mjs";
import {
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableHashFileSnapshot,
} from "../../lib/client-release-artifact-digest.mjs";
import {
  maxJsonBytes,
  maxProducerBytes,
  repoRoot,
  SHA256,
} from "../constants.mjs";
import { buildRelativeRef, reportSelectedForTargets } from "../refs.mjs";
import { artifactFileByteLimit, readJson, requireValue, text } from "../util.mjs";
import { artifactPlatformVersion } from "./helpers.mjs";
import { stableProducerSnapshotMatched } from "./stability.mjs";

export function materializeArtifactReceipts(
  config,
  selectedTargets,
  productVersion,
  buildNumber,
  expectedSourceStateDigest,
  closureStartedAtMs,
  closureChallenge,
  expectedPolicyBindings,
) {
  const spec = config.artifactReceipt || {};
  const sourcePath = path.join(repoRoot, text(spec.producer));
  const buildRoot = path.join(repoRoot, "build");
  const reportRef = buildRelativeRef(spec.ref);
  const reportPath = path.join(buildRoot, reportRef);
  try {
    removeContainedReportIfExists(buildRoot, reportRef);
  } catch {
    return emptyArtifactReceiptContext();
  }
  if (!text(spec.ref) || !text(spec.producer) || !text(spec.schemaVersion) ||
    !existsSync(sourcePath)) {
    return emptyArtifactReceiptContext();
  }
  const selectedTargetIds = selectedTargets.map((target) => target.id);
  const expectedClosureChallengeDigest = releaseClosureChallengeDigest(closureChallenge);
  let invocationStartedAtMs = Number.NaN;
  let safeSourcePath = "";
  let sourceBefore;
  try {
    safeSourcePath = resolveContainedExistingPath(
      path.join(repoRoot, "tools/scripts"), sourcePath, {
      expectedKind: "file",
      },
    );
    sourceBefore = stableHashFileSnapshot(safeSourcePath, {
      maxBytes: maxProducerBytes,
    });
    invocationStartedAtMs = Date.now();
  } catch {
    return emptyArtifactReceiptContext();
  }
  const command = spawnSync(process.execPath, [safeSourcePath, "--targets", selectedTargetIds.join(",")], {
    cwd: repoRoot,
    env: {
      ...process.env,
      ...releaseClosureEnvironment(closureChallenge, new Date(closureStartedAtMs)),
    },
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 3_900_000
  });
  let sourceAfter;
  try {
    sourceAfter = stableHashFileSnapshot(safeSourcePath, {
      maxBytes: maxProducerBytes,
    });
  } catch {
    return emptyArtifactReceiptContext();
  }
  const producerStable = stableProducerSnapshotMatched(sourceBefore, sourceAfter);
  if (command.status !== 0 || producerStable !== true) {
    return emptyArtifactReceiptContext();
  }
  try {
    const safeReportPath = resolveContainedExistingPath(buildRoot, reportPath, {
      expectedKind: "file",
    });
    const reportSnapshot = stableReadFileSnapshot(safeReportPath, {
      maxBytes: maxJsonBytes,
    });
    const payload = JSON.parse(reportSnapshot.bytes.toString("utf8"));
    const receiptSourceDigest = sourceBefore.digest;
    const receiptReportDigest = sha256Buffer(reportSnapshot.bytes);
    const generatedAtMs = Date.parse(text(payload.generatedAt));
    const fresh = Number.isFinite(generatedAtMs) &&
      Number.isFinite(invocationStartedAtMs) &&
      invocationStartedAtMs >= closureStartedAtMs - Number(config.maxClockSkewMs || 0) &&
      generatedAtMs >= invocationStartedAtMs - Number(config.maxClockSkewMs || 0) &&
      generatedAtMs >= closureStartedAtMs - Number(config.maxClockSkewMs || 0) &&
      generatedAtMs <= Date.now() + Number(config.maxClockSkewMs || 0);
    const selectedTargetsMatched =
      JSON.stringify(payload.selectedTargetIds) === JSON.stringify(selectedTargetIds);
    const receipts = Array.isArray(payload.receipts) ? payload.receipts : [];
    const receiptTargetIds = receipts.map((entry) => text(entry?.targetId));
    const receiptTargetsMatched = receipts.length === selectedTargetIds.length &&
      new Set(receiptTargetIds).size === receiptTargetIds.length &&
      JSON.stringify(receiptTargetIds) === JSON.stringify(selectedTargetIds);
    const receiptDependencyBindingsReady = receipts.every((entry) =>
      SHA256.test(text(entry?.runtimeExecutableDigest)) &&
      (!text(config.artifacts?.[entry?.targetId]?.distributionManifestRef) ||
        SHA256.test(text(entry?.artifactManifestDigest))) &&
      Array.isArray(entry?.dependencies) && entry.dependencies.length <= 16 &&
      entry.dependencies.every((dependency) =>
        text(dependency?.id) && text(dependency?.ref).startsWith("build/") &&
        SHA256.test(text(dependency?.digest)))) &&
      receipts.every((entry) => entry.targetId !== "macos-direct-arm64" ||
        (entry.dependencies.length === 1 &&
          entry.dependencies[0].id === "macos-user-presence-proof" &&
          entry.dependencies[0].ref ===
            "build/reports/secure-mesh-macos-keychain-user-presence-proof.json"));
    const privacyReady = payload.privacy?.redacted === true &&
      payload.privacy?.absolutePathsIncluded === false &&
      payload.privacy?.runtimeIdentityIncluded === false &&
      payload.privacy?.deviceIdentifiersIncluded === false &&
      payload.privacy?.deviceModelsIncluded === false &&
      payload.privacy?.signingIdentitiesIncluded === false &&
      payload.privacy?.keyMaterialIncluded === false &&
      payload.privacy?.rawLogsIncluded === false;
    const ok = payload.ok === true &&
      payload.schemaVersion === spec.schemaVersion &&
      payload.generatedBy === spec.producer &&
      payload.productVersion === productVersion &&
      payload.buildNumber === buildNumber &&
      payload.githubReleaseReady === payload.ok &&
      payload.nonBlockingDistributionGuidance?.blocking === false &&
      payload.closureChallengeDigest === expectedClosureChallengeDigest &&
      payload.sourceStateDigest === expectedSourceStateDigest &&
      JSON.stringify(payload.policyBindings) ===
        JSON.stringify(expectedPolicyBindings) &&
      selectedTargetsMatched && receiptTargetsMatched &&
      receiptDependencyBindingsReady && privacyReady && fresh &&
      SHA256.test(receiptSourceDigest) && SHA256.test(receiptReportDigest);
    return {
      ok,
      payload,
      producer: payload.generatedBy === spec.producer ? spec.producer : "producer-mismatch",
      receiptSourceDigest,
      receiptReportDigest,
      fresh,
      producerStable,
    };
  } catch {
    return emptyArtifactReceiptContext();
  }
}

export function emptyArtifactReceiptContext() {
  return {
    ok: false,
    payload: {},
    producer: "",
    receiptSourceDigest: "",
    receiptReportDigest: "",
    fresh: false,
    producerStable: false,
  };
}
