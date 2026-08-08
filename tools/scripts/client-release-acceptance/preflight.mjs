import { selectedTargetIds } from "./targets.mjs";
import { requireValue, text } from "./util.mjs";
import { validateConfig } from "./validate-config.mjs";

export function validateReleaseSelectionPreflight({
  catalog,
  config,
  receiptConfig,
  selectedTargetIds: requestedTargetIds,
}) {
  validateConfig(config);
  const authorityIds = config.releaseTargetAuthority.selectedTargetIds;
  const releaseSupportedIds = catalog.targets
    .filter((target) => target.releaseSupported === true)
    .map((target) => target.id);
  requireValue(JSON.stringify([...releaseSupportedIds].sort()) ===
    JSON.stringify([...authorityIds].sort()),
    "release-supported catalog targets do not match selected target authority");
  requireValue(
    receiptConfig?.schemaVersion ===
      "licomesh.client-artifact-verification-receipts-config.v3" &&
      JSON.stringify(Object.keys(receiptConfig.targets || {})) ===
        JSON.stringify(authorityIds),
    "artifact receipt target authority is incomplete",
  );
  requireValue(Array.isArray(requestedTargetIds) && requestedTargetIds.length > 0 &&
    new Set(requestedTargetIds).size === requestedTargetIds.length,
  "release target selection is invalid");
  requireValue(JSON.stringify(requestedTargetIds) === JSON.stringify(
    authorityIds.filter((id) => requestedTargetIds.includes(id)),
  ), "release target selection is not in canonical authority order");
  const targetEvidenceByTarget = {
    "macos-arm64": "macosCli",
    "android-arm64": "androidPlatformCrypto",
    "linux-glibc-arm64": "linuxCli",
  };
  for (const targetId of requestedTargetIds) {
    const target = catalog.targets.find((entry) => entry.id === targetId);
    requireValue(target?.releaseSupported === true && authorityIds.includes(targetId),
      `selected target is outside release authority: ${targetId}`);
    const artifact = config.artifacts[targetId];
    const receipt = receiptConfig.targets[targetId];
    const evidenceId = targetEvidenceByTarget[targetId];
    const targetEvidence = config.reports[evidenceId];
    requireValue(artifact && receipt && evidenceId && targetEvidence,
      `selected target closure specification is missing: ${targetId}`);
    requireValue(
      receipt.platform === target.platform &&
        receipt.artifactKind === artifact.artifactKind &&
        receipt.artifactRef === artifact.ref &&
        text(receipt.distributionManifestRef) ===
          text(artifact.distributionManifestRef) &&
        receipt.consumerVerificationPolicy ===
          artifact.consumerVerificationPolicy,
      `selected target artifact/receipt specification mismatch: ${targetId}`,
    );
    requireValue(
      JSON.stringify(targetEvidence.targetIds) === JSON.stringify([targetId]),
      `selected target evidence specification mismatch: ${targetId}`,
    );
    if (targetId === "macos-arm64") {
      requireValue(receipt.evidenceArtifactKind === "macos-app-bundle" &&
        receipt.evidenceArtifactRef === artifact.installArtifactRef,
      "macOS install evidence is not bound to the distribution lineage");
    }
  }
  return true;
}
