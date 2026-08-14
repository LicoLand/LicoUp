import path from "node:path";
import { digestPattern } from "../constants.mjs";
import { requireValue, text } from "../util.mjs";

export function distributionLineageReady(spec, manifest, context) {
  const commonReady = manifest?.targetId === spec.evidenceTargetId &&
    manifest?.platform === spec.platform &&
    manifest?.architecture === "arm64" &&
    manifest?.archive === path.basename(context.artifactPath) &&
    manifest?.sha256 === context.artifactDigest.slice("sha256:".length) &&
    manifest?.sourceStateDigest === context.sourceStateDigest &&
    manifest?.productVersion === context.productVersion &&
    manifest?.buildNumber === context.buildNumber &&
    manifest?.artifactReady === true &&
    manifest?.nonBlockingDistributionGuidance?.githubReleaseBlocked === false;
  if (!commonReady) return false;
  if (spec.platform === "macos") {
    return manifest.schemaVersion === "v0.0.1:client-macos:distribution-1" &&
      manifest.installArtifactKind === spec.evidenceArtifactKind &&
      digestPattern.test(text(context.evidenceArtifactDigest)) &&
      manifest.installArtifactDigest === context.evidenceArtifactDigest &&
      digestPattern.test(text(manifest.bundleManifestDigest));
  }
  return false;
}
