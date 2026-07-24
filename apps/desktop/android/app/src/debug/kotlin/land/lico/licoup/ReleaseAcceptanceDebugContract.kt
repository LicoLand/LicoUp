package land.lico.licoup

internal object ReleaseAcceptanceDebugContract {
    const val CHANNEL_VERSION = "licomesh.android.release-acceptance.v1"
    const val AUTHORIZATION_ACTION = "secure_mesh.android.releaseAcceptance.authorize"
    const val APPROVAL_RELATIVE_PATH = "secure-mesh/release-acceptance-approval.json"
    const val MAX_APPROVAL_BYTES = 4096L
    const val MAX_RESULT_BYTES = 2 * 1024 * 1024
    const val LOG_TAG = "LicoSecureMeshDebugAcceptance"

    val approvalKeys = setOf(
        "schemaVersion",
        "closureChallengeDigest",
        "invocationNonceDigest",
        "lastRequestNonceDigest",
        "expiresAtEpochMillis",
        "lastSequence",
    )

    val safeStatusKeys = setOf(
        "secretStore",
        "mobileRelaySecretStore",
        "secretTransport",
        "secretStoreBackend",
        "secretStoreContract",
        "secretStoreAccountPrefix",
        "secretStoreNamespace",
        "secretStoreHandlePattern",
        "sharedRustSecretStoreHandleContract",
        "applicationAuthorizationGrantRequired",
        "rawJsonSecretOverridesUsed",
        "rawJsonSecretOverridesProvenAbsent",
        "portableConfigAuthority",
        "kotlinConfigReadWrite",
        "statusProbeSideEffectFree",
        "androidKeyMaterialExported",
        "decryptedSecretCrossesJniInProcess",
        "jniSecretStoreCallbacksCarryInProcessSecret",
        "getNotFoundSeparatedFromFailure",
        "capabilityReport",
        "custodyOperational",
        "selectedBackend",
        "privateKeyInSelectedCustody",
        "signingKeyInSelectedCustody",
        "signedPrekeyPrivateKeyInSelectedCustody",
        "oneTimePrekeyPrivateKeyInSelectedCustody",
        "allPrivateKeysInSelectedCustody",
        "pairingSecretInSelectedCustody",
        "unsafePersistenceDetected",
        "portableConfigPrivateKeyPresent",
        "portableConfigSigningKeyPresent",
        "portableConfigSignedPrekeyPrivateKeyPresent",
        "portableConfigOneTimePrekeyPrivateKeyPresent",
        "portableConfigPairingSecretPresent",
        "productionBlocker",
    )
}
