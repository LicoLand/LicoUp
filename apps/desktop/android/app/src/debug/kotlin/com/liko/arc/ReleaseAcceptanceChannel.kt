package com.liko.arc

import java.security.MessageDigest

internal data class ReleaseAcceptanceRequest(
    val action: String,
    val closureChallenge: String,
    val invocationNonce: String,
    val requestNonce: String,
    val sequence: Long,
    val paramsByteCount: Int,
    val paramsJsonValid: Boolean,
)

internal data class ReleaseAcceptanceBinding(
    val closureChallengeDigest: String,
    val invocationNonceDigest: String,
    val requestNonceDigest: String,
    val actionDigest: String,
    val sequence: Long,
)

internal data class ReleaseAcceptanceApproval(
    val closureChallengeDigest: String,
    val invocationNonceDigest: String,
    val lastRequestNonceDigest: String,
    val expiresAtEpochMillis: Long,
    val lastSequence: Long,
) {
    fun isStructurallyValid(): Boolean {
        return ReleaseAcceptanceChannel.isDigest(closureChallengeDigest) &&
            ReleaseAcceptanceChannel.isDigest(invocationNonceDigest) &&
            lastSequence in 0L until Long.MAX_VALUE &&
            expiresAtEpochMillis > 0L &&
            if (lastSequence == 0L) {
                lastRequestNonceDigest.isEmpty()
            } else {
                ReleaseAcceptanceChannel.isDigest(lastRequestNonceDigest)
            }
    }
}

internal sealed interface ReleaseAcceptanceDecision {
    val binding: ReleaseAcceptanceBinding

    data class Authorized(
        override val binding: ReleaseAcceptanceBinding,
        val advancedApproval: ReleaseAcceptanceApproval,
    ) : ReleaseAcceptanceDecision

    data class AuthorizationRequired(
        override val binding: ReleaseAcceptanceBinding,
        val reason: String,
    ) : ReleaseAcceptanceDecision

    data class Rejected(
        override val binding: ReleaseAcceptanceBinding,
        val code: String,
    ) : ReleaseAcceptanceDecision
}

internal object ReleaseAcceptanceChannel {
    const val SCHEMA_VERSION = 1
    const val MAX_PARAMS_JSON_BYTES = 512 * 1024
    const val APPROVAL_VALIDITY_MILLIS = 30L * 60L * 1000L

    private val digestPattern = Regex("^sha256:[a-f0-9]{64}$")
    private val allowedActions = setOf(
        "mobile.relay.commands.createSecure",
        "mobile.relay.commands.resultReplayProof",
        "mobile.relay.commands.resultSecure",
        "mobile.relay.e2ee.status",
        "mobile.relay.pairing.claim",
        "mobile.relay.pairing.status",
        "secure_mesh.android.status",
        "secure_mesh.android.userAuthentication.request",
        "secure_mesh.android.userAuthentication.status",
        "secure_mesh.deviceTrust.evaluate",
        "secure_mesh.deviceTrust.recover",
        "secure_mesh.deviceTrust.revoke",
        "secure_mesh.deviceTrust.rotate",
        "secure_mesh.deviceTrust.verifyQr",
        "secure_mesh.deviceTrust.verifySas",
        "secure_mesh.file.handoffProof",
        "secure_mesh.file.receiveConfirmation",
        "secure_mesh.file.receiveDestination",
        "secure_mesh.file.route",
        "secure_mesh.lifecycle.serviceAction",
        "secure_mesh.kt.configureAuthority",
        "secure_mesh.kt.gossip",
        "secure_mesh.kt.provision",
        "secure_mesh.kt.publicationRequest",
        "secure_mesh.kt.revocationRequest",
        "secure_mesh.kt.selfMonitor",
        "secure_mesh.kt.status",
        "secure_mesh.mls.commit.process",
        "secure_mesh.mls.group.create",
        "secure_mesh.mls.group.join",
        "secure_mesh.mls.keyPackage.create",
        "secure_mesh.mls.member.add",
        "secure_mesh.mls.member.remove",
        "secure_mesh.mls.participant.ensure",
        "secure_mesh.mls.payload.open",
        "secure_mesh.mls.payload.seal",
        "secure_mesh.mls.status",
    )

    fun bindingFor(request: ReleaseAcceptanceRequest): ReleaseAcceptanceBinding {
        return ReleaseAcceptanceBinding(
            closureChallengeDigest = ReleaseClosureBinding.digest(request.closureChallenge),
            invocationNonceDigest = ReleaseClosureBinding.digest(request.invocationNonce),
            requestNonceDigest = ReleaseClosureBinding.digest(request.requestNonce),
            actionDigest = digestAction(request.action),
            sequence = request.sequence,
        )
    }

