package com.liko.arc

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

internal data class ReleaseAcceptanceIngressRequest(
    val action: String,
    val paramsBase64Url: String,
    val closureChallenge: String,
    val invocationNonce: String,
    val requestNonce: String,
    val sequence: Long,
) {
    fun toInternalIntent(context: Context): Intent {
        val requestedAction = action
        return Intent(context, MainActivity::class.java).apply {
            if (requestedAction.isNotEmpty()) {
                putExtra(
                    ReleaseAcceptanceIngress.NATIVE_ACTION_EXTRA,
                    requestedAction,
                )
                putExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_PARAMS_EXTRA, paramsBase64Url)
                putExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_NONCE_EXTRA, requestNonce)
                putExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_SEQUENCE_EXTRA, sequence)
            }
            putExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA, closureChallenge)
            putExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA, invocationNonce)
        }
    }
}

internal object ReleaseAcceptanceIngress {
    const val ACTION = "com.liko.arc.RELEASE_ACCEPTANCE"
    const val RECEIVER_CLASS = "com.liko.arc.ReleaseAcceptanceReceiver"
    const val RELEASE_CLOSURE_CHALLENGE_EXTRA =
        "com.liko.arc.extra.RELEASE_CLOSURE_CHALLENGE"
    const val RELEASE_INVOCATION_NONCE_EXTRA =
        "com.liko.arc.extra.RELEASE_INVOCATION_NONCE"
    const val RELEASE_REQUEST_NONCE_EXTRA =
        "com.liko.arc.extra.RELEASE_REQUEST_NONCE"
    const val RELEASE_REQUEST_SEQUENCE_EXTRA =
        "com.liko.arc.extra.RELEASE_REQUEST_SEQUENCE"
    const val NATIVE_ACTION_EXTRA = "lico_native_action"
    const val NATIVE_ACTION_PARAMS_EXTRA = "lico_params_b64"

    private const val MAX_ACTION_BYTES = 128
    private const val MAX_ENCODED_PARAMS_BYTES =
        ((ReleaseAcceptanceChannel.MAX_PARAMS_JSON_BYTES + 2) / 3) * 4
    private const val PENDING_TTL_MILLIS = 30_000L
    private val encodedParamsPattern = Regex("^[A-Za-z0-9_-]+$")
    private var pending: PendingRequest? = null

    private data class PendingRequest(
        val request: ReleaseAcceptanceIngressRequest,
        val stagedAtElapsedMillis: Long,
    )

    @Synchronized
    fun stage(request: ReleaseAcceptanceIngressRequest, nowElapsedMillis: Long): Boolean {
        if (!isValid(request) || nowElapsedMillis < 0L) return false
        val current = pending
        if (
            current != null &&
            nowElapsedMillis >= current.stagedAtElapsedMillis &&
            nowElapsedMillis - current.stagedAtElapsedMillis <= PENDING_TTL_MILLIS
        ) {
            return false
        }
        pending = PendingRequest(request, nowElapsedMillis)
        return true
    }

    @Synchronized
    fun consume(nowElapsedMillis: Long): ReleaseAcceptanceIngressRequest? {
        val current = pending ?: return null
        pending = null
        if (
            nowElapsedMillis < current.stagedAtElapsedMillis ||
            nowElapsedMillis - current.stagedAtElapsedMillis > PENDING_TTL_MILLIS
        ) {
            return null
        }
        return current.request
    }

    @Synchronized
    fun clearForTest() {
        pending = null
    }

    private fun isValid(request: ReleaseAcceptanceIngressRequest): Boolean {
        if (
            ReleaseClosureBinding.digest(request.closureChallenge).isEmpty() ||
            ReleaseClosureBinding.digest(request.invocationNonce).isEmpty()
        ) {
            return false
        }
        if (request.action.isEmpty()) {
            return request.paramsBase64Url.isEmpty() &&
                request.requestNonce.isEmpty() &&
                request.sequence == 0L
        }
        return request.action.toByteArray(Charsets.UTF_8).size <= MAX_ACTION_BYTES &&
            request.paramsBase64Url.length in 1..MAX_ENCODED_PARAMS_BYTES &&
            encodedParamsPattern.matches(request.paramsBase64Url) &&
            ReleaseClosureBinding.digest(request.requestNonce).isNotEmpty() &&
            request.sequence in 1L until Long.MAX_VALUE
    }
}

class ReleaseAcceptanceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ReleaseAcceptanceIngress.ACTION) {
            setResultCode(Activity.RESULT_CANCELED)
            setResultData("release_acceptance_action_rejected")
            return
        }
        val request = ReleaseAcceptanceIngressRequest(
            action = intent.getStringExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_EXTRA).orEmpty(),
            paramsBase64Url = intent
                .getStringExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_PARAMS_EXTRA)
                .orEmpty(),
            closureChallenge = intent
                .getStringExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA)
                .orEmpty(),
            invocationNonce = intent
                .getStringExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA)
                .orEmpty(),
            requestNonce = intent
                .getStringExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_NONCE_EXTRA)
                .orEmpty(),
            sequence = intent.getLongExtra(
                ReleaseAcceptanceIngress.RELEASE_REQUEST_SEQUENCE_EXTRA,
                0L,
            ),
        )
        val staged = ReleaseAcceptanceIngress.stage(request, SystemClock.elapsedRealtime())
        setResultCode(if (staged) Activity.RESULT_OK else Activity.RESULT_CANCELED)
        setResultData(if (staged) "release_acceptance_staged" else "release_acceptance_rejected")
    }
}
