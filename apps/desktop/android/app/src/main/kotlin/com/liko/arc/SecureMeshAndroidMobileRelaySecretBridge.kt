package com.liko.arc

import java.io.File

/**
 * JNI-only secret-store adapter.
 *
 * Rust is the sole authority for the public mobile-relay configuration and its
 * generation/CAS transaction. This adapter never reads or writes that JSON.
 */
internal class SecureMeshAndroidMobileRelaySecretBridge(
    private val filesDir: File,
    private val custodyManager: SecureMeshAndroidCustodyManager,
    private val recordStore: SecureMeshAndroidEncryptedRecordStore,
) {
    fun status(): Map<String, Any?> {
        val measurement = custodyManager.mobileRelayStatusMeasurement()
        return mapOf(
            "provider" to if (measurement.persistentCustodySelected) {
                "AndroidKeyStore"
            } else {
                "process-memory"
            },
            "recordLocation" to if (measurement.persistentCustodySelected) {
                "app_private_files"
            } else {
                "process_memory_only"
            },
            "cipher" to SecureMeshAndroidSecretContract.CIPHER,
            "ffiBoundary" to "jni",
            "secretTransport" to "jni_callback_in_process_secret_bytes",
            "secretStoreBackend" to custodyManager.backend(measurement),
            "secretStoreContract" to
                SecureMeshAndroidSecretContract.MOBILE_RELAY_STORE_CONTRACT,
            "secretStoreAccountPrefix" to
                SecureMeshAndroidSecretContract.MOBILE_RELAY_ACCOUNT_PREFIX,
            "secretStoreNamespace" to
                SecureMeshAndroidSecretContract.MOBILE_RELAY_NAMESPACE,
            "secretStoreHandlePattern" to "accountPrefix:namespace:key",
            "sharedRustSecretStoreHandleContract" to true,
            "applicationAuthorizationGrantRequired" to
                true,
            "rawJsonSecretOverridesUsed" to false,
            "rawJsonSecretOverridesProvenAbsent" to true,
            "secretsPassedThroughFlutterMethodChannel" to false,
            "jniSecretStoreCallbacksCarryInProcessSecret" to true,
            "portableConfigAuthority" to "rust_generation_cas",
            "kotlinConfigReadWrite" to false,
            "statusProbeSideEffectFree" to true,
            "secretClasses" to
                SecureMeshAndroidSecretContract.E2EE_SECRET_FIELDS.map { it.secretClass } +
                "pairwiseSessionSnapshot",
            "androidKeyMaterialExported" to
                (measurement.keyMaterialNonExportable == false),
            "decryptedSecretCrossesJniInProcess" to true,
            "getNotFoundSeparatedFromFailure" to true,
            "capabilityProbe" to measurement.capabilityProbe(),
            "measurements" to measurement.redactedMeasurements(),
            "implementationStatus" to
                "rust_config_authority_android_selected_custody_jni_handles",
        )
    }

    fun prepareForAuthorizedOperation() {
        custodyManager.prepareMobileRelaySelection()
    }

    fun capabilityProbeJson(operationActive: Boolean): String {
        val measurement = if (operationActive) {
            selection().measurement
        } else {
            custodyManager.mobileRelayStatusMeasurement()
        }
        return org.json.JSONObject(custodyManager.capabilityProbe(measurement)).toString()
    }

    fun selectedBackend(operationActive: Boolean): String = if (operationActive) {
        custodyManager.backend(selection())
    } else {
        custodyManager.backend(custodyManager.mobileRelayStatusMeasurement())
    }

    fun userAuthenticationSelected(): Boolean = true

    fun keyStoreStatus(deviceSecure: Boolean): Map<String, Any?> =
        custodyManager.status(custodyManager.mobileRelayStatusMeasurement(), deviceSecure)

    fun set(namespace: String, key: String, secret: String): Boolean {
        if (!SecureMeshAndroidSecretContract.secretTextPresent(secret)) return false
        val account = secretStoreAccount(namespace, key)
        writeStoredAccountSecret(secret, account)
        return true
    }

    /** Null means only a verified missing record; every other failure crosses JNI as an error. */
    fun get(namespace: String, key: String): String? =
        readStoredAccountSecret(secretStoreAccount(namespace, key))

    fun delete(namespace: String, key: String): Boolean {
        val account = secretStoreAccount(namespace, key)
        val identity = recordIdentity(account)
        return recordStore.delete(
            selection(),
            SecureMeshAndroidSecretContract.MOBILE_RELAY_SECRET_KIND,
            identity.label,
            identity.challenge,
            identity.file,
        )
    }

    private fun selection(): SecureMeshAndroidCustodySelection =
        custodyManager.requireMobileRelaySelection()

    private fun writeStoredAccountSecret(secret: String, storedAccount: String) {
        val identity = recordIdentity(storedAccount)
        val bytes = secret.toByteArray(Charsets.UTF_8)
        try {
            recordStore.write(
                selection(),
                SecureMeshAndroidSecretContract.MOBILE_RELAY_SECRET_KIND,
                identity.label,
                identity.challenge,
                bytes,
                identity.file,
            )
        } finally {
            bytes.fill(0)
        }
    }

    private fun readStoredAccountSecret(storedAccount: String): String? {
        val identity = recordIdentity(storedAccount)
        val selected = selection()
        if (
            !recordStore.exists(
                selected,
                SecureMeshAndroidSecretContract.MOBILE_RELAY_SECRET_KIND,
                identity.label,
                identity.challenge,
                identity.file,
            )
        ) return null
        val bytes = recordStore.read(
            selected,
            SecureMeshAndroidSecretContract.MOBILE_RELAY_SECRET_KIND,
            identity.label,
            identity.challenge,
            identity.file,
        )
        return try {
            SecureMeshAndroidSecretContract.decodeStoredSecret(bytes)
        } finally {
            bytes.fill(0)
        }
    }

    private fun recordIdentity(account: String): RecordIdentity {
        val safe = SecureMeshAndroidSecretContract.safeRecordId(account)
        return RecordIdentity(
            file = File(filesDir, "secure-mesh/android-mobile-relay-secrets/$safe.json"),
            label = "mobile-relay:$safe",
            challenge = "licolite.mobile-relay.secret-store.v1:$account",
        )
    }

    private fun secretStoreAccount(namespace: String, key: String): String {
        val normalizedNamespace = namespace.trim()
        val normalizedKey = key.trim()
        require(
            normalizedNamespace.isNotEmpty() &&
                !normalizedNamespace.contains("/") &&
                !normalizedNamespace.contains("\u0000"),
        ) { "secure mesh Android secret-store namespace is invalid" }
        require(
            normalizedKey.isNotEmpty() &&
                !normalizedKey.contains(":") &&
                !normalizedKey.contains("/") &&
                !normalizedKey.contains("\u0000"),
        ) { "secure mesh Android secret-store key is invalid" }
        return if (
            normalizedNamespace.startsWith(
                "${SecureMeshAndroidSecretContract.MOBILE_RELAY_ACCOUNT_PREFIX}:",
            )
        ) {
            "$normalizedNamespace:$normalizedKey"
        } else {
            "${SecureMeshAndroidSecretContract.MOBILE_RELAY_ACCOUNT_PREFIX}:" +
                "$normalizedNamespace:$normalizedKey"
        }
    }

    private data class RecordIdentity(
        val file: File,
        val label: String,
        val challenge: String,
    )
}
