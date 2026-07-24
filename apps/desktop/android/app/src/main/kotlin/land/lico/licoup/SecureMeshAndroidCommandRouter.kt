package land.lico.licoup

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import org.json.JSONObject

internal data class SecureMeshAndroidDiagnosticBindings(
    val closureChallenge: String = "",
    val invocationNonce: String = "",
)

internal class SecureMeshAndroidCommandRouter(
    private val activity: FlutterActivity,
    private val filesDir: File,
    private val secretStore: SecureMeshAndroidSecretStore,
    private val authenticator: SecureMeshAndroidUserAuthenticator,
    private val nativeRuntime: SecureMeshAndroidNativeRuntime,
    private val runtimeStatusStore: SecureMeshAndroidRuntimeStatusStore,
) {
    fun status(
        digests: SecureMeshAndroidDiagnosticBindings = SecureMeshAndroidDiagnosticBindings(),
    ): Map<String, Any?> {
        val keyStore = secretStore.androidKeyStoreStatus(
            authenticator.deviceCredentialIsConfigured(),
        )
        val runtimeStatusFile = runtimeStatusStore.runtimeStatusFile()
        return mapOf(
            "ok" to true,
            "closureChallengeDigest" to digests.closureChallenge,
            "invocationNonceDigest" to digests.invocationNonce,
            "protocolVersion" to SecureMeshAndroidBridgeContract.PROTOCOL_VERSION,
            "endpointKind" to "mobile",
            "platform" to "android",
            "bridge" to mapOf(
                "methodChannel" to SecureMeshAndroidBridgeContract.METHOD_CHANNEL,
                "statusMethod" to true,
                "writeRuntimeStatusMethod" to true,
                "nativeJsonMethod" to true,
            ),
            "device" to mapOf(
                "sdk" to Build.VERSION.SDK_INT,
                "identifierIncluded" to false,
            ),
            "secureStore" to keyStore,
            "mobileRelaySecretStore" to secretStore.mobileRelaySecretStoreStatus(),
            "userAuthentication" to SecureMeshAndroidJsonCodec.jsonObjectToMap(
                authenticator.status(),
            ),
            "nativeRuntime" to nativeRuntimeStatus(),
            "runtimeStatusFile" to mapOf(
                "relativePath" to SecureMeshAndroidBridgeContract.RUNTIME_STATUS_RELATIVE_PATH,
                "exists" to runtimeStatusFile.exists(),
                "appPrivateFilesDir" to true,
                "externalReportAvailable" to false,
            ),
            "pairwiseRuntimeStatus" to
                "authenticated_pairwise_runtime_bound_to_selected_custody",
            "mlsRuntimeStatus" to
                "product_policy_bindings_implemented_product_messaging_disabled_until_physical_group_evidence",
            "mlsRuntimeReady" to false,
            "productionReady" to false,
        )
    }

    fun run(arguments: Any?): Map<String, Any?> {
        val requestJson = when (arguments) {
            is String -> arguments
            is Map<*, *> -> JSONObject(arguments).toString()
            else -> JSONObject(
                mapOf("action" to "", "params" to emptyMap<String, Any?>()),
            ).toString()
        }
        return try {
            val request = JSONObject(requestJson)
            val action = request.optString("action", "")
            val params = request.optJSONObject("params") ?: JSONObject()
            val authorizationFailure = authorizeAction(
                action,
                allowPrompt = request.optBoolean("authorize", false),
            )
            if (authorizationFailure != null) {
                return SecureMeshAndroidJsonCodec.jsonObjectToMap(authorizationFailure)
            }
            when (action) {
                "external.url.open" -> return SecureMeshAndroidJsonCodec.jsonObjectToMap(
                    openExternalUrl(params),
                )
                "secure_mesh.android.status" -> return status()
                "secure_mesh.android.userAuthentication.request" ->
                    return SecureMeshAndroidJsonCodec.jsonObjectToMap(
                        authenticator.request(params),
                    )
                "secure_mesh.android.userAuthentication.status" ->
                    return SecureMeshAndroidJsonCodec.jsonObjectToMap(
                        authenticator.status(),
                    )
            }
            if (!nativeRuntime.libraryLoaded) return nativeLibraryUnavailable()
            val protectedOperation =
                SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(action)
            val response = try {
                if (protectedOperation) {
                    secretStore.invokeWithAuthorizedCustody {
                        nativeRuntime.invoke(
                            requestJson,
                            filesDir.absolutePath,
                            secretStore,
                        )
                    }
                } else {
                    nativeRuntime.invoke(
                        requestJson,
                        filesDir.absolutePath,
                        secretStore,
                    )
                }
            } finally {
                if (protectedOperation) authenticator.consumeAuthorizationGrant()
            }
            SecureMeshAndroidJsonCodec.jsonObjectToMap(JSONObject(response))
        } catch (error: Exception) {
            mapOf(
                "ok" to false,
                "code" to "secure_mesh_native_json_failed",
                "errorClass" to error.javaClass.simpleName,
                "bodyRedacted" to true,
            )
        }
    }

    fun writeRuntimeStatus(
        digests: SecureMeshAndroidDiagnosticBindings,
    ): Map<String, Any?> = try {
        runtimeStatusStore.pruneDiagnostics()
        val payload = status(digests).toMutableMap()
        payload["runtimeStatusFile"] = mapOf(
            "relativePath" to SecureMeshAndroidBridgeContract.RUNTIME_STATUS_RELATIVE_PATH,
            "exists" to true,
            "appPrivateFilesDir" to true,
            "externalReportAvailable" to false,
            "writtenByAppProcess" to true,
            "writtenAtEpochMillis" to System.currentTimeMillis(),
            "closureChallengeDigest" to digests.closureChallenge,
            "invocationNonceDigest" to digests.invocationNonce,
        )
        runtimeStatusStore.writePayload(payload)
        mapOf(
            "ok" to true,
            "relativePath" to SecureMeshAndroidBridgeContract.RUNTIME_STATUS_RELATIVE_PATH,
            "externalReportAvailable" to false,
            "writtenByAppProcess" to true,
        )
    } catch (error: Exception) {
        val failurePayload = mapOf(
            "ok" to false,
            "closureChallengeDigest" to digests.closureChallenge,
            "invocationNonceDigest" to digests.invocationNonce,
            "protocolVersion" to SecureMeshAndroidBridgeContract.PROTOCOL_VERSION,
            "endpointKind" to "mobile",
            "platform" to "android",
            "bridge" to mapOf(
                "methodChannel" to SecureMeshAndroidBridgeContract.METHOD_CHANNEL,
                "statusMethod" to true,
                "writeRuntimeStatusMethod" to true,
                "nativeJsonMethod" to true,
            ),
            "secureStore" to mapOf(
                "provider" to "selected-custody-unavailable",
                "available" to false,
                "privateMaterialExported" to false,
                "errorClass" to error.javaClass.simpleName,
            ),
            "nativeRuntime" to mapOf(
                "provider" to "licoup-native",
                "library" to SecureMeshAndroidBridgeContract.NATIVE_LIBRARY,
                "ffiBoundary" to "jni",
                "loaded" to nativeRuntime.libraryLoaded,
                "selfTestPassed" to false,
                "mlsRuntimeFeatureEnabled" to false,
                "usesSharedRustCore" to nativeRuntime.libraryLoaded,
                "rawJsonSecretsPassedThroughFfi" to false,
                "secretsPassedThroughFlutterMethodChannel" to false,
                "jniSecretStoreCallbacksCarryInProcessSecret" to true,
                "productionReady" to false,
            ),
            "runtimeStatusFile" to mapOf(
                "relativePath" to SecureMeshAndroidBridgeContract.RUNTIME_STATUS_RELATIVE_PATH,
                "exists" to false,
                "appPrivateFilesDir" to true,
                "externalReportAvailable" to false,
                "writtenByAppProcess" to true,
                "writeFailed" to true,
                "errorClass" to error.javaClass.simpleName,
                "closureChallengeDigest" to digests.closureChallenge,
                "invocationNonceDigest" to digests.invocationNonce,
            ),
            "productionReady" to false,
        )
        try {
            runtimeStatusStore.writePayload(failurePayload)
        } catch (_: Exception) {
        }
        mapOf(
            "ok" to false,
            "relativePath" to SecureMeshAndroidBridgeContract.RUNTIME_STATUS_RELATIVE_PATH,
            "errorClass" to error.javaClass.simpleName,
        )
    }

    fun pruneDiagnostics() = runtimeStatusStore.pruneDiagnostics()

    private fun authorizeAction(action: String, allowPrompt: Boolean): JSONObject? {
        if (!SecureMeshAndroidAuthorizationPolicy.requiresUserAuthentication(action)) return null
        if (!SecureMeshAndroidAuthorizationPolicy.mayStartAuthenticationPrompt(
                action,
                interactionAuthorized = allowPrompt,
            )
        ) {
            authenticator.consumeAuthorizationGrant()
            return authenticator.activeAuthorizationRequiredResponse()
                .put("ok", false)
                .put("code", "secure_mesh_android_user_authentication_required")
                .put("bodyRedacted", true)
        }
        val authorization = authenticator.authorizeSensitiveAction(
            action,
            forcePrompt = true,
        )
        if (authorization.optBoolean("ok", false)) return null
        return authorization
            .put("code", "secure_mesh_android_user_authentication_required")
            .put("bodyRedacted", true)
    }

    private fun openExternalUrl(params: JSONObject): JSONObject {
        val rawUrl = params.optString("url", "").trim()
        if (rawUrl.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "url_missing")
                .put("bodyRedacted", true)
        }
        val uri = try {
            Uri.parse(rawUrl)
        } catch (error: Exception) {
            return JSONObject()
                .put("ok", false)
                .put("status", "invalid_url")
                .put("errorClass", error.javaClass.simpleName)
                .put("bodyRedacted", true)
        }
        if (uri.scheme?.lowercase() != "https") {
            return JSONObject()
                .put("ok", false)
                .put("status", "unsupported_url")
                .put("bodyRedacted", true)
        }
        return try {
            activity.startActivity(
                Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE),
            )
            JSONObject()
                .put("ok", true)
                .put("status", "opened")
                .put("host", uri.host ?: "")
                .put("bodyRedacted", true)
        } catch (_: ActivityNotFoundException) {
            JSONObject()
                .put("ok", false)
                .put("status", "no_browser")
                .put("host", uri.host ?: "")
                .put("bodyRedacted", true)
        }
    }

    private fun nativeRuntimeStatus(): Map<String, Any?> {
        if (!nativeRuntime.libraryLoaded) return nativeRuntimeUnavailableStatus()
        return try {
            val nativeFeatureFlags = nativeRuntime.featureFlags()
            val productFeatureFlags = nativeFeatureFlags and
                SecureMeshAndroidBridgeContract.NATIVE_EXPECTED_FEATURE_FLAGS
            val unexpectedFeatureFlagsPresent = nativeFeatureFlags != productFeatureFlags
            mapOf(
                "provider" to "licoup-native",
                "library" to SecureMeshAndroidBridgeContract.NATIVE_LIBRARY,
                "ffiBoundary" to "jni",
                "loaded" to true,
                "selfTestPassed" to (
                    nativeRuntime.selfTest() == 1 && !unexpectedFeatureFlagsPresent
                    ),
                "featureFlags" to productFeatureFlags,
                "expectedFeatureFlags" to
                    SecureMeshAndroidBridgeContract.NATIVE_EXPECTED_FEATURE_FLAGS,
                "featureFlagsComplete" to (
                    productFeatureFlags ==
                        SecureMeshAndroidBridgeContract.NATIVE_EXPECTED_FEATURE_FLAGS
                    ),
                "unexpectedDiagnosticFeatureFlagsPresent" to
                    unexpectedFeatureFlagsPresent,
                "mlsRuntimeFeatureEnabled" to true,
                "protocolStatusHashHex" to unsignedIntHex(nativeRuntime.protocolHash()),
                "usesSharedRustCore" to true,
                "rawJsonSecretsPassedThroughFfi" to false,
                "secretsPassedThroughFlutterMethodChannel" to false,
                "jniSecretStoreCallbacksCarryInProcessSecret" to true,
                "productionReady" to false,
            )
        } catch (error: UnsatisfiedLinkError) {
            nativeRuntimeUnavailableStatus(error.javaClass.simpleName)
        }
    }

    private fun nativeRuntimeUnavailableStatus(errorClass: String? = null) = buildMap {
        put("provider", "licoup-native")
        put("library", SecureMeshAndroidBridgeContract.NATIVE_LIBRARY)
        put("ffiBoundary", "jni")
        put("loaded", false)
        put("selfTestPassed", false)
        put("mlsRuntimeFeatureEnabled", false)
        put("usesSharedRustCore", false)
        put("rawJsonSecretsPassedThroughFfi", false)
        put("secretsPassedThroughFlutterMethodChannel", false)
        put("jniSecretStoreCallbacksCarryInProcessSecret", true)
        if (errorClass != null) put("errorClass", errorClass)
        put("productionReady", false)
    }

    private fun nativeLibraryUnavailable(): Map<String, Any?> = mapOf(
        "ok" to false,
        "code" to "secure_mesh_native_library_unavailable",
        "library" to SecureMeshAndroidBridgeContract.NATIVE_LIBRARY,
    )

    private fun unsignedIntHex(value: Int): String =
        java.lang.Long.toHexString(value.toLong() and 0xffffffffL).padStart(8, '0')
}
