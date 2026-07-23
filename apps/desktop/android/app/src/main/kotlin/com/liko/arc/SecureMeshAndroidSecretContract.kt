package com.liko.arc

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import org.json.JSONObject

internal data class SecureMeshAndroidE2eeSecretField(
    val jsonField: String,
    val materialMarker: String,
    val secretClass: String,
)

internal object SecureMeshAndroidSecretContract {
    const val PROTOCOL_VERSION = "licomesh.secure-mesh.v1"
    const val MOBILE_RELAY_KEY_ALIAS =
        "licoarc_secure_mesh_android_mobile_relay_secret_store_v2"
    const val CIPHER = "AES/GCM/NoPadding"
    const val USER_AUTH_VALIDITY_SECONDS = 300
    const val MOBILE_RELAY_STORE_CONTRACT = "rust_secure_mesh_secret_store_handle_v1"
    const val MOBILE_RELAY_ACCOUNT_PREFIX = "mobileRelayE2ee"
    const val MOBILE_RELAY_NAMESPACE = "mobileRelayRuntime"
    const val MOBILE_RELAY_SECRET_KIND = "mobile_relay_secret"
    const val NONCE_LENGTH = 12
    const val TAG_BITS = 128

    val E2EE_SECRET_FIELDS = listOf(
        SecureMeshAndroidE2eeSecretField(
            "privateKeyBase64url",
            "privateKeyMaterial",
            "endpointPrivateKey",
        ),
        SecureMeshAndroidE2eeSecretField(
            "signingKeyBase64url",
            "signingKeyMaterial",
            "signingKey",
        ),
        SecureMeshAndroidE2eeSecretField(
            "signedPrekeyPrivateKeyBase64url",
            "signedPrekeyPrivateKeyMaterial",
            "signedPrekeyPrivateKey",
        ),
        SecureMeshAndroidE2eeSecretField(
            "oneTimePrekeyPrivateKeyBase64url",
            "oneTimePrekeyPrivateKeyMaterial",
            "oneTimePrekeyPrivateKey",
        ),
        SecureMeshAndroidE2eeSecretField(
            "oneTimeMlKem1024PrekeySeedBase64url",
            "oneTimeMlKem1024PrekeySeedMaterial",
            "oneTimeMlKem1024PrekeySeed",
        ),
        SecureMeshAndroidE2eeSecretField(
            "pairingSecretBase64url",
            "pairingSecretMaterial",
            "pairingSecret",
        ),
    )

    fun secretTextPresent(value: Any?): Boolean {
        val text = (value as? String)?.trim() ?: return false
        return text.isNotEmpty() &&
            text != "redacted" &&
            text != "***" &&
            text != "********"
    }

    fun decodeStoredSecret(bytes: ByteArray): String {
        check(bytes.isNotEmpty()) {
            "secure mesh Android stored secret is empty"
        }
        val decoded = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (_error: CharacterCodingException) {
            throw IllegalStateException(
                "secure mesh Android stored secret is not valid UTF-8",
            )
        }
        check(secretTextPresent(decoded)) {
            "secure mesh Android stored secret is invalid"
        }
        return decoded
    }

    fun hasPlaintextE2eeSecret(value: JSONObject?): Boolean =
        value != null && hasPlaintextE2eeSecret { field -> value.opt(field) }

    fun hasPlaintextE2eeSecret(value: Map<String, Any?>): Boolean =
        hasPlaintextE2eeSecret(value::get)

    private fun hasPlaintextE2eeSecret(valueFor: (String) -> Any?): Boolean =
        E2EE_SECRET_FIELDS.any { field -> secretTextPresent(valueFor(field.jsonField)) }

    fun removeE2eeSecrets(value: JSONObject) {
        E2EE_SECRET_FIELDS.forEach { field ->
            value.remove(field.jsonField)
            value.put(field.materialMarker, "redacted")
        }
    }

    fun removeE2eeSecrets(value: MutableMap<String, Any?>) {
        E2EE_SECRET_FIELDS.forEach { field ->
            value.remove(field.jsonField)
            value[field.materialMarker] = "redacted"
        }
    }

    fun firstNonBlank(vararg values: String): String =
        values.firstOrNull { it.isNotBlank() }.orEmpty()

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun safeRecordId(value: String): String {
        val safe = value.replace(Regex("[^a-zA-Z0-9_.-]"), "_")
        return safe.ifBlank { "account" }
    }
}
