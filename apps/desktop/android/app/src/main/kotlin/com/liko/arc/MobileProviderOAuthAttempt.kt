package com.liko.arc

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

internal data class PendingMobileProviderOAuth(
    val attemptId: String,
    val providerId: String,
    val mobileAccountId: String,
    val accountDraftId: String,
    val verifier: String,
    val state: String,
    val redirectUri: String,
    val createdAtEpochMillis: Long
) {
    fun isExpired(nowEpochMillis: Long, timeoutMillis: Long): Boolean {
        return createdAtEpochMillis <= 0L ||
            nowEpochMillis < createdAtEpochMillis ||
            nowEpochMillis - createdAtEpochMillis > timeoutMillis
    }
}

internal object MobileProviderOAuthAttemptCodec {
    private const val VERSION = 1
    private const val FIELD_COUNT = 7
    private const val MAX_FIELD_BYTES = 4096
    private const val MAX_PAYLOAD_BYTES = 32 * 1024
    private val MAGIC = byteArrayOf(0x4c, 0x49, 0x43, 0x4f, 0x4f, 0x41, 0x54, 0x54)

    fun encode(attempt: PendingMobileProviderOAuth): ByteArray {
        validate(attempt)
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { data ->
            data.write(MAGIC)
            data.writeInt(VERSION)
            data.writeInt(FIELD_COUNT)
            listOf(
                attempt.attemptId,
                attempt.providerId,
                attempt.mobileAccountId,
                attempt.accountDraftId,
                attempt.verifier,
                attempt.state,
                attempt.redirectUri
            ).forEach { writeBoundedUtf8(data, it) }
            data.writeLong(attempt.createdAtEpochMillis)
        }
        return output.toByteArray().also {
            require(it.size <= MAX_PAYLOAD_BYTES) { "OAuth attempt payload is too large" }
        }
    }

    fun decode(payload: ByteArray): PendingMobileProviderOAuth {
        require(payload.size <= MAX_PAYLOAD_BYTES) { "OAuth attempt payload is too large" }
        val input = ByteArrayInputStream(payload)
        val attempt = DataInputStream(input).use { data ->
            val magic = ByteArray(MAGIC.size)
            data.readFully(magic)
            require(magic.contentEquals(MAGIC)) { "OAuth attempt payload magic is invalid" }
            require(data.readInt() == VERSION) { "OAuth attempt payload version is invalid" }
            require(data.readInt() == FIELD_COUNT) { "OAuth attempt field count is invalid" }
            PendingMobileProviderOAuth(
                attemptId = readBoundedUtf8(data),
                providerId = readBoundedUtf8(data),
                mobileAccountId = readBoundedUtf8(data),
                accountDraftId = readBoundedUtf8(data),
                verifier = readBoundedUtf8(data),
                state = readBoundedUtf8(data),
                redirectUri = readBoundedUtf8(data),
                createdAtEpochMillis = data.readLong()
            ).also {
                require(input.available() == 0) { "OAuth attempt payload has trailing bytes" }
            }
        }
        validate(attempt)
        return attempt
    }

    private fun validate(attempt: PendingMobileProviderOAuth) {
        require(attempt.attemptId.isNotBlank()) { "OAuth attempt id is required" }
        require(attempt.providerId.isNotBlank()) { "OAuth provider id is required" }
        require(attempt.mobileAccountId.isNotBlank()) { "OAuth account id is required" }
        require(attempt.accountDraftId.isNotBlank()) { "OAuth account draft id is required" }
        require(attempt.verifier.isNotBlank()) { "OAuth verifier is required" }
        require(attempt.state.isNotBlank()) { "OAuth state is required" }
        require(attempt.redirectUri.isNotBlank()) { "OAuth redirect URI is required" }
        require(attempt.createdAtEpochMillis > 0L) { "OAuth creation time is invalid" }
    }

    private fun writeBoundedUtf8(output: DataOutputStream, value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        require(bytes.isNotEmpty() && bytes.size <= MAX_FIELD_BYTES) {
            "OAuth attempt field length is invalid"
        }
        output.writeInt(bytes.size)
        output.write(bytes)
    }

    private fun readBoundedUtf8(input: DataInputStream): String {
        val size = input.readInt()
        require(size in 1..MAX_FIELD_BYTES) { "OAuth attempt field length is invalid" }
        val bytes = ByteArray(size)
        input.readFully(bytes)
        return String(bytes, Charsets.UTF_8)
    }
}
