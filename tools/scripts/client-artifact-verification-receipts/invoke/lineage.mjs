import path from "node:path";
import { digestPattern } from "../constants.mjs";
import { requireValue, text } from "../util.mjs";

export function distributionLineageReady(spec, manifest, context) {
  const commonReady = manifest?.targetId ===
      (spec.platform === "macos" ? "macos-arm64" : "linux-glibc-arm64") &&
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
  return manifest.schemaVersion === "v0.0.1:client-linux:distribution-1" &&
    manifest.mode === "release" &&
    digestPattern.test(text(manifest.bundleManifestDigest));
}