    fun evaluate(
        request: ReleaseAcceptanceRequest,
        approval: ReleaseAcceptanceApproval?,
        nowEpochMillis: Long,
    ): ReleaseAcceptanceDecision {
        val binding = bindingFor(request)
        validateRequestShape(request, binding)?.let { code ->
            return ReleaseAcceptanceDecision.Rejected(binding, code)
        }
        val current = approval?.takeIf(ReleaseAcceptanceApproval::isStructurallyValid)
        if (current == null) {
            return if (request.sequence == 1L) {
                ReleaseAcceptanceDecision.AuthorizationRequired(binding, "approval_missing")
            } else {
                ReleaseAcceptanceDecision.Rejected(binding, "request_sequence_out_of_order")
            }
        }
        val maximumExpiry = maximumApprovalExpiry(nowEpochMillis)
            ?: return ReleaseAcceptanceDecision.Rejected(
                binding,
                "approval_clock_invalid",
            )
        if (current.expiresAtEpochMillis > maximumExpiry) {
            return ReleaseAcceptanceDecision.Rejected(binding, "approval_expiry_invalid")
        }
        if (
            current.closureChallengeDigest != binding.closureChallengeDigest ||
            current.invocationNonceDigest != binding.invocationNonceDigest
        ) {
            return if (request.sequence == 1L) {
                ReleaseAcceptanceDecision.AuthorizationRequired(binding, "invocation_changed")
            } else {
                ReleaseAcceptanceDecision.Rejected(binding, "release_binding_mismatch")
            }
        }
        val expectedSequence = current.lastSequence + 1L
        if (request.sequence <= current.lastSequence) {
            return ReleaseAcceptanceDecision.Rejected(binding, "request_replayed")
        }
        if (request.sequence != expectedSequence) {
            return ReleaseAcceptanceDecision.Rejected(binding, "request_sequence_out_of_order")
        }
        if (
            current.lastRequestNonceDigest.isNotEmpty() &&
            current.lastRequestNonceDigest == binding.requestNonceDigest
        ) {
            return ReleaseAcceptanceDecision.Rejected(binding, "request_nonce_replayed")
        }
        if (current.expiresAtEpochMillis <= nowEpochMillis) {
            return ReleaseAcceptanceDecision.AuthorizationRequired(binding, "approval_expired")
        }
        return ReleaseAcceptanceDecision.Authorized(
            binding = binding,
            advancedApproval = current.copy(
                lastRequestNonceDigest = binding.requestNonceDigest,
                lastSequence = request.sequence,
            ),
        )
    }

    fun approvalForInvocation(
        closureChallenge: String,
        invocationNonce: String,
        nowEpochMillis: Long,
    ): ReleaseAcceptanceApproval? {
        val closureDigest = ReleaseClosureBinding.digest(closureChallenge)
        val invocationDigest = ReleaseClosureBinding.digest(invocationNonce)
        val expiresAtEpochMillis = maximumApprovalExpiry(nowEpochMillis)
        if (
            closureDigest.isEmpty() ||
            invocationDigest.isEmpty() ||
            expiresAtEpochMillis == null
        ) {
            return null
        }
        return ReleaseAcceptanceApproval(
            closureChallengeDigest = closureDigest,
            invocationNonceDigest = invocationDigest,
            lastRequestNonceDigest = "",
            expiresAtEpochMillis = expiresAtEpochMillis,
            lastSequence = 0L,
        )
    }

    fun renewedApprovalForInvocation(
        closureChallenge: String,
        invocationNonce: String,
        previous: ReleaseAcceptanceApproval?,
        nowEpochMillis: Long,
    ): ReleaseAcceptanceApproval? {
        val fresh = approvalForInvocation(
            closureChallenge,
            invocationNonce,
            nowEpochMillis,
        ) ?: return null
        val current = previous?.takeIf(ReleaseAcceptanceApproval::isStructurallyValid)
        return if (
            current?.closureChallengeDigest == fresh.closureChallengeDigest &&
            current.invocationNonceDigest == fresh.invocationNonceDigest
        ) {
            current.copy(expiresAtEpochMillis = fresh.expiresAtEpochMillis)
        } else {
            fresh
        }
    }

    fun renewedApproval(
        request: ReleaseAcceptanceRequest,
        previous: ReleaseAcceptanceApproval?,
        nowEpochMillis: Long,
    ): ReleaseAcceptanceApproval? {
        val binding = bindingFor(request)
        val expiresAtEpochMillis = maximumApprovalExpiry(nowEpochMillis)
        if (validateRequestShape(request, binding) != null || expiresAtEpochMillis == null) {
            return null
        }
        val current = previous?.takeIf(ReleaseAcceptanceApproval::isStructurallyValid)
        val sameInvocation = current != null &&
            current.closureChallengeDigest == binding.closureChallengeDigest &&
            current.invocationNonceDigest == binding.invocationNonceDigest
        val priorSequence = if (sameInvocation) current.lastSequence else 0L
        if (request.sequence != priorSequence + 1L) {
            return null
        }
        return ReleaseAcceptanceApproval(
            closureChallengeDigest = binding.closureChallengeDigest,
            invocationNonceDigest = binding.invocationNonceDigest,
            lastRequestNonceDigest = current
                ?.takeIf { sameInvocation }
                ?.lastRequestNonceDigest
                .orEmpty(),
            expiresAtEpochMillis = expiresAtEpochMillis,
            lastSequence = priorSequence,
        )
    }

    fun isDigest(value: String): Boolean = digestPattern.matches(value)

    private fun validateRequestShape(
        request: ReleaseAcceptanceRequest,
        binding: ReleaseAcceptanceBinding,
    ): String? {
        return when {
            binding.closureChallengeDigest.isEmpty() -> "closure_challenge_invalid"
            binding.invocationNonceDigest.isEmpty() -> "invocation_nonce_invalid"
            binding.requestNonceDigest.isEmpty() -> "request_nonce_invalid"
            request.sequence <= 0L || request.sequence == Long.MAX_VALUE ->
                "request_sequence_invalid"
            request.action !in allowedActions -> "native_action_not_allowed"
            request.paramsByteCount < 2 -> "native_action_params_missing"
            request.paramsByteCount > MAX_PARAMS_JSON_BYTES -> "native_action_params_too_large"
            !request.paramsJsonValid -> "native_action_params_invalid"
            else -> null
        }
    }

    private fun digestAction(action: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(action.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        return "sha256:$digest"
    }

    private fun maximumApprovalExpiry(nowEpochMillis: Long): Long? {
        if (
            nowEpochMillis <= 0L ||
            nowEpochMillis > Long.MAX_VALUE - APPROVAL_VALIDITY_MILLIS
        ) {
            return null
        }
        return nowEpochMillis + APPROVAL_VALIDITY_MILLIS
    }
}
