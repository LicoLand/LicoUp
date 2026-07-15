package com.liko.arc

internal enum class SecureMeshAndroidAuthenticationMode {
    DEVICE_CREDENTIAL,
    STRONG_BIOMETRIC,
    DEVICE_CREDENTIAL_OR_STRONG_BIOMETRIC
}

internal data class SecureMeshAndroidKeyPolicyEnvironment(
    val androidApiLevel: Int,
    val strongBoxSupported: Boolean,
    val deviceCredentialAvailable: Boolean,
    val strongBiometricAvailable: Boolean
)

internal data class SecureMeshAndroidKeyPolicyCandidate(
    val requestStrongBox: Boolean,
    val requestUnlockedDevice: Boolean,
    val authenticationMode: SecureMeshAndroidAuthenticationMode,
    val authenticationValiditySeconds: Int,
    val invalidateOnBiometricEnrollmentChange: Boolean
) {
    val requestsUserAuthentication: Boolean
        get() = true
}

internal enum class SecureMeshAndroidKeyAttemptFailure {
    STRONGBOX_UNAVAILABLE,
    POLICY_INCOMPATIBLE
}

internal sealed interface SecureMeshAndroidKeyAttempt<out T> {
    data class Success<T>(val value: T) : SecureMeshAndroidKeyAttempt<T>

    data class Failure(
        val kind: SecureMeshAndroidKeyAttemptFailure
    ) : SecureMeshAndroidKeyAttempt<Nothing>
}

internal data class SecureMeshAndroidKeyPolicySelection<T>(
    val candidate: SecureMeshAndroidKeyPolicyCandidate,
    val value: T,
    val attemptCount: Int
)

/**
 * Produces a deterministic maximal-compatible candidate sequence. Generated-key inspection then
 * reports every independently enforced capability, so candidate ordering never becomes posture.
 */
internal object SecureMeshAndroidKeyPolicyStrategy {
    fun candidates(
        environment: SecureMeshAndroidKeyPolicyEnvironment,
        authenticationValiditySeconds: Int
    ): List<SecureMeshAndroidKeyPolicyCandidate> {
        val authenticationMode = when {
            environment.deviceCredentialAvailable && environment.strongBiometricAvailable ->
                SecureMeshAndroidAuthenticationMode.DEVICE_CREDENTIAL_OR_STRONG_BIOMETRIC
            environment.deviceCredentialAvailable ->
                SecureMeshAndroidAuthenticationMode.DEVICE_CREDENTIAL
            environment.strongBiometricAvailable ->
                SecureMeshAndroidAuthenticationMode.STRONG_BIOMETRIC
            else -> return emptyList()
        }
        val unlockedDeviceSupported = environment.androidApiLevel >= 28
        val variants = buildList {
            add(authenticationMode to unlockedDeviceSupported)
            if (unlockedDeviceSupported) {
                add(authenticationMode to false)
            }
        }.distinct()

        return buildList {
            val strongBoxPreferences = if (environment.strongBoxSupported) {
                listOf(true, false)
            } else {
                listOf(false)
            }
            for (requestStrongBox in strongBoxPreferences) {
                for ((mode, requestUnlockedDevice) in variants) {
                    add(
                        candidate(
                            requestStrongBox = requestStrongBox,
                            requestUnlockedDevice = requestUnlockedDevice,
                            authenticationMode = mode,
                            authenticationValiditySeconds = authenticationValiditySeconds
                        )
                    )
                }
            }
        }.distinct()
    }

    fun <T> select(
        candidates: List<SecureMeshAndroidKeyPolicyCandidate>,
        attempt: (SecureMeshAndroidKeyPolicyCandidate) -> SecureMeshAndroidKeyAttempt<T>
    ): SecureMeshAndroidKeyPolicySelection<T>? {
        var attemptCount = 0
        var strongBoxUnavailable = false
        for (candidate in candidates) {
            if (strongBoxUnavailable && candidate.requestStrongBox) {
                continue
            }
            attemptCount += 1
            when (val result = attempt(candidate)) {
                is SecureMeshAndroidKeyAttempt.Success -> {
                    return SecureMeshAndroidKeyPolicySelection(
                        candidate = candidate,
                        value = result.value,
                        attemptCount = attemptCount
                    )
                }
                is SecureMeshAndroidKeyAttempt.Failure -> {
                    if (result.kind == SecureMeshAndroidKeyAttemptFailure.STRONGBOX_UNAVAILABLE) {
                        strongBoxUnavailable = true
                    }
                }
            }
        }
        return null
    }

    private fun candidate(
        requestStrongBox: Boolean,
        requestUnlockedDevice: Boolean,
        authenticationMode: SecureMeshAndroidAuthenticationMode,
        authenticationValiditySeconds: Int
    ): SecureMeshAndroidKeyPolicyCandidate {
        return SecureMeshAndroidKeyPolicyCandidate(
            requestStrongBox = requestStrongBox,
            requestUnlockedDevice = requestUnlockedDevice,
            authenticationMode = authenticationMode,
            authenticationValiditySeconds = authenticationValiditySeconds,
            invalidateOnBiometricEnrollmentChange =
                authenticationMode == SecureMeshAndroidAuthenticationMode.STRONG_BIOMETRIC
        )
    }
}
