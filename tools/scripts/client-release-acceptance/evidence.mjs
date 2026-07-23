import { SHA256 } from "./constants.mjs";
import { text } from "./util.mjs";

export function hasPassedNativeTest(report, id) {
  return report?.nativeResults?.some((item) => item?.id === id && item?.ok === true) === true;
}

export const METADATA_PAYLOAD_CLASSES = Object.freeze([
  "command",
  "result",
  "error",
  "file_manifest",
  "file_chunk",
  "service_action",
  "typing_indicator",
  "read_receipt",
  "acp_protected",
  "mls_group",
]);

export function metadataResistanceEvidenceReady(report, sourceStateDigest) {
  const evidence = report?.metadataResistanceEvidence || {};
  return evidence.schemaVersion ===
      "licomesh.secure-mesh.metadata-resistance-evidence.v1" &&
    evidence.sourceStateDigest === sourceStateDigest &&
    SHA256.test(text(evidence.canonicalWireReportDigest)) &&
    SHA256.test(text(evidence.residualMetadataReportDigest)) &&
    SHA256.test(text(evidence.adaptiveTopologyReportDigest)) &&
    evidence.deterministic === true && evidence.canonicalEnvelopeReady === true &&
    evidence.fixedMlsPublicAadReady === true &&
    evidence.mailboxKeyedDirectionalRotating === true &&
    evidence.mailboxBoundedOverlapReady === true &&
    evidence.hostileRelayWireCanariesAbsent === true &&
    evidence.rawBypassRetired === true &&
    JSON.stringify(evidence.payloadClasses) ===
      JSON.stringify(METADATA_PAYLOAD_CLASSES);
}
