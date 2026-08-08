package land.lico.licoup

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureMeshAndroidSecretStoreBoundaryTest {
    private val sourceRoot = listOf(
        File("src/main/kotlin/land/lico/licoup"),
        File("app/src/main/kotlin/land/lico/licoup"),
        File("apps/desktop/android/app/src/main/kotlin/land/lico/licoup"),
    ).firstOrNull { it.isDirectory }
        ?: error("Android Kotlin source root is unavailable")

    @Test
    fun jniSecretStoreIsABoundedFacade() {
        val facade = source("SecureMeshAndroidSecretStore.kt")
        assertTrue(facade.lineSequence().count() < 150)
        assertTrue(facade.contains("SecureMeshAndroidCustodyManager("))
        assertTrue(facade.contains("SecureMeshAndroidEncryptedRecordStore("))
        assertTrue(facade.contains("SecureMeshAndroidMobileRelaySecretBridge("))
        assertFalse(facade.contains("KeyGenParameterSpec"))
        assertFalse(facade.contains("Cipher.getInstance"))
        assertFalse(facade.contains("portable-data/licoup/mobile-relay"))
    }

    @Test
    fun custodySelectionOwnsOnlyPlatformKeyPolicy() {
        val custody = source("SecureMeshAndroidCustodyManager.kt")
        assertTrue(custody.lineSequence().count() < 400)
        assertTrue(custody.contains("SecureMeshAndroidKeyPolicyStrategy.select"))
        assertTrue(custody.contains("KeyGenParameterSpec.Builder"))
        assertTrue(custody.contains("setUserAuthenticationParameters"))
        assertFalse(custody.contains("Cipher.getInstance"))
        assertFalse(custody.contains("portable-data/licoup/mobile-relay"))
        assertFalse(custody.contains("JSONObject("))
    }

    @Test
    fun encryptedRecordStoreOwnsCipherAndBufferErasure() {
        val records = source("SecureMeshAndroidEncryptedRecordStore.kt")
        assertTrue(records.lineSequence().count() < 500)
        assertTrue(records.contains("Cipher.getInstance"))
        assertTrue(records.contains("GCMParameterSpec"))
        assertTrue(records.contains("plaintext.fill(0)"))
        assertTrue(records.contains("loadedSecret.fill(0)"))
        assertFalse(records.contains("mobileRelayPairingInvite"))
        assertFalse(records.contains("KeyGenParameterSpec"))
    }

    @Test
    fun relayBridgeOwnsOnlyJniCustodyHandlesWithoutConfigJson() {
        val relay = source("SecureMeshAndroidMobileRelaySecretBridge.kt")
        assertTrue(relay.lineSequence().count() < 260)
        assertTrue(relay.contains("portableConfigAuthority" toStringMarker "rust_generation_cas"))
        assertTrue(relay.contains("requireMobileRelaySelection"))
        assertTrue(relay.contains("getNotFoundSeparatedFromFailure"))
        assertFalse(relay.contains("portable-data/licoup/mobile-relay"))
        assertFalse(relay.contains("readText("))
        assertFalse(relay.contains("writeText("))
        assertFalse(relay.contains("Cipher.getInstance"))
        assertFalse(relay.contains("KeyGenParameterSpec"))
        assertFalse(relay.contains("SecretKey"))
    }

    @Test
    fun statusCannotProvisionDeleteOrResetCustody() {
        val custody = source("SecureMeshAndroidCustodyManager.kt")
        val statusBody = custody.substringAfter("private fun statusMeasurement")
            .substringBefore("private fun requirePreparedSelection")
        assertTrue(statusBody.contains("capabilityProbe.memoryOnly"))
        assertFalse(statusBody.contains("generateKey("))
        assertFalse(statusBody.contains("deleteEntry("))
        assertFalse(statusBody.contains("deleteRecursively("))
        assertTrue(custody.contains("requires user-approved re-pair"))
    }

    @Test
    fun secretReadUsesNullOnlyForVerifiedMissingRecord() {
        val relay = source("SecureMeshAndroidMobileRelaySecretBridge.kt")
        val getBody = relay.substringAfter("fun get(namespace")
            .substringBefore("fun delete(namespace")
        assertTrue(getBody.contains("readStoredAccountSecret"))
        assertFalse(getBody.contains("catch"))
        assertFalse(getBody.contains("return null"))

        val readBody = relay.substringAfter("private fun readStoredAccountSecret")
            .substringBefore("private fun recordIdentity")
        assertTrue(readBody.contains("decodeStoredSecret(bytes)"))
        assertFalse(readBody.contains(".trim().takeIf"))
    }

    private infix fun String.toStringMarker(value: String): String =
        "\"$this\" to \"$value\""

    private fun source(name: String): String =
        File(sourceRoot, name).readText(Charsets.UTF_8)
}
