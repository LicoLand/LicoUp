package com.liko.arc

import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.os.Build
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import java.security.Key
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

internal data class SecureMeshAndroidPlatformCapabilities(
    val keyStoreAvailable: Boolean,
    val strongBoxSupported: Boolean,
    val deviceCredentialAvailable: Boolean,
    val strongBiometricAvailabilityMeasured: Boolean,
    val strongBiometricAvailable: Boolean
) {
    fun policyEnvironment(): SecureMeshAndroidKeyPolicyEnvironment {
        return SecureMeshAndroidKeyPolicyEnvironment(
            androidApiLevel = Build.VERSION.SDK_INT,
            strongBoxSupported = strongBoxSupported,
            deviceCredentialAvailable = deviceCredentialAvailable,
            strongBiometricAvailable = strongBiometricAvailable
        )
    }
}

internal class SecureMeshAndroidCapabilityProbe(private val context: Context) {
    fun platformCapabilities(): SecureMeshAndroidPlatformCapabilities {
        val strongBiometricMeasurement = strongBiometricAvailability()
        return SecureMeshAndroidPlatformCapabilities(
            keyStoreAvailable = androidKeyStoreAvailable(),
            strongBoxSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                context.packageManager.hasSystemFeature(STRONGBOX_FEATURE),
            deviceCredentialAvailable = deviceCredentialAvailable(),
            strongBiometricAvailabilityMeasured = strongBiometricMeasurement.first,
            strongBiometricAvailable = strongBiometricMeasurement.second
        )
    }

    fun inspectSelectedKey(
        secretKey: SecretKey,
        platform: SecureMeshAndroidPlatformCapabilities,
        selectedCandidate: SecureMeshAndroidKeyPolicyCandidate?,
        attemptCount: Int
    ): SecureMeshAndroidCapabilityMeasurement {
        val keyInfo = secretKeyKeyInfo(secretKey)
        val securityLevel = keyInfo?.let(::securityLevel)
            ?: SecureMeshAndroidSecurityLevel.UNVERIFIED
        val userAuthenticationTypeMeasured =
            keyInfo != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
        val userAuthenticationType = if (userAuthenticationTypeMeasured) {
            keyInfo?.userAuthenticationType ?: 0
        } else {
            0
        }
        val deviceCredentialAllowed = userAuthenticationTypeMeasured &&
            (userAuthenticationType and KeyProperties.AUTH_DEVICE_CREDENTIAL) != 0
        val strongBiometricAllowed = userAuthenticationTypeMeasured &&
            (userAuthenticationType and KeyProperties.AUTH_BIOMETRIC_STRONG) != 0
        val invalidatedByBiometricEnrollment = keyInfo?.let {
            keyInfoBooleanMethod(it, "isInvalidatedByBiometricEnrollment")
        }
        val unlockedDeviceRequired = keyInfo?.let {
            keyInfoBooleanMethod(it, "isUnlockedDeviceRequired")
        }
        val userAuthenticationValiditySeconds = keyInfo
            ?.userAuthenticationValidityDurationSeconds
            ?.takeIf { it >= 0 }
        @Suppress("DEPRECATION")
        val insideSecureHardware = keyInfo?.isInsideSecureHardware
        return SecureMeshAndroidCapabilityMeasurement(
            keyStoreAvailable = platform.keyStoreAvailable,
            custodyStrategy = SecureMeshAndroidCustodyStrategy.ANDROID_KEYSTORE,
            custodyReasonCode = "android_keystore_selected",
            keyPresent = true,
            keyMaterialNonExportable = secretKey.encoded == null,
            securityLevel = securityLevel,
            insideSecureHardware = insideSecureHardware,
            userAuthenticationRequested =
                selectedCandidate?.requestsUserAuthentication ?: (
                    keyInfo?.isUserAuthenticationRequired ?: (
                        platform.deviceCredentialAvailable ||
                            platform.strongBiometricAvailable
                        )
                    ),
            userAuthenticationRequired = keyInfo?.isUserAuthenticationRequired,
            userAuthenticationTypeMeasured = userAuthenticationTypeMeasured,
            deviceCredentialAllowed = deviceCredentialAllowed,
            strongBiometricAllowed = strongBiometricAllowed,
            userAuthenticationValiditySeconds = userAuthenticationValiditySeconds,
            userAuthenticationHardwareEnforced =
                keyInfo?.isUserAuthenticationRequirementEnforcedBySecureHardware,
            invalidatedByBiometricEnrollment = invalidatedByBiometricEnrollment,
            biometricEnrollmentInvalidationNotApplicableBecauseDeviceCredentialAllowed =
                deviceCredentialAllowed && invalidatedByBiometricEnrollment == false,
            unlockedDeviceRequiredRequested = selectedCandidate?.requestUnlockedDevice == true,
            unlockedDeviceRequired = unlockedDeviceRequired,
            deviceCredentialAvailable = platform.deviceCredentialAvailable,
            strongBiometricAvailable = platform.strongBiometricAvailable,
            strongBiometricAvailabilityMeasured =
                platform.strongBiometricAvailabilityMeasured,
            strongBoxRequested = selectedCandidate?.requestStrongBox == true,
            keyGenerationAttemptCount = attemptCount
        )
    }

