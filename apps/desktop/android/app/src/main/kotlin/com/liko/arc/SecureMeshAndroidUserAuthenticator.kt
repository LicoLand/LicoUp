package com.liko.arc

import android.app.Activity
import android.app.KeyguardManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject

internal object SecureMeshAndroidAuthorizationPolicy {
    // Keep this allowlist intentionally small: new and unknown actions fail closed.
    private val authenticationExemptActions = setOf(
        "external.url.open",
        "mobile.provider.web.open",
        "secure_mesh.android.status",
        "secure_mesh.android.userAuthentication.request",
        "secure_mesh.android.userAuthentication.status"
    )
    // Network/browser callbacks may consume an existing grant but never start or extend one.
    private val passiveResponseActions = setOf(
        "mobile.provider.oauth.completeCallback"
    )

    fun requiresUserAuthentication(action: String): Boolean {
        return action.trim() !in authenticationExemptActions
    }

    fun requiresSelectedUserAuthentication(
        action: String,
        userAuthenticationCapabilitySelected: Boolean
    ): Boolean {
        return userAuthenticationCapabilitySelected && requiresUserAuthentication(action)
    }

    fun mayStartAuthenticationPrompt(
        action: String,
        interactionAuthorized: Boolean
    ): Boolean {
        val normalized = action.trim()
        return interactionAuthorized &&
            requiresUserAuthentication(normalized) &&
            normalized !in passiveResponseActions
    }

    fun selectPromptStrategy(
        strongBiometricAvailable: Boolean,
        combinedPromptAvailable: Boolean,
        priorBiometricCompatibilityFailure: Boolean
    ): SecureMeshAndroidPromptStrategy {
        return if (
            strongBiometricAvailable &&
            combinedPromptAvailable &&
            !priorBiometricCompatibilityFailure
        ) {
            SecureMeshAndroidPromptStrategy.STRONG_BIOMETRIC_OR_DEVICE_CREDENTIAL
        } else {
            SecureMeshAndroidPromptStrategy.DEVICE_CREDENTIAL
        }
    }
}

internal enum class SecureMeshAndroidPromptStrategy {
    STRONG_BIOMETRIC_OR_DEVICE_CREDENTIAL,
    DEVICE_CREDENTIAL
}

class SecureMeshAndroidUserAuthenticator(private val activity: Activity) {
    private val lock = Any()
    private var pendingLatch: CountDownLatch? = null
    private var pendingCancellationSignal: CancellationSignal? = null
    private var pendingResult: Boolean? = null
    private var pendingResultCode: Int? = null
    private var pendingErrorClass: String = ""
    private var promptStarted: Boolean = false
    private var promptKind: String = PROMPT_KIND_NONE
    private var biometricPromptCompatibilityFailed: Boolean = false
    private var authorizationGrantExpiresAtElapsedRealtime: Long = 0L

    fun authorizeSensitiveAction(
        action: String,
        forcePrompt: Boolean = false,
    ): JSONObject {
        if (!SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(action)) {
            return JSONObject()
                .put("ok", true)
                .put("code", "android_user_authentication_not_required")
                .put("authorizationRequired", false)
                .put("authorizationScope", AUTHORIZATION_SCOPE)
                .put("bodyRedacted", true)
        }
        return request(
            JSONObject()
                .put("waitForCompletion", true)
                .put("timeoutSeconds", USER_AUTHENTICATION_TIMEOUT_SECONDS)
                .put("forcePrompt", forcePrompt)
        )
            .put("authorizationRequired", true)
            .put("authorizationScope", AUTHORIZATION_SCOPE)
    }

    fun hasActiveAuthorizationGrant(): Boolean {
        return synchronized(lock) {
            authorizationGrantIsActiveLocked(SystemClock.elapsedRealtime())
        }
    }

