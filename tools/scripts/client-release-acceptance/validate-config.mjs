import {
  canonicalClientSourceRootsMatch,
} from "../lib/client-source-state-digest.mjs";
import { requireValue, text } from "./util.mjs";

export function validateConfig(config) {
  requireValue(config?.schemaVersion === "licoup.client-release-acceptance-config.v3", "client release acceptance config schema mismatch");
  requireValue(config?.reportSchemaVersion === "licoup.client-release-acceptance-report.v4", "client release acceptance report schema mismatch");
  requireValue(config?.producerPolicy === "same-process-required", "client release acceptance must run approved producers in the same process closure");
  const authorityIds = config?.releaseTargetAuthority?.selectedTargetIds;
  requireValue(
    config?.releaseTargetAuthority?.schemaVersion ===
      "licoup.client-release-target-authority.v1" &&
      JSON.stringify(authorityIds) === JSON.stringify([
        "macos-direct-arm64",
      ]),
    "client release target authority is invalid",
  );
  requireValue(
    text(config.artifactReceipt?.ref) &&
      text(config.artifactReceipt?.schemaVersion) ===
        "licoup.client-artifact-verification-receipts.v3" &&
      text(config.artifactReceipt?.producer) ===
        "tools/scripts/client-artifact-verification-receipts.mjs",
    "client release acceptance artifact receipt authority is incomplete"
  );
  requireValue(canonicalClientSourceRootsMatch(config.sourceRoots),
    "client release acceptance source roots are not canonical");
  requireValue(
    config.reports === undefined && config.reportOrder === undefined,
    "client release acceptance cannot configure deleted component evidence producers",
  );
  for (const [targetId, artifact] of Object.entries(config.artifacts || {})) {
    requireValue(
      text(artifact.artifactKind) && text(artifact.ref) &&
        artifact.consumerVerificationPolicy ===
          "provenance-or-verifiable-signature",
      `client release acceptance artifact policy is incomplete: ${targetId}`
    );
    if (artifact.artifactKind === "macos-distribution-archive") {
      requireValue(text(artifact.distributionManifestRef) &&
        text(artifact.installArtifactRef) && text(artifact.entitlementsRef),
      `client release acceptance macOS lineage policy is incomplete: ${targetId}`);
    }
  }
  requireValue(
    JSON.stringify(Object.keys(config.artifacts || {})) === JSON.stringify(authorityIds),
    "client release artifact catalog does not match target authority",
  );
}
