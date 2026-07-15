package com.liko.arc

import java.security.MessageDigest

internal object MobileProviderAccountIdentity {
    private const val MAX_ACCOUNT_ID_CHARS = 256

    fun accountIdFromCredentialRef(
        credentialRef: String,
        expectedProviderId: String
    ): String {
        val trimmed = credentialRef.trim()
        if (trimmed.isBlank()) {
            return ""
        }
        // secure-ref:<kind>:<providerId>:<accountId>, where accountId may contain ':'.
        val parts = trimmed.split(':')
        if (parts.size < 4 || parts[0] != "secure-ref") {
            return ""
        }
        val kind = parts[1]
        val providerId = parts[2]
        if (kind !in setOf("api-key", "oauth") || providerId != expectedProviderId.trim()) {
            return ""
        }
        return normalizeAccountId(parts.subList(3, parts.size).joinToString(":"))
    }

    fun accountIdFromFields(
        fields: Map<String, String>,
        providerId: String,
        fallback: String
    ): String {
        val fromCredentialRef = accountIdFromCredentialRef(
            firstNonBlank(
                fields["credentialRef"].orEmpty(),
                fields["credential_ref"].orEmpty()
            ),
            providerId
        )
        return sequenceOf(
            fields["mobileAccountId"].orEmpty(),
            fields["accountId"].orEmpty(),
            fields["localAccountId"].orEmpty(),
            fields["accountDraftId"].orEmpty(),
            fromCredentialRef,
            fallback
        )
            .map(::normalizeAccountId)
            .firstOrNull { it.isNotEmpty() }
            .orEmpty()
    }

    fun normalizeAccountId(value: String): String {
        val normalized = value.trim()
        if (normalized.isEmpty() || normalized.length > MAX_ACCOUNT_ID_CHARS) {
            return ""
        }
        return if (normalized.any { it.isISOControl() }) "" else normalized
    }

    fun accountRecordId(accountId: String): String {
        val normalized = normalizeAccountId(accountId)
        require(normalized.isNotEmpty()) { "Mobile provider account id is invalid" }
        return MessageDigest.getInstance("SHA-256")
            .digest(normalized.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun firstNonBlank(vararg values: String): String {
        return values.firstOrNull { it.trim().isNotEmpty() }?.trim().orEmpty()
    }
}