    fun activeAuthorizationRequiredResponse(): JSONObject {
        if (hasActiveAuthorizationGrant()) {
            return activeGrantResponse(reused = true)
        }
        return status()
            .put("ok", false)
            .put("code", "android_user_authentication_required")
            .put("authenticated", false)
            .put("authorizationRequired", true)
            .put("authorizationScope", AUTHORIZATION_SCOPE)
            .put("userActionRequired", "authenticate_in_lico_arc_before_sensitive_operation")
    }

    fun request(params: JSONObject): JSONObject {
        val timeoutSeconds = params.optLong(
            "timeoutSeconds",
            USER_AUTHENTICATION_TIMEOUT_SECONDS
        ).coerceIn(1L, USER_AUTHENTICATION_MAX_TIMEOUT_SECONDS)
        val waitForCompletion = params.optBoolean("waitForCompletion", true)
        val forcePrompt = params.optBoolean("forcePrompt", false)
        if (!forcePrompt && hasActiveAuthorizationGrant()) {
            return activeGrantResponse(reused = true)
        }
        if (forcePrompt) {
            synchronized(lock) {
                authorizationGrantExpiresAtElapsedRealtime = 0L
            }
        }

        val keyguard = activity.getSystemService(KeyguardManager::class.java)
        if (keyguard?.isDeviceSecure != true) {
            clearAuthorizationGrant()
            return unavailableStatus(
                "android_device_credential_not_configured",
                "configure_android_device_credential"
            )
        }

        val latch = CountDownLatch(1)
        val existingLatch = synchronized(lock) {
            val active = pendingLatch
            if (active == null) {
                promptStarted = false
                promptKind = PROMPT_KIND_NONE
                pendingResult = null
                pendingResultCode = null
                pendingErrorClass = ""
                pendingCancellationSignal = null
                pendingLatch = latch
            }
            active
        }
        if (existingLatch != null) {
            return existingSystemCredentialPromptResponse(
                existingLatch,
                timeoutSeconds,
                waitForCompletion
            )
        }

        val promptLaunchLatch = CountDownLatch(1)
        activity.runOnUiThread {
            try {
                launchSystemAuthenticationPrompt(keyguard, latch)
            } catch (error: Exception) {
                completePrompt(
                    latch = latch,
                    authenticated = false,
                    resultCode = null,
                    errorClass = error.javaClass.simpleName
                )
            } finally {
                promptLaunchLatch.countDown()
            }
        }
        val promptLaunchObserved = promptLaunchLatch.await(5, TimeUnit.SECONDS)
        if (!promptLaunchObserved) {
            cancelPromptIfCurrent(latch, "PromptStartTimedOut")
        }
        writeStatusFile(status())

        if (!waitForCompletion) {
            val response = status()
            val started = response.optBoolean("promptStarted", false) &&
                response.optString("systemCredentialPromptResult", "") !=
                "system_prompt_launch_failed"
            return response
                .put("ok", hasActiveAuthorizationGrant() || started)
                .put(
                    "code",
                    when {
                        hasActiveAuthorizationGrant() -> "android_user_authenticated"
                        !promptLaunchObserved ->
                            "android_user_authentication_prompt_start_timed_out"
                        started -> "android_user_authentication_prompt_started"
                        else -> "android_user_authentication_prompt_failed"
                    }
                )
                .put("authenticated", hasActiveAuthorizationGrant())
                .put("authorizationRequired", true)
                .put("authorizationScope", AUTHORIZATION_SCOPE)
        }

        val completed = latch.await(timeoutSeconds, TimeUnit.SECONDS)
        if (!completed) {
            cancelPromptIfCurrent(latch, "AuthenticationTimedOut")
        }
        val response = status()
        if (!completed && !response.optBoolean("authenticated", false)) {
            response
                .put("ok", false)
                .put("code", "android_user_authentication_timed_out")
                .put("systemCredentialPromptCompleted", false)
                .put("systemCredentialPromptResult", "system_prompt_timed_out_waiting_for_user")
                .put("userActionRequired", "complete_android_system_credential_prompt")
        }
        return response
            .put("authorizationRequired", true)
            .put("authorizationScope", AUTHORIZATION_SCOPE)
    }

