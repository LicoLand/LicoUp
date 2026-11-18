import { text } from "./util.mjs";

export function sanitizeArtifactBinding(binding = {}) {
  return {
    targetId: text(binding.targetId),
    productVersion: text(binding.productVersion),
    artifactKind: text(binding.artifactKind),
    artifactDigest: text(binding.artifactDigest),
    runtimeExecutableDigest: text(binding.runtimeExecutableDigest),
    artifactEvidenceReportDigest: text(binding.artifactEvidenceReportDigest),
    artifactEvidenceInvocationNonceDigest:
      text(binding.artifactEvidenceInvocationNonceDigest),
    versionReady: binding.versionReady === true,
    targetReady: binding.targetReady === true,
    consumerIntegritySignatureReady:
      binding.consumerIntegritySignatureReady === true,
    publicVerificationMaterialReady:
      binding.publicVerificationMaterialReady === true,
    consumerVerificationReady: binding.consumerVerificationReady === true,
    platformSecurityReady: binding.platformSecurityReady === true,
    consumerIntegritySignatureKind:
      text(binding.consumerIntegritySignatureKind),
    installReceiptReady: binding.installReceiptReady === true,
    receiptProvenanceReady: binding.receiptProvenanceReady === true,
    receiptProducer: text(binding.receiptProducer),
    receiptSourceDigest: text(binding.receiptSourceDigest),
    receiptReportDigest: text(binding.receiptReportDigest),
    ready: binding.ready === true
  };
}