    fun memoryOnly(
        platform: SecureMeshAndroidPlatformCapabilities,
        reasonCode: String,
        attemptCount: Int
    ): SecureMeshAndroidCapabilityMeasurement {
        return SecureMeshAndroidCapabilityMeasurement(
            keyStoreAvailable = platform.keyStoreAvailable,
            custodyStrategy = SecureMeshAndroidCustodyStrategy.MEMORY_ONLY_EPHEMERAL,
            custodyReasonCode = reasonCode,
            keyPresent = false,
            keyMaterialNonExportable = null,
            securityLevel = SecureMeshAndroidSecurityLevel.UNVERIFIED,
            insideSecureHardware = null,
            userAuthenticationRequested = false,
            userAuthenticationRequired = false,
            userAuthenticationTypeMeasured = false,
            deviceCredentialAllowed = false,
            strongBiometricAllowed = false,
            userAuthenticationValiditySeconds = null,
            userAuthenticationHardwareEnforced = null,
            invalidatedByBiometricEnrollment = null,
            biometricEnrollmentInvalidationNotApplicableBecauseDeviceCredentialAllowed = false,
            unlockedDeviceRequiredRequested = false,
            unlockedDeviceRequired = null,
            deviceCredentialAvailable = platform.deviceCredentialAvailable,
            strongBiometricAvailable = platform.strongBiometricAvailable,
            strongBiometricAvailabilityMeasured =
                platform.strongBiometricAvailabilityMeasured,
            strongBoxRequested = false,
            keyGenerationAttemptCount = attemptCount
        )
    }

    fun keyIsSafeForPersistentCustody(
        key: Key,
        measurement: SecureMeshAndroidCapabilityMeasurement
    ): Boolean {
        return key.encoded == null &&
            measurement.keyPresent &&
            measurement.custodyStrategy == SecureMeshAndroidCustodyStrategy.ANDROID_KEYSTORE
    }

    private fun androidKeyStoreAvailable(): Boolean {
        return try {
            val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun deviceCredentialAvailable(): Boolean {
        return try {
            context.getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true
        } catch (_: Exception) {
            false
        }
    }

    private fun strongBiometricAvailability(): Pair<Boolean, Boolean> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return false to false
        }
        return try {
            val manager = context.getSystemService(BiometricManager::class.java)
            true to (
                manager?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
                    BiometricManager.BIOMETRIC_SUCCESS
                )
        } catch (_: Exception) {
            true to false
        }
    }

    private fun secretKeyKeyInfo(secretKey: SecretKey): KeyInfo? {
        return try {
            val factory = SecretKeyFactory.getInstance(secretKey.algorithm, "AndroidKeyStore")
            factory.getKeySpec(secretKey, KeyInfo::class.java) as? KeyInfo
        } catch (_: Exception) {
            null
        }
    }

    private fun securityLevel(keyInfo: KeyInfo): SecureMeshAndroidSecurityLevel {
        val value = keyInfoIntMethod(keyInfo, "getSecurityLevel")
        if (value != null) {
            return when (value) {
                keyPropertiesIntField("SECURITY_LEVEL_SOFTWARE") ->
                    SecureMeshAndroidSecurityLevel.SOFTWARE
                keyPropertiesIntField("SECURITY_LEVEL_UNKNOWN_SECURE") ->
                    SecureMeshAndroidSecurityLevel.UNKNOWN_SECURE
                keyPropertiesIntField("SECURITY_LEVEL_TRUSTED_ENVIRONMENT") ->
                    SecureMeshAndroidSecurityLevel.TRUSTED_ENVIRONMENT
                keyPropertiesIntField("SECURITY_LEVEL_STRONGBOX") ->
                    SecureMeshAndroidSecurityLevel.STRONGBOX
                else -> SecureMeshAndroidSecurityLevel.UNVERIFIED
            }
        }
        @Suppress("DEPRECATION")
        return if (keyInfo.isInsideSecureHardware) {
            SecureMeshAndroidSecurityLevel.UNKNOWN_SECURE
        } else {
            SecureMeshAndroidSecurityLevel.SOFTWARE
        }
    }

    private fun keyInfoBooleanMethod(keyInfo: KeyInfo, methodName: String): Boolean? {
        return try {
            KeyInfo::class.java.getMethod(methodName).invoke(keyInfo) as? Boolean
        } catch (_: Exception) {
            null
        }
    }

    private fun keyInfoIntMethod(keyInfo: KeyInfo, methodName: String): Int? {
        return try {
            KeyInfo::class.java.getMethod(methodName).invoke(keyInfo) as? Int
        } catch (_: Exception) {
            null
        }
    }

    private fun keyPropertiesIntField(fieldName: String): Int {
        return try {
            KeyProperties::class.java.getField(fieldName).getInt(null)
        } catch (_: Exception) {
            Int.MIN_VALUE
        }
    }

    private companion object {
        private const val STRONGBOX_FEATURE = "android.hardware.strongbox_keystore"
    }
}