    private fun launchSystemAuthenticationPrompt(
        keyguard: KeyguardManager,
        latch: CountDownLatch
    ) {
        val promptStrategy = SecureMeshAndroidAuthorizationPolicy.selectPromptStrategy(
            strongBiometricAvailable = strongBiometricPromptIsAvailable(),
            combinedPromptAvailable = biometricOrDeviceCredentialPromptIsAvailable(),
            priorBiometricCompatibilityFailure = synchronized(lock) {
                biometricPromptCompatibilityFailed
            }
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            promptStrategy ==
            SecureMeshAndroidPromptStrategy.STRONG_BIOMETRIC_OR_DEVICE_CREDENTIAL
        ) {
            launchBiometricOrDeviceCredentialPrompt(latch)
            return
        }
        val prompt = keyguard.createConfirmDeviceCredentialIntent(
            "Lico Arc Secure Mesh",
            "Authenticate once to authorize Secure Mesh keys and credentials."
        ) ?: throw IllegalStateException("android device credential prompt unavailable")
        synchronized(lock) {
            if (pendingLatch !== latch) {
                return
            }
            promptStarted = true
            promptKind = PROMPT_KIND_DEVICE_CREDENTIAL
        }
        activity.startActivityForResult(prompt, REQUEST_CODE)
    }

