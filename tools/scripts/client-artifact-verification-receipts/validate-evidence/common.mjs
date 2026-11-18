import { digestPattern } from "../constants.mjs";
import { isPlainObject, requireValue, text } from "../util.mjs";

export function freshnessReady(payload, input, closureStartedAtMs, nowMs, config) {
  const skewMs = config.maxClockSkewMs;
  const invocationStartedAtMs = Number(input.invocationStartedAtMs);
  const generatedAtMs = Date.parse(text(payload?.generatedAt));
  return input.invocationExitCode === 0 &&
    Number.isFinite(invocationStartedAtMs) &&
    Number.isFinite(generatedAtMs) &&
    invocationStartedAtMs >= closureStartedAtMs - skewMs &&
    generatedAtMs >= invocationStartedAtMs - skewMs &&
    generatedAtMs >= closureStartedAtMs - skewMs &&
    generatedAtMs <= nowMs + skewMs;
}

export function validateCommonEvidence(
  payload,
  spec,
  input,
  expectedClosureChallengeDigest,
  closureStartedAtMs,
  nowMs,
  config,
) {
  requireValue(isPlainObject(payload), "approved_evidence_invalid");
  requireValue(input.invocationExitCode === 0, "evidence_invocation_failed");
  requireValue(input.producerStable === true, "evidence_producer_changed_during_invocation");
  if (spec.evidenceSchema) {
    requireValue(payload.schema === spec.evidenceSchema, "evidence_schema_mismatch");
  }
  requireValue(payload.schemaVersion === spec.evidenceSchemaVersion,
    "evidence_schema_version_mismatch");
  const expectedProducerValue = text(spec.evidenceProducerValue || spec.evidenceProducer);
  requireValue(text(payload[spec.evidenceProducerField]) === expectedProducerValue,
    "evidence_producer_mismatch");
  requireValue(payload.closureChallengeDigest === expectedClosureChallengeDigest,
    "evidence_closure_challenge_mismatch");
  requireValue(payload.invocationNonceDigest === input.expectedInvocationNonceDigest,
    "evidence_invocation_nonce_mismatch");
  requireValue(digestPattern.test(text(input.evidenceProducerSourceDigest)),
    "evidence_producer_digest_missing");
  requireValue(digestPattern.test(text(input.evidenceReportDigest)),
    "evidence_report_digest_missing");
  const fresh = freshnessReady(payload, input, closureStartedAtMs, nowMs, config);
  requireValue(fresh, "evidence_stale");
  return { freshnessReady: true, provenanceReady: true };
}
