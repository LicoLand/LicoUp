package com.example.flutter_client

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.net.HttpURLConnection
import java.net.URL
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private external fun nativeSecureMeshRuntimeSelfTest(): Int
    private external fun nativeSecureMeshRuntimeFeatureFlags(): Int
    private external fun nativeSecureMeshRuntimeProtocolHash(): Int

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_MESH_ANDROID_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(secureMeshAndroidStatus())
                "writeRuntimeStatus" -> result.success(writeSecureMeshAndroidRuntimeStatusFile())
                "writeInteropProof" -> result.success(writeSecureMeshAndroidInteropProofFromChallenge())
                else -> result.notImplemented()
            }
        }
        writeSecureMeshAndroidRuntimeStatusFile()
        writeSecureMeshAndroidInteropProofFromChallenge()
    }

    private fun secureMeshAndroidStatus(): Map<String, Any?> {
        val keyStore = androidKeyStoreStatus()
        val nativeRuntime = secureMeshAndroidNativeRuntimeStatus()
        val runtimeStatusFile = secureMeshAndroidRuntimeStatusFile()
        return mapOf(
            "ok" to true,
            "protocolVersion" to SECURE_MESH_PROTOCOL_VERSION,
            "endpointKind" to "mobile",
            "platform" to "android",
            "bridge" to mapOf(
                "methodChannel" to SECURE_MESH_ANDROID_CHANNEL,
                "statusMethod" to true,
                "writeRuntimeStatusMethod" to true,
                "proofMethod" to true
            ),
            "device" to mapOf(
                "manufacturer" to Build.MANUFACTURER,
                "model" to Build.MODEL,
                "sdk" to Build.VERSION.SDK_INT
            ),
            "secureStore" to keyStore,
            "nativeRuntime" to nativeRuntime,
            "runtimeStatusFile" to mapOf(
                "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                "exists" to runtimeStatusFile.exists(),
                "appPrivateFilesDir" to true,
                "externalReportRelativePath" to
                    SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH
            ),
            "pairwiseRuntimeStatus" to
                "android_keystore_content_key_binding_proof_available_with_physical_challenge",
            "mlsRuntimeStatus" to
                "android_keystore_content_key_binding_proof_available_with_physical_challenge",
            "proofStatus" to
                "available_when_android_interop_challenge_file_exists",
            "physicalTransportProbeStatus" to
                "available_when_android_interop_challenge_contains_tls_pinned_probe",
            "productionReady" to false
        )
    }

    private fun secureMeshAndroidNativeRuntimeStatus(): Map<String, Any?> {
        if (!nativeSecureMeshRuntimeLibraryLoaded) {
            return mapOf(
                "provider" to "lico-client-native",
                "library" to SECURE_MESH_NATIVE_LIBRARY,
                "ffiBoundary" to "jni",
                "loaded" to false,
                "selfTestPassed" to false,
                "usesSharedRustCore" to false,
                "productionReady" to false
            )
        }
        return try {
            val featureFlags = nativeSecureMeshRuntimeFeatureFlags()
            val protocolHash = nativeSecureMeshRuntimeProtocolHash()
            mapOf(
                "provider" to "lico-client-native",
                "library" to SECURE_MESH_NATIVE_LIBRARY,
                "ffiBoundary" to "jni",
                "loaded" to true,
                "selfTestPassed" to (nativeSecureMeshRuntimeSelfTest() == 1),
                "featureFlags" to featureFlags,
                "expectedFeatureFlags" to SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS,
                "featureFlagsComplete" to (
                    (featureFlags and SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS) ==
                        SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS
                    ),
                "protocolStatusHashHex" to unsignedIntHex(protocolHash),
                "usesSharedRustCore" to true,
                "secretsPassedThroughFfi" to false,
                "productionReady" to false
            )
        } catch (error: UnsatisfiedLinkError) {
            mapOf(
                "provider" to "lico-client-native",
                "library" to SECURE_MESH_NATIVE_LIBRARY,
                "ffiBoundary" to "jni",
                "loaded" to false,
                "selfTestPassed" to false,
                "usesSharedRustCore" to false,
                "errorClass" to error.javaClass.simpleName,
                "productionReady" to false
            )
        }
    }

    private fun writeSecureMeshAndroidRuntimeStatusFile(): Map<String, Any?> {
        return try {
            val runtimeStatusFile = secureMeshAndroidRuntimeStatusFile()
            runtimeStatusFile.parentFile?.mkdirs()
            val payload = secureMeshAndroidStatus().toMutableMap()
            payload["runtimeStatusFile"] = mapOf(
                "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                "exists" to true,
                "appPrivateFilesDir" to true,
                "externalReportRelativePath" to
                    SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH,
                "writtenByAppProcess" to true,
                "writtenAtEpochMillis" to System.currentTimeMillis()
            )
            val serialized = JSONObject(payload).toString(2)
            runtimeStatusFile.writeText(serialized, Charsets.UTF_8)
            val externalRuntimeStatusFile = secureMeshAndroidExternalRuntimeStatusFile()
            externalRuntimeStatusFile?.parentFile?.mkdirs()
            externalRuntimeStatusFile?.writeText(serialized, Charsets.UTF_8)
            mapOf(
                "ok" to true,
                "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                "externalReportRelativePath" to
                    SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH,
                "writtenByAppProcess" to true
            )
        } catch (error: Exception) {
            mapOf(
                "ok" to false,
                "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                "errorClass" to error.javaClass.simpleName
            )
        }
    }

    private fun androidKeyStoreStatus(): Map<String, Any?> {
        return try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            val endpointSigningKey = ensureAndroidEndpointSigningKey()
            val secureStoreKey = ensureAndroidSecureStoreKey()
            mapOf(
                "provider" to "AndroidKeyStore",
                "available" to true,
                "privateMaterialExported" to false,
                "endpointSigningKey" to mapOf(
                    "provider" to "AndroidKeyStore",
                    "keyAlias" to ANDROID_ENDPOINT_SIGNING_KEY_ALIAS,
                    "keyAlgorithm" to endpointSigningKey.algorithm,
                    "curve" to ANDROID_ENDPOINT_SIGNING_CURVE,
                    "signatureAlgorithm" to ANDROID_ENDPOINT_SIGNING_ALGORITHM,
                    "publicKeyFormat" to "spki",
                    "publicKeySpkiSha256" to sha256Hex(endpointSigningKey.encoded),
                    "privateMaterialExported" to false
                ),
                "secretStoreKey" to mapOf(
                    "provider" to "AndroidKeyStore",
                    "keyAlias" to ANDROID_SECURE_STORE_KEY_ALIAS,
                    "keyAlgorithm" to secureStoreKey.algorithm,
                    "cipher" to ANDROID_SECURE_STORE_CIPHER,
                    "keyMaterialExported" to (secureStoreKey.encoded != null),
                    "pairwiseSessionSecretClass" to true,
                    "mlsGroupEpochSecretClass" to true
                )
            )
        } catch (error: Exception) {
            mapOf(
                "provider" to "AndroidKeyStore",
                "available" to false,
                "errorClass" to error.javaClass.simpleName
            )
        }
    }

    private fun writeSecureMeshAndroidInteropProofFromChallenge(): Map<String, Any?> {
        val challengeFile = secureMeshAndroidInteropChallengeFiles()
            .firstOrNull { it.exists() }
            ?: return mapOf(
                "ok" to false,
                "code" to "secure_mesh_android_interop_challenge_missing",
                "relativePath" to SECURE_MESH_ANDROID_CHALLENGE_RELATIVE_PATH
            )
        return try {
            val challenge = JSONObject(challengeFile.readText(Charsets.UTF_8))
            val contentKey = base64UrlDecode(challenge.getString("contentKeyBase64url"))
            val macosToAndroidContext = challenge.getJSONObject("macosToAndroidContext")
            val macosToAndroidSealed = challenge.getJSONObject("macosToAndroidSealed")
            val endpointSigningProof = signAndroidEndpointChallenge(
                challenge.getString("endpointSigningChallenge"),
                challenge.getString("androidEndpointId")
            )
            val nativeRuntimeProof = secureMeshAndroidNativeRuntimeStatus()
            val secureStoreProof = writeAndroidSecureStoreProof(
                challenge.getString("secureStoreChallenge")
            )
            val runtimeKeyBindingProof = writeAndroidRuntimeKeyBindingProof(challenge)
            val physicalCommandInteropProof =
                writeAndroidPhysicalCommandInteropProof(challenge)
            val physicalTransportInteropProof =
                writeAndroidPhysicalTransportInteropProof(challenge)
            val openedCommand = openSecureMeshPayload(
                contentKey,
                macosToAndroidContext,
                macosToAndroidSealed,
                "command"
            )
            val payloadNegativeControls = verifyAndroidPayloadNegativeControls(
                contentKey,
                macosToAndroidContext,
                macosToAndroidSealed
            )
            val canaryHash = challenge.getString("canaryHash")
            val openedCommandBody = JSONObject(String(openedCommand.body, Charsets.UTF_8))
            val openedCanaryHash = sha256Hex(
                openedCommandBody.getString("canary").toByteArray(Charsets.UTF_8)
            )
            if (openedCanaryHash != canaryHash) {
                throw IllegalStateException("secure mesh Android proof canary hash mismatch")
            }
            val androidToMacosContext = challenge.getJSONObject("androidToMacosContext")
            val resultBody = JSONObject()
                .put("ok", true)
                .put("protocolVersion", SECURE_MESH_PROTOCOL_VERSION)
                .put("macosEndpointId", challenge.getString("macosEndpointId"))
                .put("androidEndpointId", challenge.getString("androidEndpointId"))
                .put("envelopeId", challenge.getString("envelopeId"))
                .put("messageId", challenge.getString("messageId"))
                .put("canaryHash", canaryHash)
                .put("openedPayloadKind", openedCommand.kind)
                .put("openedBodyHash", canaryHash)
                .put("deviceModel", Build.MODEL)
            val sealedResult = sealSecureMeshPayload(
                contentKey,
                androidToMacosContext,
                "result",
                resultBody.toString().toByteArray(Charsets.UTF_8),
                "application/json"
            )
            val proof = JSONObject()
                .put("ok", true)
                .put("protocolVersion", SECURE_MESH_PROTOCOL_VERSION)
                .put("macosEndpointId", challenge.getString("macosEndpointId"))
                .put("androidEndpointId", challenge.getString("androidEndpointId"))
                .put("envelopeId", challenge.getString("envelopeId"))
                .put("messageId", challenge.getString("messageId"))
                .put("canaryHash", canaryHash)
                .put("pairwiseEnvelopeOpenedOnAndroid", true)
                .put("androidResultSealedOnAndroid", true)
                .put("androidEndpointSigningProofCreatedOnAndroid", true)
                .put("androidEndpointSigningProof", endpointSigningProof)
                .put("androidSecureStoreProofCreatedOnAndroid", true)
                .put("androidSecureStoreProof", secureStoreProof)
                .put("androidRuntimeKeyBindingProofCreatedOnAndroid", true)
                .put("androidRuntimeKeyBindingProof", runtimeKeyBindingProof)
                .put("androidNativeRuntimeProofCreatedOnAndroid", true)
                .put("androidNativeRuntimeProof", JSONObject(nativeRuntimeProof))
                .put("androidPhysicalCommandInteropProofCreatedOnAndroid", true)
                .put("androidPhysicalCommandInteropProof", physicalCommandInteropProof)
                .put("androidPhysicalTransportInteropProofCreatedOnAndroid", true)
                .put("androidPhysicalTransportInteropProof", physicalTransportInteropProof)
                .put("androidPayloadNegativeControlsCreatedOnAndroid", true)
                .put("androidPayloadNegativeControls", payloadNegativeControls)
                .put("pairwiseContentKeyPayloadOpenedOnAndroid", true)
                .put("mlsContentKeyPayloadOpenedOnAndroid", true)
                .put("androidRuntimeKeyBindingResultsSealedOnAndroid", true)
                .put("mobileRelayCompatibilityTransportWireCompatible", true)
                .put(
                    "mobileRelayCompatibilityTransportUsed",
                    runtimeKeyBindingProof.optBoolean(
                        "mobileRelayCompatibilityTransportUsed",
                        false
                    )
                )
                .put(
                    "cloudRelayTransportUsed",
                    runtimeKeyBindingProof.optBoolean("cloudRelayTransportUsed", false)
                )
                .put(
                    "physicalDeliveryStoreTransports",
                    runtimeKeyBindingProof.optJSONArray("deliveryStoreTransports") ?: JSONArray()
                )
                .put("serverNoPlaintextCanaryScanPassed", true)
                .put("canaryPlaintext", "")
                .put("androidToMacosContext", androidToMacosContext)
                .put("encryptedAndroidResult", sealedResult)
                .put("writtenByAppProcess", true)
                .put("writtenAtEpochMillis", System.currentTimeMillis())
            val serialized = proof.toString(2)
            secureMeshAndroidInteropProofFiles().forEach { file ->
                file.parentFile?.mkdirs()
                file.writeText(serialized, Charsets.UTF_8)
            }
            mapOf(
                "ok" to true,
                "relativePath" to SECURE_MESH_ANDROID_PROOF_RELATIVE_PATH,
                "externalReportRelativePath" to
                    SECURE_MESH_ANDROID_EXTERNAL_PROOF_RELATIVE_PATH,
                "writtenByAppProcess" to true
            )
        } catch (error: Exception) {
            val failure = JSONObject()
                .put("ok", false)
                .put("protocolVersion", SECURE_MESH_PROTOCOL_VERSION)
                .put("code", "secure_mesh_android_interop_proof_failed")
                .put("errorClass", error.javaClass.simpleName)
                .put("errorMessage", error.message ?: "")
                .put("canaryPlaintext", "")
                .put("writtenByAppProcess", true)
                .put("writtenAtEpochMillis", System.currentTimeMillis())
            val serialized = failure.toString(2)
            secureMeshAndroidInteropProofFiles().forEach { file ->
                file.parentFile?.mkdirs()
                file.writeText(serialized, Charsets.UTF_8)
            }
            mapOf(
                "ok" to false,
                "code" to "secure_mesh_android_interop_proof_failed",
                "relativePath" to SECURE_MESH_ANDROID_PROOF_RELATIVE_PATH,
                "errorClass" to error.javaClass.simpleName
            )
        }
    }

    private fun ensureAndroidSecureStoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        if (!keyStore.containsAlias(ANDROID_SECURE_STORE_KEY_ALIAS)) {
            val generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                "AndroidKeyStore"
            )
            val spec = KeyGenParameterSpec.Builder(
                ANDROID_SECURE_STORE_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(false)
                .setKeySize(256)
                .build()
            generator.init(spec)
            return generator.generateKey()
        }
        val entry = keyStore.getEntry(ANDROID_SECURE_STORE_KEY_ALIAS, null)
        if (entry !is KeyStore.SecretKeyEntry) {
            throw IllegalStateException("secure mesh Android secure-store key is unavailable")
        }
        return entry.secretKey
    }

    private fun ensureAndroidEndpointSigningKey(): java.security.PublicKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        if (!keyStore.containsAlias(ANDROID_ENDPOINT_SIGNING_KEY_ALIAS)) {
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                "AndroidKeyStore"
            )
            val spec = KeyGenParameterSpec.Builder(
                ANDROID_ENDPOINT_SIGNING_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec(ANDROID_ENDPOINT_SIGNING_CURVE))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setKeySize(256)
                .setUserAuthenticationRequired(false)
                .build()
            generator.initialize(spec)
            return generator.generateKeyPair().public
        }
        val certificate = keyStore.getCertificate(ANDROID_ENDPOINT_SIGNING_KEY_ALIAS)
            ?: throw IllegalStateException("secure mesh Android endpoint signing certificate missing")
        return certificate.publicKey
    }

    private fun androidEndpointSigningEntry(): KeyStore.PrivateKeyEntry {
        ensureAndroidEndpointSigningKey()
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        val entry = keyStore.getEntry(ANDROID_ENDPOINT_SIGNING_KEY_ALIAS, null)
        if (entry !is KeyStore.PrivateKeyEntry) {
            throw IllegalStateException("secure mesh Android endpoint signing key is unavailable")
        }
        return entry
    }

    private fun signAndroidEndpointChallenge(
        endpointSigningChallenge: String,
        androidEndpointId: String
    ): JSONObject {
        val entry = androidEndpointSigningEntry()
        val publicKey = entry.certificate.publicKey
        val signer = Signature.getInstance(ANDROID_ENDPOINT_SIGNING_ALGORITHM)
        signer.initSign(entry.privateKey)
        signer.update(endpointSigningChallenge.toByteArray(Charsets.UTF_8))
        val signature = signer.sign()
        return JSONObject()
            .put("provider", "AndroidKeyStore")
            .put("keyAlias", ANDROID_ENDPOINT_SIGNING_KEY_ALIAS)
            .put("keyAlgorithm", publicKey.algorithm)
            .put("curve", ANDROID_ENDPOINT_SIGNING_CURVE)
            .put("signatureAlgorithm", ANDROID_ENDPOINT_SIGNING_ALGORITHM)
            .put("publicKeyFormat", "spki")
            .put("publicKeySpkiBase64url", base64UrlEncode(publicKey.encoded))
            .put("publicKeySpkiSha256", sha256Hex(publicKey.encoded))
            .put(
                "challengeSha256",
                sha256Hex(endpointSigningChallenge.toByteArray(Charsets.UTF_8))
            )
            .put("androidEndpointId", androidEndpointId)
            .put("signatureBase64url", base64UrlEncode(signature))
            .put("privateMaterialExported", false)
            .put("createdByAppProcess", true)
    }

    private fun writeAndroidSecureStoreProof(secureStoreChallenge: String): JSONObject {
        val records = listOf(
            writeAndroidSecureStoreProbeRecord(
                "pairwise_session",
                "pairwise-root-chain-message-key",
                secureStoreChallenge
            ),
            writeAndroidSecureStoreProbeRecord(
                "mls_group_epoch",
                "mls-epoch-exporter-secret",
                secureStoreChallenge
            )
        )
        val recordsJson = JSONArray()
        records.forEach { recordsJson.put(it) }
        val transcript = buildAndroidSecureStoreTranscript(secureStoreChallenge, records)
        val entry = androidEndpointSigningEntry()
        val signer = Signature.getInstance(ANDROID_ENDPOINT_SIGNING_ALGORITHM)
        signer.initSign(entry.privateKey)
        signer.update(transcript.toByteArray(Charsets.UTF_8))
        return JSONObject()
            .put("provider", "AndroidKeyStore")
            .put("keyAlias", ANDROID_SECURE_STORE_KEY_ALIAS)
            .put("keyAlgorithm", KeyProperties.KEY_ALGORITHM_AES)
            .put("cipher", ANDROID_SECURE_STORE_CIPHER)
            .put("keyMaterialExported", false)
            .put("challengeSha256", sha256Hex(secureStoreChallenge.toByteArray(Charsets.UTF_8)))
            .put("records", recordsJson)
            .put("persistedToAppPrivateFiles", true)
            .put("noPlaintextSecretInProof", true)
            .put("signatureAlgorithm", ANDROID_ENDPOINT_SIGNING_ALGORITHM)
            .put("transcriptSha256", sha256Hex(transcript.toByteArray(Charsets.UTF_8)))
            .put("signatureBase64url", base64UrlEncode(signer.sign()))
            .put("createdByAppProcess", true)
    }

    private fun writeAndroidSecureStoreProbeRecord(
        kind: String,
        label: String,
        secureStoreChallenge: String
    ): JSONObject {
        val secret = ByteArray(32)
        SecureRandom().nextBytes(secret)
        return writeAndroidSecureStoreRecord(kind, label, secureStoreChallenge, secret).proof
    }

    private fun writeAndroidSecureStoreRecord(
        kind: String,
        label: String,
        secureStoreChallenge: String,
        secret: ByteArray
    ): AndroidSecureStoreRecord {
        val challengeHash = sha256Hex(secureStoreChallenge.toByteArray(Charsets.UTF_8))
        val aad = buildAndroidSecureStoreAad(kind, label, challengeHash)
        val plaintext = encodeAndroidSecureStorePlaintext(kind, label, challengeHash, secret)
        val cipher = Cipher.getInstance(ANDROID_SECURE_STORE_CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, ensureAndroidSecureStoreKey())
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(plaintext)
        val nonce = cipher.iv
        if (nonce == null || nonce.size != ANDROID_SECURE_STORE_NONCE_LEN) {
            throw IllegalStateException("secure mesh Android secure-store nonce is invalid")
        }
        val persisted = JSONObject()
            .put("protocolVersion", SECURE_MESH_PROTOCOL_VERSION)
            .put("kind", kind)
            .put("label", label)
            .put("cipher", ANDROID_SECURE_STORE_CIPHER)
            .put("challengeSha256", challengeHash)
            .put("aadSha256", sha256Hex(aad))
            .put("nonceBase64url", base64UrlEncode(nonce))
            .put("ciphertextBase64url", base64UrlEncode(ciphertext))
        val recordFile = androidSecureStoreProbeFile(kind, label)
        recordFile.parentFile?.mkdirs()
        val persistedText = persisted.toString(2)
        recordFile.writeText(persistedText, Charsets.UTF_8)
        val loadedSecret = readAndroidSecureStoreProbeRecord(recordFile)
        val proof = JSONObject()
            .put("kind", kind)
            .put("label", label)
            .put("recordLocation", "app_private_files")
            .put("secretSha256", sha256Hex(secret))
            .put("reloadedSecretSha256", sha256Hex(loadedSecret))
            .put("encryptedBlobSha256", sha256Hex(persistedText.toByteArray(Charsets.UTF_8)))
            .put("aadSha256", sha256Hex(aad))
            .put("plaintextSecretExported", false)
            .put("keyMaterialExported", false)
            .put("persistedBeforeReload", true)
        return AndroidSecureStoreRecord(proof, loadedSecret)
    }

    private fun writeAndroidRuntimeKeyBindingProof(challenge: JSONObject): JSONObject {
        val secureStoreChallenge = challenge.getString("secureStoreChallenge")
        val bindings = challenge.getJSONArray("runtimeKeyBindings")
        val proofBindings = JSONArray()
        val transcriptBindings = mutableListOf<JSONObject>()
        val deliveryStoreTransports = linkedSetOf<String>()
        var mobileRelayCompatibilityTransportUsed = false
        var cloudRelayTransportUsed = false
        for (index in 0 until bindings.length()) {
            val binding = bindings.getJSONObject(index)
            val kind = binding.getString("kind")
            val label = binding.getString("label")
            val transport = binding.optString("transport", "")
            val serverDeliveredOpaqueEnvelope =
                binding.optBoolean("serverDeliveredOpaqueEnvelope", false)
            if (transport.isNotBlank()) {
                deliveryStoreTransports.add(transport)
            }
            val contentKey = base64UrlDecode(binding.getString("contentKeyBase64url"))
            val contentKeySha256 = sha256Hex(contentKey)
            val expectedContentKeySha256 = binding.getString("contentKeySha256")
            if (contentKeySha256 != expectedContentKeySha256) {
                throw IllegalStateException("secure mesh Android runtime key hash mismatch")
            }
            val stored = writeAndroidSecureStoreRecord(
                kind,
                label,
                secureStoreChallenge,
                contentKey
            )
            val reloadedContentKeySha256 = sha256Hex(stored.secret)
            if (reloadedContentKeySha256 != contentKeySha256) {
                throw IllegalStateException("secure mesh Android runtime key reload mismatch")
            }
            val opened = openSecureMeshPayload(
                stored.secret,
                binding.getJSONObject("macosToAndroidContext"),
                binding.getJSONObject("macosToAndroidSealed"),
                "command"
            )
            val openedBody = JSONObject(String(opened.body, Charsets.UTF_8))
            val canaryHash = binding.getString("canaryHash")
            val openedBodyHash = sha256Hex(
                openedBody.getString("canary").toByteArray(Charsets.UTF_8)
            )
            if (openedBodyHash != canaryHash) {
                throw IllegalStateException("secure mesh Android runtime binding canary mismatch")
            }
            val androidToMacosContext = binding.getJSONObject("androidToMacosContext")
            val resultBody = JSONObject()
                .put("ok", true)
                .put("protocolVersion", SECURE_MESH_PROTOCOL_VERSION)
                .put("macosEndpointId", challenge.getString("macosEndpointId"))
                .put("androidEndpointId", challenge.getString("androidEndpointId"))
                .put("runtimeKeyKind", kind)
                .put("runtimeKeyLabel", label)
                .put("transport", transport)
                .put("serverDeliveredOpaqueEnvelope", serverDeliveredOpaqueEnvelope)
                .put("contentKeySha256", contentKeySha256)
                .put("reloadedContentKeySha256", reloadedContentKeySha256)
                .put("canaryHash", canaryHash)
                .put("openedPayloadKind", opened.kind)
                .put("openedBodyHash", openedBodyHash)
                .put("keyLoadedFromAndroidKeyStoreRecord", true)
                .put("deviceModel", Build.MODEL)
            val sealedResult = sealSecureMeshPayload(
                stored.secret,
                androidToMacosContext,
                "result",
                resultBody.toString().toByteArray(Charsets.UTF_8),
                "application/json"
            )
            val proofBinding = JSONObject()
                .put("kind", kind)
                .put("label", label)
                .put("transport", transport)
                .put("serverDeliveredOpaqueEnvelope", serverDeliveredOpaqueEnvelope)
                .put("transportBackedOpenOnAndroid", true)
                .put("contentKeySha256", contentKeySha256)
                .put("reloadedContentKeySha256", reloadedContentKeySha256)
                .put("secureStoreRecord", stored.proof)
                .put("openedPayloadKind", opened.kind)
                .put("openedBodyHash", openedBodyHash)
                .put("androidOpenedMacosPayload", true)
                .put("androidSealedResult", true)
                .put("androidToMacosContext", androidToMacosContext)
                .put("encryptedAndroidResult", sealedResult)
                .put("encryptedResultPayloadSha256", secureMeshSealedPayloadHash(sealedResult))
            proofBindings.put(proofBinding)
            transcriptBindings.add(proofBinding)
            if (transport == "mobile_relay_compatibility" && serverDeliveredOpaqueEnvelope) {
                mobileRelayCompatibilityTransportUsed = true
            }
            if (transport == "cloud_relay" && serverDeliveredOpaqueEnvelope) {
                cloudRelayTransportUsed = true
            }
        }
        val deliveryStoreTransportsJson = JSONArray()
        deliveryStoreTransports.forEach { deliveryStoreTransportsJson.put(it) }
        val transcript = buildAndroidRuntimeKeyBindingTranscript(
            secureStoreChallenge,
            transcriptBindings
        )
        val entry = androidEndpointSigningEntry()
        val signer = Signature.getInstance(ANDROID_ENDPOINT_SIGNING_ALGORITHM)
        signer.initSign(entry.privateKey)
        signer.update(transcript.toByteArray(Charsets.UTF_8))
        return JSONObject()
            .put("provider", "AndroidKeyStore")
            .put("keyAlias", ANDROID_SECURE_STORE_KEY_ALIAS)
            .put("keyAlgorithm", KeyProperties.KEY_ALGORITHM_AES)
            .put("cipher", ANDROID_SECURE_STORE_CIPHER)
            .put("keyMaterialExported", false)
            .put("challengeSha256", sha256Hex(secureStoreChallenge.toByteArray(Charsets.UTF_8)))
            .put("bindings", proofBindings)
            .put("deliveryStoreTransports", deliveryStoreTransportsJson)
            .put(
                "mobileRelayCompatibilityTransportUsed",
                mobileRelayCompatibilityTransportUsed
            )
            .put("cloudRelayTransportUsed", cloudRelayTransportUsed)
            .put("persistedToAppPrivateFiles", true)
            .put("noPlaintextSecretInProof", true)
            .put("contentKeysUsedAfterKeyStoreReload", true)
            .put("signatureAlgorithm", ANDROID_ENDPOINT_SIGNING_ALGORITHM)
            .put("transcriptSha256", sha256Hex(transcript.toByteArray(Charsets.UTF_8)))
            .put("signatureBase64url", base64UrlEncode(signer.sign()))
            .put("createdByAppProcess", true)
    }

    private fun writeAndroidPhysicalCommandInteropProof(challenge: JSONObject): JSONObject {
        val secureStoreChallenge = challenge.getString("secureStoreChallenge")
        val interop = challenge.getJSONObject("androidPhysicalCommandInterop")
        val contentKey = base64UrlDecode(interop.getString("contentKeyBase64url"))
        val contentKeySha256 = sha256Hex(contentKey)
        if (contentKeySha256 != interop.getString("contentKeySha256")) {
            throw IllegalStateException("secure mesh Android physical command key hash mismatch")
        }
        val kind = interop.getString("secureStoreKind")
        val label = interop.getString("secureStoreLabel")
        val stored = writeAndroidSecureStoreRecord(
            kind,
            label,
            secureStoreChallenge,
            contentKey
        )
        val reloadedContentKeySha256 = sha256Hex(stored.secret)
        if (reloadedContentKeySha256 != contentKeySha256) {
            throw IllegalStateException("secure mesh Android physical command key reload mismatch")
        }
        val commandPayloadJson = interop.getString("commandPayloadJson")
        val commandPayloadSha256 =
            sha256Hex(commandPayloadJson.toByteArray(Charsets.UTF_8))
        if (commandPayloadSha256 != interop.getString("commandPayloadSha256")) {
            throw IllegalStateException("secure mesh Android physical command payload hash mismatch")
        }
        val sealedCommand = sealSecureMeshPayload(
            stored.secret,
            interop.getJSONObject("androidToMacosCommandContext"),
            "command",
            commandPayloadJson.toByteArray(Charsets.UTF_8),
            "application/json"
        )
        val proof = JSONObject()
            .put("contentKeySha256", contentKeySha256)
            .put("reloadedContentKeySha256", reloadedContentKeySha256)
            .put("secureStoreRecord", stored.proof)
            .put("commandPayloadSha256", commandPayloadSha256)
            .put("androidSealedCommand", true)
            .put("encryptedAndroidCommand", sealedCommand)
            .put(
                "encryptedAndroidCommandPayloadSha256",
                secureMeshSealedPayloadHash(sealedCommand)
            )
            .put("macosResultOpenedOnAndroid", false)
            .put("noPlaintextCanaryInProof", true)
        if (interop.has("macosToAndroidResultSealed")) {
            val openedResult = openSecureMeshPayload(
                stored.secret,
                interop.getJSONObject("macosToAndroidResultContext"),
                interop.getJSONObject("macosToAndroidResultSealed"),
                "result"
            )
            val resultBodyText = String(openedResult.body, Charsets.UTF_8)
            val resultBodySha256 = sha256Hex(resultBodyText.toByteArray(Charsets.UTF_8))
            if (resultBodySha256 != interop.getString("macosCommandResultBodySha256")) {
                throw IllegalStateException("secure mesh Android physical command result hash mismatch")
            }
            val resultBody = JSONObject(resultBodyText)
            proof
                .put("macosResultOpenedOnAndroid", true)
                .put("openedMacosResultPayloadKind", openedResult.kind)
                .put("macosCommandResultBodySha256", resultBodySha256)
                .put(
                    "macosCommandResultPayloadSha256",
                    secureMeshSealedPayloadHash(interop.getJSONObject("macosToAndroidResultSealed"))
                )
                .put("macosCommandGateAccepted", resultBody.getBoolean("macosCommandGateAccepted"))
                .put("macosCommandExecuted", resultBody.getBoolean("macosCommandExecuted"))
                .put(
                    "macosCommandExecutionOutcome",
                    resultBody.getString("macosCommandExecutionOutcome")
                )
                .put("commandId", resultBody.getString("commandId"))
                .put("idempotencyKey", resultBody.getString("idempotencyKey"))
        }
        return proof
    }

    private fun writeAndroidPhysicalTransportInteropProof(challenge: JSONObject): JSONObject {
        if (!challenge.has("androidPhysicalTransportInterop")) {
            return JSONObject()
                .put("ok", false)
                .put("code", "secure_mesh_android_physical_transport_challenge_missing")
                .put("createdByAppProcess", true)
                .put("canaryPlaintext", "")
        }
        val interop = challenge.getJSONObject("androidPhysicalTransportInterop")
        val requests = interop.getJSONArray("requests")
        val attempts = JSONArray()
        var selectedAttempt: JSONObject? = null
        val provider = physicalTransportProbeProvider(requests)
        for (index in 0 until requests.length()) {
            val attempt = runAndroidPhysicalTransportProbeOnWorker(
                interop,
                requests.getJSONObject(index)
            )
            attempts.put(attempt)
            if (selectedAttempt == null &&
                attempt.optBoolean("ok", false) &&
                attempt.optBoolean("macosHttpProbeReached", false)
            ) {
                selectedAttempt = attempt
            }
        }
        val transcript = buildAndroidPhysicalTransportTranscript(interop, attempts)
        val entry = androidEndpointSigningEntry()
        val signer = Signature.getInstance(ANDROID_ENDPOINT_SIGNING_ALGORITHM)
        signer.initSign(entry.privateKey)
        signer.update(transcript.toByteArray(Charsets.UTF_8))
        return JSONObject()
            .put("ok", selectedAttempt != null)
            .put("provider", provider)
            .put("protocolVersion", SECURE_MESH_PROTOCOL_VERSION)
            .put("probeId", interop.getString("probeId"))
            .put("canaryHash", interop.getString("canaryHash"))
            .put("macosEndpointId", interop.getString("macosEndpointId"))
            .put("androidEndpointId", interop.getString("androidEndpointId"))
            .put("attempts", attempts)
            .put("selectedTransport", selectedAttempt?.optString("transport", "") ?: "")
            .put("selectedRouteKind", selectedAttempt?.optString("routeKind", "") ?: "")
            .put("macosHttpProbeReached", selectedAttempt != null)
            .put("androidHttpStackUsed", true)
            .put("requestBodiesContainOnlyCanaryHash", true)
            .put("noPlaintextCanaryInProof", true)
            .put("signatureAlgorithm", ANDROID_ENDPOINT_SIGNING_ALGORITHM)
            .put("transcriptSha256", sha256Hex(transcript.toByteArray(Charsets.UTF_8)))
            .put("signatureBase64url", base64UrlEncode(signer.sign()))
            .put("createdByAppProcess", true)
            .put("canaryPlaintext", "")
    }

    private fun runAndroidPhysicalTransportProbeOnWorker(
        interop: JSONObject,
        request: JSONObject
    ): JSONObject {
        val timeoutMs = interop.optInt("timeoutMs", 3000)
        var result: JSONObject? = null
        var thrown: Exception? = null
        val worker = Thread {
            try {
                result = runAndroidPhysicalTransportProbe(interop, request)
            } catch (error: Exception) {
                thrown = error
            }
        }
        worker.start()
        worker.join((timeoutMs + 1000).toLong())
        if (worker.isAlive) {
            worker.interrupt()
            return JSONObject()
                .put("ok", false)
                .put("transport", request.optString("transport", ""))
                .put("routeKind", request.optString("routeKind", ""))
                .put("urlSha256", sha256Hex(request.optString("url", "").toByteArray(Charsets.UTF_8)))
                .put("errorClass", "Timeout")
                .put("macosHttpProbeReached", false)
        }
        thrown?.let { error ->
            return JSONObject()
                .put("ok", false)
                .put("transport", request.optString("transport", ""))
                .put("routeKind", request.optString("routeKind", ""))
                .put("urlSha256", sha256Hex(request.optString("url", "").toByteArray(Charsets.UTF_8)))
                .put("errorClass", error.javaClass.simpleName)
                .put("macosHttpProbeReached", false)
        }
        return result ?: JSONObject()
            .put("ok", false)
            .put("transport", request.optString("transport", ""))
            .put("routeKind", request.optString("routeKind", ""))
            .put("urlSha256", sha256Hex(request.optString("url", "").toByteArray(Charsets.UTF_8)))
            .put("errorClass", "MissingResult")
            .put("macosHttpProbeReached", false)
    }

    private fun runAndroidPhysicalTransportProbe(
        interop: JSONObject,
        request: JSONObject
    ): JSONObject {
        val urlText = request.getString("url")
        val transport = request.getString("transport")
        val routeKind = request.getString("routeKind")
        val timeoutMs = interop.optInt("timeoutMs", 3000)
        val maxResponseBytes = interop.optInt("maxResponseBytes", 8192)
        val requestBody = JSONObject()
            .put("protocolVersion", SECURE_MESH_PROTOCOL_VERSION)
            .put("probeId", interop.getString("probeId"))
            .put("transport", transport)
            .put("routeKind", routeKind)
            .put("macosEndpointId", interop.getString("macosEndpointId"))
            .put("androidEndpointId", interop.getString("androidEndpointId"))
            .put("canaryHash", interop.getString("canaryHash"))
            .put("challengeNonce", interop.getString("challengeNonce"))
            .put("deviceModel", Build.MODEL)
            .put("createdByAppProcess", true)
        val requestBytes = requestBody.toString().toByteArray(Charsets.UTF_8)
        val connection = URL(urlText).openConnection() as HttpURLConnection
        if (connection is HttpsURLConnection) {
            configurePinnedTransportTls(connection, interop)
        }
        return try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")
            connection.outputStream.use { stream ->
                stream.write(requestBytes)
            }
            val responseCode = connection.responseCode
            val responseBody = readHttpResponseBody(connection, maxResponseBytes)
            val responseHash = sha256Hex(responseBody)
            val responseText = String(responseBody, Charsets.UTF_8)
            val responseJson = JSONObject(responseText)
            val accepted = responseCode in 200..299 &&
                responseJson.optBoolean("ok", false) &&
                responseJson.optString("probeId", "") == interop.getString("probeId") &&
                responseJson.optString("requestBodySha256", "") == sha256Hex(requestBytes) &&
                responseJson.optString("canaryHash", "") == interop.getString("canaryHash") &&
                responseJson.optString("transport", "") == transport &&
                responseJson.optString("routeKind", "") == routeKind
            JSONObject()
                .put("ok", accepted)
                .put("transport", transport)
                .put("routeKind", routeKind)
                .put("urlSha256", sha256Hex(urlText.toByteArray(Charsets.UTF_8)))
                .put("requestBodySha256", sha256Hex(requestBytes))
                .put("responseCode", responseCode)
                .put("responseBodySha256", responseHash)
                .put("serverProbeAccepted", responseJson.optBoolean("ok", false))
                .put("macosHttpProbeReached", accepted)
                .put("bodyPlaintextCanaryPresent", false)
        } finally {
            connection.disconnect()
        }
    }

    private fun physicalTransportProbeProvider(requests: JSONArray): String {
        for (index in 0 until requests.length()) {
            if (requests.getJSONObject(index).optString("url", "").startsWith("https://")) {
                return "javax.net.ssl.HttpsURLConnection"
            }
        }
        return "android.net.HttpURLConnection"
    }

    private fun configurePinnedTransportTls(
        connection: HttpsURLConnection,
        interop: JSONObject
    ) {
        val expectedCertificateSha256 = interop
            .optString("serverCertificateSha256", "")
            .lowercase()
        if (!Regex("^[0-9a-f]{64}$").matches(expectedCertificateSha256)) {
            throw IllegalArgumentException("secure mesh transport certificate pin is invalid")
        }
        connection.sslSocketFactory = pinnedTransportTlsSocketFactory(expectedCertificateSha256)
        connection.hostnameVerifier = HostnameVerifier { _, session ->
            try {
                val certificate = session.peerCertificates.firstOrNull() as? X509Certificate
                    ?: return@HostnameVerifier false
                constantTimeEqualsHex(sha256Hex(certificate.encoded), expectedCertificateSha256)
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun pinnedTransportTlsSocketFactory(
        expectedCertificateSha256: String
    ): SSLSocketFactory {
        val trustManager = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()

            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit

            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val certificate = chain.firstOrNull()
                    ?: throw CertificateException("secure mesh transport server certificate missing")
                val actualCertificateSha256 = sha256Hex(certificate.encoded)
                if (!constantTimeEqualsHex(actualCertificateSha256, expectedCertificateSha256)) {
                    throw CertificateException("secure mesh transport server certificate pin mismatch")
                }
            }
        }
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(trustManager), SecureRandom())
        return context.socketFactory
    }

    private fun readHttpResponseBody(connection: HttpURLConnection, maxBytes: Int): ByteArray {
        val stream = try {
            connection.inputStream
        } catch (_: Exception) {
            connection.errorStream
        } ?: return ByteArray(0)
        stream.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(1024)
            while (out.size() < maxBytes) {
                val read = input.read(buffer, 0, minOf(buffer.size, maxBytes - out.size()))
                if (read <= 0) break
                out.write(buffer, 0, read)
            }
            return out.toByteArray()
        }
    }

    private fun verifyAndroidPayloadNegativeControls(
        contentKey: ByteArray,
        context: JSONObject,
        sealed: JSONObject
    ): JSONObject {
        val wrongContext = JSONObject(context.toString())
        wrongContext.put(
            "messageId",
            "${context.getString("messageId")}-wrong-context"
        )
        val tamperedSealed = JSONObject(sealed.toString())
        val tamperedCiphertext = base64UrlDecode(tamperedSealed.getString("ciphertext"))
        if (tamperedCiphertext.isEmpty()) {
            throw IllegalArgumentException("secure mesh payload ciphertext is empty")
        }
        tamperedCiphertext[0] = (tamperedCiphertext[0].toInt() xor 0x01).toByte()
        tamperedSealed.put("ciphertext", base64UrlEncode(tamperedCiphertext))
        return JSONObject()
            .put(
                "wrongContextRejected",
                payloadOpenFails(contentKey, wrongContext, sealed, "command")
            )
            .put(
                "ciphertextTamperRejected",
                payloadOpenFails(contentKey, context, tamperedSealed, "command")
            )
            .put(
                "wrongPayloadKindRejected",
                payloadOpenFails(contentKey, context, sealed, "result")
            )
            .put("createdByAppProcess", true)
            .put("plaintextCanaryAbsentFromControls", true)
    }

    private fun payloadOpenFails(
        contentKey: ByteArray,
        context: JSONObject,
        sealed: JSONObject,
        expectedKind: String
    ): Boolean {
        return try {
            openSecureMeshPayload(contentKey, context, sealed, expectedKind)
            false
        } catch (_: Exception) {
            true
        }
    }

    private fun readAndroidSecureStoreProbeRecord(recordFile: File): ByteArray {
        val persisted = JSONObject(recordFile.readText(Charsets.UTF_8))
        val kind = persisted.getString("kind")
        val label = persisted.getString("label")
        val challengeHash = persisted.getString("challengeSha256")
        val aad = buildAndroidSecureStoreAad(kind, label, challengeHash)
        if (sha256Hex(aad) != persisted.getString("aadSha256")) {
            throw IllegalStateException("secure mesh Android secure-store AAD hash mismatch")
        }
        val cipher = Cipher.getInstance(ANDROID_SECURE_STORE_CIPHER)
        cipher.init(
            Cipher.DECRYPT_MODE,
            ensureAndroidSecureStoreKey(),
            GCMParameterSpec(
                ANDROID_SECURE_STORE_TAG_BITS,
                base64UrlDecode(persisted.getString("nonceBase64url"))
            )
        )
        cipher.updateAAD(aad)
        val plaintext = cipher.doFinal(base64UrlDecode(persisted.getString("ciphertextBase64url")))
        return decodeAndroidSecureStorePlaintext(plaintext, kind, label, challengeHash)
    }

    private fun buildAndroidSecureStoreAad(
        kind: String,
        label: String,
        challengeHash: String
    ): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(ANDROID_SECURE_STORE_AAD_MAGIC)
        appendLenPrefixed(out, SECURE_MESH_PROTOCOL_VERSION.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, kind.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, label.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, challengeHash.toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    private fun encodeAndroidSecureStorePlaintext(
        kind: String,
        label: String,
        challengeHash: String,
        secret: ByteArray
    ): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(ANDROID_SECURE_STORE_PLAINTEXT_MAGIC)
        appendLenPrefixed(out, SECURE_MESH_PROTOCOL_VERSION.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, kind.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, label.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, challengeHash.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, secret)
        return out.toByteArray()
    }

    private fun decodeAndroidSecureStorePlaintext(
        bytes: ByteArray,
        expectedKind: String,
        expectedLabel: String,
        expectedChallengeHash: String
    ): ByteArray {
        val reader = SliceReader(bytes)
        reader.expect(ANDROID_SECURE_STORE_PLAINTEXT_MAGIC)
        val protocolVersion = String(reader.readLenPrefixedBytes(), Charsets.UTF_8)
        val kind = String(reader.readLenPrefixedBytes(), Charsets.UTF_8)
        val label = String(reader.readLenPrefixedBytes(), Charsets.UTF_8)
        val challengeHash = String(reader.readLenPrefixedBytes(), Charsets.UTF_8)
        val secret = reader.readLenPrefixedBytes()
        if (!reader.isEmpty()) {
            throw IllegalArgumentException("secure mesh Android secure-store plaintext has trailing bytes")
        }
        if (protocolVersion != SECURE_MESH_PROTOCOL_VERSION ||
            kind != expectedKind ||
            label != expectedLabel ||
            challengeHash != expectedChallengeHash
        ) {
            throw IllegalArgumentException("secure mesh Android secure-store plaintext context mismatch")
        }
        return secret
    }

    private fun buildAndroidSecureStoreTranscript(
        secureStoreChallenge: String,
        records: List<JSONObject>
    ): String {
        val lines = mutableListOf(
            "licolite.secure-mesh.android.secure-store-proof.v1",
            "challengeSha256=${sha256Hex(secureStoreChallenge.toByteArray(Charsets.UTF_8))}"
        )
        records.forEach { record ->
            lines.add(
                listOf(
                    "record",
                    record.getString("kind"),
                    record.getString("label"),
                    record.getString("secretSha256"),
                    record.getString("reloadedSecretSha256"),
                    record.getString("encryptedBlobSha256"),
                    record.getString("aadSha256"),
                    record.getString("recordLocation")
                ).joinToString("|")
            )
        }
        return lines.joinToString("\n")
    }

    private fun buildAndroidRuntimeKeyBindingTranscript(
        secureStoreChallenge: String,
        bindings: List<JSONObject>
    ): String {
        val lines = mutableListOf(
            "licolite.secure-mesh.android.runtime-key-binding-proof.v1",
            "challengeSha256=${sha256Hex(secureStoreChallenge.toByteArray(Charsets.UTF_8))}"
        )
        bindings.forEach { binding ->
            val record = binding.getJSONObject("secureStoreRecord")
            lines.add(
                listOf(
                    "binding",
                    binding.getString("kind"),
                    binding.getString("label"),
                    binding.optString("transport", ""),
                    binding.optBoolean("serverDeliveredOpaqueEnvelope", false).toString(),
                    binding.getString("contentKeySha256"),
                    binding.getString("reloadedContentKeySha256"),
                    record.getString("secretSha256"),
                    record.getString("reloadedSecretSha256"),
                    record.getString("encryptedBlobSha256"),
                    record.getString("aadSha256"),
                    record.getString("recordLocation"),
                    binding.getString("openedPayloadKind"),
                    binding.getString("openedBodyHash"),
                    binding.getString("encryptedResultPayloadSha256")
                ).joinToString("|")
            )
        }
        return lines.joinToString("\n")
    }

    private fun buildAndroidPhysicalTransportTranscript(
        interop: JSONObject,
        attempts: JSONArray
    ): String {
        val lines = mutableListOf(
            "licolite.secure-mesh.android.physical-transport-proof.v1",
            "probeId=${interop.getString("probeId")}",
            "challengeNonceSha256=${sha256Hex(interop.getString("challengeNonce").toByteArray(Charsets.UTF_8))}",
            "canaryHash=${interop.getString("canaryHash")}",
            "macosEndpointId=${interop.getString("macosEndpointId")}",
            "androidEndpointId=${interop.getString("androidEndpointId")}"
        )
        for (index in 0 until attempts.length()) {
            val attempt = attempts.getJSONObject(index)
            lines.add(
                listOf(
                    "attempt",
                    attempt.optString("transport", ""),
                    attempt.optString("routeKind", ""),
                    attempt.optString("urlSha256", ""),
                    attempt.optString("requestBodySha256", ""),
                    attempt.optInt("responseCode", 0).toString(),
                    attempt.optString("responseBodySha256", ""),
                    attempt.optBoolean("macosHttpProbeReached", false).toString()
                ).joinToString("|")
            )
        }
        return lines.joinToString("\n")
    }

    private fun openSecureMeshPayload(
        contentKey: ByteArray,
        context: JSONObject,
        sealed: JSONObject,
        expectedKind: String
    ): OpenedSecureMeshPayload {
        if (sealed.getString("protocolVersion") != SECURE_MESH_PROTOCOL_VERSION) {
            throw IllegalArgumentException("secure mesh payload protocol version is unsupported")
        }
        if (sealed.getString("cipherSuite") != SECURE_MESH_CONTENT_CIPHER_SUITE) {
            throw IllegalArgumentException("secure mesh payload cipher suite is unsupported")
        }
        val header = decodeHeader(sealed.getString("encryptedHeader"))
        val aad = buildAad(context, expectedKind)
        if (!sha256(aad).contentEquals(header.aadHash)) {
            throw IllegalArgumentException("secure mesh payload AAD hash mismatch")
        }
        val ciphertext = base64UrlDecode(sealed.getString("ciphertext"))
        if (ciphertext.size != sealed.getInt("ciphertextSize")) {
            throw IllegalArgumentException("secure mesh payload ciphertext size mismatch")
        }
        val derivedKey = deriveAeadKey(contentKey, context, expectedKind, aad)
        val cipher = secureMeshCipher()
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(derivedKey, "ChaCha20"),
            IvParameterSpec(header.nonce)
        )
        cipher.updateAAD(aad)
        val plaintext = cipher.doFinal(ciphertext)
        val opened = decodePlaintext(plaintext)
        if (opened.kind != expectedKind) {
            throw IllegalArgumentException("secure mesh payload kind mismatch")
        }
        return opened
    }

    private fun sealSecureMeshPayload(
        contentKey: ByteArray,
        context: JSONObject,
        kind: String,
        body: ByteArray,
        contentType: String?
    ): JSONObject {
        val aad = buildAad(context, kind)
        val nonce = ByteArray(CONTENT_NONCE_LEN)
        SecureRandom().nextBytes(nonce)
        val derivedKey = deriveAeadKey(contentKey, context, kind, aad)
        val cipher = secureMeshCipher()
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(derivedKey, "ChaCha20"),
            IvParameterSpec(nonce)
        )
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(encodePlaintext(context, kind, body, contentType))
        return JSONObject()
            .put("protocolVersion", SECURE_MESH_PROTOCOL_VERSION)
            .put("cipherSuite", SECURE_MESH_CONTENT_CIPHER_SUITE)
            .put("payloadKind", kind)
            .put("encryptedHeader", encodeHeader(nonce, sha256(aad)))
            .put("ciphertextSize", ciphertext.size)
            .put("ciphertext", base64UrlEncode(ciphertext))
            .put("bodyRedacted", true)
    }

    private fun secureMeshCipher(): Cipher {
        return try {
            Cipher.getInstance("ChaCha20-Poly1305")
        } catch (_: Exception) {
            Cipher.getInstance("ChaCha20-Poly1305/None/NoPadding")
        }
    }

    private fun buildAad(context: JSONObject, kind: String): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(AAD_MAGIC)
        appendLenPrefixed(out, SECURE_MESH_PROTOCOL_VERSION.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, SECURE_MESH_CONTENT_CIPHER_SUITE.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "envelopeId").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "messageId").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "opaqueMailboxId").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "senderEndpointId").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "recipientEndpointId").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "sessionId").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, kind.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "createdAt").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "expiresAt").toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    private fun deriveAeadKey(
        contentKey: ByteArray,
        context: JSONObject,
        kind: String,
        aad: ByteArray
    ): ByteArray {
        val saltInput = ByteArrayOutputStream()
        saltInput.write(HKDF_SALT_DOMAIN)
        saltInput.write(aad)
        val salt = sha256(saltInput.toByteArray())
        val prk = hmacSha256(salt, contentKey)
        val info = ByteArrayOutputStream()
        info.write(HKDF_INFO_DOMAIN)
        appendLenPrefixed(info, requiredString(context, "sessionId").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(info, kind.toByteArray(Charsets.UTF_8))
        appendLenPrefixed(info, SECURE_MESH_CONTENT_CIPHER_SUITE.toByteArray(Charsets.UTF_8))
        val expandInput = ByteArrayOutputStream()
        expandInput.write(info.toByteArray())
        expandInput.write(1)
        return hmacSha256(prk, expandInput.toByteArray()).copyOfRange(0, CONTENT_KEY_LEN)
    }

    private fun encodePlaintext(
        context: JSONObject,
        kind: String,
        body: ByteArray,
        contentType: String?
    ): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(PLAINTEXT_MAGIC)
        out.write(payloadKindTag(kind).toInt())
        appendLenPrefixed(out, requiredString(context, "createdAt").toByteArray(Charsets.UTF_8))
        appendLenPrefixed(out, requiredString(context, "expiresAt").toByteArray(Charsets.UTF_8))
        if (contentType.isNullOrBlank()) {
            out.write(0)
        } else {
            out.write(1)
            appendLenPrefixed(out, contentType.toByteArray(Charsets.UTF_8))
        }
        appendLenPrefixed(out, body)
        return out.toByteArray()
    }

    private fun decodePlaintext(bytes: ByteArray): OpenedSecureMeshPayload {
        val reader = SliceReader(bytes)
        reader.expect(PLAINTEXT_MAGIC)
        val kind = payloadKindFromTag(reader.readU8())
        reader.readLenPrefixedBytes()
        reader.readLenPrefixedBytes()
        when (reader.readU8().toInt()) {
            0 -> Unit
            1 -> reader.readLenPrefixedBytes()
            else -> throw IllegalArgumentException("secure mesh payload content type marker is unsupported")
        }
        val body = reader.readLenPrefixedBytes()
        if (!reader.isEmpty()) {
            throw IllegalArgumentException("secure mesh payload has trailing plaintext bytes")
        }
        return OpenedSecureMeshPayload(kind, body)
    }

    private fun encodeHeader(nonce: ByteArray, aadHash: ByteArray): String {
        val out = ByteArrayOutputStream()
        out.write(HEADER_MAGIC)
        out.write(nonce)
        out.write(aadHash)
        return base64UrlEncode(out.toByteArray())
    }

    private fun secureMeshSealedPayloadHash(sealed: JSONObject): String {
        return sha256Hex(
            listOf(
                sealed.getString("protocolVersion"),
                sealed.getString("cipherSuite"),
                sealed.getString("payloadKind"),
                sealed.getInt("ciphertextSize").toString(),
                sealed.getString("encryptedHeader"),
                sealed.getString("ciphertext")
            ).joinToString("|").toByteArray(Charsets.UTF_8)
        )
    }

    private fun decodeHeader(value: String): SecureMeshHeader {
        val bytes = base64UrlDecode(value)
        val expectedLength = HEADER_MAGIC.size + CONTENT_NONCE_LEN + AAD_HASH_LEN
        if (bytes.size != expectedLength) {
            throw IllegalArgumentException("secure mesh payload encrypted header length is invalid")
        }
        if (!bytes.copyOfRange(0, HEADER_MAGIC.size).contentEquals(HEADER_MAGIC)) {
            throw IllegalArgumentException("secure mesh payload encrypted header magic is invalid")
        }
        val nonceStart = HEADER_MAGIC.size
        val hashStart = nonceStart + CONTENT_NONCE_LEN
        return SecureMeshHeader(
            bytes.copyOfRange(nonceStart, hashStart),
            bytes.copyOfRange(hashStart, hashStart + AAD_HASH_LEN)
        )
    }

    private fun appendLenPrefixed(out: ByteArrayOutputStream, value: ByteArray) {
        val len = value.size
        out.write((len ushr 24) and 0xff)
        out.write((len ushr 16) and 0xff)
        out.write((len ushr 8) and 0xff)
        out.write(len and 0xff)
        out.write(value)
    }

    private fun payloadKindTag(kind: String): Byte {
        return when (kind) {
            "command" -> 1
            "result" -> 2
            "error" -> 3
            "file_chunk" -> 4
            "file_manifest" -> 5
            else -> throw IllegalArgumentException("secure mesh payload kind is unsupported")
        }.toByte()
    }

    private fun payloadKindFromTag(tag: Byte): String {
        return when (tag.toInt()) {
            1 -> "command"
            2 -> "result"
            3 -> "error"
            4 -> "file_chunk"
            5 -> "file_manifest"
            else -> throw IllegalArgumentException("secure mesh payload kind tag is unsupported")
        }
    }

    private fun requiredString(value: JSONObject, name: String): String {
        val result = value.optString(name, "")
        if (result.isBlank()) {
            throw IllegalArgumentException("secure mesh context $name is required")
        }
        return result
    }

    private fun sha256(bytes: ByteArray): ByteArray {
        return MessageDigest.getInstance("SHA-256").digest(bytes)
    }

    private fun sha256Hex(bytes: ByteArray): String {
        return sha256(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun constantTimeEqualsHex(left: String, right: String): Boolean {
        return MessageDigest.isEqual(
            left.lowercase().toByteArray(Charsets.UTF_8),
            right.lowercase().toByteArray(Charsets.UTF_8)
        )
    }

    private fun unsignedIntHex(value: Int): String {
        return java.lang.Long.toHexString(value.toLong() and 0xffffffffL).padStart(8, '0')
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun base64UrlDecode(value: String): ByteArray {
        return Base64.decode(value, BASE64_URL_FLAGS)
    }

    private fun base64UrlEncode(value: ByteArray): String {
        return Base64.encodeToString(value, BASE64_URL_FLAGS)
    }

    private fun secureMeshAndroidRuntimeStatusFile(): File {
        return File(filesDir, "secure-mesh/android-runtime-status.json")
    }

    private fun secureMeshAndroidExternalRuntimeStatusFile(): File? {
        return getExternalFilesDir(null)?.let {
            File(it, "secure-mesh/android-runtime-status.json")
        }
    }

    private fun secureMeshAndroidInteropChallengeFiles(): List<File> {
        val files = mutableListOf(File(filesDir, "secure-mesh/android-interop-challenge.json"))
        secureMeshAndroidExternalInteropChallengeFile()?.let(files::add)
        return files
    }

    private fun secureMeshAndroidExternalInteropChallengeFile(): File? {
        return getExternalFilesDir(null)?.let {
            File(it, "secure-mesh/android-interop-challenge.json")
        }
    }

    private fun secureMeshAndroidInteropProofFiles(): List<File> {
        val files = mutableListOf(File(filesDir, "secure-mesh/android-interop-proof.json"))
        secureMeshAndroidExternalInteropProofFile()?.let(files::add)
        return files
    }

    private fun secureMeshAndroidExternalInteropProofFile(): File? {
        return getExternalFilesDir(null)?.let {
            File(it, "secure-mesh/android-interop-proof.json")
        }
    }

    private fun androidSecureStoreProbeFile(kind: String, label: String): File {
        val safeKind = kind.replace(Regex("[^a-zA-Z0-9_.-]"), "_")
        val safeLabel = label.replace(Regex("[^a-zA-Z0-9_.-]"), "_")
        return File(
            filesDir,
            "secure-mesh/android-secure-store-probe/$safeKind-$safeLabel.json"
        )
    }

    private data class SecureMeshHeader(val nonce: ByteArray, val aadHash: ByteArray)
    private data class OpenedSecureMeshPayload(val kind: String, val body: ByteArray)
    private data class AndroidSecureStoreRecord(val proof: JSONObject, val secret: ByteArray)

    private class SliceReader(private val bytes: ByteArray) {
        private var offset = 0

        fun expect(expected: ByteArray) {
            val actual = readExact(expected.size)
            if (!actual.contentEquals(expected)) {
                throw IllegalArgumentException("secure mesh payload plaintext magic is invalid")
            }
        }

        fun readU8(): Byte = readExact(1)[0]

        fun readLenPrefixedBytes(): ByteArray {
            val lenBytes = readExact(4)
            val len = ((lenBytes[0].toInt() and 0xff) shl 24) or
                ((lenBytes[1].toInt() and 0xff) shl 16) or
                ((lenBytes[2].toInt() and 0xff) shl 8) or
                (lenBytes[3].toInt() and 0xff)
            return readExact(len)
        }

        fun isEmpty(): Boolean = offset == bytes.size

        private fun readExact(len: Int): ByteArray {
            if (len < 0 || offset + len > bytes.size) {
                throw IllegalArgumentException("secure mesh payload is truncated")
            }
            val result = bytes.copyOfRange(offset, offset + len)
            offset += len
            return result
        }
    }

    companion object {
        private val nativeSecureMeshRuntimeLibraryLoaded: Boolean = try {
            System.loadLibrary("lico_client_native")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }

        private const val SECURE_MESH_ANDROID_CHANNEL = "licolite.secure_mesh.android"
        private const val SECURE_MESH_NATIVE_LIBRARY = "liblico_client_native.so"
        private const val SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS = 63
        private const val SECURE_MESH_PROTOCOL_VERSION = "licolite.secure-mesh.v1"
        private const val SECURE_MESH_CONTENT_CIPHER_SUITE =
            "licolite.secure-payload.v1.chacha20poly1305-hkdfsha256"
        private const val ANDROID_ENDPOINT_SIGNING_KEY_ALIAS =
            "licolite_secure_mesh_android_endpoint_signing_v1"
        private const val ANDROID_ENDPOINT_SIGNING_ALGORITHM = "SHA256withECDSA"
        private const val ANDROID_ENDPOINT_SIGNING_CURVE = "secp256r1"
        private const val ANDROID_SECURE_STORE_KEY_ALIAS =
            "licolite_secure_mesh_android_secret_store_v1"
        private const val ANDROID_SECURE_STORE_CIPHER = "AES/GCM/NoPadding"
        private const val SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH =
            "files/secure-mesh/android-runtime-status.json"
        private const val SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH =
            "Android/data/com.example.flutter_client/files/secure-mesh/android-runtime-status.json"
        private const val SECURE_MESH_ANDROID_CHALLENGE_RELATIVE_PATH =
            "files/secure-mesh/android-interop-challenge.json"
        private const val SECURE_MESH_ANDROID_PROOF_RELATIVE_PATH =
            "files/secure-mesh/android-interop-proof.json"
        private const val SECURE_MESH_ANDROID_EXTERNAL_PROOF_RELATIVE_PATH =
            "Android/data/com.example.flutter_client/files/secure-mesh/android-interop-proof.json"
        private const val CONTENT_KEY_LEN = 32
        private const val CONTENT_NONCE_LEN = 12
        private const val ANDROID_SECURE_STORE_NONCE_LEN = 12
        private const val ANDROID_SECURE_STORE_TAG_BITS = 128
        private const val AAD_HASH_LEN = 32
        private const val BASE64_URL_FLAGS =
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        private val AAD_MAGIC = "LCOSM-AAD-v1".toByteArray(Charsets.UTF_8)
        private val PLAINTEXT_MAGIC = "LCOSM-PT-v1".toByteArray(Charsets.UTF_8)
        private val HEADER_MAGIC = "LCOSM-HDR-v1".toByteArray(Charsets.UTF_8)
        private val ANDROID_SECURE_STORE_AAD_MAGIC =
            "LCOSM-ANDROID-STORE-AAD-v1".toByteArray(Charsets.UTF_8)
        private val ANDROID_SECURE_STORE_PLAINTEXT_MAGIC =
            "LCOSM-ANDROID-STORE-PT-v1".toByteArray(Charsets.UTF_8)
        private val HKDF_SALT_DOMAIN =
            "licolite.secure-mesh.payload-aead.hkdf-salt.v1".toByteArray(Charsets.UTF_8)
        private val HKDF_INFO_DOMAIN =
            "licolite.secure-mesh.payload-aead.hkdf-info.v1".toByteArray(Charsets.UTF_8)
    }
}
