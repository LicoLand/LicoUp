package land.lico.licoup

import java.util.Base64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseAcceptanceIngressTest {
    @After
    fun clearPendingRequest() {
        ReleaseAcceptanceIngress.clearForTest()
    }

    @Test
    fun authorizationOnlyIngressIsSingleUseAndMemoryOnly() {
        val request = authorizationRequest()
        assertTrue(ReleaseAcceptanceIngress.stage(request, 100L))
        assertEquals(request, ReleaseAcceptanceIngress.consume(101L))
        assertNull(ReleaseAcceptanceIngress.consume(102L))
    }

    @Test
    fun nativeActionIngressRequiresAllCanonicalBindings() {
        val request = actionRequest()
        assertTrue(ReleaseAcceptanceIngress.stage(request, 200L))
        assertEquals(request, ReleaseAcceptanceIngress.consume(201L))

        assertFalse(
            ReleaseAcceptanceIngress.stage(
                request.copy(closureChallenge = canonical(31, 1)),
                202L,
            ),
        )
        assertFalse(
            ReleaseAcceptanceIngress.stage(
                request.copy(requestNonce = canonical(31, 3)),
                202L,
            ),
        )
        assertFalse(ReleaseAcceptanceIngress.stage(request.copy(sequence = 0L), 202L))
        assertFalse(
            ReleaseAcceptanceIngress.stage(
                request.copy(paramsBase64Url = "not+canonical"),
                202L,
            ),
        )
    }

    @Test
    fun pendingIngressCannotBeOverwrittenAndExpiresFailClosed() {
        val first = actionRequest()
        val second = first.copy(requestNonce = canonical(32, 9), sequence = 2L)
        assertTrue(ReleaseAcceptanceIngress.stage(first, 300L))
        assertFalse(ReleaseAcceptanceIngress.stage(second, 301L))
        assertNull(ReleaseAcceptanceIngress.consume(30_301L))
        assertTrue(ReleaseAcceptanceIngress.stage(second, 30_302L))
        assertEquals(second, ReleaseAcceptanceIngress.consume(30_303L))
    }

    @Test
    fun elapsedClockRollbackDropsPendingIngress() {
        assertTrue(ReleaseAcceptanceIngress.stage(actionRequest(), 500L))
        assertNull(ReleaseAcceptanceIngress.consume(499L))
    }

    private fun authorizationRequest(): ReleaseAcceptanceIngressRequest {
        return ReleaseAcceptanceIngressRequest(
            action = "",
            paramsBase64Url = "",
            closureChallenge = canonical(32, 1),
            invocationNonce = canonical(32, 2),
            requestNonce = "",
            sequence = 0L,
        )
    }

    private fun actionRequest(): ReleaseAcceptanceIngressRequest {
        return ReleaseAcceptanceIngressRequest(
            action = "secure_mesh.android.status",
            paramsBase64Url = "e30",
            closureChallenge = canonical(32, 1),
            invocationNonce = canonical(32, 2),
            requestNonce = canonical(32, 3),
            sequence = 1L,
        )
    }

    private fun canonical(size: Int, byte: Int): String {
        return Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(ByteArray(size) { byte.toByte() })
    }
}
