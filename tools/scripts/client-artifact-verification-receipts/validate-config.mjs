import { canonicalClientSourceRootsMatch } from "../lib/client-source-state-digest.mjs";
import {
  canonicalReportRef,
  producer,
} from "./constants.mjs";
import { requireValue, text } from "./util.mjs";

export function validateConfig(config) {
  requireValue(
    config?.schemaVersion === "licolite.client-artifact-verification-receipts-config.v3",
    "receipt_config_schema_mismatch",
  );
  requireValue(
    config?.reportSchemaVersion === "licolite.client-artifact-verification-receipts.v3",
    "receipt_report_schema_mismatch",
  );
  requireValue(config?.producer === producer, "receipt_config_producer_mismatch");
  requireValue(config?.reportRef === canonicalReportRef,
    "receipt_config_report_ref_mismatch");
  requireValue(
    config?.producerPolicy === "same-closure-approved-producer-invocation",
    "receipt_producer_policy_mismatch",
  );
  requireValue(
    Number.isInteger(config.maxClockSkewMs) && config.maxClockSkewMs >= 0,
    "receipt_clock_skew_invalid",
  );
  requireValue(canonicalClientSourceRootsMatch(config.sourceRoots),
    "receipt_source_roots_not_canonical");
  const expectedTargetIds = ["macos-arm64", "android-arm64", "linux-glibc-arm64"];
  requireValue(
    JSON.stringify(Object.keys(config.targets || {})) === JSON.stringify(expectedTargetIds),
    "receipt_target_catalog_mismatch",
  );
  for (const [targetId, spec] of Object.entries(config.targets)) {
    for (const field of [
      "platform",
      "artifactKind",
      "artifactRef",
      "artifactDigestKind",
      "evidenceRef",
      "evidenceProducer",
      "evidenceProducerField",
      "freshnessKind",
      "consumerVerificationPolicy",
    ]) {
      requireValue(text(spec[field]), `receipt_target_spec_incomplete:${targetId}`);
    }
    requireValue(
      ["file", "tree"].includes(spec.artifactDigestKind),
      `receipt_artifact_digest_kind_invalid:${targetId}`,
    );
    requireValue(
      spec.freshnessKind === "generated-at",
      `receipt_freshness_kind_invalid:${targetId}`,
    );
    requireValue(
      spec.consumerVerificationPolicy === "provenance-or-verifiable-signature",
      `receipt_consumer_verification_policy_invalid:${targetId}`,
    );
    requireValue(text(spec.evidenceInvocation?.script) &&
      Array.isArray(spec.evidenceInvocation?.args) &&
      Number.isInteger(spec.evidenceInvocation?.timeoutMs) &&
      spec.evidenceInvocation.timeoutMs > 0,
    `receipt_evidence_invocation_invalid:${targetId}`);
    if (["macos", "linux"].includes(spec.platform)) {
      requireValue(text(spec.distributionManifestRef),
        `receipt_distribution_manifest_missing:${targetId}`);
    }
    if (spec.platform === "macos") {
      requireValue(spec.evidenceArtifactKind === "macos-app-bundle" &&
        text(spec.evidenceArtifactRef) &&
        spec.evidenceArtifactDigestKind === "tree",
      `receipt_macos_evidence_artifact_invalid:${targetId}`);
    }
  }
  return config;
}
