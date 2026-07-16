import { stableStringList } from "./lists.mjs";

export function buildReleaseProofSummaryCore({
  ok,
  sourceResults,
  updateReleaseVerifier,
  physicalEvidenceManifestVerifier,
  reportRedactionVerifier,
  updateReleaseReport,
  releaseInputFreshness,
  releaseInputFreshnessSelfTest,
  physicalEvidenceManifest,
  physicalEvidenceManifestReadinessSelfTest,
  releaseProofContractReadinessSelfTest,
  physicalMatrixContractReadiness,
  physicalEvidenceManifestContractReadiness,
  reportRedactionProof,
  redactionFreshnessSelfTest,
  clientRelayCryptoInputs,
  clientRelayCryptoInputsReadinessSelfTest,
  physicalMatrixReport,
  androidPhysicalInstallLaunchReport,
  ubuntuLinuxPackageUpdateReady,
  windowsLocalImplementationReady,
  windowsNativeHostEvidenceReady,
  productionReady,
  remainingGates
}) {
  return {
	    verificationPassed: ok,
	    bundleDiagnosticOk:
	      sourceResults.every((check) => check.ok) &&
	      updateReleaseVerifier.ok &&
	      reportRedactionVerifier.ok &&
	      updateReleaseReport.ok === true &&
	      releaseInputFreshness.ready === true,
	    sourceCheckCount: sourceResults.length,
    releaseInputFreshnessReady: releaseInputFreshness.ready === true,
    releaseInputFreshnessCurrentCount: releaseInputFreshness.currentCount,
    releaseInputFreshnessStaleOrInvalidCount: releaseInputFreshness.staleOrInvalidCount,
    releaseInputFreshnessFailedLabels: releaseInputFreshness.failedLabels,
    releaseInputFreshnessSelfTestReady: releaseInputFreshnessSelfTest.ok === true,
    updateReleaseVerifierPassed: updateReleaseVerifier.ok,
    physicalEvidenceManifestVerifierPassed: physicalEvidenceManifestVerifier.ok,
    reportRedactionVerifierPassed: reportRedactionVerifier.ok,
    reportRedactionReady: reportRedactionProof.ready === true,
    redactionFreshnessSelfTestReady: redactionFreshnessSelfTest.ok === true,
	    physicalEvidenceManifestReadinessSelfTestReady:
	      physicalEvidenceManifestReadinessSelfTest.ok === true,
	    releaseProofContractReadinessSelfTestReady:
	      releaseProofContractReadinessSelfTest.ok === true,
	    forgedPhysicalMatrixSummaryReadyRejected:
	      releaseProofContractReadinessSelfTest.forgedPhysicalMatrixSummaryReadyRejected === true,
	    forgedPhysicalEvidenceManifestSummaryReadyRejected:
	      releaseProofContractReadinessSelfTest.forgedPhysicalEvidenceManifestSummaryReadyRejected === true,
	    legacyPhysicalMatrixSchemaRejected:
	      releaseProofContractReadinessSelfTest.legacyPhysicalMatrixSchemaRejected === true,
	    legacyPhysicalEvidenceManifestSchemaRejected:
	      releaseProofContractReadinessSelfTest.legacyPhysicalEvidenceManifestSchemaRejected === true,
	    androidPhysicalInstallLaunchLocalReadyDiagnosticOnly:
	      releaseProofContractReadinessSelfTest.androidPhysicalInstallLaunchLocalReadyDiagnosticOnly === true,
	    androidPhysicalInstallLaunchOneShotAuthorizationRequired:
	      releaseProofContractReadinessSelfTest.androidOneShotAuthorizationRequired === true,
	    physicalMatrixContractReadinessReady:
	      physicalMatrixContractReadiness.ready === true,
	    physicalMatrixContractReadinessReason:
	      physicalMatrixContractReadiness.reason,
	    physicalMatrixContractReadinessRemainingGateCount:
	      physicalMatrixContractReadiness.remainingGateCount,
	    physicalMatrixContractReadinessSourceOfTruthAccepted:
	      physicalMatrixContractReadiness.sourceOfTruthAccepted === true,
	    physicalMatrixContractReadinessProvenanceAccepted:
	      physicalMatrixContractReadiness.provenanceAccepted === true,
	    physicalMatrixContractReadinessScopeAccepted:
	      physicalMatrixContractReadiness.missingRequiredScopeClaims.length === 0 &&
	      physicalMatrixContractReadiness.missingRequiredScopeEvidenceClaims.length === 0,
	    physicalEvidenceManifestContractReadinessReady:
	      physicalEvidenceManifestContractReadiness.ready === true,
	    physicalEvidenceManifestContractReadinessReason:
	      physicalEvidenceManifestContractReadiness.reason,
	    physicalEvidenceManifestContractReadinessRemainingGateCount:
	      physicalEvidenceManifestContractReadiness.remainingGateCount,
	    physicalEvidenceManifestContractReadinessSourceOfTruthAccepted:
	      physicalEvidenceManifestContractReadiness.sourceOfTruthAccepted === true,
	    physicalEvidenceManifestContractReadinessProvenanceAccepted:
	      physicalEvidenceManifestContractReadiness.provenanceAccepted === true,
	    physicalEvidenceManifestContractReadinessScopeAccepted:
	      physicalEvidenceManifestContractReadiness.missingRequiredScopeClaims.length === 0 &&
	      physicalEvidenceManifestContractReadiness.missingRequiredScopeEvidenceClaims.length === 0,
	    physicalEvidenceManifestDiagnosticOnlyRejected:
      physicalEvidenceManifestReadinessSelfTest.diagnosticOnlyRejected === true,
    physicalEvidenceManifestReleaseEvidenceRequired:
      physicalEvidenceManifestReadinessSelfTest.releaseEvidenceRequired === true,
    physicalEvidenceManifestLegacySchemaRejected:
      physicalEvidenceManifestReadinessSelfTest.legacySchemaRejected === true,
    physicalEvidenceManifestPlatformSystemAuthorizationReady:
      physicalEvidenceManifest.platformSystemAuthorizationReleaseReady === true,
    physicalEvidenceManifestAndroidSystemCredentialReleaseReady:
      physicalEvidenceManifest.androidSystemCredentialReleaseReady === true,
    physicalEvidenceManifestMacosSingleSystemAuthorizationReleaseReady:
      physicalEvidenceManifest.macosSingleSystemAuthorizationReleaseReady === true,
    physicalEvidenceManifestIosSystemLocalAuthReleaseReady:
      physicalEvidenceManifest.iosSystemLocalAuthReleaseReady === true,
    physicalEvidenceManifestPlatformSystemAuthorizationRequired:
      physicalEvidenceManifestReadinessSelfTest.platformSystemAuthorizationRequired === true,
    physicalEvidenceManifestAndroidAppPasswordPromptRejected:
      physicalEvidenceManifestReadinessSelfTest.androidAppPasswordPromptRejected === true,
    physicalEvidenceManifestMacosRepeatedAuthorizationRejected:
      physicalEvidenceManifestReadinessSelfTest.macosRepeatedAuthorizationRejected === true,
    physicalEvidenceManifestMacosAppPasswordPromptRejected:
      physicalEvidenceManifestReadinessSelfTest.macosAppPasswordPromptRejected === true,
    physicalEvidenceManifestIosAppCredentialPromptRejected:
      physicalEvidenceManifestReadinessSelfTest.iosAppCredentialPromptRejected === true,
    releaseInputRedactionDigestsCurrent:
      reportRedactionProof.scannedRefDigestsCurrent === true,
    releaseInputRedactionDigestManifestExact:
      reportRedactionProof.digestManifestExact === true,
    releaseInputRedactionRunIdMatched:
      reportRedactionProof.redactionRunIdMatched === true,
    releaseInputRedactionDigestCount:
      reportRedactionProof.scannedRefDigestCount,
    clientRelayCryptoInputsReady: clientRelayCryptoInputs.ready === true,
    clientRelayCryptoInputsReadinessSelfTestReady:
      clientRelayCryptoInputsReadinessSelfTest.ok === true,
    completeClientRelayCryptoEvidenceAccepted:
      clientRelayCryptoInputsReadinessSelfTest.completeEvidenceAccepted === true,
    invalidRelayOperationCountRejected:
      clientRelayCryptoInputsReadinessSelfTest.invalidOperationCountRejected === true,
    invalidRelayOuterFieldCountRejected:
      clientRelayCryptoInputsReadinessSelfTest.invalidOuterFieldCountRejected === true,
    relayReplayAcceptanceRejected:
      clientRelayCryptoInputsReadinessSelfTest.replayAcceptanceRejected === true,
    relayStaleLeaseAcceptanceRejected:
      clientRelayCryptoInputsReadinessSelfTest.staleLeaseAcceptanceRejected === true,
    relayNonIdempotentAckRejected:
      clientRelayCryptoInputsReadinessSelfTest.nonIdempotentAckRejected === true,
    relayPlaintextWireRejected:
      clientRelayCryptoInputsReadinessSelfTest.plaintextWireRejected === true,
    unmeasuredRelayWireBytesRejected:
      clientRelayCryptoInputsReadinessSelfTest.unmeasuredWireBytesRejected === true,
    rawRustCryptoPlaintextRejected:
      clientRelayCryptoInputsReadinessSelfTest.rawRustPlaintextRejected === true,
    rawAndroidCryptoPrivateMaterialRejected:
      clientRelayCryptoInputsReadinessSelfTest.rawAndroidPrivateMaterialRejected === true,
    legacyPlatformCryptoSchemaRejected:
      clientRelayCryptoInputsReadinessSelfTest.legacyPlatformCryptoSchemaRejected === true,
    releaseInputRedactionCoversClientRefs:
      clientRelayCryptoInputs.releaseInputRedactionCoversClientRefs === true,
    relayMockContractReady:
      clientRelayCryptoInputs.relayMockContractReady === true,
    relayMockExactFiveOperationsReady:
      clientRelayCryptoInputs.relayMockExactFiveOperationsReady === true,
    relayMockExactSixOuterFieldsReady:
      clientRelayCryptoInputs.relayMockExactSixOuterFieldsReady === true,
    relayMockReplayRejected:
      clientRelayCryptoInputs.relayMockReplayRejected === true,
    relayMockStaleLeaseRejected:
      clientRelayCryptoInputs.relayMockStaleLeaseRejected === true,
    relayMockAckIdempotencyReady:
      clientRelayCryptoInputs.relayMockAckIdempotencyReady === true,
    relayMockPlaintextWireReady:
      clientRelayCryptoInputs.relayMockPlaintextWireReady === true,
    relayMockWireBytesSemanticsReady:
      clientRelayCryptoInputs.relayMockWireBytesSemanticsReady === true,
    rustCryptoReportReady:
      clientRelayCryptoInputs.rustCryptoReportReady === true,
    rustCryptoNativeTestsReady:
      clientRelayCryptoInputs.rustCryptoNativeTestsReady === true,
    rustCryptoVectorCorpusReady:
      clientRelayCryptoInputs.rustCryptoVectorCorpusReady === true,
    rustCryptoReviewReady:
      clientRelayCryptoInputs.rustCryptoReviewReady === true,
    platformCryptoReportReady:
      clientRelayCryptoInputs.platformCryptoReportReady === true,
    androidPlatformCryptoReportReady:
      clientRelayCryptoInputs.androidPlatformCryptoReportReady === true,
			    physicalEvidenceManifestLocalReadyDiagnostic:
			      physicalEvidenceManifest.localReadyDiagnostic === true,
		    physicalEvidenceManifestInputIntegrityReady:
		      physicalEvidenceManifest.inputIntegrityReady === true,
		    physicalEvidenceManifestInputSchemaStatus:
		      String(physicalEvidenceManifest.inputSchemaStatus || "unknown"),
		    physicalEvidenceManifestInputSchemaFailureCount:
		      Number(physicalEvidenceManifest.inputSchemaFailureCount || 0),
		    physicalEvidenceManifestDiagnosticOk:
		      physicalEvidenceManifest.diagnosticOk === true,
	    physicalEvidenceManifestRedactionReady:
	      physicalEvidenceManifest.redactionReady === true,
	    physicalEvidenceManifestIntegrityReady:
	      physicalEvidenceManifest.manifestIntegrityReady === true,
	    physicalEvidenceManifestChainReady:
	      physicalEvidenceManifest.physicalEvidenceChainReady === true,
	    physicalEvidenceManifestEvidenceChainComplete:
	      physicalEvidenceManifest.evidenceChainComplete === true,
		    physicalEvidenceManifestLocalReleaseEvidenceReadyDiagnostic:
		      physicalEvidenceManifest.localReleaseEvidenceReadyDiagnostic === true,
  };
}
