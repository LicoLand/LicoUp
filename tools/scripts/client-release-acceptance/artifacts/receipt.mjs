import { SHA256 } from "../constants.mjs";
import { requireValue, text } from "../util.mjs";

export function verifyArtifactReceipt(
  context,
  spec,
  targetId,
  productVersion,
  buildNumber,
  artifactDigest,
  artifactManifestDigest = "",
) {
  const entry = Array.isArray(context.payload?.receipts)
    ? context.payload.receipts.find((item) => item?.targetId === targetId)
    : null;
  const matched = context.ok === true && entry?.targetId === targetId &&
    entry?.productVersion === productVersion &&
    entry?.buildNumber === buildNumber &&
    entry?.artifactKind === spec.artifactKind &&
    entry?.artifactDigest === artifactDigest &&
    (!text(spec.distributionManifestRef) ||
      entry?.artifactManifestDigest === artifactManifestDigest) &&
    entry?.sourceStateDigest === context.payload.sourceStateDigest &&
    entry?.platformSecurityReady === true &&
    entry?.consumerVerificationReady === true;
  const receiptProvenanceReady = matched && context.fresh === true &&
    entry?.freshnessReady === true && entry?.provenanceReady === true &&
    SHA256.test(text(entry?.runtimeExecutableDigest)) &&
    SHA256.test(text(entry?.evidenceProducerSourceDigest)) &&
    SHA256.test(text(entry?.evidenceReportDigest)) &&
    SHA256.test(context.receiptSourceDigest) && SHA256.test(context.receiptReportDigest);
  return {
    matched,
    installReceiptReady: matched && entry?.installReceiptReady === true,
    receiptProvenanceReady,
    receiptProducer: context.producer,
    receiptSourceDigest: context.receiptSourceDigest,
    receiptReportDigest: context.receiptReportDigest,
    consumerIntegritySignatureReady:
      matched && entry?.consumerIntegritySignatureReady === true,
    publicVerificationMaterialReady:
      matched && entry?.publicVerificationMaterialReady === true,
    consumerVerificationReady:
      matched && entry?.consumerVerificationReady === true,
    platformSecurityReady: matched && entry?.platformSecurityReady === true,
    consumerIntegritySignatureKind: matched
      ? text(entry.consumerIntegritySignatureKind)
      : "none"
    ,runtimeExecutableDigest: matched ? text(entry.runtimeExecutableDigest) : ""
    ,artifactEvidenceReportDigest: matched ? text(entry.evidenceReportDigest) : ""
    ,artifactEvidenceInvocationNonceDigest:
      matched ? text(entry.invocationNonceDigest) : ""
    ,artifactManifestDigest:
      matched ? text(entry.artifactManifestDigest) : ""
  };
}
