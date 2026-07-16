import { existsSync } from "node:fs";
import path from "node:path";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  canonicalClientSourceRootsMatch,
} from "../lib/client-source-state-digest.mjs";
import {
  SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
} from "../lib/secure-mesh-trust-ux-reducer.mjs";
import { repoRoot, SHA256 } from "./constants.mjs";
import { requireValue, text } from "./util.mjs";

export function validateConfig(config) {
  requireValue(config?.schemaVersion === "licolite.client-release-acceptance-config.v3", "client release acceptance config schema mismatch");
  requireValue(config?.reportSchemaVersion === "licolite.client-release-acceptance-report.v3", "client release acceptance report schema mismatch");
  requireValue(config?.producerPolicy === "same-process-required", "client release acceptance must run approved producers in the same process closure");
  const authorityIds = config?.releaseTargetAuthority?.selectedTargetIds;
  requireValue(
    config?.releaseTargetAuthority?.schemaVersion ===
      "licolite.client-release-target-authority.v1" &&
      JSON.stringify(authorityIds) === JSON.stringify([
        "macos-arm64",
        "android-arm64",
        "linux-glibc-arm64",
      ]),
    "client release target authority is invalid",
  );
  requireValue(
    text(config.artifactReceipt?.ref) &&
      text(config.artifactReceipt?.schemaVersion) ===
        "licolite.client-artifact-verification-receipts.v3" &&
      text(config.artifactReceipt?.producer) ===
        "tools/scripts/client-artifact-verification-receipts.mjs",
    "client release acceptance artifact receipt authority is incomplete"
  );
  const requiredReports = [
    "pairwise",
    "relayMock",
    "file",
    "trust",
    "acp",
    "acpArchive",
    "androidPlatformCrypto",
    "macosCli",
    "linuxCli",
    "redaction",
  ];
  requireValue(canonicalClientSourceRootsMatch(config.sourceRoots),
    "client release acceptance source roots are not canonical");
  requireValue(JSON.stringify(config.reportOrder) === JSON.stringify([
    "pairwise",
    "relayMock",
    "file",
    "trust",
    "acp",
    "acpArchive",
    "androidPlatformCrypto",
    "macosCli",
    "linuxCli",
    "redaction",
  ]), "client release acceptance producer DAG is invalid");
  requireValue(requiredReports.every((id) => {
    const spec = config.reports?.[id];
    return text(spec?.ref) && text(spec?.schemaVersion) && text(spec?.producer);
  }), "client release acceptance report producer map is incomplete");
  requireValue(
    config.reports.trust.schemaVersion === SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION &&
      config.reports.trust.producer === "tools/scripts/client-secure-mesh-trust-ux.mjs",
    "client release acceptance must bind Trust UX v2 to its canonical producer"
  );
  requireValue(
    JSON.stringify(config.reports.androidPlatformCrypto?.targetIds) ===
      JSON.stringify(["android-arm64"]) &&
      config.reports.androidPlatformCrypto?.producer ===
        "tools/scripts/client-android-native-tests.mjs" &&
      JSON.stringify(config.reports.macosCli?.targetIds) ===
        JSON.stringify(["macos-arm64"]) &&
      config.reports.macosCli?.producer ===
        "tools/scripts/client-secure-mesh-release-cli-proof.mjs" &&
      JSON.stringify(config.reports.linuxCli?.targetIds) ===
        JSON.stringify(["linux-glibc-arm64"]) &&
      config.reports.linuxCli?.producer ===
        "tools/scripts/client-secure-mesh-release-cli-proof.mjs" &&
      Array.isArray(config.reports.linuxCli?.args),
    "client release target-specific evidence DAG is incomplete",
  );
  for (const [targetId, artifact] of Object.entries(config.artifacts || {})) {
    requireValue(
      text(artifact.artifactKind) && text(artifact.ref) &&
        artifact.consumerVerificationPolicy ===
          "provenance-or-verifiable-signature",
      `client release acceptance artifact policy is incomplete: ${targetId}`
    );
    if (artifact.artifactKind === "android-apk") {
      requireValue(text(artifact.packageName),
        `client release acceptance Android package policy is incomplete: ${targetId}`);
    }
    if (artifact.artifactKind === "macos-distribution-archive") {
      requireValue(text(artifact.distributionManifestRef) &&
        text(artifact.installArtifactRef) && text(artifact.entitlementsRef),
      `client release acceptance macOS lineage policy is incomplete: ${targetId}`);
    }
    if (artifact.artifactKind === "linux-tar-archive") {
      requireValue(text(artifact.distributionManifestRef),
        `client release acceptance Linux manifest policy is incomplete: ${targetId}`);
    }
  }
  requireValue(
    JSON.stringify(Object.keys(config.artifacts || {})) === JSON.stringify(authorityIds),
    "client release artifact catalog does not match target authority",
  );
}
