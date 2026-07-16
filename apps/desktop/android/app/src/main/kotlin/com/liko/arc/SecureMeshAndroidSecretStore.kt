package com.liko.arc

import android.content.Context
import java.io.File

/** JNI-facing facade. Rust owns relay JSON; this class owns only custody handles. */
class SecureMeshAndroidSecretStore(
    context: Context,
    filesDir: File,
    authorizationGrantIsActive: () -> Boolean = { false },
) {
    private val nativeOperationLock = Any()
    @Volatile
    private var nativeOperationActive = false
    private val custodyManager = SecureMeshAndroidCustodyManager(
        context,
        authorizationGrantIsActive,
    )
    private val recordStore = SecureMeshAndroidEncryptedRecordStore(
        filesDir,
        custodyManager,
    )
    private val mobileRelaySecrets = SecureMeshAndroidMobileRelaySecretBridge(
        filesDir,
        custodyManager,
        recordStore,
    )

    fun mobileRelaySecretStoreStatus(): Map<String, Any?> =
        mobileRelaySecrets.status()

    fun secureMeshAndroidCapabilityProbeJson(): String =
        mobileRelaySecrets.capabilityProbeJson(nativeOperationActive)

    fun secureMeshAndroidSelectedCustodyBackend(): String =
        mobileRelaySecrets.selectedBackend(nativeOperationActive)

    fun userAuthenticationSelected(): Boolean =
        mobileRelaySecrets.userAuthenticationSelected()

    fun invokeWithAuthorizedCustody(operation: () -> String): String =
        synchronized(nativeOperationLock) {
            check(!nativeOperationActive) {
                "secure mesh Android native custody operation is already active"
            }
            mobileRelaySecrets.prepareForAuthorizedOperation()
            nativeOperationActive = true
            try {
                operation()
            } finally {
                nativeOperationActive = false
            }
        }

    fun secureMeshAndroidSecretStoreSet(
        namespace: String,
        key: String,
        secret: String,
    ): Boolean {
        requireActiveNativeOperation()
        return mobileRelaySecrets.set(namespace, key, secret)
    }

    fun secureMeshAndroidSecretStoreGet(namespace: String, key: String): String? {
        requireActiveNativeOperation()
        return mobileRelaySecrets.get(namespace, key)
    }

    fun secureMeshAndroidSecretStoreDelete(namespace: String, key: String): Boolean {
        requireActiveNativeOperation()
        return mobileRelaySecrets.delete(namespace, key)
    }

    fun androidKeyStoreStatus(deviceSecure: Boolean): Map<String, Any?> =
        mobileRelaySecrets.keyStoreStatus(deviceSecure)

    private fun requireActiveNativeOperation() {
        check(nativeOperationActive) {
            "secure mesh Android secret callback invoked outside an authorized operation"
        }
    }
}
