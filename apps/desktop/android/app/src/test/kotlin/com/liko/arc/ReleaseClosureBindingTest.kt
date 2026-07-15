package com.liko.arc

import java.security.MessageDigest
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class ReleaseClosureBindingTest {
    @Test
    fun validThirtyTwoByteBase64UrlValueProducesOnlyItsDigest() {
        val raw = ByteArray(32) { index -> index.toByte() }
        val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(raw)
        val expected = MessageDigest.getInstance("SHA-256")
            .digest(encoded.toByteArray(Charsets.US_ASCII))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

        val result = ReleaseClosureBinding.digest(encoded)

        assertEquals("sha256:$expected", result)
        assertNotEquals(encoded, result)
    }

    @Test
    fun malformedNonCanonicalAndWrongLengthValuesFailClosed() {
        val valid = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(ByteArray(32) { 7 })
        listOf(
            "",
            "short",
            "$valid=",
            valid.dropLast(1),
            "!${valid.drop(1)}",
            Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(31) { 7 }),
        ).forEach { candidate ->
            assertEquals(candidate, "", ReleaseClosureBinding.digest(candidate))
        }
    }

    @Test
    fun distinctInvocationsCannotShareTheSameDigest() {
        val first = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(ByteArray(32) { 1 })
        val second = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(ByteArray(32) { 2 })

        assertNotEquals(
            ReleaseClosureBinding.digest(first),
            ReleaseClosureBinding.digest(second),
        )
    }
}
