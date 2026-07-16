package com.liko.arc

import android.util.Base64
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

internal data class DecodedReleaseAcceptanceParams(
    val value: JSONObject?,
    val byteCount: Int,
    val valid: Boolean,
)

internal object ReleaseAcceptanceDebugCodec {
    private const val BASE64_URL_FLAGS =
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
    private val canonicalBase64UrlPattern = Regex("^[A-Za-z0-9_-]+$")

    fun decodeParams(encoded: String): DecodedReleaseAcceptanceParams {
        if (encoded.isEmpty()) {
            return DecodedReleaseAcceptanceParams(null, 0, false)
        }
        val maximumEncodedLength =
            ((ReleaseAcceptanceChannel.MAX_PARAMS_JSON_BYTES + 2) / 3) * 4
        if (
            encoded.length > maximumEncodedLength ||
            !canonicalBase64UrlPattern.matches(encoded)
        ) {
            return DecodedReleaseAcceptanceParams(
                null,
                ReleaseAcceptanceChannel.MAX_PARAMS_JSON_BYTES + 1,
                false,
            )
        }
        return try {
            val decoded = Base64.decode(encoded, BASE64_URL_FLAGS)
            if (
                decoded.size > ReleaseAcceptanceChannel.MAX_PARAMS_JSON_BYTES ||
                base64UrlEncode(decoded) != encoded
            ) {
                return DecodedReleaseAcceptanceParams(null, decoded.size, false)
            }
            val text = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(decoded))
                .toString()
            val tokener = JSONTokener(text)
            val value = tokener.nextValue()
            val valid = value is JSONObject && tokener.nextClean() == '\u0000'
            DecodedReleaseAcceptanceParams(
                value = value as? JSONObject,
                byteCount = decoded.size,
                valid = valid,
            )
        } catch (_: Exception) {
            DecodedReleaseAcceptanceParams(null, encoded.length, false)
        }
    }

    fun sanitize(value: Any?): Any? = when (value) {
        is JSONObject -> JSONObject().also { output ->
            val keys = value.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                output.put(
                    key,
                    if (isSensitiveKey(key)) "[redacted]" else sanitize(value.opt(key)),
                )
            }
        }
        is JSONArray -> JSONArray().also { output ->
            for (index in 0 until value.length()) {
                output.put(sanitize(value.opt(index)))
            }
        }
        is Map<*, *> -> JSONObject().also { output ->
            value.entries
                .map { entry ->
                    val key = entry.key as? String
                        ?: throw IllegalArgumentException("debug response map key must be a string")
                    key to entry.value
                }
                .sortedBy { (key, _) -> key }
                .forEach { (key, nestedValue) ->
                    output.put(
                        key,
                        if (isSensitiveKey(key)) "[redacted]" else sanitize(nestedValue),
                    )
                }
        }
        is Iterable<*> -> JSONArray().also { output ->
            value.forEach { output.put(sanitize(it)) }
        }
        is Array<*> -> JSONArray().also { output ->
            value.forEach { output.put(sanitize(it)) }
        }
        else -> value
    }

    private fun isSensitiveKey(key: String): Boolean {
        if (key in ReleaseAcceptanceDebugContract.safeStatusKeys) return false
        val normalized = key.lowercase()
        return normalized == "body" ||
            normalized == "content" ||
            normalized == "message" ||
            normalized.contains("plaintext") ||
            normalized.contains("ciphertext") ||
            normalized.contains("bodybase64url") ||
            normalized.contains("contentbase64url") ||
            normalized.contains("token") ||
            normalized.contains("secret") ||
            normalized.contains("apikey") ||
            normalized.contains("api_key") ||
            normalized.contains("authorization") ||
            normalized.contains("privatekey") ||
            normalized.contains("private_key") ||
            normalized.contains("pairingcode")
    }

    private fun base64UrlEncode(value: ByteArray): String =
        Base64.encodeToString(value, BASE64_URL_FLAGS)
}
