package land.lico.licoup

internal enum class SecureMeshAndroidCustodyStrategy(val wireName: String) {
    ANDROID_KEYSTORE("os_secure_store"),
    MEMORY_ONLY_EPHEMERAL("memory_only_ephemeral")
}

internal enum class SecureMeshAndroidSecurityLevel(val wireName: String) {
    SOFTWARE("software"),
    UNKNOWN_SECURE("unknown_secure"),
    TRUSTED_ENVIRONMENT("trusted_environment"),
    STRONGBOX("strongbox"),
    UNVERIFIED("unverified")
}

internal data class SecureMeshAndroidCapabilityMeasurement(
    val keyStoreAvailable: Boolean,
    val custodyStrategy: SecureMeshAndroidCustodyStrategy,
    val custodyReasonCode: String,
    val keyPresent: Boolean,
    val keyMaterialNonExportable: Boolean?,
    val securityLevel: SecureMeshAndroidSecurityLevel,
    val insideSecureHardware: Boolean?,
    val userAuthenticationRequested: Boolean,
    val userAuthenticationRequired: Boolean?,
    val userAuthenticationTypeMeasured: Boolean,
    val deviceCredentialAllowed: Boolean,
    val strongBiometricAllowed: Boolean,
    val userAuthenticationValiditySeconds: Int?,
    val userAuthenticationHardwareEnforced: Boolean?,
    val invalidatedByBiometricEnrollment: Boolean?,
    val biometricEnrollmentInvalidationNotApplicableBecauseDeviceCredentialAllowed: Boolean,
    val unlockedDeviceRequiredRequested: Boolean,
    val unlockedDeviceRequired: Boolean?,
    val deviceCredentialAvailable: Boolean,
    val strongBiometricAvailable: Boolean,
    val strongBiometricAvailabilityMeasured: Boolean,
    val strongBoxRequested: Boolean,
    val keyGenerationAttemptCount: Int
) {
    val persistentCustodySelected: Boolean
        get() = custodyStrategy == SecureMeshAndroidCustodyStrategy.ANDROID_KEYSTORE

    val hardwareBacked: Boolean
        get() = securityLevel == SecureMeshAndroidSecurityLevel.UNKNOWN_SECURE ||
            securityLevel == SecureMeshAndroidSecurityLevel.TRUSTED_ENVIRONMENT ||
            securityLevel == SecureMeshAndroidSecurityLevel.STRONGBOX

    val teeBacked: Boolean?
        get() = when (securityLevel) {
            SecureMeshAndroidSecurityLevel.TRUSTED_ENVIRONMENT -> true
            SecureMeshAndroidSecurityLevel.SOFTWARE,
            SecureMeshAndroidSecurityLevel.STRONGBOX -> false
            SecureMeshAndroidSecurityLevel.UNKNOWN_SECURE,
            SecureMeshAndroidSecurityLevel.UNVERIFIED -> null
        }

    val strongBoxBacked: Boolean?
        get() = when (securityLevel) {
            SecureMeshAndroidSecurityLevel.STRONGBOX -> true
            SecureMeshAndroidSecurityLevel.SOFTWARE,
            SecureMeshAndroidSecurityLevel.TRUSTED_ENVIRONMENT -> false
            SecureMeshAndroidSecurityLevel.UNKNOWN_SECURE,
            SecureMeshAndroidSecurityLevel.UNVERIFIED -> null
        }

    val userAuthenticationType: String
        get() = when {
            userAuthenticationRequired == null -> "unverified"
            userAuthenticationRequired == false -> "none"
            !userAuthenticationTypeMeasured -> "unverified"
            deviceCredentialAllowed && strongBiometricAllowed ->
                "device_credential_or_strong_biometric"
            deviceCredentialAllowed -> "device_credential"
            strongBiometricAllowed -> "strong_biometric"
            else -> "unverified"
        }

    fun capabilityProbe(): Map<String, Any?> {
        return mapOf(
            "schemaVersion" to 1,
            "facts" to capabilityFacts().map(SecureMeshAndroidCapabilityFact::toMap)
        )
    }

    fun redactedMeasurements(): Map<String, Any?> {
        return mapOf(
            "schemaVersion" to 1,
            "keyStoreAvailable" to keyStoreAvailable,
            "custodyStrategy" to custodyStrategy.wireName,
            "restartSemantics" to if (persistentCustodySelected) {
                "persistent_state_available"
            } else {
                "re_pair_rekey_after_restart"
            },
            "keyPresent" to keyPresent,
            "keyMaterialNonExportable" to keyMaterialNonExportable,
            "securityLevelMeasured" to
                (securityLevel != SecureMeshAndroidSecurityLevel.UNVERIFIED),
            "securityLevel" to securityLevel.wireName,
            "insideSecureHardware" to insideSecureHardware,
            "userAuthenticationRequested" to userAuthenticationRequested,
            "userAuthenticationRequired" to userAuthenticationRequired,
            "userAuthenticationTypeMeasured" to userAuthenticationTypeMeasured,
            "userAuthenticationType" to userAuthenticationType,
            "deviceCredentialAvailable" to deviceCredentialAvailable,
            "deviceCredentialAllowed" to deviceCredentialAllowed,
            "strongBiometricAvailable" to strongBiometricAvailable,
            "strongBiometricAvailabilityMeasured" to strongBiometricAvailabilityMeasured,
            "strongBiometricAllowed" to strongBiometricAllowed,
            "userAuthenticationValiditySeconds" to userAuthenticationValiditySeconds,
            "userAuthenticationHardwareEnforced" to userAuthenticationHardwareEnforced,
            "invalidatedByBiometricEnrollment" to invalidatedByBiometricEnrollment,
            "biometricEnrollmentInvalidationNotApplicableBecauseDeviceCredentialAllowed" to
                biometricEnrollmentInvalidationNotApplicableBecauseDeviceCredentialAllowed,
            "unlockedDeviceRequiredRequested" to unlockedDeviceRequiredRequested,
            "unlockedDeviceRequired" to unlockedDeviceRequired,
            "strongBoxRequested" to strongBoxRequested,
            "keyGenerationAttemptCount" to keyGenerationAttemptCount,
            "bodyRedacted" to true
        )
    }

    private fun capabilityFacts(): List<SecureMeshAndroidCapabilityFact> {
        val unavailableBecauseCustody = if (keyStoreAvailable) {
            custodyReasonCode.ifBlank { "android_keystore_key_generation_failed" }
        } else {
            "android_keystore_unavailable"
        }
        val facts = mutableListOf<SecureMeshAndroidCapabilityFact>()
        facts += fact(
            "custody.os_secure_store",
            persistentCustodySelected,
            unavailableBecauseCustody,
            "runtime_operation"
        )
        facts += measuredFact(
            "custody.software_backed",
            securityLevel.takeIf { persistentCustodySelected }?.let {
                it == SecureMeshAndroidSecurityLevel.SOFTWARE
            },
            "generated_key_inspection",
            "android_keystore_not_software_backed"
        )
        facts += measuredFact(
            "custody.non_exportable",
            keyMaterialNonExportable.takeIf { persistentCustodySelected },
            "generated_key_inspection",
            "android_key_material_exportable"
        )
        facts += fact(
            "custody.device_bound",
            persistentCustodySelected && keyPresent,
            unavailableBecauseCustody,
            "generated_key_inspection"
        )
        facts += measuredFact(
            "custody.unlocked_device_required",
            unlockedDeviceRequired.takeIf { persistentCustodySelected },
            "generated_key_inspection",
            "android_unlocked_device_requirement_not_enforced"
        )
        facts += measuredFact(
            "custody.os_user_presence",
            userAuthenticationRequired.takeIf { persistentCustodySelected },
            "generated_key_inspection",
            "android_user_authentication_not_selected"
        )
        facts += if (persistentCustodySelected &&
            (userAuthenticationRequired == null ||
                (userAuthenticationRequired == true && !userAuthenticationTypeMeasured))
        ) {
            SecureMeshAndroidCapabilityFact.unverified(
                "custody.device_credential",
                "not_measured",
                "android_user_authentication_type_not_measured"
            )
        } else {
            fact(
                "custody.device_credential",
                persistentCustodySelected && userAuthenticationRequired == true &&
                    deviceCredentialAllowed && deviceCredentialAvailable,
                if (deviceCredentialAvailable) {
                    "android_device_credential_not_selected"
                } else {
                    "android_device_credential_unavailable"
                },
                "os_authorization"
            )
        }
        facts += if (!strongBiometricAvailabilityMeasured ||
            (persistentCustodySelected &&
                (userAuthenticationRequired == null ||
                    (userAuthenticationRequired == true && !userAuthenticationTypeMeasured)))
        ) {
            SecureMeshAndroidCapabilityFact.unverified(
                "custody.strong_biometric",
                "not_measured",
                "android_strong_biometric_not_measured"
            )
        } else {
            fact(
                "custody.strong_biometric",
                persistentCustodySelected && userAuthenticationRequired == true &&
                    strongBiometricAllowed && strongBiometricAvailable,
                if (strongBiometricAvailable) {
                    "android_strong_biometric_not_selected"
                } else {
                    "android_strong_biometric_unavailable"
                },
                "os_authorization"
            )
        }
        facts += measuredFact(
            "custody.authentication_validity_window",
            when {
                !persistentCustodySelected -> null
                userAuthenticationRequired == false -> false
                userAuthenticationRequired == true ->
                    userAuthenticationValiditySeconds?.let { it > 0 }
                else -> null
            },
            "generated_key_inspection",
            "android_authentication_window_not_selected"
        )
        facts += if (biometricEnrollmentInvalidationNotApplicableBecauseDeviceCredentialAllowed) {
            SecureMeshAndroidCapabilityFact.unsupported(
                "custody.enrollment_change_invalidation",
                "generated_key_inspection",
                "android_enrollment_invalidation_not_applicable_with_device_credential"
            )
        } else {
            measuredFact(
                "custody.enrollment_change_invalidation",
                when {
                    !persistentCustodySelected -> null
                    strongBiometricAllowed -> invalidatedByBiometricEnrollment
                    userAuthenticationRequired != null -> false
                    else -> null
                },
                "generated_key_inspection",
                "android_enrollment_invalidation_not_enforced"
            )
        }
        facts += measuredFact(
            "custody.hardware_backed",
            if (persistentCustodySelected &&
                securityLevel != SecureMeshAndroidSecurityLevel.UNVERIFIED
            ) {
                hardwareBacked
            } else {
                null
            },
            "generated_key_inspection",
            "android_keystore_software_security_level"
        )
        facts += measuredFact(
            "custody.hardware_enforced_user_authentication",
            when {
                !persistentCustodySelected -> null
                userAuthenticationRequired == false -> false
                userAuthenticationRequired == true -> userAuthenticationHardwareEnforced
                else -> null
            },
            "generated_key_inspection",
            "android_user_authentication_not_hardware_enforced"
        )
        facts += fact(
            "custody.android_keystore",
            persistentCustodySelected,
            unavailableBecauseCustody,
            "runtime_operation"
        )
        facts += unsupportedPlatformFact("custody.apple_keychain")
        facts += unsupportedPlatformFact("custody.linux_secret_service")
        facts += unsupportedPlatformFact("custody.data_protection_keychain")
        facts += measuredFact(
            "custody.tee",
            if (persistentCustodySelected) {
                teeBacked
            } else {
                null
            },
            "generated_key_inspection",
            "android_trusted_execution_not_present"
        )
        facts += measuredFact(
            "custody.strongbox",
            if (persistentCustodySelected) {
                strongBoxBacked
            } else {
                null
            },
            "generated_key_inspection",
            "android_strongbox_not_present"
        )
        facts += unsupportedPlatformFact("custody.secure_enclave")
        return facts
    }

    private fun fact(
        capability: String,
        supported: Boolean,
        unsupportedReason: String,
        evidenceKind: String
    ): SecureMeshAndroidCapabilityFact {
        return if (supported) {
            SecureMeshAndroidCapabilityFact.supported(capability, evidenceKind)
        } else {
            SecureMeshAndroidCapabilityFact.unsupported(
                capability,
                evidenceKind,
                unsupportedReason
            )
        }
    }

    private fun measuredFact(
        capability: String,
        supported: Boolean?,
        evidenceKind: String,
        unsupportedReason: String
    ): SecureMeshAndroidCapabilityFact {
        return when (supported) {
            true -> SecureMeshAndroidCapabilityFact.supported(capability, evidenceKind)
            false -> SecureMeshAndroidCapabilityFact.unsupported(
                capability,
                evidenceKind,
                unsupportedReason
            )
            null -> SecureMeshAndroidCapabilityFact.unverified(
                capability,
                "not_measured",
                "android_capability_not_measured"
            )
        }
    }

    private fun unsupportedPlatformFact(capability: String): SecureMeshAndroidCapabilityFact {
        return SecureMeshAndroidCapabilityFact.unsupported(
            capability,
            "source_contract",
            "capability_not_applicable_on_android"
        )
    }
}

