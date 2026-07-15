package com.liko.arc

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseAcceptanceChannelTest {
    @Test
    fun canonicalInvocationRequiresApprovalThenAdvancesExactlyOnce() {
        val request = request(sequence = 1L, requestByte = 3)
        val missing = ReleaseAcceptanceChannel.evaluate(request, null, NOW)
        assertTrue(missing is ReleaseAcceptanceDecision.AuthorizationRequired)

        val approval = ReleaseAcceptanceChannel.approvalForInvocation(
            request.closureChallenge,
            request.invocationNonce,
            NOW,
        )
        assertNotNull(approval)
        val authorized = ReleaseAcceptanceChannel.evaluate(request, approval, NOW)
        assertTrue(authorized is ReleaseAcceptanceDecision.Authorized)
        val advanced = (authorized as ReleaseAcceptanceDecision.Authorized).advancedApproval
        assertEquals(1L, advanced.lastSequence)
        assertEquals(authorized.binding.requestNonceDigest, advanced.lastRequestNonceDigest)

        val replay = ReleaseAcceptanceChannel.evaluate(request, advanced, NOW)
        assertRejected(replay, "request_replayed")
    }

    @Test
    fun missingAndMalformedBindingsFailClosed() {
        val base = request()
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(
                base.copy(closureChallenge = ""),
                null,
                NOW,
            ),
            "closure_challenge_invalid",
        )
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(
                base.copy(invocationNonce = canonical(31, 2)),
                null,
                NOW,
            ),
            "invocation_nonce_invalid",
        )
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(
                base.copy(requestNonce = canonical(33, 3)),
                null,
                NOW,
            ),
            "request_nonce_invalid",
        )
    }

    @Test
    fun unknownActionAndParameterBoundsFailClosed() {
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(
                request(action = "mobile.relay.arbitrary"),
                null,
                NOW,
            ),
            "native_action_not_allowed",
        )
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(
                request(paramsByteCount = ReleaseAcceptanceChannel.MAX_PARAMS_JSON_BYTES + 1),
                null,
                NOW,
            ),
            "native_action_params_too_large",
        )
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(
                request(paramsJsonValid = false),
                null,
                NOW,
            ),
            "native_action_params_invalid",
        )
    }

    @Test
    fun changedInvocationAndExpiredApprovalRequireFreshUserAuthorization() {
        val first = request(sequence = 1L)
        val approval = ReleaseAcceptanceChannel.approvalForInvocation(
            first.closureChallenge,
            first.invocationNonce,
            NOW,
        )!!
        val changed = first.copy(invocationNonce = canonical(32, 8))
        val changedDecision = ReleaseAcceptanceChannel.evaluate(changed, approval, NOW)
        assertTrue(changedDecision is ReleaseAcceptanceDecision.AuthorizationRequired)
        assertEquals(
            "invocation_changed",
            (changedDecision as ReleaseAcceptanceDecision.AuthorizationRequired).reason,
        )

        val expired = approval.copy(expiresAtEpochMillis = NOW - 1L)
        val expiredDecision = ReleaseAcceptanceChannel.evaluate(first, expired, NOW)
        assertTrue(expiredDecision is ReleaseAcceptanceDecision.AuthorizationRequired)
        assertEquals(
            "approval_expired",
            (expiredDecision as ReleaseAcceptanceDecision.AuthorizationRequired).reason,
        )
        val renewed = ReleaseAcceptanceChannel.renewedApproval(first, expired, NOW)
        assertNotNull(renewed)
        assertTrue(renewed!!.expiresAtEpochMillis > NOW)
        assertEquals(0L, renewed.lastSequence)
    }

    @Test
    fun outOfOrderAndRepeatedRequestNonceFailClosed() {
        val first = request(sequence = 1L, requestByte = 4)
        val initial = ReleaseAcceptanceChannel.approvalForInvocation(
            first.closureChallenge,
            first.invocationNonce,
            NOW,
        )!!
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(first.copy(sequence = 2L), initial, NOW),
            "request_sequence_out_of_order",
        )
        val firstAuthorized = ReleaseAcceptanceChannel.evaluate(first, initial, NOW)
            as ReleaseAcceptanceDecision.Authorized
        val secondWithRepeatedNonce = first.copy(sequence = 2L)
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(
                secondWithRepeatedNonce,
                firstAuthorized.advancedApproval,
                NOW,
            ),
            "request_nonce_replayed",
        )
    }

    @Test
    fun persistedApprovalShapeContainsOnlyDigestsExpiryAndSequence() {
        val request = request()
        val approval = ReleaseAcceptanceChannel.approvalForInvocation(
            request.closureChallenge,
            request.invocationNonce,
            NOW,
        )!!
        assertTrue(approval.isStructurallyValid())
        assertTrue(ReleaseAcceptanceChannel.isDigest(approval.closureChallengeDigest))
        assertTrue(ReleaseAcceptanceChannel.isDigest(approval.invocationNonceDigest))
        assertEquals("", approval.lastRequestNonceDigest)
        assertEquals(0L, approval.lastSequence)
    }

    @Test
    fun approvalWindowRejectsOverflowAndExcessFutureExpiry() {
        val request = request()
        assertEquals(
            null,
            ReleaseAcceptanceChannel.approvalForInvocation(
                request.closureChallenge,
                request.invocationNonce,
                Long.MAX_VALUE,
            ),
        )
        val approval = ReleaseAcceptanceChannel.approvalForInvocation(
            request.closureChallenge,
            request.invocationNonce,
            NOW,
        )!!
        val excessive = approval.copy(
            expiresAtEpochMillis = NOW + ReleaseAcceptanceChannel.APPROVAL_VALIDITY_MILLIS + 1L,
        )
        assertRejected(
            ReleaseAcceptanceChannel.evaluate(request, excessive, NOW),
            "approval_expiry_invalid",
        )
    }

    @Test
    fun invocationRenewalPreservesMonotonicSequenceAcrossRestart() {
        val request = request()
        val initial = ReleaseAcceptanceChannel.approvalForInvocation(
            request.closureChallenge,
            request.invocationNonce,
            NOW,
        )!!
        val advanced = (
            ReleaseAcceptanceChannel.evaluate(request, initial, NOW)
                as ReleaseAcceptanceDecision.Authorized
            ).advancedApproval
            .copy(expiresAtEpochMillis = NOW - 1L)
        val renewed = ReleaseAcceptanceChannel.renewedApprovalForInvocation(
            request.closureChallenge,
            request.invocationNonce,
            advanced,
            NOW,
        )!!
        assertEquals(1L, renewed.lastSequence)
        assertEquals(advanced.lastRequestNonceDigest, renewed.lastRequestNonceDigest)
        val second = request(sequence = 2L, requestByte = 9)
        assertTrue(
            ReleaseAcceptanceChannel.evaluate(second, renewed, NOW) is
                ReleaseAcceptanceDecision.Authorized
        )
    }

    @Test
    fun currentKtAndMlsProductActionsAreExplicitlyAllowed() {
        for (
            action in listOf(
                "secure_mesh.kt.status",
                "secure_mesh.mls.member.remove",
                "secure_mesh.mls.payload.seal",
            )
        ) {
            val request = request(action = action)
            val approval = ReleaseAcceptanceChannel.approvalForInvocation(
                request.closureChallenge,
                request.invocationNonce,
                NOW,
            )!!
            assertTrue(
                ReleaseAcceptanceChannel.evaluate(request, approval, NOW) is
                    ReleaseAcceptanceDecision.Authorized
            )
        }
    }

    private fun request(
        action: String = "secure_mesh.android.status",
        sequence: Long = 1L,
        requestByte: Int = 3,
        paramsByteCount: Int = 2,
        paramsJsonValid: Boolean = true,
    ): ReleaseAcceptanceRequest {
        return ReleaseAcceptanceRequest(
            action = action,
            closureChallenge = canonical(32, 1),
            invocationNonce = canonical(32, 2),
            requestNonce = canonical(32, requestByte),
            sequence = sequence,
            paramsByteCount = paramsByteCount,
            paramsJsonValid = paramsJsonValid,
        )
    }

    private fun canonical(size: Int, byte: Int): String {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(size) { byte.toByte() })
    }

    private fun assertRejected(decision: ReleaseAcceptanceDecision, expectedCode: String) {
        assertTrue(decision is ReleaseAcceptanceDecision.Rejected)
        assertEquals(expectedCode, (decision as ReleaseAcceptanceDecision.Rejected).code)
    }

    companion object {
        private const val NOW = 2_000_000_000_000L
    }
}