    private fun biometricOrDeviceCredentialPromptIsAvailable(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return false
        }
        val manager = activity.getSystemService(BiometricManager::class.java) ?: return false
        return manager.canAuthenticate(ALLOWED_AUTHENTICATORS) ==
            BiometricManager.BIOMETRIC_SUCCESS
    }

    private fun strongBiometricPromptIsAvailable(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return false
        }
        val manager = activity.getSystemService(BiometricManager::class.java) ?: return false
        return manager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG
        ) == BiometricManager.BIOMETRIC_SUCCESS
    }

    private fun launchBiometricOrDeviceCredentialPrompt(latch: CountDownLatch) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            throw IllegalStateException("android biometric prompt API unavailable")
        }
        val cancellationSignal = CancellationSignal()
        val prompt = BiometricPrompt.Builder(activity)
            .setTitle("Lico Arc Secure Mesh")
            .setSubtitle("Authenticate once to authorize Secure Mesh keys and credentials.")
            .setAllowedAuthenticators(ALLOWED_AUTHENTICATORS)
            .build()
        synchronized(lock) {
            if (pendingLatch !== latch) {
                return
            }
            promptStarted = true
            promptKind = PROMPT_KIND_BIOMETRIC_OR_DEVICE_CREDENTIAL
            pendingCancellationSignal = cancellationSignal
        }
        prompt.authenticate(
            cancellationSignal,
            activity.mainExecutor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    result: BiometricPrompt.AuthenticationResult
                ) {
                    completePrompt(
                        latch = latch,
                        authenticated = true,
                        resultCode = Activity.RESULT_OK,
                        errorClass = ""
                    )
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    if (errorCode in BIOMETRIC_COMPATIBILITY_FAILURE_CODES) {
                        synchronized(lock) {
                            biometricPromptCompatibilityFailed = true
                        }
                    }
                    completePrompt(
                        latch = latch,
                        authenticated = false,
                        resultCode = Activity.RESULT_CANCELED,
                        errorClass = "BiometricPromptError$errorCode"
                    )
                }

                override fun onAuthenticationFailed() {
                    // The system prompt remains active and may accept another attempt.
                }
            }
        )
    }

    private fun existingSystemCredentialPromptResponse(
        activeLatch: CountDownLatch,
        timeoutSeconds: Long,
        waitForCompletion: Boolean
    ): JSONObject {
        if (!waitForCompletion) {
            return status()
                .put("ok", false)
                .put("code", "android_user_authentication_already_pending")
                .put("systemCredentialPromptReused", true)
                .put("systemCredentialPromptReusedFromPendingRequest", true)
                .put("authorizationRequired", true)
                .put("authorizationScope", AUTHORIZATION_SCOPE)
        }
        val completed = activeLatch.await(timeoutSeconds, TimeUnit.SECONDS)
        val current = status()
            .put("systemCredentialPromptReused", true)
            .put("systemCredentialPromptReusedFromPendingRequest", true)
            .put("authorizationRequired", true)
            .put("authorizationScope", AUTHORIZATION_SCOPE)
        if (completed) {
            return current
        }
        return current
            .put("ok", false)
            .put("code", "android_user_authentication_timed_out")
            .put("systemCredentialPromptCompleted", false)
            .put("systemCredentialPromptResult", "system_prompt_timed_out_waiting_for_user")
            .put("userActionRequired", "complete_android_system_credential_prompt")
    }

    private fun completePrompt(
        latch: CountDownLatch,
        authenticated: Boolean,
        resultCode: Int?,
        errorClass: String
    ) {
        val active = synchronized(lock) {
            if (pendingLatch !== latch) {
                return
            }
            pendingResult = authenticated
            pendingResultCode = resultCode
            pendingErrorClass = errorClass
            pendingCancellationSignal = null
            pendingLatch = null
            if (authenticated) {
                authorizationGrantExpiresAtElapsedRealtime =
                    SystemClock.elapsedRealtime() + USER_AUTHENTICATION_VALIDITY_MILLIS
            } else {
                authorizationGrantExpiresAtElapsedRealtime = 0L
            }
            latch
        }
        active.countDown()
        writeStatusFile(status())
    }

    private fun cancelPromptIfCurrent(latch: CountDownLatch, errorClass: String) {
        val cancellationSignal = synchronized(lock) {
            if (pendingLatch !== latch) {
                return
            }
            pendingLatch = null
            pendingResult = false
            pendingResultCode = null
            pendingErrorClass = errorClass
            authorizationGrantExpiresAtElapsedRealtime = 0L
            pendingCancellationSignal.also { pendingCancellationSignal = null }
        }
        cancellationSignal?.cancel()
        latch.countDown()
    }

    fun status(): JSONObject {
        val keyguard = activity.getSystemService(KeyguardManager::class.java)
        if (keyguard?.isDeviceSecure != true) {
            clearAuthorizationGrant()
            return unavailableStatus(
                "android_device_credential_not_configured",
                "configure_android_device_credential",
                includePromptStatus = true
            )
        }
        val now = SystemClock.elapsedRealtime()
        val snapshot = synchronized(lock) {
            val grantActive = authorizationGrantIsActiveLocked(now)
            AuthenticationSnapshot(
                promptStarted = promptStarted,
                promptKind = promptKind,
                result = pendingResult,
                resultCode = pendingResultCode,
                errorClass = pendingErrorClass,
                pending = pendingLatch != null,
                grantActive = grantActive,
                grantRemainingSeconds = authorizationGrantRemainingSecondsLocked(now),
                biometricCompatibilityFallbackSelected =
                    biometricPromptCompatibilityFailed
            )
        }
        val systemPromptResult = when {
            snapshot.grantActive -> "authenticated"
            snapshot.pending -> "system_prompt_pending_user_action"
            snapshot.result == true -> "authorization_grant_expired"
            snapshot.errorClass.isNotBlank() -> "system_prompt_launch_failed"
            snapshot.promptStarted -> "system_prompt_cancelled_by_user"
            else -> "system_prompt_not_requested"
        }
        return JSONObject()
            .put("ok", snapshot.grantActive)
            .put(
                "code",
                when {
                    snapshot.grantActive -> "android_user_authenticated"
                    snapshot.pending -> "android_user_authentication_pending"
                    snapshot.result == true -> "android_user_authentication_expired"
                    snapshot.errorClass.isNotBlank() ->
                        "android_user_authentication_prompt_failed"
                    snapshot.promptStarted -> "android_user_authentication_cancelled"
                    else -> "android_user_authentication_not_requested"
                }
            )
            .put("platform", "android")
            .put("promptStarted", snapshot.promptStarted)
            .put("authenticated", snapshot.grantActive)
            .put("pending", snapshot.pending)
            .put("physicalUserPresenceRequired", true)
            .put("systemAuthenticationOnly", true)
            .put("appLockScreenCredentialCollection", false)
            .put("systemCredentialPromptAvailable", true)
            .put("systemCredentialPromptStarted", snapshot.promptStarted)
            .put("systemCredentialPromptCompleted", snapshot.result != null)
            .put("systemCredentialPromptResultCodePresent", snapshot.resultCode != null)
            .put("systemCredentialPromptResultCode", snapshot.resultCode ?: 0)
            .put("systemCredentialPromptResult", systemPromptResult)
            .put(
                "userActionRequired",
                if (snapshot.grantActive) "" else "complete_android_system_credential_prompt"
            )
            .put("credentialEntrySurface", "android_system_credential_prompt")
            .put("authenticationPromptKind", snapshot.promptKind)
            .put(
                "strongBiometricOrDeviceCredentialPromptUsed",
                snapshot.promptKind == PROMPT_KIND_BIOMETRIC_OR_DEVICE_CREDENTIAL
            )
            .put(
                "biometricCompatibilityFallbackSelected",
                snapshot.biometricCompatibilityFallbackSelected
            )
            .put("appCredentialPromptUsed", false)
            .put("appPasswordPromptUsed", false)
            .put("systemCredentialPromptReused", false)
            .put("systemCredentialPromptReusedFromPendingRequest", false)
            .put("androidKeyStoreUserAuthenticationWindowSeconds", USER_AUTHENTICATION_VALIDITY_SECONDS)
            .put("authorizationScope", AUTHORIZATION_SCOPE)
            .put("authorizationGrantActive", snapshot.grantActive)
            .put("authorizationGrantRemainingSeconds", snapshot.grantRemainingSeconds)
            .put("authorizationGrantPersisted", false)
            .put("authorizationGrantExtendedByDispatch", false)
            .put("keyMaterialExported", false)
            .put("bodyRedacted", true)
            .put("errorClass", snapshot.errorClass)
    }

    private fun activeGrantResponse(reused: Boolean): JSONObject {
        return status()
            .put("ok", true)
            .put("code", "android_user_authenticated")
            .put("authenticated", true)
            .put("systemCredentialPromptReused", reused)
            .put("authorizationGrantReused", reused)
            .put("authorizationRequired", true)
            .put("authorizationScope", AUTHORIZATION_SCOPE)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) {
            return false
        }
        val latch = synchronized(lock) {
            if (promptKind != PROMPT_KIND_DEVICE_CREDENTIAL) {
                null
            } else {
                pendingLatch
            }
        } ?: return true
        completePrompt(
            latch = latch,
            authenticated = resultCode == Activity.RESULT_OK,
            resultCode = resultCode,
            errorClass = ""
        )
        return true
    }

    fun deviceCredentialIsConfigured(): Boolean {
        return try {
            val keyguard = activity.getSystemService(KeyguardManager::class.java)
            keyguard?.isDeviceSecure == true
        } catch (_: Exception) {
            false
        }
    }

    private fun authorizationGrantIsActiveLocked(now: Long): Boolean {
        if (authorizationGrantExpiresAtElapsedRealtime <= now) {
            authorizationGrantExpiresAtElapsedRealtime = 0L
            return false
        }
        return true
    }

    private fun authorizationGrantRemainingSecondsLocked(now: Long): Long {
        if (!authorizationGrantIsActiveLocked(now)) {
            return 0L
        }
        return ((authorizationGrantExpiresAtElapsedRealtime - now) + 999L) / 1000L
    }

    private fun clearAuthorizationGrant() {
        synchronized(lock) {
            authorizationGrantExpiresAtElapsedRealtime = 0L
        }
    }

    private fun unavailableStatus(
        code: String,
        userActionRequired: String,
        includePromptStatus: Boolean = false
    ): JSONObject {
        val value = JSONObject()
            .put("ok", false)
            .put("code", code)
            .put("platform", "android")
            .put("physicalUserPresenceRequired", true)
            .put("systemAuthenticationOnly", true)
            .put("appLockScreenCredentialCollection", false)
            .put("systemCredentialPromptAvailable", false)
            .put("systemCredentialPromptStarted", false)
            .put("systemCredentialPromptCompleted", false)
            .put("systemCredentialPromptResultCodePresent", false)
            .put("systemCredentialPromptResultCode", 0)
            .put("systemCredentialPromptResult", "system_prompt_unavailable")
            .put("userActionRequired", userActionRequired)
            .put("credentialEntrySurface", "none")
            .put("authenticationPromptKind", PROMPT_KIND_NONE)
            .put("strongBiometricOrDeviceCredentialPromptUsed", false)
            .put("appCredentialPromptUsed", false)
            .put("appPasswordPromptUsed", false)
            .put("systemCredentialPromptReused", false)
            .put("systemCredentialPromptReusedFromPendingRequest", false)
            .put("authorizationScope", AUTHORIZATION_SCOPE)
            .put("authorizationGrantActive", false)
            .put("authorizationGrantRemainingSeconds", 0)
            .put("authorizationGrantPersisted", false)
            .put("authorizationGrantExtendedByDispatch", false)
            .put("keyMaterialExported", false)
            .put("bodyRedacted", true)
        if (includePromptStatus) {
            value
                .put("promptStarted", false)
                .put("authenticated", false)
                .put("pending", false)
                .put("androidKeyStoreUserAuthenticationWindowSeconds", USER_AUTHENTICATION_VALIDITY_SECONDS)
        }
        return value
    }

    private fun writeStatusFile(value: JSONObject) {
        try {
            val output = File(
                activity.getExternalFilesDir(null),
                "secure-mesh/adb-user-auth-status.json"
            )
            output.parentFile?.mkdirs()
            output.writeText(value.toString(2), Charsets.UTF_8)
        } catch (_: Exception) {
            Log.w(TAG, "failed to write adb user authentication status file")
        }
    }

    private data class AuthenticationSnapshot(
        val promptStarted: Boolean,
        val promptKind: String,
        val result: Boolean?,
        val resultCode: Int?,
        val errorClass: String,
        val pending: Boolean,
        val grantActive: Boolean,
        val grantRemainingSeconds: Long,
        val biometricCompatibilityFallbackSelected: Boolean
    )

    companion object {
        const val USER_AUTHENTICATION_VALIDITY_SECONDS = 300
        private const val USER_AUTHENTICATION_VALIDITY_MILLIS =
            USER_AUTHENTICATION_VALIDITY_SECONDS * 1000L
        private const val REQUEST_CODE = 49170
        private const val USER_AUTHENTICATION_TIMEOUT_SECONDS = 240L
        private const val USER_AUTHENTICATION_MAX_TIMEOUT_SECONDS = 300L
        private const val AUTHORIZATION_SCOPE = "secure_mesh_keys_and_credentials"
        private const val PROMPT_KIND_NONE = "none"
        private const val PROMPT_KIND_DEVICE_CREDENTIAL = "device_credential"
        private const val PROMPT_KIND_BIOMETRIC_OR_DEVICE_CREDENTIAL =
            "strong_biometric_or_device_credential"
        private const val TAG = "LicoSecureMeshAdb"

        private val ALLOWED_AUTHENTICATORS: Int
            get() = BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        private val BIOMETRIC_COMPATIBILITY_FAILURE_CODES =
            setOf(1, 5, 7, 9, 11, 12, 14, 15)
    }
}
