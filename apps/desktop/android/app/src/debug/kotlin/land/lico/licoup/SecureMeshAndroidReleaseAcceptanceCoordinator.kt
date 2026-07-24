package land.lico.licoup

import android.app.AlertDialog
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.AtomicFile
import android.util.Log
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import org.json.JSONObject

internal class SecureMeshAndroidReleaseAcceptanceCoordinator(
    private val activity: FlutterActivity,
    private val commandRouter: SecureMeshAndroidCommandRouter,
    private val secretStore: SecureMeshAndroidSecretStore,
    private val authenticator: SecureMeshAndroidUserAuthenticator,
    private val runtimeStatusStore: SecureMeshAndroidRuntimeStatusStore,
) {
    private val dispatchLock = Any()
    private val promptLock = Any()
    private var pendingPromptKey = ""
    private var pendingIntent: Intent? = null
    private var currentDigests = SecureMeshAndroidDiagnosticBindings()

    fun onCreate() {
        val acceptanceIntent = pendingIntent ?: consumeIngress()
        pendingIntent = null
        processIntent(acceptanceIntent)
    }

    fun onFlutterEngineConfigured() {
        commandRouter.pruneDiagnostics()
        commandRouter.writeRuntimeStatus(currentDigests)
        if (pendingIntent == null) pendingIntent = consumeIngress()
    }

    fun onNewIntent() {
        processIntent(consumeIngress())
    }

    fun digests(): SecureMeshAndroidDiagnosticBindings = currentDigests

    private fun processIntent(intent: Intent?) {
        consumeClosureChallenge(intent)
        maybeRequestAuthorization(intent)
        handleNativeAction(intent)
        commandRouter.writeRuntimeStatus(currentDigests)
    }

    private fun consumeIngress(): Intent? = ReleaseAcceptanceIngress
        .consume(SystemClock.elapsedRealtime())
        ?.toInternalIntent(activity)

    private fun handleNativeAction(intent: Intent?) {
        val sourceIntent = intent ?: return
        val nativeAction = sourceIntent
            .getStringExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_EXTRA)
            ?: return
        val closureChallenge = sourceIntent
            .getStringExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA)
            .orEmpty()
        val invocationNonce = sourceIntent
            .getStringExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA)
            .orEmpty()
        val requestNonce = sourceIntent
            .getStringExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_NONCE_EXTRA)
            .orEmpty()
        val requestSequence = sourceIntent.getLongExtra(
            ReleaseAcceptanceIngress.RELEASE_REQUEST_SEQUENCE_EXTRA,
            0L,
        )
        val decodedParams = ReleaseAcceptanceDebugCodec.decodeParams(
            sourceIntent
                .getStringExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_PARAMS_EXTRA)
                .orEmpty(),
        )
        val request = ReleaseAcceptanceRequest(
            action = nativeAction,
            closureChallenge = closureChallenge,
            invocationNonce = invocationNonce,
            requestNonce = requestNonce,
            sequence = requestSequence,
            paramsByteCount = decodedParams.byteCount,
            paramsJsonValid = decodedParams.valid,
        )
        val initialBinding = ReleaseAcceptanceChannel.bindingFor(request)
        clearIntentExtras(sourceIntent)
        Thread {
            synchronized(dispatchLock) {
                try {
                    when (
                        val decision = ReleaseAcceptanceChannel.evaluate(
                            request,
                            loadApproval(),
                            System.currentTimeMillis(),
                        )
                    ) {
                        is ReleaseAcceptanceDecision.Rejected -> writeResult(
                            failure(decision.binding, decision.code),
                        )
                        is ReleaseAcceptanceDecision.AuthorizationRequired -> {
                            writeResult(
                                failure(
                                    decision.binding,
                                    "authorization_required",
                                    decision.reason,
                                ).put(
                                    "userActionRequired",
                                    "approve_local_release_acceptance_in_lico_up",
                                ),
                            )
                            requestAuthorization(
                                closureChallenge,
                                invocationNonce,
                                request,
                            )
                        }
                        is ReleaseAcceptanceDecision.Authorized -> {
                            persistApproval(decision.advancedApproval)
                            val params = decodedParams.value
                                ?: throw IllegalArgumentException(
                                    "validated release acceptance params are missing",
                                )
                            val response = JSONObject(
                                commandRouter.run(
                                    JSONObject()
                                        .put("action", nativeAction)
                                        .put("params", params)
                                        .toString(),
                                ),
                            )
                            val sanitized = ReleaseAcceptanceDebugCodec
                                .sanitize(response) as JSONObject
                            val boundResult = addBinding(sanitized, decision.binding)
                            val bytes = boundResult.toString().toByteArray(Charsets.UTF_8)
                            writeResult(
                                if (
                                    bytes.size <=
                                    ReleaseAcceptanceDebugContract.MAX_RESULT_BYTES
                                ) {
                                    boundResult
                                } else {
                                    failure(
                                        decision.binding,
                                        "native_action_result_too_large",
                                    )
                                },
                            )
                        }
                    }
                } catch (error: Exception) {
                    writeResult(
                        failure(
                            initialBinding,
                            "secure_mesh_native_action_failed",
                        ).put("errorClass", error.javaClass.simpleName),
                    )
                }
            }
        }.start()
    }

    private fun maybeRequestAuthorization(sourceIntent: Intent?) {
        val challenge = sourceIntent
            ?.getStringExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA)
            .orEmpty()
        val invocationNonce = sourceIntent
            ?.getStringExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA)
            .orEmpty()
        val closureDigest = ReleaseClosureBinding.digest(challenge)
        val invocationDigest = ReleaseClosureBinding.digest(invocationNonce)
        if (closureDigest.isEmpty() || invocationDigest.isEmpty()) return
        val now = System.currentTimeMillis()
        val maximumExpiry = if (
            now > 0L &&
            now <= Long.MAX_VALUE - ReleaseAcceptanceChannel.APPROVAL_VALIDITY_MILLIS
        ) now + ReleaseAcceptanceChannel.APPROVAL_VALIDITY_MILLIS else 0L
        val approval = synchronized(dispatchLock) { loadApproval() }
        if (
            approval?.isStructurallyValid() == true &&
            approval.closureChallengeDigest == closureDigest &&
            approval.invocationNonceDigest == invocationDigest &&
            approval.expiresAtEpochMillis > now &&
            approval.expiresAtEpochMillis <= maximumExpiry
        ) return
        requestAuthorization(challenge, invocationNonce, null)
    }

    private fun requestAuthorization(
        closureChallenge: String,
        invocationNonce: String,
        request: ReleaseAcceptanceRequest?,
    ) {
        val closureDigest = ReleaseClosureBinding.digest(closureChallenge)
        val invocationDigest = ReleaseClosureBinding.digest(invocationNonce)
        if (closureDigest.isEmpty() || invocationDigest.isEmpty()) return
        val promptKey = "$closureDigest:$invocationDigest"
        synchronized(promptLock) {
            if (pendingPromptKey.isNotEmpty()) return
            pendingPromptKey = promptKey
        }
        activity.runOnUiThread {
            if (
                activity.isFinishing ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 &&
                    activity.isDestroyed)
            ) {
                clearPendingPrompt(promptKey)
                return@runOnUiThread
            }
            AlertDialog.Builder(activity)
                .setTitle("Allow local release acceptance?")
                .setMessage(
                    "A locally connected verifier requested access to the release-safe " +
                        "acceptance channel. Approval is bound to this invocation, expires " +
                        "automatically, and never exposes keys or message content.\n\n" +
                        "Requested operation: " +
                        (request?.action ?: "release verification session"),
                )
                .setPositiveButton("Allow") { _, _ ->
                    completeAuthorization(
                        promptKey,
                        closureChallenge,
                        invocationNonce,
                        request,
                    )
                }
                .setNegativeButton("Deny") { _, _ ->
                    denyAuthorization(promptKey, request, "user_denied")
                }
                .setOnCancelListener {
                    denyAuthorization(promptKey, request, "user_cancelled")
                }
                .show()
        }
    }

    private fun completeAuthorization(
        promptKey: String,
        closureChallenge: String,
        invocationNonce: String,
        request: ReleaseAcceptanceRequest?,
    ) {
        Thread {
            var approved = false
            try {
                val authentication = authenticator.authorizeSensitiveAction(
                    ReleaseAcceptanceDebugContract.AUTHORIZATION_ACTION,
                    forcePrompt = true,
                )
                val userPresenceApproved =
                    authentication.optBoolean("ok", false) &&
                        authentication.optBoolean("authenticated", false)
                if (userPresenceApproved) {
                    synchronized(dispatchLock) {
                        val now = System.currentTimeMillis()
                        val existing = loadApproval()
                        val next = if (request == null) {
                            ReleaseAcceptanceChannel.renewedApprovalForInvocation(
                                closureChallenge,
                                invocationNonce,
                                existing,
                                now,
                            )
                        } else {
                            ReleaseAcceptanceChannel.renewedApproval(
                                request,
                                existing,
                                now,
                            )
                        }
                        if (next != null) {
                            persistApproval(next)
                            approved = true
                        }
                    }
                }
            } catch (_: Exception) {
                approved = false
            } finally {
                clearPendingPrompt(promptKey)
                if (request != null) {
                    writeResult(
                        failure(
                            ReleaseAcceptanceChannel.bindingFor(request),
                            if (approved) {
                                "authorization_approved"
                            } else {
                                "authorization_denied"
                            },
                            if (approved) "user_approved"
                            else "system_authentication_failed",
                        ),
                    )
                }
                activity.runOnUiThread {
                    Toast.makeText(
                        activity,
                        if (approved) {
                            "Local release acceptance approved. Rerun the verifier."
                        } else {
                            "Local release acceptance was not approved."
                        },
                        Toast.LENGTH_LONG,
                    ).show()
                }
            }
        }.start()
    }

    private fun denyAuthorization(
        promptKey: String,
        request: ReleaseAcceptanceRequest?,
        reason: String,
    ) {
        clearPendingPrompt(promptKey)
        if (request == null) return
        Thread {
            writeResult(
                failure(
                    ReleaseAcceptanceChannel.bindingFor(request),
                    "authorization_denied",
                    reason,
                ),
            )
        }.start()
    }

    private fun clearPendingPrompt(promptKey: String) {
        synchronized(promptLock) {
            if (pendingPromptKey == promptKey) pendingPromptKey = ""
        }
    }

    private fun loadApproval(): ReleaseAcceptanceApproval? {
        val file = approvalFile()
        if (
            !file.isFile ||
            file.length() !in 1L..ReleaseAcceptanceDebugContract.MAX_APPROVAL_BYTES
        ) return null
        return try {
            val text = AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use {
                it.readText()
            }
            val value = JSONObject(text)
            val keys = buildSet {
                val iterator = value.keys()
                while (iterator.hasNext()) add(iterator.next())
            }
            if (keys != ReleaseAcceptanceDebugContract.approvalKeys) {
                return null
            }
            if (value.optInt("schemaVersion", 0) != ReleaseAcceptanceChannel.SCHEMA_VERSION) {
                return null
            }
            ReleaseAcceptanceApproval(
                closureChallengeDigest = value.optString("closureChallengeDigest", ""),
                invocationNonceDigest = value.optString("invocationNonceDigest", ""),
                lastRequestNonceDigest = value.optString("lastRequestNonceDigest", ""),
                expiresAtEpochMillis = value.optLong("expiresAtEpochMillis", 0L),
                lastSequence = value.optLong("lastSequence", -1L),
            ).takeIf(ReleaseAcceptanceApproval::isStructurallyValid)
        } catch (_: Exception) {
            null
        }
    }

    private fun persistApproval(approval: ReleaseAcceptanceApproval) {
        check(approval.isStructurallyValid()) {
            "release acceptance approval is invalid"
        }
        val value = JSONObject()
            .put("schemaVersion", ReleaseAcceptanceChannel.SCHEMA_VERSION)
            .put("closureChallengeDigest", approval.closureChallengeDigest)
            .put("invocationNonceDigest", approval.invocationNonceDigest)
            .put("lastRequestNonceDigest", approval.lastRequestNonceDigest)
            .put("expiresAtEpochMillis", approval.expiresAtEpochMillis)
            .put("lastSequence", approval.lastSequence)
        runtimeStatusStore.writeAtomic(approvalFile(), value.toString())
    }

    private fun approvalFile(): File = File(
        activity.filesDir,
        ReleaseAcceptanceDebugContract.APPROVAL_RELATIVE_PATH,
    )

    private fun consumeClosureChallenge(sourceIntent: Intent?) {
        currentDigests = SecureMeshAndroidDiagnosticBindings(
            closureChallenge = ReleaseClosureBinding.digest(
                sourceIntent
                    ?.getStringExtra(
                        ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA,
                    )
                    .orEmpty(),
            ),
            invocationNonce = ReleaseClosureBinding.digest(
                sourceIntent
                    ?.getStringExtra(
                        ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA,
                    )
                    .orEmpty(),
            ),
        )
    }

    private fun clearIntentExtras(intent: Intent) {
        intent.removeExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_PARAMS_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_NONCE_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_SEQUENCE_EXTRA)
    }

    private fun failure(
        binding: ReleaseAcceptanceBinding,
        code: String,
        authorizationReason: String = "",
    ): JSONObject {
        val value = JSONObject()
            .put("ok", false)
            .put("code", code)
            .put("status", code)
        if (authorizationReason.isNotEmpty()) {
            value.put("authorizationReason", authorizationReason)
        }
        return addBinding(value, binding)
    }

    private fun addBinding(
        value: JSONObject,
        binding: ReleaseAcceptanceBinding,
    ): JSONObject = value
        .put(
            "releaseAcceptanceChannel",
            ReleaseAcceptanceDebugContract.CHANNEL_VERSION,
        )
        .put("closureChallengeDigest", binding.closureChallengeDigest)
        .put("invocationNonceDigest", binding.invocationNonceDigest)
        .put("requestNonceDigest", binding.requestNonceDigest)
        .put("actionDigest", binding.actionDigest)
        .put("sequence", binding.sequence)
        .put("bodyRedacted", true)

    private fun writeResult(value: JSONObject) {
        try {
            val externalRoot = activity.getExternalFilesDir(null) ?: return
            runtimeStatusStore.writeAtomic(
                File(externalRoot, "secure-mesh/adb-last-result.json"),
                value.toString(2),
            )
        } catch (_: Exception) {
            Log.w(
                ReleaseAcceptanceDebugContract.LOG_TAG,
                "failed to write redacted native-action result",
            )
        }
    }
}
