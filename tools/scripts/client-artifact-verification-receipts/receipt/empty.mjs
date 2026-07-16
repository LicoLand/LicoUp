import { digestPattern } from "../constants.mjs";
import { requireValue, text } from "../util.mjs";

export function emptyReceipt({
  targetId,
  productVersion,
  buildNumber,
  sourceStateDigest,
  closureChallengeDigest,
  spec,
  input,
}) {
  return {
    targetId,
    productVersion,
    buildNumber,
    artifactKind: spec.artifactKind,
    artifactDigest: digestPattern.test(text(input.artifactDigest)) ? input.artifactDigest : "",
    artifactManifestDigest: digestPattern.test(text(input.artifactManifestDigest))
      ? input.artifactManifestDigest
      : "",
    sourceStateDigest,
    closureChallengeDigest,
    invocationNonceDigest: text(input.expectedInvocationNonceDigest),
    evidenceSchemaVersion: spec.evidenceSchemaVersion,
    evidenceProducer: spec.evidenceProducer,
    evidenceProducerSourceDigest: digestPattern.test(text(input.evidenceProducerSourceDigest))
      ? input.evidenceProducerSourceDigest
      : "",
    evidenceReportDigest: digestPattern.test(text(input.evidenceReportDigest))
      ? input.evidenceReportDigest
      : "",
    freshnessReady: false,
    consumerIntegritySignatureKind: "none",
    consumerIntegritySignatureReady: false,
    publicVerificationMaterialReady: false,
    platformSecurityReady: false,
    installReady: false,
    launchReady: false,
    smokeReady: false,
    runtimeExecutableDigest: "",
    dependencies: [],
    installReceiptReady: false,
    provenanceReady: false,
    ready: false,
    blockers: [],
  };
}