internal data class SecureMeshAndroidCapabilityFact(
    val capability: String,
    val state: String,
    val evidenceKind: String,
    val reasonCode: String?
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "capability" to capability,
            "state" to state,
            "evidenceKind" to evidenceKind,
            "measuredAtUnixSeconds" to null,
            "reasonCode" to reasonCode
        )
    }

    companion object {
        fun supported(
            capability: String,
            evidenceKind: String
        ): SecureMeshAndroidCapabilityFact {
            return SecureMeshAndroidCapabilityFact(
                capability = capability,
                state = "supported",
                evidenceKind = evidenceKind,
                reasonCode = null
            )
        }

        fun unsupported(
            capability: String,
            evidenceKind: String,
            reasonCode: String
        ): SecureMeshAndroidCapabilityFact {
            return SecureMeshAndroidCapabilityFact(
                capability = capability,
                state = "unsupported",
                evidenceKind = evidenceKind,
                reasonCode = reasonCode
            )
        }

        fun unverified(
            capability: String,
            evidenceKind: String,
            reasonCode: String
        ): SecureMeshAndroidCapabilityFact {
            return SecureMeshAndroidCapabilityFact(
                capability = capability,
                state = "unverified",
                evidenceKind = evidenceKind,
                reasonCode = reasonCode
            )
        }
    }
}
