package com.liko.arc

import android.content.Context
import android.os.Build
import android.security.keystore.StrongBoxUnavailableException
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.security.ProviderException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

class SecureMeshAndroidSecretStore(
    context: Context,
    private val filesDir: File,
    private val authorizationGrantIsActive: () -> Boolean = { false }
) {
    private sealed interface AndroidCustodySelection {
        val measurement: SecureMeshAndroidCapabilityMeasurement

        data class KeyStore(
            val secretKey: SecretKey,
            override val measurement: SecureMeshAndroidCapabilityMeasurement
        ) : AndroidCustodySelection

        data class MemoryOnly(
            override val measurement: SecureMeshAndroidCapabilityMeasurement
        ) : AndroidCustodySelection
    }

    private val capabilityProbe = SecureMeshAndroidCapabilityProbe(context.applicationContext)
    private val ephemeralSecretStore = SecureMeshAndroidEphemeralSecretStore()
    private val custodySelectionLock = Any()
    private val custodySelectionByAlias = mutableMapOf<String, AndroidCustodySelection>()

    fun requestTextWithMobileRelaySecretOverrides(
        requestText: String,
        action: String
    ): String {
        val request = JSONObject(requestText)
        val params = request.optJSONObject("params") ?: JSONObject()
        val removedCallerSuppliedOverrides =
            params.has("secretOverrides") || params.has("secretOverrideTransport")
        params.remove("secretOverrides")
        params.remove("secretOverrideTransport")
        request.put("params", params)

        if (!mobileRelayActionUsesSecretOverrides(action)) {
            return if (removedCallerSuppliedOverrides) request.toString() else requestText
        }

        captureMobileRelaySecretsFromParams(params)
        val overrides = mobileRelaySecretOverrides()
        if (overrides.length() == 0) {
            return if (removedCallerSuppliedOverrides) request.toString() else requestText
        }
        params.put("secretOverrides", overrides)
        params.put("secretOverrideTransport", MOBILE_RELAY_SECRET_OVERRIDE_TRANSPORT)
        params.put("secretOverrideBackend", "android-keystore")
        return request.toString()
    }

    fun captureMobileRelaySecretsFromNativeResponse(response: JSONObject) {
        val mobileTokenCaptured = persistResponseSecret(response, "mobileToken", "mobileToken")
        persistResponseSecret(response, "pcToken", "pcToken")
        captureTopLevelMobileRelayE2eeSecrets(response)
        captureMobileRelayE2eeSecrets(response.optJSONObject("mobileRelayE2ee"))
        capturePairingInviteSecret(response.optJSONObject("mobileRelayPairingInvite"))
        response.optJSONObject("config")?.let { config ->
            captureMobileRelayConfigSecrets(config)
        }
        repairMobileRelayPairingStateFromResponse(response, mobileTokenCaptured)
    }

    fun redactPersistedMobileRelaySecrets() {
        val config = readMobileRelayConfig() ?: return
        var changed = false
        changed = persistTopLevelSecret(config, "pcToken", "pcToken") || changed
        changed = persistTopLevelSecret(config, "mobileToken", "mobileToken") || changed

        val e2ee = config.optJSONObject("mobileRelayE2ee")
        if (e2ee != null) {
            changed = persistNestedSecret(
                e2ee,
                "privateKeyBase64url",
                "privateKeyBase64url"
            ) || changed
            changed = persistNestedSecret(
                e2ee,
                "signingKeyBase64url",
                "signingKeyBase64url"
            ) || changed
            changed = persistNestedSecret(
                e2ee,
                "signedPrekeyPrivateKeyBase64url",
                "signedPrekeyPrivateKeyBase64url"
            ) || changed
            changed = persistNestedSecret(
                e2ee,
                "oneTimePrekeyPrivateKeyBase64url",
                "oneTimePrekeyPrivateKeyBase64url"
            ) || changed
            changed = persistNestedSecret(
                e2ee,
                "pairingSecretBase64url",
                "pairingSecretBase64url"
            ) || changed
            e2ee.put("privateKeyMaterial", "redacted")
            e2ee.put("signingKeyMaterial", "redacted")
            e2ee.put("signedPrekeyPrivateKeyMaterial", "redacted")
            e2ee.put("oneTimePrekeyPrivateKeyMaterial", "redacted")
            e2ee.put("pairingSecretMaterial", "redacted")
            e2ee.put(
                "secretStorageStatus",
                selectedMobileRelayCustody().measurement.custodyStrategy.wireName
            )
            changed = true
        }

        val invite = config.optJSONObject("mobileRelayPairingInvite")
        if (invite != null) {
            changed = persistNestedSecret(
                invite,
                "e2eePairingSecret",
                "pairingSecretBase64url"
            ) || changed
            invite.put("e2eePairingSecretMaterial", "redacted")
            changed = true
        }

        val devices = config.optJSONArray("pairedDevices")
        if (devices != null) {
            for (index in 0 until devices.length()) {
                val device = devices.optJSONObject(index) ?: continue
                val secret = device.optString("mobileToken", "")
                if (secretTextPresent(secret)) {
                    writeMobileRelaySecret(secret, pairedDeviceTokenAccount(device))
                    device.put("mobileToken", "")
                    device.put("credentialPresent", true)
                    changed = true
                }
            }
        }

        if (changed) {
            config.put(
                "secretStorageStatus",
                JSONObject()
                    .put("tokenMaterial", "redacted")
                    .put("mobileRelayPrivateKeyMaterial", "redacted")
                    .put(
                        "persistentBackend",
                        if (selectedMobileRelayCustody().measurement.persistentCustodySelected) {
                            "android_keystore_shared_rust_secret_store_handle_contract"
                        } else {
                            "none_memory_only_ephemeral"
                        }
                    )
                    .put("secretStoreContract", ANDROID_MOBILE_RELAY_SECRET_STORE_CONTRACT)
                    .put("secretStoreNamespace", MOBILE_RELAY_SECRET_STORE_NAMESPACE)
                    .put(
                        "restartSemantics",
                        selectedMobileRelayCustody().measurement.redactedMeasurements()[
                            "restartSemantics"
                        ]
                    )
            )
            writeMobileRelayConfig(config)
        }
    }

    fun mobileRelaySecretStoreStatus(): Map<String, Any?> {
        val config = try {
            readMobileRelayConfig()
        } catch (_: Exception) {
            null
        }
        val selection = selectedMobileRelayCustody()
        val measurement = selection.measurement
        return mapOf(
            "provider" to if (measurement.persistentCustodySelected) {
                "AndroidKeyStore"
            } else {
                "process-memory"
            },
            "recordLocation" to if (measurement.persistentCustodySelected) {
                "app_private_files"
            } else {
                "process_memory_only"
            },
            "cipher" to ANDROID_SECURE_STORE_CIPHER,
            "ffiBoundary" to "jni",
            "secretTransport" to MOBILE_RELAY_SECRET_OVERRIDE_TRANSPORT,
            "secretStoreBackend" to if (measurement.persistentCustodySelected) {
                "android-keystore"
            } else {
                "memory-only-ephemeral"
            },
            "secretStoreContract" to ANDROID_MOBILE_RELAY_SECRET_STORE_CONTRACT,
            "secretStoreAccountPrefix" to MOBILE_RELAY_SECRET_STORE_ACCOUNT_PREFIX,
            "secretStoreNamespace" to MOBILE_RELAY_SECRET_STORE_NAMESPACE,
            "secretStoreHandlePattern" to "accountPrefix:namespace:key",
            "sharedRustSecretStoreHandleContract" to true,
            "applicationAuthorizationGrantRequired" to
                selectedUserAuthenticationRequired(measurement),
            "rawJsonSecretOverridesUsed" to false,
            "rawJsonSecretOverridesProvenAbsent" to true,
            "secretClasses" to listOf(
                "endpointPrivateKey",
                "signingKey",
                "signedPrekeyPrivateKey",
                "oneTimePrekeyPrivateKey",
                "pairingSecret",
                "pairwiseSessionSnapshot"
            ),
            "portableConfigRedacted" to !mobileRelayConfigHasPlaintextSecrets(config),
            "keyMaterialExported" to (measurement.keyMaterialNonExportable == false),
            "capabilityProbe" to measurement.capabilityProbe(),
            "measurements" to measurement.redactedMeasurements(),
            "implementationStatus" to
                "adaptive_android_custody_shared_capability_evaluation"
        )
    }

    fun secureMeshAndroidCapabilityProbeJson(): String {
        return JSONObject(selectedMobileRelayCustody().measurement.capabilityProbe()).toString()
    }

    fun secureMeshAndroidSelectedCustodyBackend(): String {
        return custodyBackend(selectedMobileRelayCustody())
    }

    fun secureMeshAndroidGeneralCustodyBackend(): String {
        return custodyBackend(selectedGeneralCustody())
    }

    fun userAuthenticationSelected(): Boolean {
        return selectedUserAuthenticationRequired(
            selectedMobileRelayCustody().measurement
        )
    }

    fun generalUserAuthenticationSelected(): Boolean {
        return selectedUserAuthenticationRequired(selectedGeneralCustody().measurement)
    }

    fun secureMeshAndroidSecretStoreSet(
        namespace: String,
        key: String,
        secret: String
    ): Boolean {
        return try {
            if (!secretTextPresent(secret)) {
                return false
            }
            val account = secureMeshAndroidSecretStoreAccount(namespace, key)
            val recordFile = androidMobileRelaySecretFile(account)
            val selection = selectedMobileRelayCustody()
            val kind = ANDROID_MOBILE_RELAY_SECRET_KIND
            val label = androidMobileRelaySecretLabel(account)
            val challenge = androidMobileRelaySecretChallenge(account)
            val secretBytes = secret.toByteArray(Charsets.UTF_8)
            try {
                when (selection) {
                    is AndroidCustodySelection.KeyStore -> {
                        requireSelectedUserAuthorization(selection)
                        writeAndroidSecureStoreRecordToFile(
                            kind,
                            label,
                            challenge,
                            secretBytes,
                            recordFile,
                            selection.secretKey
                        )
                    }
                    is AndroidCustodySelection.MemoryOnly -> {
                        deleteRecordFile(recordFile)
                        ephemeralSecretStore.put(
                            ephemeralRecordKey(recordFile, kind, label, challenge),
                            secretBytes
                        )
                    }
                }
            } finally {
                secretBytes.fill(0)
            }
            true
        } catch (_: Exception) {
            Log.w(SECURE_MESH_ADB_TAG, "android secret-store set failed")
            false
        }
    }

    fun secureMeshAndroidSecretStoreGet(namespace: String, key: String): String? {
        return try {
            val account = secureMeshAndroidSecretStoreAccount(namespace, key)
            readMobileRelaySecretFromStoredAccount(account)
        } catch (_: Exception) {
            Log.w(SECURE_MESH_ADB_TAG, "android secret-store get failed")
            null
        }
    }

    fun secureMeshAndroidSecretStoreDelete(namespace: String, key: String): Boolean {
        return try {
            val account = secureMeshAndroidSecretStoreAccount(namespace, key)
            val secretFile = androidMobileRelaySecretFile(account)
            val selection = selectedMobileRelayCustody()
            requireSelectedUserAuthorization(selection)
            val kind = ANDROID_MOBILE_RELAY_SECRET_KIND
            val label = androidMobileRelaySecretLabel(account)
            val challenge = androidMobileRelaySecretChallenge(account)
            when (selection) {
                is AndroidCustodySelection.KeyStore -> {
                    if (!secretFile.exists()) {
                        true
                    } else {
                        val verified = readAndroidSecureStoreRecordFromFile(
                            secretFile,
                            selection.secretKey,
                            kind,
                            label,
                            challenge
                        )
                        verified.fill(0)
                        secretFile.delete() && !secretFile.exists()
                    }
                }
                is AndroidCustodySelection.MemoryOnly -> {
                    val deleted = ephemeralSecretStore.delete(
                        ephemeralRecordKey(secretFile, kind, label, challenge)
                    )
                    deleteRecordFile(secretFile)
                    deleted || !secretFile.exists()
                }
            }
        } catch (_: Exception) {
            Log.w(SECURE_MESH_ADB_TAG, "android secret-store delete failed")
            false
        }
    }

    private fun pruneMobileRelayPortableConfigAfterSecretStoreReset() {
        val config = readMobileRelayConfig() ?: return
        config.remove("pcToken")
        config.remove("mobileToken")
        config.remove("mobileRelayPairingInvite")
        config.put("pairingId", "")
        val e2ee = config.optJSONObject("mobileRelayE2ee")
        if (e2ee != null) {
            e2ee.remove("privateKeyBase64url")
            e2ee.remove("signingKeyBase64url")
            e2ee.remove("signedPrekeyPrivateKeyBase64url")
            e2ee.remove("oneTimePrekeyPrivateKeyBase64url")
            e2ee.remove("pairingSecretBase64url")
            e2ee.put("privateKeyMaterial", "redacted")
            e2ee.put("signingKeyMaterial", "redacted")
            e2ee.put("signedPrekeyPrivateKeyMaterial", "redacted")
            e2ee.put("oneTimePrekeyPrivateKeyMaterial", "redacted")
            e2ee.put("pairingSecretMaterial", "redacted")
            e2ee.put("secretStorageStatus", "selected_custody_reset_requires_re_pair_rekey")
        }
        config.put("pairedDevices", JSONArray())
        writeMobileRelayConfig(config)
    }

    private fun mobileRelayActionUsesSecretOverrides(action: String): Boolean {
        return action != "mobile.relay.config.get" && action.startsWith("mobile.relay.")
    }

    private fun captureMobileRelaySecretsFromParams(params: JSONObject) {
        persistParamSecret(params, "pcToken", "pcToken")
        persistParamSecret(params, "mobileToken", "mobileToken")
        captureMobileRelayE2eeSecrets(params.optJSONObject("mobileRelayE2ee"))
        captureMobileRelayE2eeSecrets(params.optJSONObject("e2ee"))
        capturePairingInviteSecret(jsonObjectParam(params, "invite"))
        capturePairingInviteSecret(jsonObjectParam(params, "pairingInvite"))
        capturePairingInviteSecret(jsonObjectParam(params, "inviteJson"))
        persistParamSecret(params, "e2eePairingSecret", "pairingSecretBase64url")
        persistParamSecret(params, "pairingSecret", "pairingSecretBase64url")
    }

    private fun captureMobileRelayE2eeSecrets(e2ee: JSONObject?) {
        if (e2ee == null) {
            return
        }
        persistNestedSecret(e2ee, "privateKeyBase64url", "privateKeyBase64url")
        persistNestedSecret(e2ee, "signingKeyBase64url", "signingKeyBase64url")
        persistNestedSecret(
            e2ee,
            "signedPrekeyPrivateKeyBase64url",
            "signedPrekeyPrivateKeyBase64url"
        )
        persistNestedSecret(
            e2ee,
            "oneTimePrekeyPrivateKeyBase64url",
            "oneTimePrekeyPrivateKeyBase64url"
        )
        persistNestedSecret(e2ee, "pairingSecretBase64url", "pairingSecretBase64url")
        if (!e2ee.has("privateKeyBase64url")) {
            e2ee.put("privateKeyMaterial", "redacted")
        }
        if (!e2ee.has("signingKeyBase64url")) {
            e2ee.put("signingKeyMaterial", "redacted")
        }
        if (!e2ee.has("signedPrekeyPrivateKeyBase64url")) {
            e2ee.put("signedPrekeyPrivateKeyMaterial", "redacted")
        }
        if (!e2ee.has("oneTimePrekeyPrivateKeyBase64url")) {
            e2ee.put("oneTimePrekeyPrivateKeyMaterial", "redacted")
        }
        if (!e2ee.has("pairingSecretBase64url")) {
            e2ee.put("pairingSecretMaterial", "redacted")
        }
    }

    private fun capturePairingInviteSecret(invite: JSONObject?) {
        if (invite == null) {
            return
        }
        persistNestedSecret(invite, "e2eePairingSecret", "pairingSecretBase64url")
        if (!invite.has("e2eePairingSecret")) {
            invite.put("e2eePairingSecretMaterial", "redacted")
        }
    }

    private fun captureTopLevelMobileRelayE2eeSecrets(container: JSONObject) {
        var captured = false
        captured = persistResponseSecret(
            container,
            "privateKeyBase64url",
            "privateKeyBase64url"
        ) || captured
        captured = persistResponseSecret(
            container,
            "signingKeyBase64url",
            "signingKeyBase64url"
        ) || captured
        captured = persistResponseSecret(
            container,
            "signedPrekeyPrivateKeyBase64url",
            "signedPrekeyPrivateKeyBase64url"
        ) || captured
        captured = persistResponseSecret(
            container,
            "oneTimePrekeyPrivateKeyBase64url",
            "oneTimePrekeyPrivateKeyBase64url"
        ) || captured
        captured = persistResponseSecret(
            container,
            "pairingSecretBase64url",
            "pairingSecretBase64url"
        ) || captured
        if (captured) {
            container.put(
                "mobileRelayE2eeSecretStorageStatus",
                "android_keystore_shared_rust_secret_store_handle_contract"
            )
        }
    }

    private fun captureMobileRelayConfigSecrets(config: JSONObject) {
        persistTopLevelSecret(config, "pcToken", "pcToken")
        persistTopLevelSecret(config, "mobileToken", "mobileToken")
        captureMobileRelayE2eeSecrets(config.optJSONObject("mobileRelayE2ee"))
        capturePairingInviteSecret(config.optJSONObject("mobileRelayPairingInvite"))
        val devices = config.optJSONArray("pairedDevices") ?: return
        for (index in 0 until devices.length()) {
            val device = devices.optJSONObject(index) ?: continue
            val secret = device.optString("mobileToken", "")
            if (secretTextPresent(secret)) {
                writeMobileRelaySecret(secret, pairedDeviceTokenAccount(device))
                device.put("mobileToken", "")
                device.put("credentialPresent", true)
            }
        }
    }

    private fun persistResponseSecret(
        container: JSONObject,
        key: String,
        account: String
    ): Boolean {
        val secret = container.optString(key, "")
        if (!secretTextPresent(secret)) {
            return false
        }
        writeMobileRelaySecret(secret, account)
        container.put(key, "")
        container.put("${key}Present", true)
        return true
    }

    private fun repairMobileRelayPairingStateFromResponse(
        response: JSONObject,
        mobileTokenCaptured: Boolean
    ) {
        val pairing = response.optJSONObject("pairing")
        val pairingId = firstNonBlank(
            response.optString("pairingId", ""),
            pairing?.optString("pairingId", "") ?: ""
        )
        val paired = pairing?.optString("status", "") == "paired" ||
            response.optBoolean("paired", false) ||
            mobileTokenCaptured
        if (pairingId.isBlank() && !paired && !mobileTokenCaptured) {
            return
        }
        val config = readMobileRelayConfig() ?: JSONObject()
        var changed = false
        if (pairingId.isNotBlank() && config.optString("pairingId", "").isBlank()) {
            config.put("pairingId", pairingId)
            changed = true
        }
        if (mobileTokenCaptured && !config.optBoolean("mobileTokenPresent", false)) {
            config.put("mobileTokenPresent", true)
            changed = true
        }
        if (paired) {
            if (!config.optBoolean("paired", false)) {
                config.put("paired", true)
                changed = true
            }
            if (!config.optBoolean("relayEnabled", false)) {
                config.put("relayEnabled", true)
                changed = true
            }
        }
        if (changed) {
            writeMobileRelayConfig(config)
        }
    }

    private fun persistParamSecret(params: JSONObject, key: String, account: String) {
        val secret = params.optString(key, "")
        if (!secretTextPresent(secret)) {
            return
        }
        writeMobileRelaySecret(secret, account)
        params.remove(key)
        params.put("${key}Present", true)
    }

    private fun persistNestedSecret(value: JSONObject, key: String, account: String): Boolean {
        val secret = value.optString(key, "")
        if (!secretTextPresent(secret)) {
            return false
        }
        writeMobileRelaySecret(secret, account)
        value.remove(key)
        return true
    }

    private fun mobileRelaySecretOverrides(): JSONObject {
        val overrides = JSONObject()
        overrides.put(
            "mobileRelayE2eeSecretStore",
            JSONObject()
                .put("contract", ANDROID_MOBILE_RELAY_SECRET_STORE_CONTRACT)
                .put("namespace", MOBILE_RELAY_SECRET_STORE_NAMESPACE)
                .put("accountPrefix", MOBILE_RELAY_SECRET_STORE_ACCOUNT_PREFIX)
                .put("rawJsonSecretOverridesUsed", false)
        )
        return overrides
    }

    private fun persistTopLevelSecret(config: JSONObject, key: String, account: String): Boolean {
        val secret = config.optString(key, "")
        if (!secretTextPresent(secret)) {
            return false
        }
        writeMobileRelaySecret(secret, account)
        config.put(key, "")
        config.put("${key}Present", true)
        return true
    }

    private fun mobileRelayConfigHasPlaintextSecrets(config: JSONObject?): Boolean {
        if (config == null) {
            return false
        }
        if (secretTextPresent(config.opt("pcToken")) ||
            secretTextPresent(config.opt("mobileToken"))
        ) {
            return true
        }
        val e2ee = config.optJSONObject("mobileRelayE2ee")
        if (e2ee != null &&
            (secretTextPresent(e2ee.opt("privateKeyBase64url")) ||
                secretTextPresent(e2ee.opt("signingKeyBase64url")) ||
                secretTextPresent(e2ee.opt("signedPrekeyPrivateKeyBase64url")) ||
                secretTextPresent(e2ee.opt("oneTimePrekeyPrivateKeyBase64url")) ||
                secretTextPresent(e2ee.opt("pairingSecretBase64url")))
        ) {
            return true
        }
        val invite = config.optJSONObject("mobileRelayPairingInvite")
        if (invite != null && secretTextPresent(invite.opt("e2eePairingSecret"))) {
            return true
        }
        val devices = config.optJSONArray("pairedDevices")
        if (devices != null) {
            for (index in 0 until devices.length()) {
                if (secretTextPresent(devices.optJSONObject(index)?.opt("mobileToken"))) {
                    return true
                }
            }
        }
        return false
    }

    private fun readMobileRelayConfig(): JSONObject? {
        val file = mobileRelayConfigFile()
        if (!file.exists()) {
            return null
        }
        return JSONObject(file.readText(Charsets.UTF_8))
    }

    private fun writeMobileRelayConfig(config: JSONObject) {
        val file = mobileRelayConfigFile()
        file.parentFile?.mkdirs()
        file.writeText(config.toString(2), Charsets.UTF_8)
    }

    private fun mobileRelayConfigFile(): File {
        return File(filesDir, "portable-data/lico-client/mobile-relay/config.json")
    }

    private fun writeMobileRelaySecret(secret: String, account: String) {
        if (!secretTextPresent(secret)) {
            return
        }
        val handleAccount = mobileRelaySecretStoreAccount(account)
        val recordFile = androidMobileRelaySecretFile(handleAccount)
        val selection = selectedMobileRelayCustody()
        val kind = ANDROID_MOBILE_RELAY_SECRET_KIND
        val label = androidMobileRelaySecretLabel(handleAccount)
        val challenge = androidMobileRelaySecretChallenge(handleAccount)
        val secretBytes = secret.toByteArray(Charsets.UTF_8)
        try {
            when (selection) {
                is AndroidCustodySelection.KeyStore -> {
                    requireSelectedUserAuthorization(selection)
                    writeAndroidSecureStoreRecordToFile(
                        kind,
                        label,
                        challenge,
                        secretBytes,
                        recordFile,
                        selection.secretKey
                    )
                }
                is AndroidCustodySelection.MemoryOnly -> {
                    deleteRecordFile(recordFile)
                    ephemeralSecretStore.put(
                        ephemeralRecordKey(recordFile, kind, label, challenge),
                        secretBytes
                    )
                }
            }
        } finally {
            secretBytes.fill(0)
        }
    }

    private fun readMobileRelaySecret(account: String): String? {
        readMobileRelaySecretFromStoredAccount(mobileRelaySecretStoreAccount(account))?.let {
            return it
        }
        return null
    }

    private fun readMobileRelaySecretFromStoredAccount(storedAccount: String): String? {
        val file = androidMobileRelaySecretFile(storedAccount)
        val selection = selectedMobileRelayCustody()
        val kind = ANDROID_MOBILE_RELAY_SECRET_KIND
        val label = androidMobileRelaySecretLabel(storedAccount)
        val challenge = androidMobileRelaySecretChallenge(storedAccount)
        requireSelectedUserAuthorization(selection)
        val secretBytes = when (selection) {
            is AndroidCustodySelection.KeyStore -> {
                if (!file.exists()) {
                    return null
                }
                readAndroidSecureStoreRecordFromFile(
                    file,
                    selection.secretKey,
                    kind,
                    label,
                    challenge
                )
            }
            is AndroidCustodySelection.MemoryOnly ->
                ephemeralSecretStore.get(
                    ephemeralRecordKey(file, kind, label, challenge)
                ) ?: return null
        }
        val secret = String(secretBytes, Charsets.UTF_8).trim()
        secretBytes.fill(0)
        return if (secretTextPresent(secret)) secret else null
    }

    private fun androidMobileRelaySecretFile(account: String): File {
        return File(
            filesDir,
            "secure-mesh/android-mobile-relay-secrets/${safeAndroidRecordId(account)}.json"
        )
    }

    private fun androidMobileRelaySecretLabel(account: String): String {
        return "mobile-relay:${safeAndroidRecordId(account)}"
    }

    private fun androidMobileRelaySecretChallenge(account: String): String {
        return "licolite.mobile-relay.secret-store.v1:$account"
    }

    private fun pairedDeviceTokenAccount(device: JSONObject): String {
        val suffix = firstNonBlank(
            device.optString("pairingId", ""),
            device.optString("id", ""),
            "unknown"
        )
        return "pairedDevices.${sha256Hex(suffix.toByteArray(Charsets.UTF_8))}.mobileToken"
    }

    private fun mobileRelaySecretStoreAccount(secretStoreKey: String): String {
        val key = secretStoreKey.trim()
        require(key.isNotEmpty() && !key.contains(":")) {
            "secure mesh mobile relay secret-store key is invalid"
        }
        return "$MOBILE_RELAY_SECRET_STORE_ACCOUNT_PREFIX:$MOBILE_RELAY_SECRET_STORE_NAMESPACE:$key"
    }

    private fun secureMeshAndroidSecretStoreAccount(namespace: String, key: String): String {
        val normalizedNamespace = namespace.trim()
        val normalizedKey = key.trim()
        require(normalizedNamespace.isNotEmpty() &&
            !normalizedNamespace.contains("/") &&
            !normalizedNamespace.contains("\u0000")
        ) {
            "secure mesh Android secret-store namespace is invalid"
        }
        require(normalizedKey.isNotEmpty() &&
            !normalizedKey.contains(":") &&
            !normalizedKey.contains("/") &&
            !normalizedKey.contains("\u0000")
        ) {
            "secure mesh Android secret-store key is invalid"
        }
        if (normalizedNamespace.startsWith("$MOBILE_RELAY_SECRET_STORE_ACCOUNT_PREFIX:")) {
            return "$normalizedNamespace:$normalizedKey"
        }
        return "$MOBILE_RELAY_SECRET_STORE_ACCOUNT_PREFIX:$normalizedNamespace:$normalizedKey"
    }

    private fun mobileRelaySecretStoreClass(secretStoreKey: String): String {
        return when (secretStoreKey) {
            "privateKeyBase64url" -> "endpointPrivateKey"
            "signingKeyBase64url" -> "signingKey"
            "signedPrekeyPrivateKeyBase64url" -> "signedPrekeyPrivateKey"
            "oneTimePrekeyPrivateKeyBase64url" -> "oneTimePrekeyPrivateKey"
            "pairingSecretBase64url" -> "pairingSecret"
            "pcToken", "mobileToken" -> "relayToken"
            else -> if (secretStoreKey.startsWith("pairedDevices.")) {
                "pairedDeviceToken"
            } else {
                "mobileRelaySecret"
            }
        }
    }

    private fun secureMeshAndroidSecretStoreClass(namespace: String, key: String): String {
        return if (namespace.startsWith("pairwiseSessionSnapshot:")) {
            "pairwiseSessionSnapshot"
        } else {
            mobileRelaySecretStoreClass(key)
        }
    }

    private fun selectedMobileRelayCustody(): AndroidCustodySelection {
        return selectedCustody(
            ANDROID_MOBILE_RELAY_SECRET_STORE_KEY_ALIAS,
            ::resetAndroidMobileRelaySecretRecordsAfterKeyPolicyMigration
        )
    }

    private fun selectedGeneralCustody(): AndroidCustodySelection {
        return selectedCustody(
            ANDROID_SECURE_STORE_KEY_ALIAS,
            ::resetAndroidSecureStoreRecordsAfterKeyPolicyMigration
        )
    }

    private fun selectedCustody(
        alias: String,
        resetRecords: () -> Unit
    ): AndroidCustodySelection {
        synchronized(custodySelectionLock) {
            custodySelectionByAlias[alias]?.let { return it }
            return selectCustody(alias, resetRecords).also {
                custodySelectionByAlias[alias] = it
            }
        }
    }

    private fun selectCustody(
        alias: String,
        resetRecords: () -> Unit
    ): AndroidCustodySelection {
        val platform = capabilityProbe.platformCapabilities()
        if (!platform.keyStoreAvailable) {
            resetRecords()
            return AndroidCustodySelection.MemoryOnly(
                capabilityProbe.memoryOnly(
                    platform,
                    "android_keystore_unavailable",
                    attemptCount = 0
                )
            )
        }

        val keyStore = try {
            KeyStore.getInstance("AndroidKeyStore").also { it.load(null) }
        } catch (_: Exception) {
            resetRecords()
            return AndroidCustodySelection.MemoryOnly(
                capabilityProbe.memoryOnly(
                    platform,
                    "android_keystore_unavailable",
                    attemptCount = 0
                )
            )
        }
        val existing = existingAndroidSecretKey(keyStore, alias)
        if (existing != null) {
            val measurement = capabilityProbe.inspectSelectedKey(
                existing,
                platform,
                selectedCandidate = null,
                attemptCount = 0
            )
            val authenticationStillAvailable =
                measurement.userAuthenticationRequired != true ||
                    platform.deviceCredentialAvailable ||
                    platform.strongBiometricAvailable
            if (authenticationStillAvailable &&
                capabilityProbe.keyIsSafeForPersistentCustody(existing, measurement)
            ) {
                return AndroidCustodySelection.KeyStore(existing, measurement)
            }
            keyStore.deleteEntry(alias)
            resetRecords()
        }

        val candidates = SecureMeshAndroidKeyPolicyStrategy.candidates(
            platform.policyEnvironment(),
            ANDROID_KEYSTORE_USER_AUTH_VALIDITY_SECONDS
        )
        var attemptedCandidateCount = 0
        val selection = SecureMeshAndroidKeyPolicyStrategy.select(candidates) { candidate ->
            attemptedCandidateCount += 1
            try {
                if (keyStore.containsAlias(alias)) {
                    keyStore.deleteEntry(alias)
                }
                val generated = generateAndroidSecretKey(alias, candidate)
                val measurement = capabilityProbe.inspectSelectedKey(
                    generated,
                    platform,
                    selectedCandidate = candidate,
                    attemptCount = 0
                )
                if (!capabilityProbe.keyIsSafeForPersistentCustody(generated, measurement)) {
                    if (keyStore.containsAlias(alias)) {
                        keyStore.deleteEntry(alias)
                    }
                    SecureMeshAndroidKeyAttempt.Failure(
                        SecureMeshAndroidKeyAttemptFailure.POLICY_INCOMPATIBLE
                    )
                } else {
                    SecureMeshAndroidKeyAttempt.Success(generated to measurement)
                }
            } catch (error: Exception) {
                try {
                    if (keyStore.containsAlias(alias)) {
                        keyStore.deleteEntry(alias)
                    }
                } catch (_: Exception) {
                }
                SecureMeshAndroidKeyAttempt.Failure(
                    if (strongBoxUnavailable(error)) {
                        SecureMeshAndroidKeyAttemptFailure.STRONGBOX_UNAVAILABLE
                    } else {
                        SecureMeshAndroidKeyAttemptFailure.POLICY_INCOMPATIBLE
                    }
                )
            }
        }

        if (selection != null) {
            val (key, measured) = selection.value
            val measurement = measured.copy(
                strongBoxRequested = selection.candidate.requestStrongBox,
                keyGenerationAttemptCount = selection.attemptCount
            )
            return AndroidCustodySelection.KeyStore(key, measurement)
        }

        resetRecords()
        return AndroidCustodySelection.MemoryOnly(
            capabilityProbe.memoryOnly(
                platform,
                "android_keystore_safe_key_generation_failed",
                attemptCount = attemptedCandidateCount
            )
        )
    }

    private fun generateAndroidSecretKey(
        alias: String,
        candidate: SecureMeshAndroidKeyPolicyCandidate
    ): SecretKey {
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        val builder = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setKeySize(256)

        if (candidate.requestStrongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        if (candidate.requestUnlockedDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setUnlockedDeviceRequired(true)
        }
        if (candidate.requestsUserAuthentication) {
            builder.setUserAuthenticationRequired(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                builder.setInvalidatedByBiometricEnrollment(
                    candidate.invalidateOnBiometricEnrollmentChange
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val authenticators = when (candidate.authenticationMode) {
                    SecureMeshAndroidAuthenticationMode.DEVICE_CREDENTIAL ->
                        KeyProperties.AUTH_DEVICE_CREDENTIAL
                    SecureMeshAndroidAuthenticationMode.STRONG_BIOMETRIC ->
                        KeyProperties.AUTH_BIOMETRIC_STRONG
                    SecureMeshAndroidAuthenticationMode.DEVICE_CREDENTIAL_OR_STRONG_BIOMETRIC ->
                        KeyProperties.AUTH_DEVICE_CREDENTIAL or
                            KeyProperties.AUTH_BIOMETRIC_STRONG
                }
                builder.setUserAuthenticationParameters(
                    candidate.authenticationValiditySeconds,
                    authenticators
                )
            } else {
                @Suppress("DEPRECATION")
                builder.setUserAuthenticationValidityDurationSeconds(
                    candidate.authenticationValiditySeconds
                )
            }
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun strongBoxUnavailable(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            if (current is StrongBoxUnavailableException ||
                (current is ProviderException &&
                    current.javaClass.simpleName == "StrongBoxUnavailableException")
            ) {
                return true
            }
            current = current.cause
        }
        return false
    }

    private fun resetAndroidMobileRelaySecretRecordsAfterKeyPolicyMigration() {
        deleteSecretDirectoryOrThrow("secure-mesh/android-mobile-relay-secrets")
        pruneMobileRelayPortableConfigAfterSecretStoreReset()
    }

    fun androidKeyStoreStatus(deviceSecure: Boolean): Map<String, Any?> {
        val measurement = selectedMobileRelayCustody().measurement
        return mapOf(
            "provider" to if (measurement.persistentCustodySelected) {
                "AndroidKeyStore"
            } else {
                "process-memory"
            },
            "available" to measurement.keyStoreAvailable,
            "custodyStrategy" to measurement.custodyStrategy.wireName,
            "restartSemantics" to measurement.redactedMeasurements()["restartSemantics"],
            "deviceCredentialAvailable" to measurement.deviceCredentialAvailable,
            "strongBiometricAvailabilityMeasured" to
                measurement.strongBiometricAvailabilityMeasured,
            "strongBiometricAvailable" to measurement.strongBiometricAvailable,
            "deviceSecure" to deviceSecure,
            "privateMaterialExported" to false,
            "capabilityProbe" to measurement.capabilityProbe(),
            "measurements" to measurement.redactedMeasurements(),
            "bodyRedacted" to true
        )
    }

    private fun existingAndroidSecretKey(
        keyStore: KeyStore,
        alias: String
    ): SecretKey? {
        if (!keyStore.containsAlias(alias)) {
            return null
        }
        return try {
            val entry = keyStore.getEntry(alias, null)
            if (entry is KeyStore.SecretKeyEntry) entry.secretKey else null
        } catch (_: Exception) {
            null
        }
    }

    private fun requireSelectedUserAuthorization(selection: AndroidCustodySelection) {
        if (selectedUserAuthenticationRequired(selection.measurement)) {
            requireActiveUserAuthorization()
        }
    }

    private fun selectedUserAuthenticationRequired(
        measurement: SecureMeshAndroidCapabilityMeasurement
    ): Boolean {
        return measurement.userAuthenticationRequired == true ||
            measurement.userAuthenticationRequested
    }

    private fun custodyBackend(selection: AndroidCustodySelection): String {
        return when (selection) {
            is AndroidCustodySelection.KeyStore -> "android-keystore"
            is AndroidCustodySelection.MemoryOnly -> "memory-only-ephemeral"
        }
    }

    private fun ephemeralRecordKey(
        recordFile: File,
        kind: String,
        label: String,
        secureStoreChallenge: String
    ): String {
        val identity = listOf(
            recordFile.absolutePath,
            kind,
            label,
            sha256Hex(secureStoreChallenge.toByteArray(Charsets.UTF_8))
        ).joinToString("\u0000")
        return sha256Hex(identity.toByteArray(Charsets.UTF_8))
    }

    private fun deleteRecordFile(recordFile: File) {
        check(!recordFile.exists() || (recordFile.delete() && !recordFile.exists())) {
            "secure mesh Android memory-only custody could not remove a persistent record"
        }
    }
    fun writeAndroidSecureStoreRecordToFile(
        kind: String,
        label: String,
        secureStoreChallenge: String,
        secret: ByteArray,
        recordFile: File
    ) {
        val selection = selectedGeneralCustody()
        requireSelectedUserAuthorization(selection)
        when (selection) {
            is AndroidCustodySelection.KeyStore -> writeAndroidSecureStoreRecordToFile(
                kind,
                label,
                secureStoreChallenge,
                secret,
                recordFile,
                selection.secretKey
            )
            is AndroidCustodySelection.MemoryOnly -> {
                deleteRecordFile(recordFile)
                ephemeralSecretStore.put(
                    ephemeralRecordKey(recordFile, kind, label, secureStoreChallenge),
                    secret
                )
            }
        }
    }

    fun readAndroidSecureStoreRecord(
        kind: String,
        label: String,
        secureStoreChallenge: String,
        recordFile: File
    ): ByteArray {
        val selection = selectedGeneralCustody()
        requireSelectedUserAuthorization(selection)
        return when (selection) {
            is AndroidCustodySelection.KeyStore ->
                readAndroidSecureStoreRecordFromFile(
                    recordFile,
                    selection.secretKey,
                    kind,
                    label,
                    secureStoreChallenge
                )
            is AndroidCustodySelection.MemoryOnly ->
                ephemeralSecretStore.get(
                    ephemeralRecordKey(recordFile, kind, label, secureStoreChallenge)
                )
                    ?: throw IllegalStateException(
                        "secure mesh Android memory-only record is unavailable after restart"
                    )
        }
    }

    fun androidSecureStoreRecordExists(
        kind: String,
        label: String,
        secureStoreChallenge: String,
        recordFile: File
    ): Boolean {
        val selection = selectedGeneralCustody()
        return when (selection) {
            is AndroidCustodySelection.KeyStore -> recordFile.isFile
            is AndroidCustodySelection.MemoryOnly -> ephemeralSecretStore.get(
                ephemeralRecordKey(recordFile, kind, label, secureStoreChallenge)
            )?.also { it.fill(0) } != null
        }
    }

    fun deleteAndroidSecureStoreRecord(
        kind: String,
        label: String,
        secureStoreChallenge: String,
        recordFile: File
    ): Boolean {
        val selection = selectedGeneralCustody()
        requireSelectedUserAuthorization(selection)
        return when (selection) {
            is AndroidCustodySelection.KeyStore -> {
                if (!recordFile.exists()) {
                    true
                } else {
                    val verified = readAndroidSecureStoreRecordFromFile(
                        recordFile,
                        selection.secretKey,
                        kind,
                        label,
                        secureStoreChallenge
                    )
                    verified.fill(0)
                    recordFile.delete() && !recordFile.exists()
                }
            }
            is AndroidCustodySelection.MemoryOnly -> {
                val memoryDeleted = ephemeralSecretStore.delete(
                    ephemeralRecordKey(recordFile, kind, label, secureStoreChallenge)
                )
                deleteRecordFile(recordFile)
                memoryDeleted || !recordFile.exists()
            }
        }
    }

    private fun resetAndroidSecureStoreRecordsAfterKeyPolicyMigration() {
        listOf(
            "secure-mesh/android-provider-credentials-by-account-v3",
            "secure-mesh/android-provider-credentials-by-account",
            "secure-mesh/android-provider-credentials",
            "secure-mesh/android-provider-oauth-credentials-by-account-v3",
            "secure-mesh/android-provider-oauth-credentials-by-account",
            "secure-mesh/android-provider-oauth-credentials",
            "secure-mesh/android-provider-oauth-attempts",
            "secure-mesh/android-secure-store-probe"
        ).forEach(::deleteSecretDirectoryOrThrow)
    }

    private fun deleteSecretDirectoryOrThrow(relativePath: String) {
        val directory = File(filesDir, relativePath)
        if (!directory.exists()) {
            return
        }
        check(directory.deleteRecursively() && !directory.exists()) {
            "secure mesh Android encrypted-record cleanup failed"
        }
    }

    private fun writeAndroidSecureStoreRecordToFile(
        kind: String,
        label: String,
        secureStoreChallenge: String,
        secret: ByteArray,
        recordFile: File,
        secretKey: SecretKey
    ) {
        val challengeHash = sha256Hex(secureStoreChallenge.toByteArray(Charsets.UTF_8))
        val aad = buildAndroidSecureStoreAad(kind, label, challengeHash)
        val plaintext = encodeAndroidSecureStorePlaintext(kind, label, challengeHash, secret)
        val cipher = Cipher.getInstance(ANDROID_SECURE_STORE_CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey)
        cipher.updateAAD(aad)
        val ciphertext = try {
            cipher.doFinal(plaintext)
        } finally {
            plaintext.fill(0)
        }
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
        recordFile.parentFile?.mkdirs()
        val persistedText = persisted.toString(2)
        recordFile.writeText(persistedText, Charsets.UTF_8)
        val loadedSecret = readAndroidSecureStoreRecordFromFile(
            recordFile,
            secretKey,
            kind,
            label,
            secureStoreChallenge
        )
        val reloadMatches = MessageDigest.isEqual(secret, loadedSecret)
        loadedSecret.fill(0)
        check(reloadMatches) {
            "secure mesh Android secure-store reload verification failed"
        }
    }

    private fun readAndroidSecureStoreRecordFromFile(
        recordFile: File,
        secretKey: SecretKey,
        expectedKind: String,
        expectedLabel: String,
        expectedSecureStoreChallenge: String
    ): ByteArray {
        val persisted = JSONObject(recordFile.readText(Charsets.UTF_8))
        val kind = persisted.getString("kind")
        val label = persisted.getString("label")
        val challengeHash = persisted.getString("challengeSha256")
        val expectedChallengeHash = sha256Hex(
            expectedSecureStoreChallenge.toByteArray(Charsets.UTF_8)
        )
        if (kind != expectedKind ||
            label != expectedLabel ||
            challengeHash != expectedChallengeHash
        ) {
            throw IllegalStateException(
                "secure mesh Android secure-store record identity mismatch"
            )
        }
        val aad = buildAndroidSecureStoreAad(kind, label, challengeHash)
        if (sha256Hex(aad) != persisted.getString("aadSha256")) {
            throw IllegalStateException("secure mesh Android secure-store AAD hash mismatch")
        }
        val cipher = Cipher.getInstance(ANDROID_SECURE_STORE_CIPHER)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey,
            GCMParameterSpec(
                ANDROID_SECURE_STORE_TAG_BITS,
                base64UrlDecode(persisted.getString("nonceBase64url"))
            )
        )
        cipher.updateAAD(aad)
        val plaintext = cipher.doFinal(base64UrlDecode(persisted.getString("ciphertextBase64url")))
        return try {
            decodeAndroidSecureStorePlaintext(plaintext, kind, label, challengeHash)
        } finally {
            plaintext.fill(0)
        }
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
            throw IllegalArgumentException("secure mesh Android secure-store plaintext metadata mismatch")
        }
        return secret
    }


    private fun jsonObjectParam(params: JSONObject, key: String): JSONObject? {
        return when (val value = params.opt(key)) {
            is JSONObject -> value
            is String -> try {
                val parsed = JSONObject(value)
                params.put(key, parsed)
                parsed
            } catch (_: Exception) {
                null
            }
            else -> null
        }
    }

    private fun requireActiveUserAuthorization() {
        check(authorizationGrantIsActive()) {
            "secure mesh Android user authentication grant is required"
        }
    }

    private fun secretTextPresent(value: Any?): Boolean {
        val text = when (value) {
            is String -> value
            else -> return false
        }.trim()
        return text.isNotEmpty() &&
            text != "redacted" &&
            text != "***" &&
            text != "********"
    }

    private fun firstNonBlank(vararg values: String): String {
        return values.firstOrNull { it.isNotBlank() } ?: ""
    }

    private fun appendLenPrefixed(out: ByteArrayOutputStream, value: ByteArray) {
        val len = value.size
        out.write((len ushr 24) and 0xff)
        out.write((len ushr 16) and 0xff)
        out.write((len ushr 8) and 0xff)
        out.write(len and 0xff)
        out.write(value)
    }

    private fun sha256(bytes: ByteArray): ByteArray {
        return MessageDigest.getInstance("SHA-256").digest(bytes)
    }

    private fun sha256Hex(bytes: ByteArray): String {
        return sha256(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun base64UrlDecode(value: String): ByteArray {
        return Base64.decode(value, BASE64_URL_FLAGS)
    }

    private fun base64UrlEncode(value: ByteArray): String {
        return Base64.encodeToString(value, BASE64_URL_FLAGS)
    }

    private fun safeAndroidRecordId(value: String): String {
        val safe = value.replace(Regex("[^a-zA-Z0-9_.-]"), "_")
        return if (safe.isBlank()) "account" else safe
    }

    private class SliceReader(private val bytes: ByteArray) {
        private var offset = 0

        fun expect(expected: ByteArray) {
            val actual = readExact(expected.size)
            if (!actual.contentEquals(expected)) {
                throw IllegalArgumentException("secure mesh payload plaintext magic is invalid")
            }
        }

        fun readLenPrefixedBytes(): ByteArray {
            val lenBytes = readExact(4)
            val len = ((lenBytes[0].toInt() and 0xff) shl 24) or
                ((lenBytes[1].toInt() and 0xff) shl 16) or
                ((lenBytes[2].toInt() and 0xff) shl 8) or
                (lenBytes[3].toInt() and 0xff)
            if (len < 0) {
                throw IllegalArgumentException("secure mesh payload length is invalid")
            }
            return readExact(len)
        }

        fun isEmpty(): Boolean = offset == bytes.size

        private fun readExact(len: Int): ByteArray {
            if (len < 0 || offset + len > bytes.size) {
                throw IllegalArgumentException("secure mesh payload buffer is truncated")
            }
            return bytes.copyOfRange(offset, offset + len).also {
                offset += len
            }
        }
    }

    companion object {
        private const val SECURE_MESH_ADB_TAG = "LicoSecureMeshAdb"
        private const val SECURE_MESH_PROTOCOL_VERSION = "licolite.secure-mesh.v1"
        private const val ANDROID_MOBILE_RELAY_SECRET_STORE_KEY_ALIAS =
            "licolite_secure_mesh_android_mobile_relay_secret_store_v1"
        private const val ANDROID_SECURE_STORE_KEY_ALIAS =
            "licolite_secure_mesh_android_secret_store_v1"
        private const val ANDROID_SECURE_STORE_CIPHER = "AES/GCM/NoPadding"
        private const val ANDROID_KEYSTORE_USER_AUTH_VALIDITY_SECONDS = 300
        private const val MOBILE_RELAY_SECRET_OVERRIDE_TRANSPORT =
            "platform_keyring_to_rust_ffi_memory_override"
        private const val ANDROID_MOBILE_RELAY_SECRET_STORE_CONTRACT =
            "rust_secure_mesh_secret_store_handle_v1"
        private const val MOBILE_RELAY_SECRET_STORE_ACCOUNT_PREFIX = "mobileRelayE2ee"
        private const val MOBILE_RELAY_SECRET_STORE_NAMESPACE = "mobileRelayRuntime"
        private const val ANDROID_MOBILE_RELAY_SECRET_KIND = "mobile_relay_secret"
        private const val ANDROID_SECURE_STORE_NONCE_LEN = 12
        private const val ANDROID_SECURE_STORE_TAG_BITS = 128
        private const val BASE64_URL_FLAGS =
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        private val ANDROID_SECURE_STORE_AAD_MAGIC =
            "LCOSM-ANDROID-STORE-AAD-v1".toByteArray(Charsets.UTF_8)
        private val ANDROID_SECURE_STORE_PLAINTEXT_MAGIC =
            "LCOSM-ANDROID-STORE-PT-v1".toByteArray(Charsets.UTF_8)
    }
}
