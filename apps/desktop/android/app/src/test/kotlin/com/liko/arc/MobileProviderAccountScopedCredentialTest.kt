package com.liko.arc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileProviderAccountScopedCredentialTest {
    @Test
    fun credentialReferenceParsesOnlyTheExpectedProvider() {
        assertEquals(
            "mpa-deepseek-1",
            MobileProviderAccountIdentity.accountIdFromCredentialRef(
                "secure-ref:api-key:deepseek:mpa-deepseek-1",
                "deepseek"
            )
        )
        assertEquals(
            "desktop-relay:pair:chatgpt:a1",
            MobileProviderAccountIdentity.accountIdFromCredentialRef(
                "secure-ref:oauth:chatgpt:desktop-relay:pair:chatgpt:a1",
                "chatgpt"
            )
        )
        assertEquals(
            "",
            MobileProviderAccountIdentity.accountIdFromCredentialRef(
                "secure-ref:oauth:chatgpt:account-a",
                "deepseek"
            )
        )
    }

    @Test
    fun accountSelectionPrefersExplicitAccountAndRejectsForeignReference() {
        val explicit = mapOf(
            "credentialRef" to "secure-ref:api-key:deepseek:from-ref",
            "mobileAccountId" to "explicit-account",
            "accountId" to "alternate-account"
        )
        assertEquals(
            "explicit-account",
            MobileProviderAccountIdentity.accountIdFromFields(
                explicit,
                providerId = "deepseek",
                fallback = "deepseek"
            )
        )

        assertEquals(
            "deepseek",
            MobileProviderAccountIdentity.accountIdFromFields(
                mapOf("credentialRef" to "secure-ref:oauth:chatgpt:foreign"),
                providerId = "deepseek",
                fallback = "deepseek"
            )
        )
    }

    @Test
    fun accountRecordIdsDoNotCollideAfterPathUnsafeCharacters() {
        val colon = MobileProviderAccountIdentity.accountRecordId("account:a")
        val underscore = MobileProviderAccountIdentity.accountRecordId("account_a")

        assertNotEquals(colon, underscore)
        assertEquals(64, colon.length)
        assertTrue(colon.all { it in '0'..'9' || it in 'a'..'f' })
    }

    @Test
    fun oauthAttemptRoundTripsAcrossARepositoryRestartBoundary() {
        val attempt = PendingMobileProviderOAuth(
            attemptId = "oauth-attempt-1",
            providerId = "chatgpt",
            mobileAccountId = "mpa-chatgpt-1",
            accountDraftId = "mpa-chatgpt-1",
            state = "state-1",
            verifier = "verifier-1",
            redirectUri = "http://localhost:1455/auth/callback",
            createdAtEpochMillis = 10_000L
        )

        val persistedEncryptedPayloadPlaintext = MobileProviderOAuthAttemptCodec.encode(attempt)
        val loadedByFreshProcess = MobileProviderOAuthAttemptCodec.decode(
            persistedEncryptedPayloadPlaintext.copyOf()
        )

        assertEquals(attempt, loadedByFreshProcess)
        assertFalse(loadedByFreshProcess.isExpired(20_000L, 15_000L))
        assertTrue(loadedByFreshProcess.isExpired(30_001L, 15_000L))
        assertFalse(loadedByFreshProcess.verifier.contains("access_token"))
        persistedEncryptedPayloadPlaintext.fill(0)
    }

    @Test
    fun oauthAttemptCodecRejectsTrailingOrTruncatedPayloads() {
        val attempt = PendingMobileProviderOAuth(
            attemptId = "oauth-attempt-2",
            providerId = "chatgpt",
            mobileAccountId = "mpa-chatgpt-2",
            accountDraftId = "mpa-chatgpt-2",
            state = "state-2",
            verifier = "verifier-2",
            redirectUri = "http://localhost:1455/auth/callback",
            createdAtEpochMillis = 20_000L
        )
        val encoded = MobileProviderOAuthAttemptCodec.encode(attempt)

        assertThrows(IllegalArgumentException::class.java) {
            MobileProviderOAuthAttemptCodec.decode(encoded + byteArrayOf(1))
        }
        assertThrows(Exception::class.java) {
            MobileProviderOAuthAttemptCodec.decode(encoded.copyOf(encoded.size - 1))
        }
        encoded.fill(0)
    }
}
