package land.lico.licoup

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.KeyStore
import java.security.ProviderException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

internal sealed interface SecureMeshAndroidCustodySelection {
    val measurement: SecureMeshAndroidCapabilityMeasurement

    data class KeyStore(
        val secretKey: SecretKey,
        override val measurement: SecureMeshAndroidCapabilityMeasurement,
    ) : SecureMeshAndroidCustodySelection

    data class MemoryOnly(
        override val measurement: SecureMeshAndroidCapabilityMeasurement,
    ) : SecureMeshAndroidCustodySelection
}

/**
 * Owns Android key policy and nothing else.
 *
 * Capability/status reads are side-effect free. Key lookup or provisioning is
 * allowed only inside an explicitly authorized native operation. A transient
 * provider failure or an incompatible pre-existing key never deletes either
 * the key alias or encrypted records; recovery requires a separate user-owned
 * re-pair/reset transaction.
 */
internal class SecureMeshAndroidCustodyManager(
    context: Context,
    private val authorizationGrantIsActive: () -> Boolean,
) {
    private val capabilityProbe =
        SecureMeshAndroidCapabilityProbe(context.applicationContext)
    private val selectionLock = Any()
    private val selectionByAlias =
        mutableMapOf<String, SecureMeshAndroidCustodySelection>()

    fun mobileRelayStatusMeasurement(): SecureMeshAndroidCapabilityMeasurement =
        statusMeasurement(SecureMeshAndroidSecretContract.MOBILE_RELAY_KEY_ALIAS)

    fun prepareMobileRelaySelection(): SecureMeshAndroidCustodySelection =
        prepareSelection(SecureMeshAndroidSecretContract.MOBILE_RELAY_KEY_ALIAS)

    fun requireMobileRelaySelection(): SecureMeshAndroidCustodySelection =
        requirePreparedSelection(SecureMeshAndroidSecretContract.MOBILE_RELAY_KEY_ALIAS)

    fun capabilityProbe(
        measurement: SecureMeshAndroidCapabilityMeasurement,
    ): Map<String, Any?> = measurement.capabilityProbe()

    fun backend(measurement: SecureMeshAndroidCapabilityMeasurement): String =
        if (measurement.persistentCustodySelected) {
            "android-keystore"
        } else {
            "memory-only-ephemeral"
        }

    fun backend(selection: SecureMeshAndroidCustodySelection): String =
        backend(selection.measurement)

    fun userAuthenticationSelected(
        measurement: SecureMeshAndroidCapabilityMeasurement,
    ): Boolean = measurement.userAuthenticationRequired == true ||
        measurement.userAuthenticationRequested

    fun userAuthenticationSelected(
        selection: SecureMeshAndroidCustodySelection,
    ): Boolean = userAuthenticationSelected(selection.measurement)

    fun requireAuthorization(selection: SecureMeshAndroidCustodySelection) {
        check(authorizationGrantIsActive()) {
            "secure mesh Android user authentication grant is required"
        }
        check(userAuthenticationSelected(selection)) {
            "secure mesh Android selected custody lacks mandatory user authentication"
        }
    }

    fun status(
        measurement: SecureMeshAndroidCapabilityMeasurement,
        deviceSecure: Boolean,
    ): Map<String, Any?> = mapOf(
        "provider" to if (measurement.persistentCustodySelected) {
            "AndroidKeyStore"
        } else {
            "not-provisioned"
        },
        "available" to measurement.keyStoreAvailable,
        "custodyStrategy" to measurement.custodyStrategy.wireName,
        "restartSemantics" to measurement.redactedMeasurements()["restartSemantics"],
        "deviceCredentialAvailable" to measurement.deviceCredentialAvailable,
        "strongBiometricAvailabilityMeasured" to
            measurement.strongBiometricAvailabilityMeasured,
        "strongBiometricAvailable" to measurement.strongBiometricAvailable,
        "deviceSecure" to deviceSecure,
        "privateMaterialExportedFromAndroidKeyStore" to false,
        "jniCallbacksCarryDecryptedSecretBytesInProcess" to true,
        "statusProbeSideEffectFree" to true,
        "capabilityProbe" to measurement.capabilityProbe(),
        "measurements" to measurement.redactedMeasurements(),
        "bodyRedacted" to true,
    )

    private fun statusMeasurement(alias: String): SecureMeshAndroidCapabilityMeasurement =
        synchronized(selectionLock) {
            selectionByAlias[alias]?.measurement ?: run {
                val platform = capabilityProbe.platformCapabilities()
                capabilityProbe.memoryOnly(
                    platform,
                    reasonCode = "android_keystore_not_provisioned_by_user_operation",
                    attemptCount = 0,
                )
            }
        }

    private fun requirePreparedSelection(alias: String): SecureMeshAndroidCustodySelection =
        synchronized(selectionLock) {
            check(authorizationGrantIsActive()) {
                "secure mesh Android custody requested outside an authorized operation"
            }
            selectionByAlias[alias]
                ?: error("secure mesh Android custody was not prepared by the authorized operation")
        }

    private fun prepareSelection(alias: String): SecureMeshAndroidCustodySelection =
        synchronized(selectionLock) {
            check(authorizationGrantIsActive()) {
                "secure mesh Android custody provisioning requires direct user authentication"
            }
            selectionByAlias[alias] ?: selectForAuthorizedOperation(alias).also {
                selectionByAlias[alias] = it
            }
        }

    private fun selectForAuthorizedOperation(alias: String): SecureMeshAndroidCustodySelection {
        val platform = capabilityProbe.platformCapabilities()
        if (!platform.keyStoreAvailable) {
            return memoryOnly(platform, "android_keystore_unavailable", 0)
        }
        val keyStore = KeyStore.getInstance("AndroidKeyStore").also { it.load(null) }
        if (keyStore.containsAlias(alias)) {
            val existing = (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)
                ?.secretKey
                ?: error("secure mesh Android existing custody alias is not a secret key")
            val measurement = capabilityProbe.inspectSelectedKey(
                existing,
                platform,
                selectedCandidate = null,
                attemptCount = 0,
            )
            check(
                capabilityProbe.keyMeetsCurrentPersistentCustodyPolicy(
                    existing,
                    measurement,
                    SecureMeshAndroidSecretContract.USER_AUTH_VALIDITY_SECONDS,
                ),
            ) {
                "secure mesh Android existing custody key requires user-approved re-pair"
            }
            return SecureMeshAndroidCustodySelection.KeyStore(existing, measurement)
        }

        val candidates = SecureMeshAndroidKeyPolicyStrategy.candidates(
            platform.policyEnvironment(),
            SecureMeshAndroidSecretContract.USER_AUTH_VALIDITY_SECONDS,
        )
        var attemptedCandidateCount = 0
        val selected = SecureMeshAndroidKeyPolicyStrategy.select(candidates) { candidate ->
            attemptedCandidateCount += 1
            try {
                val generated = generateKey(alias, candidate)
                val measurement = capabilityProbe.inspectSelectedKey(
                    generated,
                    platform,
                    selectedCandidate = candidate,
                    attemptCount = 0,
                )
                if (
                    capabilityProbe.keyMeetsCurrentPersistentCustodyPolicy(
                        generated,
                        measurement,
                        SecureMeshAndroidSecretContract.USER_AUTH_VALIDITY_SECONDS,
                    )
                ) {
                    SecureMeshAndroidKeyAttempt.Success(generated to measurement)
                } else {
                    removeOnlyNewlyGeneratedAlias(keyStore, alias)
                    SecureMeshAndroidKeyAttempt.Failure(
                        SecureMeshAndroidKeyAttemptFailure.POLICY_INCOMPATIBLE,
                    )
                }
            } catch (error: Exception) {
                removeOnlyNewlyGeneratedAlias(keyStore, alias)
                SecureMeshAndroidKeyAttempt.Failure(
                    if (strongBoxUnavailable(error)) {
                        SecureMeshAndroidKeyAttemptFailure.STRONGBOX_UNAVAILABLE
                    } else {
                        SecureMeshAndroidKeyAttemptFailure.POLICY_INCOMPATIBLE
                    },
                )
            }
        }
        if (selected != null) {
            val (key, measured) = selected.value
            return SecureMeshAndroidCustodySelection.KeyStore(
                key,
                measured.copy(
                    strongBoxRequested = selected.candidate.requestStrongBox,
                    keyGenerationAttemptCount = selected.attemptCount,
                ),
            )
        }
        return memoryOnly(
            platform,
            "android_keystore_safe_key_generation_failed",
            attemptedCandidateCount,
        )
    }

    private fun removeOnlyNewlyGeneratedAlias(keyStore: KeyStore, alias: String) {
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
            check(!keyStore.containsAlias(alias)) {
                "secure mesh Android rejected key cleanup failed"
            }
        }
    }

    private fun memoryOnly(
        platform: SecureMeshAndroidPlatformCapabilities,
        reason: String,
        attempts: Int,
    ) = SecureMeshAndroidCustodySelection.MemoryOnly(
        capabilityProbe.memoryOnly(platform, reason, attemptCount = attempts),
    )

    private fun generateKey(
        alias: String,
        candidate: SecureMeshAndroidKeyPolicyCandidate,
    ): SecretKey {
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        val builder = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setKeySize(256)
        if (candidate.requestStrongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        if (candidate.requestUnlockedDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setUnlockedDeviceRequired(true)
        }
        builder.setUserAuthenticationRequired(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            builder.setInvalidatedByBiometricEnrollment(
                candidate.invalidateOnBiometricEnrollmentChange,
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val authenticators = when (candidate.authenticationMode) {
                SecureMeshAndroidAuthenticationMode.DEVICE_CREDENTIAL ->
                    KeyProperties.AUTH_DEVICE_CREDENTIAL
                SecureMeshAndroidAuthenticationMode.STRONG_BIOMETRIC ->
                    KeyProperties.AUTH_BIOMETRIC_STRONG
                SecureMeshAndroidAuthenticationMode.DEVICE_CREDENTIAL_OR_STRONG_BIOMETRIC ->
                    KeyProperties.AUTH_DEVICE_CREDENTIAL or KeyProperties.AUTH_BIOMETRIC_STRONG
            }
            builder.setUserAuthenticationParameters(
                candidate.authenticationValiditySeconds,
                authenticators,
            )
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(
                candidate.authenticationValiditySeconds,
            )
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun strongBoxUnavailable(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            if (
                current is StrongBoxUnavailableException ||
                (current is ProviderException &&
                    current.javaClass.simpleName == "StrongBoxUnavailableException")
            ) return true
            current = current.cause
        }
        return false
    }
}
