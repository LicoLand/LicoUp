package com.liko.arc

import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

internal class SecureMeshAndroidEncryptedRecordStore(
    private val filesDir: File,
    private val custodyManager: SecureMeshAndroidCustodyManager,
    private val atomicRecordWriter: SecureMeshAndroidAtomicRecordWriter =
        SecureMeshAndroidAtomicRecordWriter(),
) {
    private val ephemeralStore = SecureMeshAndroidEphemeralSecretStore()

    fun write(
        selection: SecureMeshAndroidCustodySelection,
        kind: String,
        label: String,
        challenge: String,
        secret: ByteArray,
        recordFile: File,
    ) {
        custodyManager.requireAuthorization(selection)
        when (selection) {
            is SecureMeshAndroidCustodySelection.KeyStore -> writePersistent(
                kind,
                label,
                challenge,
                secret,
                recordFile,
                selection.secretKey,
            )
            is SecureMeshAndroidCustodySelection.MemoryOnly -> {
                check(!recordFile.exists()) {
                    "secure mesh Android persistent record requires user-approved re-pair"
                }
                ephemeralStore.put(recordKey(recordFile, kind, label, challenge), secret)
            }
        }
    }

    fun read(
        selection: SecureMeshAndroidCustodySelection,
        kind: String,
        label: String,
        challenge: String,
        recordFile: File,
    ): ByteArray {
        custodyManager.requireAuthorization(selection)
        return when (selection) {
            is SecureMeshAndroidCustodySelection.KeyStore -> readPersistent(
                recordFile,
                selection.secretKey,
                kind,
                label,
                challenge,
            )
            is SecureMeshAndroidCustodySelection.MemoryOnly ->
                ephemeralStore.get(recordKey(recordFile, kind, label, challenge))
                    ?: throw IllegalStateException(
                        "secure mesh Android memory-only record is unavailable after restart",
                    )
        }
    }

    fun exists(
        selection: SecureMeshAndroidCustodySelection,
        kind: String,
        label: String,
        challenge: String,
        recordFile: File,
    ): Boolean = when (selection) {
        is SecureMeshAndroidCustodySelection.KeyStore -> recordFile.isFile
        is SecureMeshAndroidCustodySelection.MemoryOnly -> ephemeralStore
            .get(recordKey(recordFile, kind, label, challenge))
            ?.also { it.fill(0) } != null
    }

    fun delete(
        selection: SecureMeshAndroidCustodySelection,
        kind: String,
        label: String,
        challenge: String,
        recordFile: File,
    ): Boolean {
        custodyManager.requireAuthorization(selection)
        return when (selection) {
            is SecureMeshAndroidCustodySelection.KeyStore -> {
                if (!recordFile.exists()) true else {
                    val verified = readPersistent(
                        recordFile,
                        selection.secretKey,
                        kind,
                        label,
                        challenge,
                    )
                    verified.fill(0)
                    recordFile.delete() && !recordFile.exists()
                }
            }
            is SecureMeshAndroidCustodySelection.MemoryOnly -> {
                val deleted = ephemeralStore.delete(
                    recordKey(recordFile, kind, label, challenge),
                )
                check(!recordFile.exists()) {
                    "secure mesh Android persistent record requires user-approved re-pair"
                }
                deleted
            }
        }
    }

    private fun recordKey(
        recordFile: File,
        kind: String,
        label: String,
        challenge: String,
    ): String {
        val identity = listOf(
            recordFile.absolutePath,
            kind,
            label,
            SecureMeshAndroidSecretContract.sha256Hex(
                challenge.toByteArray(Charsets.UTF_8),
            ),
        ).joinToString("\u0000")
        return SecureMeshAndroidSecretContract.sha256Hex(
            identity.toByteArray(Charsets.UTF_8),
        )
    }

    private fun writePersistent(
        kind: String,
        label: String,
        challenge: String,
        secret: ByteArray,
        recordFile: File,
        secretKey: SecretKey,
    ) {
        val challengeHash = SecureMeshAndroidSecretContract.sha256Hex(
            challenge.toByteArray(Charsets.UTF_8),
        )
        val aad = buildAad(kind, label, challengeHash)
        val plaintext = encodePlaintext(kind, label, challengeHash, secret)
        val cipher = Cipher.getInstance(SecureMeshAndroidSecretContract.CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey)
        cipher.updateAAD(aad)
        val ciphertext = try {
            cipher.doFinal(plaintext)
        } finally {
            plaintext.fill(0)
        }
        val nonce = cipher.iv
        check(nonce != null && nonce.size == SecureMeshAndroidSecretContract.NONCE_LENGTH) {
            "secure mesh Android secure-store nonce is invalid"
        }
        val persisted = JSONObject()
            .put("protocolVersion", SecureMeshAndroidSecretContract.PROTOCOL_VERSION)
            .put("kind", kind)
            .put("label", label)
            .put("cipher", SecureMeshAndroidSecretContract.CIPHER)
            .put("challengeSha256", challengeHash)
            .put("aadSha256", SecureMeshAndroidSecretContract.sha256Hex(aad))
            .put("nonceBase64url", base64UrlEncode(nonce))
            .put("ciphertextBase64url", base64UrlEncode(ciphertext))
        val serialized = persisted.toString(2).toByteArray(Charsets.UTF_8)
        try {
            atomicRecordWriter.write(recordFile, serialized) { pendingFile ->
                val loadedSecret = readPersistent(
                    pendingFile,
                    secretKey,
                    kind,
                    label,
                    challenge,
                )
                val matches = MessageDigest.isEqual(secret, loadedSecret)
                loadedSecret.fill(0)
                check(matches) {
                    "secure mesh Android secure-store pending-record verification failed"
                }
            }
        } finally {
            serialized.fill(0)
        }
    }

    private fun readPersistent(
        recordFile: File,
        secretKey: SecretKey,
        expectedKind: String,
        expectedLabel: String,
        expectedChallenge: String,
    ): ByteArray {
        val persisted = JSONObject(recordFile.readText(Charsets.UTF_8))
        val kind = persisted.getString("kind")
        val label = persisted.getString("label")
        val challengeHash = persisted.getString("challengeSha256")
        val expectedChallengeHash = SecureMeshAndroidSecretContract.sha256Hex(
            expectedChallenge.toByteArray(Charsets.UTF_8),
        )
        check(
            kind == expectedKind &&
                label == expectedLabel &&
                challengeHash == expectedChallengeHash,
        ) { "secure mesh Android secure-store record identity mismatch" }
        val aad = buildAad(kind, label, challengeHash)
        check(
            SecureMeshAndroidSecretContract.sha256Hex(aad) ==
                persisted.getString("aadSha256"),
        ) { "secure mesh Android secure-store AAD hash mismatch" }
        val cipher = Cipher.getInstance(SecureMeshAndroidSecretContract.CIPHER)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey,
            GCMParameterSpec(
                SecureMeshAndroidSecretContract.TAG_BITS,
                base64UrlDecode(persisted.getString("nonceBase64url")),
            ),
        )
        cipher.updateAAD(aad)
        val plaintext = cipher.doFinal(
            base64UrlDecode(persisted.getString("ciphertextBase64url")),
        )
        return try {
            decodePlaintext(plaintext, kind, label, challengeHash)
        } finally {
            plaintext.fill(0)
        }
    }

    private fun buildAad(kind: String, label: String, challengeHash: String): ByteArray =
        ByteArrayOutputStream().use { output ->
            output.write(AAD_MAGIC)
            appendLenPrefixed(output, SecureMeshAndroidSecretContract.PROTOCOL_VERSION)
            appendLenPrefixed(output, kind)
            appendLenPrefixed(output, label)
            appendLenPrefixed(output, challengeHash)
            output.toByteArray()
        }

    private fun encodePlaintext(
        kind: String,
        label: String,
        challengeHash: String,
        secret: ByteArray,
    ): ByteArray = ByteArrayOutputStream().use { output ->
        output.write(PLAINTEXT_MAGIC)
        appendLenPrefixed(output, SecureMeshAndroidSecretContract.PROTOCOL_VERSION)
        appendLenPrefixed(output, kind)
        appendLenPrefixed(output, label)
        appendLenPrefixed(output, challengeHash)
        appendLenPrefixed(output, secret)
        output.toByteArray()
    }

    private fun decodePlaintext(
        bytes: ByteArray,
        expectedKind: String,
        expectedLabel: String,
        expectedChallengeHash: String,
    ): ByteArray {
        val reader = SliceReader(bytes)
        reader.expect(PLAINTEXT_MAGIC)
        val protocolVersion = reader.readText()
        val kind = reader.readText()
        val label = reader.readText()
        val challengeHash = reader.readText()
        val secret = reader.readLenPrefixedBytes()
        require(reader.isEmpty()) {
            "secure mesh Android secure-store plaintext has trailing bytes"
        }
        require(
            protocolVersion == SecureMeshAndroidSecretContract.PROTOCOL_VERSION &&
                kind == expectedKind &&
                label == expectedLabel &&
                challengeHash == expectedChallengeHash,
        ) { "secure mesh Android secure-store plaintext metadata mismatch" }
        return secret
    }

    private fun appendLenPrefixed(output: ByteArrayOutputStream, value: String) =
        appendLenPrefixed(output, value.toByteArray(Charsets.UTF_8))

    private fun appendLenPrefixed(output: ByteArrayOutputStream, value: ByteArray) {
        val length = value.size
        output.write((length ushr 24) and 0xff)
        output.write((length ushr 16) and 0xff)
        output.write((length ushr 8) and 0xff)
        output.write(length and 0xff)
        output.write(value)
    }

    private fun base64UrlDecode(value: String): ByteArray =
        Base64.decode(value, BASE64_URL_FLAGS)

    private fun base64UrlEncode(value: ByteArray): String =
        Base64.encodeToString(value, BASE64_URL_FLAGS)

    private class SliceReader(private val bytes: ByteArray) {
        private var offset = 0

        fun expect(expected: ByteArray) {
            require(readExact(expected.size).contentEquals(expected)) {
                "secure mesh payload plaintext magic is invalid"
            }
        }

        fun readText(): String = String(readLenPrefixedBytes(), Charsets.UTF_8)

        fun readLenPrefixedBytes(): ByteArray {
            val lengthBytes = readExact(4)
            val length = ((lengthBytes[0].toInt() and 0xff) shl 24) or
                ((lengthBytes[1].toInt() and 0xff) shl 16) or
                ((lengthBytes[2].toInt() and 0xff) shl 8) or
                (lengthBytes[3].toInt() and 0xff)
            require(length >= 0) { "secure mesh payload length is invalid" }
            return readExact(length)
        }

        fun isEmpty(): Boolean = offset == bytes.size

        private fun readExact(length: Int): ByteArray {
            require(length >= 0 && offset + length <= bytes.size) {
                "secure mesh payload buffer is truncated"
            }
            return bytes.copyOfRange(offset, offset + length).also {
                offset += length
            }
        }
    }

    companion object {
        private const val BASE64_URL_FLAGS =
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        private val AAD_MAGIC =
            "LCOSM-ANDROID-STORE-AAD-v1".toByteArray(Charsets.UTF_8)
        private val PLAINTEXT_MAGIC =
            "LCOSM-ANDROID-STORE-PT-v1".toByteArray(Charsets.UTF_8)
    }
}
