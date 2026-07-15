package com.liko.arc

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureMeshAndroidAdaptiveCustodyTest {
    @Test
    fun noLockScreenRejectsPersistentKeyStoreAndRequiresMemoryOnlyCustody() {
        val candidates = SecureMeshAndroidKeyPolicyStrategy.candidates(
            SecureMeshAndroidKeyPolicyEnvironment(
                androidApiLevel = 35,
                strongBoxSupported = false,
                deviceCredentialAvailable = false,
                strongBiometricAvailable = false
            ),
            authenticationValiditySeconds = 300
        )

        assertTrue(candidates.isEmpty())
    }

    @Test
    fun strongBoxUnavailableSelectsNextSafeKeyStoreCandidate() {
        val candidates = SecureMeshAndroidKeyPolicyStrategy.candidates(
            SecureMeshAndroidKeyPolicyEnvironment(
                androidApiLevel = 35,
                strongBoxSupported = true,
                deviceCredentialAvailable = true,
                strongBiometricAvailable = true
            ),
            authenticationValiditySeconds = 300
        )
        val attemptedStrongBox = mutableListOf<Boolean>()
        val selection = SecureMeshAndroidKeyPolicyStrategy.select(candidates) { candidate ->
            attemptedStrongBox += candidate.requestStrongBox
            if (candidate.requestStrongBox) {
                SecureMeshAndroidKeyAttempt.Failure(
                    SecureMeshAndroidKeyAttemptFailure.STRONGBOX_UNAVAILABLE
                )
            } else {
                SecureMeshAndroidKeyAttempt.Success("safe-keystore-key")
            }
        }

        assertEquals("safe-keystore-key", selection?.value)
        assertFalse(selection?.candidate?.requestStrongBox ?: true)
        assertEquals(listOf(true, false), attemptedStrongBox)
    }

    @Test
    fun policyIncompatibilityRelaxesStrongBoxPolicyBeforeLeavingStrongBox() {
        val candidates = SecureMeshAndroidKeyPolicyStrategy.candidates(
            SecureMeshAndroidKeyPolicyEnvironment(
                androidApiLevel = 35,
                strongBoxSupported = true,
                deviceCredentialAvailable = true,
                strongBiometricAvailable = true
            ),
            authenticationValiditySeconds = 300
        )
        val attemptedCandidates = mutableListOf<SecureMeshAndroidKeyPolicyCandidate>()
        val selection = SecureMeshAndroidKeyPolicyStrategy.select(candidates) { candidate ->
            attemptedCandidates += candidate
            if (attemptedCandidates.size == 1) {
                SecureMeshAndroidKeyAttempt.Failure(
                    SecureMeshAndroidKeyAttemptFailure.POLICY_INCOMPATIBLE
                )
            } else {
                SecureMeshAndroidKeyAttempt.Success("relaxed-strongbox-key")
            }
        }

        assertEquals("relaxed-strongbox-key", selection?.value)
        assertTrue(selection?.candidate?.requestStrongBox == true)
        assertTrue(attemptedCandidates.all { it.requestStrongBox })
    }

    @Test
    fun totalKeyStoreFailureSelectsNoPersistentCandidate() {
        val candidates = SecureMeshAndroidKeyPolicyStrategy.candidates(
            SecureMeshAndroidKeyPolicyEnvironment(
                androidApiLevel = 35,
                strongBoxSupported = true,
                deviceCredentialAvailable = true,
                strongBiometricAvailable = false
            ),
            authenticationValiditySeconds = 300
        )
        val selection = SecureMeshAndroidKeyPolicyStrategy.select(candidates) {
            SecureMeshAndroidKeyAttempt.Failure(
                SecureMeshAndroidKeyAttemptFailure.POLICY_INCOMPATIBLE
            )
        }

        assertNull(selection)
    }

    @Test
    fun memoryOnlyStoreCopiesAndClearsProcessBuffers() {
        val store = SecureMeshAndroidEphemeralSecretStore()
        val input = byteArrayOf(1, 2, 3)
        store.put("secret", input)
        input.fill(9)
        assertArrayEquals(byteArrayOf(1, 2, 3), store.get("secret"))

        val output = store.get("secret")!!
        output.fill(8)
        assertArrayEquals(byteArrayOf(1, 2, 3), store.get("secret"))
        assertEquals(1, store.entryCountForTest())

        store.clear()
        assertEquals(0, store.entryCountForTest())
        assertNull(store.get("secret"))
    }

    @Test
    fun securityLevelsRemainIndependentFacts() {
        val software = factsById(measurement(SecureMeshAndroidSecurityLevel.SOFTWARE))
        assertEquals("supported", software.getValue("custody.software_backed")["state"])
        assertEquals("unsupported", software.getValue("custody.hardware_backed")["state"])
        assertEquals("unsupported", software.getValue("custody.tee")["state"])

        val secureEnvironmentExpectations = mapOf(
            SecureMeshAndroidSecurityLevel.UNKNOWN_SECURE to ("unverified" to "unverified"),
            SecureMeshAndroidSecurityLevel.TRUSTED_ENVIRONMENT to ("supported" to "unsupported"),
            SecureMeshAndroidSecurityLevel.STRONGBOX to ("unsupported" to "supported")
        )
        for ((securityLevel, expected) in secureEnvironmentExpectations) {
            val facts = factsById(measurement(securityLevel))
            assertEquals("unsupported", facts.getValue("custody.software_backed")["state"])
            assertEquals("supported", facts.getValue("custody.hardware_backed")["state"])
            assertEquals(expected.first, facts.getValue("custody.tee")["state"])
            assertEquals(expected.second, facts.getValue("custody.strongbox")["state"])
        }

        val unverified = factsById(measurement(SecureMeshAndroidSecurityLevel.UNVERIFIED))
        assertEquals("unverified", unverified.getValue("custody.hardware_backed")["state"])
        assertEquals("unverified", unverified.getValue("custody.tee")["state"])
        assertEquals("unverified", unverified.getValue("custody.strongbox")["state"])
    }

    @Test
    fun credentialBiometricUnlockedAndEnrollmentFactsDoNotImplyEachOther() {
        val noCredential = factsById(
            measurement(
                securityLevel = SecureMeshAndroidSecurityLevel.SOFTWARE,
                userAuthenticationRequired = false,
                userAuthenticationTypeMeasured = true,
                deviceCredentialAvailable = false,
                deviceCredentialAllowed = false,
                strongBiometricAvailabilityMeasured = true,
                strongBiometricAvailable = false,
                strongBiometricAllowed = false,
                unlockedDeviceRequired = true,
                invalidatedByBiometricEnrollment = false
            )
        )
        assertEquals("supported", noCredential.getValue("custody.os_secure_store")["state"])
        assertEquals("supported", noCredential.getValue("custody.unlocked_device_required")["state"])
        assertEquals("unsupported", noCredential.getValue("custody.os_user_presence")["state"])
        assertEquals("unsupported", noCredential.getValue("custody.device_credential")["state"])
        assertEquals("unsupported", noCredential.getValue("custody.strong_biometric")["state"])

        val credentialOnly = factsById(
            measurement(
                securityLevel = SecureMeshAndroidSecurityLevel.TRUSTED_ENVIRONMENT,
                userAuthenticationRequired = true,
                userAuthenticationTypeMeasured = true,
                deviceCredentialAvailable = true,
                deviceCredentialAllowed = true,
                strongBiometricAvailabilityMeasured = true,
                strongBiometricAvailable = false,
                strongBiometricAllowed = false,
                unlockedDeviceRequired = true,
                invalidatedByBiometricEnrollment = false,
                enrollmentNotApplicable = true
            )
        )
        assertEquals("supported", credentialOnly.getValue("custody.device_credential")["state"])
        assertEquals("unsupported", credentialOnly.getValue("custody.strong_biometric")["state"])
        assertEquals(
            "unsupported",
            credentialOnly.getValue("custody.enrollment_change_invalidation")["state"]
        )

        val biometric = factsById(
            measurement(
                securityLevel = SecureMeshAndroidSecurityLevel.TRUSTED_ENVIRONMENT,
                userAuthenticationRequired = true,
                userAuthenticationTypeMeasured = true,
                deviceCredentialAvailable = false,
                deviceCredentialAllowed = false,
                strongBiometricAvailabilityMeasured = true,
                strongBiometricAvailable = true,
                strongBiometricAllowed = true,
                unlockedDeviceRequired = true,
                invalidatedByBiometricEnrollment = true
            )
        )
        assertEquals("unsupported", biometric.getValue("custody.device_credential")["state"])
        assertEquals("supported", biometric.getValue("custody.strong_biometric")["state"])
        assertEquals(
            "supported",
            biometric.getValue("custody.enrollment_change_invalidation")["state"]
        )
    }

    @Test
    fun memoryOnlyCapabilitySnapshotRequiresRestartRekeyWithoutPersistentClaims() {
        val measurement = measurement(
            securityLevel = SecureMeshAndroidSecurityLevel.UNVERIFIED,
            custodyStrategy = SecureMeshAndroidCustodyStrategy.MEMORY_ONLY_EPHEMERAL,
            keyStoreAvailable = false,
            keyMaterialNonExportable = null,
            userAuthenticationRequired = false,
            userAuthenticationTypeMeasured = false,
            unlockedDeviceRequired = null
        )
        val facts = factsById(measurement)
        assertEquals("unsupported", facts.getValue("custody.os_secure_store")["state"])
        assertEquals("unsupported", facts.getValue("custody.android_keystore")["state"])
        assertEquals(
            "re_pair_rekey_after_restart",
            measurement.redactedMeasurements()["restartSemantics"]
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun factsById(
        measurement: SecureMeshAndroidCapabilityMeasurement
    ): Map<String, Map<String, Any?>> {
        val facts = measurement.capabilityProbe()["facts"] as List<Map<String, Any?>>
        return facts.associateBy { it.getValue("capability") as String }
    }

    private fun measurement(
        securityLevel: SecureMeshAndroidSecurityLevel,
        custodyStrategy: SecureMeshAndroidCustodyStrategy =
            SecureMeshAndroidCustodyStrategy.ANDROID_KEYSTORE,
        keyStoreAvailable: Boolean = true,
        keyMaterialNonExportable: Boolean? = true,
        userAuthenticationRequired: Boolean? = true,
        userAuthenticationTypeMeasured: Boolean = true,
        deviceCredentialAvailable: Boolean = true,
        deviceCredentialAllowed: Boolean = true,
        strongBiometricAvailabilityMeasured: Boolean = true,
        strongBiometricAvailable: Boolean = true,
        strongBiometricAllowed: Boolean = true,
        unlockedDeviceRequired: Boolean? = true,
        invalidatedByBiometricEnrollment: Boolean? = true,
        enrollmentNotApplicable: Boolean = false
    ): SecureMeshAndroidCapabilityMeasurement {
        return SecureMeshAndroidCapabilityMeasurement(
            keyStoreAvailable = keyStoreAvailable,
            custodyStrategy = custodyStrategy,
            custodyReasonCode = if (keyStoreAvailable) {
                "android_keystore_selected"
            } else {
                "android_keystore_unavailable"
            },
            keyPresent = custodyStrategy == SecureMeshAndroidCustodyStrategy.ANDROID_KEYSTORE,
            keyMaterialNonExportable = keyMaterialNonExportable,
            securityLevel = securityLevel,
            insideSecureHardware = when (securityLevel) {
                SecureMeshAndroidSecurityLevel.SOFTWARE -> false
                SecureMeshAndroidSecurityLevel.UNVERIFIED -> null
                else -> true
            },
            userAuthenticationRequested = userAuthenticationRequired == true,
            userAuthenticationRequired = userAuthenticationRequired,
            userAuthenticationTypeMeasured = userAuthenticationTypeMeasured,
            deviceCredentialAllowed = deviceCredentialAllowed,
            strongBiometricAllowed = strongBiometricAllowed,
            userAuthenticationValiditySeconds =
                if (userAuthenticationRequired == true) 300 else null,
            userAuthenticationHardwareEnforced =
                if (userAuthenticationRequired == true) {
                    securityLevel != SecureMeshAndroidSecurityLevel.SOFTWARE
                } else {
                    null
                },
            invalidatedByBiometricEnrollment = invalidatedByBiometricEnrollment,
            biometricEnrollmentInvalidationNotApplicableBecauseDeviceCredentialAllowed =
                enrollmentNotApplicable,
            unlockedDeviceRequiredRequested = unlockedDeviceRequired != null,
            unlockedDeviceRequired = unlockedDeviceRequired,
            deviceCredentialAvailable = deviceCredentialAvailable,
            strongBiometricAvailable = strongBiometricAvailable,
            strongBiometricAvailabilityMeasured = strongBiometricAvailabilityMeasured,
            strongBoxRequested = securityLevel == SecureMeshAndroidSecurityLevel.STRONGBOX,
            keyGenerationAttemptCount = 1
        )
    }
}
