package com.liko.arc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureMeshAndroidSecretContractTest {
    @Test
    fun placeholderAndBlankValuesAreNeverSecrets() {
        listOf(null, "", "  ", "redacted", "***", "********").forEach {
            assertFalse(SecureMeshAndroidSecretContract.secretTextPresent(it))
        }
        assertTrue(SecureMeshAndroidSecretContract.secretTextPresent("opaque-value"))
    }

    @Test
    fun recordIdsAndDigestsAreDeterministicAndPathSafe() {
        assertEquals("account_with_spaces", SecureMeshAndroidSecretContract.safeRecordId(
            "account with spaces",
        ))
        assertEquals("account", SecureMeshAndroidSecretContract.safeRecordId(""))
        assertEquals(
            SecureMeshAndroidSecretContract.sha256Hex("x".toByteArray()),
            SecureMeshAndroidSecretContract.sha256Hex("x".toByteArray()),
        )
    }

    @Test
    fun storedSecretDecoderKeepsMissingSeparateFromInvalidExistingRecords() {
        listOf(
            byteArrayOf(),
            "   ".toByteArray(Charsets.UTF_8),
            "redacted".toByteArray(Charsets.UTF_8),
            byteArrayOf(0xc3.toByte(), 0x28),
        ).forEach { invalid ->
            assertThrows(IllegalStateException::class.java) {
                SecureMeshAndroidSecretContract.decodeStoredSecret(invalid)
            }
        }

        val valid = "  opaque-secret  "
        assertEquals(
            valid,
            SecureMeshAndroidSecretContract.decodeStoredSecret(valid.toByteArray(Charsets.UTF_8)),
        )
    }

    @Test
    fun e2eeSecretCatalogOwnsEveryRustCustodyField() {
        assertEquals(
            listOf(
                "privateKeyBase64url",
                "signingKeyBase64url",
                "signedPrekeyPrivateKeyBase64url",
                "oneTimePrekeyPrivateKeyBase64url",
                "oneTimeMlKem1024PrekeySeedBase64url",
                "pairingSecretBase64url",
            ),
            SecureMeshAndroidSecretContract.E2EE_SECRET_FIELDS.map { it.jsonField },
        )
    }

    @Test
    fun mlKemSeedAloneFailsPlaintextCheckAndIsRemovedByReset() {
        val e2ee = mutableMapOf<String, Any?>(
            "oneTimeMlKem1024PrekeySeedBase64url" to "opaque-seed",
        )

        assertTrue(SecureMeshAndroidSecretContract.hasPlaintextE2eeSecret(e2ee))

        SecureMeshAndroidSecretContract.removeE2eeSecrets(e2ee)

        assertFalse(SecureMeshAndroidSecretContract.hasPlaintextE2eeSecret(e2ee))
        assertFalse(e2ee.containsKey("oneTimeMlKem1024PrekeySeedBase64url"))
        assertEquals(
            "redacted",
            e2ee["oneTimeMlKem1024PrekeySeedMaterial"],
        )
    }
}
