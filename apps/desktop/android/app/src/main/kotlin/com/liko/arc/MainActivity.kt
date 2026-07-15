package com.liko.arc

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Base64
import android.util.AtomicFile
import android.util.Log
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileDescriptor
import java.io.InputStreamReader
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

class MainActivity : FlutterActivity() {
    private external fun nativeSecureMeshRuntimeSelfTest(): Int
    private external fun nativeSecureMeshRuntimeFeatureFlags(): Int
    private external fun nativeSecureMeshRuntimeProtocolHash(): Int
    private external fun nativeSecureMeshJson(
        requestJson: String,
        filesDir: String,
        secretStoreBridge: SecureMeshAndroidSecretStore
    ): String
    private val mobileProviderOAuthCallbackLock = Any()
    private var activeMobileProviderOAuthCallbackServer: MobileProviderOAuthCallbackServer? = null
    private val pendingMobileProviderOAuthByState =
        mutableMapOf<String, PendingMobileProviderOAuth>()
    private var deferredMobileProviderOAuthCallback: DeferredMobileProviderOAuthCallback? = null
    private var deferredMobileProviderOAuthRetryInFlight: Boolean = false
    private var currentReleaseClosureChallengeDigest: String = ""
    private var currentReleaseInvocationNonceDigest: String = ""
    private val releaseAcceptanceDispatchLock = Any()
    private val releaseAcceptancePromptLock = Any()
    private var pendingReleaseAcceptancePromptKey: String = ""
    private var pendingReleaseAcceptanceIntent: Intent? = null
    private val secureMeshAndroidUserAuthenticator by lazy {
        SecureMeshAndroidUserAuthenticator(this)
    }
    private val secureMeshAndroidSecretStore by lazy {
        SecureMeshAndroidSecretStore(this, filesDir) {
            secureMeshAndroidUserAuthenticator.hasActiveAuthorizationGrant()
        }
    }

    private data class DeferredMobileProviderOAuthCallback(
        val providerId: String,
        val callbackUrl: String,
        val mobileAccountId: String,
        val attemptId: String
    )

    private data class AndroidSecureRecordIdentity(
        val kind: String,
        val label: String,
        val challenge: String,
        val file: File
    )

    private data class MobileProviderOAuthDefinition(
        val providerId: String,
        val authSurface: String,
        val conversationSurface: String,
        val authorizeUrl: String,
        val tokenUrl: String,
        val clientId: String,
        val clientSecret: String = "",
        val scope: String,
        val callbackHost: String,
        val callbackPort: Int,
        val callbackPath: String,
        val defaultModel: String,
        val extraAuthorizeParams: List<Pair<String, String>> = emptyList()
    )

    private data class AndroidHttpProxyConfig(
        val host: String,
        val port: Int
    ) {
        fun toJavaProxy(): java.net.Proxy {
            return java.net.Proxy(
                java.net.Proxy.Type.HTTP,
                InetSocketAddress(host, port)
            )
        }
    }

    private data class ProviderHttpsConnection(
        val connection: HttpsURLConnection,
        val proxyMode: String
    ) {
        val proxyDetected: Boolean
            get() = proxyMode != "direct"
    }

    private data class ChatGptCodexModelSelection(
        val model: String,
        val requestedModel: String,
        val discoveryStatus: String = "",
        val discoveredModelCount: Int = 0
    )

    private inner class MobileProviderOAuthCallbackServer(
        private val fileDescriptor: FileDescriptor
    ) : AutoCloseable {
        fun accept(timeoutMs: Int): FileDescriptor? {
            if (!pollFileDescriptor(
                    fileDescriptor,
                    OsConstants.POLLIN,
                    timeoutMs
                )
            ) {
                return null
            }
            return Os.accept(fileDescriptor, InetSocketAddress(0))
        }

        override fun close() {
            try {
                Os.close(fileDescriptor)
            } catch (_: Exception) {
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val acceptanceIntent = pendingReleaseAcceptanceIntent
            ?: consumeReleaseAcceptanceIngress()
        pendingReleaseAcceptanceIntent = null
        consumeReleaseClosureChallenge(acceptanceIntent)
        maybeRequestReleaseAcceptanceAuthorization(acceptanceIntent)
        handleMobileProviderOAuthCallbackIntent(intent)
        handleSecureMeshAdbIntent(acceptanceIntent)
        writeSecureMeshAndroidRuntimeStatusFile()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_MESH_ANDROID_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(secureMeshAndroidStatus())
                "writeRuntimeStatus" -> result.success(writeSecureMeshAndroidRuntimeStatusFile())
                "nativeJson" -> {
                    Thread {
                        val output = runSecureMeshNativeJson(call.arguments)
                        runOnUiThread {
                            result.success(output)
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
        prunePersistentSecureMeshDiagnostics()
        writeSecureMeshAndroidRuntimeStatusFile()
        if (pendingReleaseAcceptanceIntent == null) {
            pendingReleaseAcceptanceIntent = consumeReleaseAcceptanceIngress()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val acceptanceIntent = consumeReleaseAcceptanceIngress()
        consumeReleaseClosureChallenge(acceptanceIntent)
        maybeRequestReleaseAcceptanceAuthorization(acceptanceIntent)
        handleMobileProviderOAuthCallbackIntent(intent)
        handleSecureMeshAdbIntent(acceptanceIntent)
        writeSecureMeshAndroidRuntimeStatusFile()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        secureMeshAndroidUserAuthenticator.onActivityResult(requestCode, resultCode)
        retryDeferredMobileProviderOAuthCallbackAsync()
    }

    private fun secureMeshAndroidStatus(): Map<String, Any?> {
        val keyStore = secureMeshAndroidSecretStore.androidKeyStoreStatus(
            secureMeshAndroidUserAuthenticator.deviceCredentialIsConfigured()
        )
        val nativeRuntime = secureMeshAndroidNativeRuntimeStatus()
        val runtimeStatusFile = secureMeshAndroidRuntimeStatusFile()
        return mapOf(
            "ok" to true,
            "closureChallengeDigest" to currentReleaseClosureChallengeDigest,
            "invocationNonceDigest" to currentReleaseInvocationNonceDigest,
            "protocolVersion" to SECURE_MESH_PROTOCOL_VERSION,
            "endpointKind" to "mobile",
            "platform" to "android",
            "bridge" to mapOf(
                "methodChannel" to SECURE_MESH_ANDROID_CHANNEL,
                "statusMethod" to true,
                "writeRuntimeStatusMethod" to true,
                "nativeJsonMethod" to true
            ),
            "device" to mapOf(
                "sdk" to Build.VERSION.SDK_INT,
                "identifierIncluded" to false
            ),
            "secureStore" to keyStore,
            "mobileRelaySecretStore" to secureMeshAndroidSecretStore.mobileRelaySecretStoreStatus(),
            "userAuthentication" to
                jsonObjectToMap(secureMeshAndroidUserAuthenticator.status()),
            "nativeRuntime" to nativeRuntime,
            "runtimeStatusFile" to mapOf(
                "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                "exists" to runtimeStatusFile.exists(),
                "appPrivateFilesDir" to true,
                "externalReportRelativePath" to
                    SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH
            ),
            "pairwiseRuntimeStatus" to
                "authenticated_pairwise_runtime_bound_to_selected_custody",
            "mlsRuntimeStatus" to
                "product_policy_bindings_implemented_product_messaging_disabled_until_physical_group_evidence",
            "mlsRuntimeReady" to false,
            "productionReady" to false
        )
    }

    private fun runSecureMeshNativeJson(arguments: Any?): Map<String, Any?> {
        val requestJson = when (arguments) {
            is String -> arguments
            is Map<*, *> -> JSONObject(arguments).toString()
            else -> JSONObject(mapOf("action" to "", "params" to emptyMap<String, Any?>())).toString()
        }
        return try {
            val request = JSONObject(requestJson)
            val action = request.optString("action", "")
            val params = request.optJSONObject("params") ?: JSONObject()
            val authorizationFailure = authorizeSecureMeshAction(
                action,
                allowPrompt = request.optBoolean("authorize", false)
            )
            if (authorizationFailure != null) {
                return jsonObjectToMap(authorizationFailure)
            }
            when (action) {
                "external.url.open" ->
                    return jsonObjectToMap(openExternalUrl(params))
                "mobile.provider.web.open" ->
                    return jsonObjectToMap(openMobileProviderWebConversation(params))
                "mobile.provider.web.snapshot" ->
                    return jsonObjectToMap(mobileProviderWebConversationSnapshot(params))
                "mobile.provider.oauth.login" ->
                    return jsonObjectToMap(loginMobileProviderOAuth(params))
                "mobile.provider.oauth.completeCallback" ->
                    return jsonObjectToMap(completeMobileProviderOAuthCallback(params))
                "mobile.provider.oauth.status" ->
                    return jsonObjectToMap(mobileProviderOAuthStatus(params))
                "secure_mesh.android.status" ->
                    return secureMeshAndroidStatus()
                "secure_mesh.android.userAuthentication.request" -> {
                    val authentication = secureMeshAndroidUserAuthenticator.request(params)
                    if (authentication.optBoolean("ok", false) &&
                        authentication.optBoolean("authenticated", false)
                    ) {
                        retryDeferredMobileProviderOAuthCallbackAsync()
                    }
                    return jsonObjectToMap(authentication)
                }
                "secure_mesh.android.userAuthentication.status" ->
                    return jsonObjectToMap(secureMeshAndroidUserAuthenticator.status())
                "mobile.provider.credential.set" ->
                    return jsonObjectToMap(setMobileProviderCredential(params))
                "mobile.provider.credential.delete" ->
                    return jsonObjectToMap(deleteMobileProviderCredential(params))
                "mobile.provider.credential.status" ->
                    return jsonObjectToMap(mobileProviderCredentialStatus(params))
                "mobile.provider.credential.syncFromRelay" -> {
                    val providerId = mobileProviderIdFromParams(params)
                    if (isDeferredAndroidMobileProvider(providerId)) {
                        return jsonObjectToMap(
                            deferredAndroidMobileProvider(providerId, "local_credential_sync")
                        )
                    }
                    if (!nativeSecureMeshRuntimeLibraryLoaded) {
                        return secureMeshNativeLibraryUnavailable()
                    }
                    return jsonObjectToMap(syncMobileProviderCredentialFromRelay(params))
                }
                "mobile.provider.chat.send" -> {
                    if (!nativeSecureMeshRuntimeLibraryLoaded &&
                        !mobileProviderChatCanRunWithoutNativeRuntime(params)
                    ) {
                        return secureMeshNativeLibraryUnavailable()
                    }
                    return jsonObjectToMap(sendMobileProviderChat(params))
                }
            }
            if (!nativeSecureMeshRuntimeLibraryLoaded) {
                return secureMeshNativeLibraryUnavailable()
            }
            secureMeshAndroidSecretStore.redactPersistedMobileRelaySecrets()
            val effectiveRequestJson = secureMeshAndroidSecretStore.requestTextWithMobileRelaySecretOverrides(
                requestJson,
                action
            )
            val response = nativeSecureMeshJson(
                effectiveRequestJson,
                filesDir.absolutePath,
                secureMeshAndroidSecretStore
            )
            val responseJson = JSONObject(response)
            secureMeshAndroidSecretStore.captureMobileRelaySecretsFromNativeResponse(responseJson)
            secureMeshAndroidSecretStore.redactPersistedMobileRelaySecrets()
            jsonObjectToMap(responseJson)
        } catch (error: Exception) {
            mapOf(
                "ok" to false,
                "code" to "secure_mesh_native_json_failed",
                "errorClass" to error.javaClass.simpleName,
                "bodyRedacted" to true
            )
        }
    }

    private fun authorizeSecureMeshAction(
        action: String,
        allowPrompt: Boolean
    ): JSONObject? {
        val selectedUserAuthentication = if (action.startsWith("mobile.provider.")) {
            secureMeshAndroidSecretStore.userAuthenticationSelected() ||
                secureMeshAndroidSecretStore.generalUserAuthenticationSelected()
        } else {
            secureMeshAndroidSecretStore.userAuthenticationSelected()
        }
        if (!SecureMeshAndroidAuthorizationPolicy.requiresSelectedUserAuthentication(
                action,
                selectedUserAuthentication
            )
        ) {
            return null
        }
        val authorization = if (
            SecureMeshAndroidAuthorizationPolicy.mayStartAuthenticationPrompt(
                action,
                interactionAuthorized = allowPrompt
            )
        ) {
            secureMeshAndroidUserAuthenticator.authorizeSensitiveAction(action)
        } else {
            secureMeshAndroidUserAuthenticator.activeAuthorizationRequiredResponse()
        }
        if (authorization.optBoolean("ok", false)) {
            return null
        }
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
            startActivity(
                Intent(Intent.ACTION_VIEW, uri)
                    .addCategory(Intent.CATEGORY_BROWSABLE)
            )
            JSONObject()
                .put("ok", true)
                .put("status", "opened")
                .put("host", uri.host ?: "")
                .put("bodyRedacted", true)
        } catch (error: ActivityNotFoundException) {
            JSONObject()
                .put("ok", false)
                .put("status", "no_browser")
                .put("host", uri.host ?: "")
                .put("bodyRedacted", true)
        }
    }

    private fun openMobileProviderWebConversation(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                "chatgpt"
            )
        )
        if (providerId != "chatgpt") {
            return unsupportedMobileProvider(providerId)
        }
        return try {
            startActivity(
                Intent(this, ChatGptWebActivity::class.java)
                    .putExtra("providerId", providerId)
            )
            JSONObject()
                .put("ok", true)
                .put("providerId", providerId)
                .put("mode", "chatgpt-webview")
                .put("status", "opened")
                .put("bodyRedacted", true)
        } catch (error: Exception) {
            JSONObject()
                .put("ok", false)
                .put("providerId", providerId)
                .put("mode", "chatgpt-webview")
                .put("status", "open_failed")
                .put("errorClass", error.javaClass.simpleName)
                .put("bodyRedacted", true)
        }
    }

    private fun mobileProviderWebConversationSnapshot(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                "chatgpt"
            )
        )
        if (providerId != "chatgpt") {
            return unsupportedMobileProvider(providerId)
        }
        val file = File(
            getExternalFilesDir(null),
            "${ChatGptWebActivity.SNAPSHOT_RELATIVE_PATH}"
        )
        if (!file.exists()) {
            return JSONObject()
                .put("ok", true)
                .put("providerId", providerId)
                .put("mode", "chatgpt-webview")
                .put("snapshotPresent", false)
                .put("messages", JSONArray())
                .put("bodyRedacted", false)
        }
        return try {
            val snapshot = JSONObject(file.readText(Charsets.UTF_8))
            snapshot
                .put("ok", true)
                .put("providerId", providerId)
                .put("mode", "chatgpt-webview")
                .put("snapshotPresent", true)
                .put("bodyRedacted", false)
        } catch (error: Exception) {
            JSONObject()
                .put("ok", false)
                .put("providerId", providerId)
                .put("mode", "chatgpt-webview")
                .put("snapshotPresent", false)
                .put("status", "snapshot_unreadable")
                .put("errorClass", error.javaClass.simpleName)
                .put("bodyRedacted", true)
        }
    }

    private fun handleMobileProviderOAuthCallbackIntent(intent: Intent?) {
        if (intent == null) {
            return
        }
        val fromExplicitCallbackAction =
            intent.action == MOBILE_PROVIDER_OAUTH_CALLBACK_ACTION
        val callbackUrl = if (fromExplicitCallbackAction) {
            intent.getStringExtra("callbackUrl")?.trim().orEmpty()
        } else if (
            intent.action == Intent.ACTION_VIEW &&
            intent.data?.let(::isMobileProviderOAuthCallbackUri) == true
        ) {
            intent.dataString?.trim().orEmpty()
        } else {
            ""
        }
        if (callbackUrl.isBlank()) {
            return
        }
        val providerId = if (fromExplicitCallbackAction) {
            normalizeMobileProviderId(intent.getStringExtra("providerId") ?: "chatgpt")
        } else {
            "chatgpt"
        }
        if (providerId.isBlank() || callbackUrl.isBlank()) {
            return
        }
        Thread {
            val result = completeMobileProviderOAuthCallback(
                JSONObject()
                    .put("providerId", providerId)
                    .put("callbackUrl", callbackUrl)
            )
            Log.i(
                "LicoArcOAuth",
                "OAuth callback intent completed: " +
                    result.optString("status", if (result.optBoolean("ok")) "ok" else "failed")
            )
        }.start()
    }

    private fun isMobileProviderOAuthCallbackUri(uri: Uri): Boolean {
        val host = (uri.host ?: "").lowercase()
        if (uri.scheme?.lowercase() != "http") {
            return false
        }
        return listOf("chatgpt").any { providerId ->
            (host == mobileProviderOAuthCallbackHost(providerId) ||
                host == CHATGPT_OAUTH_CALLBACK_BIND_HOST) &&
                uri.port == mobileProviderOAuthCallbackPort(providerId) &&
                uri.path == mobileProviderOAuthCallbackPath(providerId)
        }
    }

    private fun loginMobileProviderOAuth(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
        if (isDeferredAndroidMobileProvider(providerId)) {
            return deferredAndroidMobileProvider(providerId, "local_oauth_start")
        }
        if (!isSupportedLocalMobileProviderOAuth(providerId)) {
            return JSONObject()
                .put("ok", false)
                .put("status", "unsupported_local_oauth_provider")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val mobileAccountId = mobileAccountIdFromParams(params, providerId)
        val verifier = randomBase64Url(64)
        val challenge = base64UrlEncode(sha256(verifier.toByteArray(Charsets.US_ASCII)))
        val state = randomBase64Url(32)
        val server = try {
            openFreshMobileProviderOAuthCallbackServer(providerId)
        } catch (error: Exception) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_unavailable")
                .put("providerId", providerId)
                .put("errorClass", error.javaClass.simpleName)
                .put("bodyRedacted", true)
        }
        synchronized(mobileProviderOAuthCallbackLock) {
            activeMobileProviderOAuthCallbackServer = server
        }
        try {
            server.use {
            val redirectUri = mobileProviderOAuthRedirectUri(providerId)
            val oauthStartedAt = System.currentTimeMillis()
            val pending = PendingMobileProviderOAuth(
                attemptId = firstNonBlank(
                    params.optString("attemptId", ""),
                    "oauth-attempt-$oauthStartedAt"
                ),
                providerId = providerId,
                mobileAccountId = mobileAccountId,
                accountDraftId = firstNonBlank(
                    params.optString("accountDraftId", ""),
                    mobileAccountId
                ),
                verifier = verifier,
                state = state,
                redirectUri = redirectUri,
                createdAtEpochMillis = oauthStartedAt
            )
            try {
                replacePendingMobileProviderOAuth(pending)
            } catch (error: Exception) {
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_attempt_secure_store_failed")
                    .put("providerId", providerId)
                    .put("errorClass", error.javaClass.simpleName)
                    .put("bodyRedacted", true)
            }
            val authorizeUrl = mobileProviderOAuthAuthorizeUrl(
                providerId,
                redirectUri,
                challenge,
                state
            )
            val browserOpenError = openMobileProviderOAuthAuthorizeUrl(authorizeUrl, providerId)
            if (browserOpenError != null) {
                clearPendingMobileProviderOAuth(providerId, state)
                return browserOpenError
            }
            val callback = awaitMobileProviderOAuthCallback(server, providerId, state)
            if (!callback.optBoolean("ok", false)) {
                val completedStatus = waitForMobileProviderOAuthCredential(
                    providerId,
                    mobileAccountId,
                    minUpdatedAtEpochMillis = oauthStartedAt
                )
                if (completedStatus != null) {
                    return completedStatus
                }
                callback.put("providerId", providerId)
                callback.put("bodyRedacted", true)
                return callback
            }
            val code = callback.optString("code", "")
            if (code.isBlank()) {
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_code_missing")
                    .put("providerId", providerId)
                    .put("bodyRedacted", true)
            }
            val exchanged = exchangeMobileProviderOAuthCode(
                providerId,
                code,
                redirectUri,
                verifier
            )
            if (!exchanged.optBoolean("ok", false)) {
                val completedStatus = waitForMobileProviderOAuthCredential(
                    providerId,
                    mobileAccountId,
                    minUpdatedAtEpochMillis = oauthStartedAt
                )
                if (completedStatus != null) {
                    return completedStatus
                }
                exchanged.put("providerId", providerId)
                exchanged.put("bodyRedacted", true)
                return exchanged
            }
            clearPendingMobileProviderOAuth(providerId, state)
            return writeMobileProviderOAuthCredential(providerId, mobileAccountId, exchanged)
            }
        } finally {
            synchronized(mobileProviderOAuthCallbackLock) {
                if (activeMobileProviderOAuthCallbackServer === server) {
                    activeMobileProviderOAuthCallbackServer = null
                }
            }
        }
    }

    private fun completeMobileProviderOAuthCallback(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
        if (isDeferredAndroidMobileProvider(providerId)) {
            return deferredAndroidMobileProvider(providerId, "local_oauth_callback")
        }
        if (!isSupportedLocalMobileProviderOAuth(providerId)) {
            return JSONObject()
                .put("ok", false)
                .put("status", "unsupported_local_oauth_provider")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val callbackUrl = params.optString("callbackUrl", "").trim()
        if (callbackUrl.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_url_missing")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val requestedMobileAccountId = mobileAccountIdFromParams(params, "")
        val uri = try {
            parseMobileProviderOAuthCallbackUri(providerId, callbackUrl)
        } catch (_: Exception) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_url_invalid")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        if (uri.path != mobileProviderOAuthCallbackPath(providerId)) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_path_invalid")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val state = uri.getQueryParameter("state") ?: ""
        val code = uri.getQueryParameter("code") ?: ""
        val error = uri.getQueryParameter("error") ?: ""
        if (error.isNotBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_provider_error")
                .put("providerId", providerId)
                .put("errorCode", error)
                .put("bodyRedacted", true)
        }
        if (state.isBlank() || code.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_code_missing")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        if (secureMeshAndroidSecretStore.generalUserAuthenticationSelected() &&
            !secureMeshAndroidUserAuthenticator.hasActiveAuthorizationGrant()
        ) {
            synchronized(mobileProviderOAuthCallbackLock) {
                deferredMobileProviderOAuthCallback = DeferredMobileProviderOAuthCallback(
                    providerId = providerId,
                    callbackUrl = callbackUrl,
                    mobileAccountId = requestedMobileAccountId,
                    attemptId = params.optString("attemptId", "").trim()
                )
            }
            return secureMeshAndroidUserAuthenticator.activeAuthorizationRequiredResponse()
                .put("status", "oauth_user_authentication_required")
                .put("providerId", providerId)
                .put("callbackDeferredInProcessMemory", true)
                .put("bodyRedacted", true)
        }
        val pending = try {
            loadPendingMobileProviderOAuth(providerId, state)
        } catch (error: Exception) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_pending_unreadable")
                .put("providerId", providerId)
                .put("errorClass", error.javaClass.simpleName)
                .put("bodyRedacted", true)
        }
        if (pending == null) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_pending_missing")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val requestedAttemptId = params.optString("attemptId", "").trim()
        if (requestedAttemptId.isNotBlank() && requestedAttemptId != pending.attemptId) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_attempt_mismatch")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val mobileAccountId = if (requestedMobileAccountId.isBlank()) {
            firstNonBlank(pending.accountDraftId, pending.mobileAccountId)
        } else {
            requestedMobileAccountId
        }
        if (
            pending.mobileAccountId != mobileAccountId &&
            pending.accountDraftId != mobileAccountId
        ) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_account_mismatch")
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("bodyRedacted", true)
        }
        if (pending.isExpired(
                System.currentTimeMillis(),
                CHATGPT_OAUTH_CALLBACK_PENDING_TIMEOUT_MS
            )
        ) {
            clearPendingMobileProviderOAuth(providerId, pending.state)
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_pending_expired")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        if (pending.state != state) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_state_mismatch")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val expectedRedirect = pending.redirectUri.trim()
        if (expectedRedirect.isNotBlank()) {
            val callbackOrigin = "${uri.scheme}://${uri.host}:${uri.port}${uri.path}"
            if (callbackOrigin != expectedRedirect &&
                uri.toString().substringBefore('?') != expectedRedirect
            ) {
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_callback_redirect_mismatch")
                    .put("providerId", providerId)
                    .put("bodyRedacted", true)
            }
        }
        if (pending.verifier.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_callback_verifier_missing")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val exchanged = exchangeMobileProviderOAuthCode(
            providerId,
            code,
            pending.redirectUri,
            pending.verifier
        )
        if (!exchanged.optBoolean("ok", false)) {
            exchanged.put("providerId", providerId)
            exchanged.put("bodyRedacted", true)
            return exchanged
        }
        val stored = writeMobileProviderOAuthCredential(
            providerId,
            mobileAccountId,
            exchanged
        )
        clearPendingMobileProviderOAuth(providerId, state)
        closeActiveMobileProviderOAuthCallbackServer()
        return stored
    }

    private fun parseMobileProviderOAuthCallbackUri(
        providerId: String,
        callbackUrl: String
    ): Uri {
        val normalized = if (
            callbackUrl.startsWith("http://", ignoreCase = true) ||
            callbackUrl.startsWith("https://", ignoreCase = true)
        ) {
            callbackUrl
        } else {
            "http://$callbackUrl"
        }
        val uri = Uri.parse(normalized)
        val host = (uri.host ?: "").lowercase()
        if (
            uri.scheme?.lowercase() != "http" ||
            (
                host != mobileProviderOAuthCallbackHost(providerId) &&
                    host != CHATGPT_OAUTH_CALLBACK_BIND_HOST
            ) ||
            uri.port != mobileProviderOAuthCallbackPort(providerId)
        ) {
            throw IllegalArgumentException("Invalid OAuth callback URI")
        }
        return uri
    }

    private fun isSupportedLocalMobileProviderOAuth(providerId: String): Boolean {
        return mobileProviderOAuthDefinitionOrNull(providerId) != null
    }

    private fun mobileProviderOAuthDefinition(providerId: String): MobileProviderOAuthDefinition {
        return mobileProviderOAuthDefinitionOrNull(providerId)
            ?: throw IllegalArgumentException("Unsupported OAuth provider")
    }

    private fun mobileProviderOAuthDefinitionOrNull(
        providerId: String
    ): MobileProviderOAuthDefinition? {
        return when (providerId) {
            "chatgpt" -> MobileProviderOAuthDefinition(
                providerId = "chatgpt",
                authSurface = "openai-chatgpt-oauth",
                conversationSurface = "chatgpt-codex-responses",
                authorizeUrl = "$CHATGPT_OAUTH_ISSUER/oauth/authorize",
                tokenUrl = "$CHATGPT_OAUTH_ISSUER/oauth/token",
                clientId = CHATGPT_OAUTH_CLIENT_ID,
                scope = CHATGPT_OAUTH_SCOPE,
                callbackHost = CHATGPT_OAUTH_CALLBACK_HOST,
                callbackPort = CHATGPT_OAUTH_CALLBACK_PORT,
                callbackPath = CHATGPT_OAUTH_CALLBACK_PATH,
                defaultModel = CHATGPT_OAUTH_DEFAULT_MODEL,
                extraAuthorizeParams = listOf(
                    "id_token_add_organizations" to "true",
                    "codex_cli_simplified_flow" to "true",
                    "originator" to CHATGPT_OAUTH_ORIGINATOR
                )
            )
            else -> null
        }
    }

    private fun mobileProviderOAuthRedirectUri(providerId: String): String {
        return "http://${mobileProviderOAuthCallbackHost(providerId)}:" +
            "${mobileProviderOAuthCallbackPort(providerId)}" +
            mobileProviderOAuthCallbackPath(providerId)
    }

    private fun mobileProviderOAuthCallbackHost(providerId: String): String {
        return mobileProviderOAuthDefinition(providerId).callbackHost
    }

    private fun mobileProviderOAuthCallbackPort(providerId: String): Int {
        return mobileProviderOAuthDefinition(providerId).callbackPort
    }

    private fun mobileProviderOAuthCallbackPath(providerId: String): String {
        return mobileProviderOAuthDefinition(providerId).callbackPath
    }

    private fun replacePendingMobileProviderOAuth(pending: PendingMobileProviderOAuth) {
        val recordFile = androidProviderOAuthAttemptFile(pending.providerId, pending.state)
        val payload = MobileProviderOAuthAttemptCodec.encode(pending)
        try {
            secureMeshAndroidSecretStore.writeAndroidSecureStoreRecordToFile(
                ANDROID_PROVIDER_OAUTH_ATTEMPT_KIND,
                androidProviderOAuthAttemptLabel(pending.providerId, pending.state),
                androidProviderOAuthAttemptChallenge(pending.providerId, pending.state),
                payload,
                recordFile
            )
        } finally {
            payload.fill(0)
        }
        synchronized(mobileProviderOAuthCallbackLock) {
            pendingMobileProviderOAuthByState[
                pendingMobileProviderOAuthKey(pending.providerId, pending.state)
            ] = pending
        }
    }

    private fun loadPendingMobileProviderOAuth(
        providerId: String,
        state: String
    ): PendingMobileProviderOAuth? {
        synchronized(mobileProviderOAuthCallbackLock) {
            pendingMobileProviderOAuthByState[
                pendingMobileProviderOAuthKey(providerId, state)
            ]?.let { return it }
        }
        val recordFile = androidProviderOAuthAttemptFile(providerId, state)
        val label = androidProviderOAuthAttemptLabel(providerId, state)
        val challenge = androidProviderOAuthAttemptChallenge(providerId, state)
        if (!secureMeshAndroidSecretStore.androidSecureStoreRecordExists(
                ANDROID_PROVIDER_OAUTH_ATTEMPT_KIND,
                label,
                challenge,
                recordFile
            )
        ) {
            return null
        }
        val payload = secureMeshAndroidSecretStore.readAndroidSecureStoreRecord(
            ANDROID_PROVIDER_OAUTH_ATTEMPT_KIND,
            label,
            challenge,
            recordFile
        )
        val pending = try {
            MobileProviderOAuthAttemptCodec.decode(payload)
        } finally {
            payload.fill(0)
        }
        check(pending.providerId == providerId && pending.state == state) {
            "OAuth attempt record identity mismatch"
        }
        synchronized(mobileProviderOAuthCallbackLock) {
            pendingMobileProviderOAuthByState[
                pendingMobileProviderOAuthKey(providerId, state)
            ] = pending
        }
        return pending
    }

    private fun clearPendingMobileProviderOAuth(providerId: String, state: String) {
        synchronized(mobileProviderOAuthCallbackLock) {
            pendingMobileProviderOAuthByState.remove(
                pendingMobileProviderOAuthKey(providerId, state)
            )
            deferredMobileProviderOAuthCallback = null
        }
        deletePendingMobileProviderOAuthRecord(providerId, state)
    }

    private fun pendingMobileProviderOAuthKey(providerId: String, state: String): String {
        return "$providerId\u0000$state"
    }

    private fun deletePendingMobileProviderOAuthRecord(providerId: String, state: String) {
        val recordFile = androidProviderOAuthAttemptFile(providerId, state)
        val label = androidProviderOAuthAttemptLabel(providerId, state)
        val challenge = androidProviderOAuthAttemptChallenge(providerId, state)
        secureMeshAndroidSecretStore.deleteAndroidSecureStoreRecord(
            ANDROID_PROVIDER_OAUTH_ATTEMPT_KIND,
            label,
            challenge,
            recordFile
        )
    }

    private fun retryDeferredMobileProviderOAuthCallbackAsync() {
        if (!secureMeshAndroidUserAuthenticator.hasActiveAuthorizationGrant()) {
            return
        }
        val deferred = synchronized(mobileProviderOAuthCallbackLock) {
            if (deferredMobileProviderOAuthRetryInFlight) {
                null
            } else {
                deferredMobileProviderOAuthCallback?.also {
                    deferredMobileProviderOAuthRetryInFlight = true
                }
            }
        } ?: return
        Thread {
            try {
                val result = completeMobileProviderOAuthCallback(
                    JSONObject()
                        .put("providerId", deferred.providerId)
                        .put("callbackUrl", deferred.callbackUrl)
                        .put("mobileAccountId", deferred.mobileAccountId)
                        .put("attemptId", deferred.attemptId)
                )
                if (result.optString("status", "") !=
                    "oauth_user_authentication_required"
                ) {
                    synchronized(mobileProviderOAuthCallbackLock) {
                        if (deferredMobileProviderOAuthCallback == deferred) {
                            deferredMobileProviderOAuthCallback = null
                        }
                    }
                }
                Log.i(
                    "LicoArcOAuth",
                    "Deferred OAuth callback completed: " +
                        result.optString(
                            "status",
                            if (result.optBoolean("ok")) "ok" else "failed"
                        )
                )
            } finally {
                synchronized(mobileProviderOAuthCallbackLock) {
                    deferredMobileProviderOAuthRetryInFlight = false
                }
            }
        }.start()
    }

    private fun mobileProviderOAuthStatus(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
        if (isDeferredAndroidMobileProvider(providerId)) {
            return deferredAndroidMobileProvider(providerId, "local_oauth_status")
        }
        if (!isSupportedLocalMobileProviderOAuth(providerId)) {
            return JSONObject()
                .put("ok", false)
                .put("status", "unsupported_oauth_provider")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val mobileAccountId = mobileAccountIdFromParams(params, providerId)
        val recordFile = androidProviderOAuthCredentialReadableFile(providerId, mobileAccountId)
        if (!secureMeshAndroidSecretStore.androidSecureStoreRecordExists(
                ANDROID_PROVIDER_OAUTH_CREDENTIAL_KIND,
                androidProviderOAuthCredentialLabel(providerId, mobileAccountId),
                androidProviderOAuthCredentialChallenge(providerId, mobileAccountId),
                recordFile
            )
        ) {
            return addMobileProviderOAuthSurfaces(JSONObject()
                .put("ok", true)
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("credentialPresent", false)
                .put("credentialKind", "oauth-pkce")
                .put("status", "oauth_credential_missing")
                .put("bodyRedacted", true), providerId
            )
        }
        return try {
            val credential = readMobileProviderOAuthCredential(providerId, mobileAccountId)
            val accessToken = credential.optString("accessToken", "")
            val accountId = credential.optString("accountId", "")
            val credentialPresent = accessToken.isNotBlank() && accountId.isNotBlank()
            addMobileProviderOAuthSurfaces(JSONObject()
                .put("ok", true)
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("credentialPresent", credentialPresent)
                .put("credentialKind", "oauth-pkce")
                .put("credentialHint", "OAuth")
                .put("expiresAtEpochMillis", credential.optLong("expiresAtEpochMillis", 0L))
                .put("updatedAtEpochMillis", credential.optLong("updatedAtEpochMillis", 0L))
                .put(
                    "status",
                    if (accessToken.isNotBlank() && accountId.isBlank()) {
                        "oauth_account_id_missing"
                    } else {
                        ""
                    }
                )
                .put("source", "$providerId-oauth")
                .put("bodyRedacted", true), providerId
            )
        } catch (error: Exception) {
            addMobileProviderOAuthSurfaces(JSONObject()
                .put("ok", false)
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("credentialPresent", false)
                .put("status", "oauth_credential_unreadable")
                .put("errorClass", error.javaClass.simpleName)
                .put("bodyRedacted", true), providerId
            )
        }
    }

    private fun waitForMobileProviderOAuthCredential(
        providerId: String,
        mobileAccountId: String,
        timeoutMs: Long = CHATGPT_OAUTH_DUPLICATE_CALLBACK_SETTLE_MS,
        minUpdatedAtEpochMillis: Long = 0L
    ): JSONObject? {
        val deadlineAt = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadlineAt) {
            val status = mobileProviderOAuthStatus(
                JSONObject()
                    .put("providerId", providerId)
                    .put("mobileAccountId", mobileAccountId)
            )
            if (status.optBoolean("credentialPresent", false)) {
                val updatedAt = status.optLong("updatedAtEpochMillis", 0L)
                if (minUpdatedAtEpochMillis <= 0L ||
                    (updatedAt > 0L && updatedAt >= minUpdatedAtEpochMillis)
                ) {
                    return status
                }
            }
            Thread.sleep(CHATGPT_OAUTH_DUPLICATE_CALLBACK_POLL_MS)
        }
        return null
    }

    private fun mobileProviderOAuthAuthorizeUrl(
        providerId: String,
        redirectUri: String,
        codeChallenge: String,
        state: String
    ): String {
        val definition = mobileProviderOAuthDefinition(providerId)
        val query = (
            listOf(
            "response_type" to "code",
            "client_id" to definition.clientId,
            "redirect_uri" to redirectUri,
            "scope" to definition.scope,
            "code_challenge" to codeChallenge,
            "code_challenge_method" to "S256",
            "state" to state
            ) + definition.extraAuthorizeParams
            ).joinToString("&") { (key, value) ->
            "${urlEncode(key)}=${urlEncode(value)}"
        }
        return "${definition.authorizeUrl}?$query"
    }

    private fun openFreshMobileProviderOAuthCallbackServer(
        providerId: String
    ): MobileProviderOAuthCallbackServer {
        closeActiveMobileProviderOAuthCallbackServer()
        var lastError: Exception? = null
        val callbackPort = mobileProviderOAuthCallbackPort(providerId)
        repeat(CHATGPT_OAUTH_CALLBACK_BIND_ATTEMPTS) { attempt ->
            try {
                val fd = Os.socket(
                    OsConstants.AF_INET,
                    OsConstants.SOCK_STREAM,
                    0
                )
                Os.setsockoptInt(
                    fd,
                    OsConstants.SOL_SOCKET,
                    OsConstants.SO_REUSEADDR,
                    1
                )
                Os.bind(
                    fd,
                    InetAddress.getByName(CHATGPT_OAUTH_CALLBACK_BIND_HOST),
                    callbackPort
                )
                Os.listen(fd, CHATGPT_OAUTH_CALLBACK_BACKLOG)
                return MobileProviderOAuthCallbackServer(fd)
            } catch (error: Exception) {
                lastError = error
                if (attempt < CHATGPT_OAUTH_CALLBACK_BIND_ATTEMPTS - 1) {
                    Thread.sleep(CHATGPT_OAUTH_CALLBACK_BIND_RETRY_DELAY_MS)
                }
            }
        }
        throw lastError ?: IllegalStateException("OAuth callback server unavailable")
    }

    private fun closeActiveMobileProviderOAuthCallbackServer() {
        val server = synchronized(mobileProviderOAuthCallbackLock) {
            val active = activeMobileProviderOAuthCallbackServer
            activeMobileProviderOAuthCallbackServer = null
            active
        }
        try {
            server?.close()
        } catch (_: Exception) {
        }
    }

    private fun openMobileProviderOAuthAuthorizeUrl(
        authorizeUrl: String,
        providerId: String
    ): JSONObject? {
        val latch = CountDownLatch(1)
        val errorBox = arrayOfNulls<JSONObject>(1)
        runOnUiThread {
            try {
                startActivity(
                    oauthBrowserIntent(authorizeUrl)
                )
            } catch (error: Exception) {
                errorBox[0] = JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_browser_open_failed")
                    .put("providerId", providerId)
                    .put("errorClass", error.javaClass.simpleName)
                    .put("bodyRedacted", true)
            } finally {
                latch.countDown()
            }
        }
        if (!latch.await(5, TimeUnit.SECONDS)) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_browser_open_timed_out")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        return errorBox[0]
    }

    private fun oauthBrowserIntent(authorizeUrl: String): Intent {
        return Intent(Intent.ACTION_VIEW, Uri.parse(authorizeUrl))
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(
                "com.android.browser.application_id",
                "$packageName.oauth.${System.nanoTime()}"
            )
            .putExtra("create_new_tab", true)
    }

    private fun awaitMobileProviderOAuthCallback(
        server: MobileProviderOAuthCallbackServer,
        providerId: String,
        expectedState: String
    ): JSONObject {
        val callbackHost = mobileProviderOAuthCallbackHost(providerId)
        val callbackPort = mobileProviderOAuthCallbackPort(providerId)
        val callbackPath = mobileProviderOAuthCallbackPath(providerId)
        val deadlineAt = System.currentTimeMillis() + CHATGPT_OAUTH_CALLBACK_TIMEOUT_MS
        while (System.currentTimeMillis() < deadlineAt) {
            val remainingMs = deadlineAt - System.currentTimeMillis()
            val pollMs = minOf(
                remainingMs,
                CHATGPT_OAUTH_CALLBACK_ACCEPT_POLL_MS.toLong()
            ).toInt()
            val client = try {
                server.accept(pollMs)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (error: Exception) {
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_callback_failed")
                    .put("errorClass", error.javaClass.simpleName)
            }
            if (client == null) {
                continue
            }
            try {
                val requestLine = try {
                    readMobileProviderOAuthCallbackRequestLine(client)
                } catch (_: SocketTimeoutException) {
                    null
                } catch (_: Exception) {
                    null
                }
                if (requestLine.isNullOrBlank()) {
                    continue
                }
                val parts = requestLine.split(" ")
                val target = parts.getOrNull(1) ?: ""
                val uri = if (target.startsWith("http://") || target.startsWith("https://")) {
                    Uri.parse(target)
                } else {
                    Uri.parse(
                        "http://$callbackHost:$callbackPort$target"
                    )
                }
                if (uri.path != callbackPath) {
                    sendOAuthCallbackResponse(
                        client,
                        false,
                        "Invalid OAuth callback path."
                    )
                    continue
                }
                val state = uri.getQueryParameter("state") ?: ""
                val code = uri.getQueryParameter("code") ?: ""
                val error = uri.getQueryParameter("error") ?: ""
                val ok = state == expectedState && code.isNotBlank() && error.isBlank()
                sendOAuthCallbackResponse(client, ok, error)
                if (state != expectedState) {
                    return JSONObject()
                        .put("ok", false)
                        .put("status", "oauth_state_mismatch")
                }
                if (error.isNotBlank()) {
                    return JSONObject()
                        .put("ok", false)
                        .put("status", "oauth_provider_error")
                        .put("errorCode", error)
                }
                return JSONObject()
                    .put("ok", true)
                    .put("code", code)
            } finally {
                try {
                    Os.close(client)
                } catch (_: Exception) {
                }
            }
        }
        return JSONObject()
            .put("ok", false)
            .put("status", "oauth_callback_timed_out")
    }

    private fun readMobileProviderOAuthCallbackRequestLine(client: FileDescriptor): String? {
        val request = ByteArrayOutputStream()
        val buffer = ByteArray(CHATGPT_OAUTH_CALLBACK_READ_BUFFER_BYTES)
        val deadlineAt = System.currentTimeMillis() +
            CHATGPT_OAUTH_CALLBACK_SOCKET_READ_TIMEOUT_MS
        while (System.currentTimeMillis() < deadlineAt) {
            val remainingMs = (deadlineAt - System.currentTimeMillis()).toInt()
            if (!pollFileDescriptor(
                    client,
                    OsConstants.POLLIN,
                    remainingMs
                )
            ) {
                return null
            }
            val bytesRead = Os.read(client, buffer, 0, buffer.size)
            if (bytesRead <= 0) {
                break
            }
            request.write(buffer, 0, bytesRead)
            if (request.size() > CHATGPT_OAUTH_CALLBACK_MAX_REQUEST_BYTES) {
                return null
            }
            val raw = request.toByteArray()
            val text = String(raw, Charsets.UTF_8)
            if (text.contains("\r\n\r\n") || text.contains("\n\n")) {
                return text.lineSequence().firstOrNull()
            }
        }
        return null
    }

    private fun sendOAuthCallbackResponse(client: FileDescriptor, ok: Boolean, error: String) {
        val body = if (ok) {
            "<!doctype html><html><body><h1>Lico Arc authorization received</h1><p>Return to Lico Arc. The app will verify direct ChatGPT chat before marking this authorization successful.</p></body></html>"
        } else {
            "<!doctype html><html><body><h1>Lico Arc authorization failed</h1><p>${error.ifBlank { "Please return to Lico Arc and retry." }}</p></body></html>"
        }
        val bodyBytes = body.toByteArray(Charsets.UTF_8)
        val status = if (ok) "200 OK" else "400 Bad Request"
        val response = "HTTP/1.1 $status\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: ${bodyBytes.size}\r\n" +
            "Connection: close\r\n\r\n"
        val responseBytes = response.toByteArray(Charsets.UTF_8) + bodyBytes
        var offset = 0
        while (offset < responseBytes.size) {
            if (!pollFileDescriptor(
                    client,
                    OsConstants.POLLOUT,
                    CHATGPT_OAUTH_CALLBACK_SOCKET_WRITE_TIMEOUT_MS
                )
            ) {
                break
            }
            val written = Os.write(
                client,
                responseBytes,
                offset,
                responseBytes.size - offset
            )
            if (written <= 0) {
                break
            }
            offset += written
        }
        try {
            Os.shutdown(client, OsConstants.SHUT_RDWR)
        } catch (_: Exception) {
        }
    }

    private fun pollFileDescriptor(
        fileDescriptor: FileDescriptor,
        events: Int,
        timeoutMs: Int
    ): Boolean {
        if (timeoutMs <= 0) {
            return false
        }
        val pollFd = StructPollfd().also {
            it.fd = fileDescriptor
            it.events = events.toShort()
        }
        val ready = Os.poll(arrayOf(pollFd), timeoutMs)
        return ready > 0 && (pollFd.revents.toInt() and events) != 0
    }

    private fun openProviderHttpsConnection(urlText: String): ProviderHttpsConnection {
        val url = URL(urlText)
        val androidProxy = currentAndroidHttpProxy()
        if (androidProxy != null) {
            return ProviderHttpsConnection(
                connection = url.openConnection(androidProxy.toJavaProxy())
                    as HttpsURLConnection,
                proxyMode = "android-system-proxy"
            )
        }
        val selectorProxy = currentProxySelectorProxy(urlText)
        if (selectorProxy != null) {
            return ProviderHttpsConnection(
                connection = url.openConnection(selectorProxy) as HttpsURLConnection,
                proxyMode = "java-proxy-selector"
            )
        }
        return ProviderHttpsConnection(
            connection = url.openConnection() as HttpsURLConnection,
            proxyMode = "direct"
        )
    }

    @Suppress("DEPRECATION")
    private fun currentAndroidHttpProxy(): AndroidHttpProxyConfig? {
        val contextHost = try {
            android.net.Proxy.getHost(this) ?: ""
        } catch (_: Exception) {
            ""
        }
        val defaultHost = try {
            android.net.Proxy.getDefaultHost() ?: ""
        } catch (_: Exception) {
            ""
        }
        val host = firstNonBlank(
            contextHost,
            defaultHost,
            System.getProperty("https.proxyHost") ?: "",
            System.getProperty("http.proxyHost") ?: ""
        )
        if (host.isBlank()) {
            return null
        }
        val port = listOf(
            try {
                android.net.Proxy.getPort(this)
            } catch (_: Exception) {
                -1
            },
            try {
                android.net.Proxy.getDefaultPort()
            } catch (_: Exception) {
                -1
            },
            proxyPortProperty("https.proxyPort"),
            proxyPortProperty("http.proxyPort")
        ).firstOrNull { it in 1..65535 } ?: return null
        return AndroidHttpProxyConfig(host = host, port = port)
    }

    private fun proxyPortProperty(name: String): Int {
        return System.getProperty(name)?.toIntOrNull() ?: -1
    }

    private fun currentProxySelectorProxy(urlText: String): java.net.Proxy? {
        return try {
            val uri = URL(urlText).toURI()
            java.net.ProxySelector.getDefault()
                ?.select(uri)
                ?.firstOrNull {
                    it.type() != java.net.Proxy.Type.DIRECT && it.address() != null
                }
        } catch (_: Exception) {
            null
        }
    }

    private fun addProviderProxyDiagnostic(
        response: JSONObject,
        proxyMode: String
    ): JSONObject {
        return response
            .put("proxyDetected", proxyMode != "direct")
            .put("proxyMode", proxyMode)
    }

    private fun addMobileProviderOAuthSurfaces(
        response: JSONObject,
        providerId: String
    ): JSONObject {
        val definition = mobileProviderOAuthDefinitionOrNull(providerId)
            ?: return response
        return response
            .put("authSurface", definition.authSurface)
            .put("conversationSurface", definition.conversationSurface)
    }

    private fun exchangeMobileProviderOAuthCode(
        providerId: String,
        code: String,
        redirectUri: String,
        verifier: String
    ): JSONObject {
        return exchangeChatGptOAuthCode(code, redirectUri, verifier)
    }

    private fun exchangeChatGptOAuthCode(
        code: String,
        redirectUri: String,
        verifier: String
    ): JSONObject {
        val definition = mobileProviderOAuthDefinition("chatgpt")
        val body = listOf(
            "grant_type" to "authorization_code",
            "code" to code,
            "redirect_uri" to redirectUri,
            "client_id" to definition.clientId,
            "code_verifier" to verifier
        ).joinToString("&") { (key, value) ->
            "${urlEncode(key)}=${urlEncode(value)}"
        }
        var proxyMode = "direct"
        return try {
            val opened = openProviderHttpsConnection(definition.tokenUrl)
            proxyMode = opened.proxyMode
            val connection = opened.connection
            connection.requestMethod = "POST"
            connection.connectTimeout = 30_000
            connection.readTimeout = 30_000
            connection.doOutput = true
            connection.setRequestProperty(
                "Content-Type",
                "application/x-www-form-urlencoded"
            )
            connection.outputStream.use {
                it.write(body.toByteArray(Charsets.UTF_8))
            }
            val status = connection.responseCode
            val responseText = readHttpText(connection)
            if (status !in 200..299) {
                return addProviderProxyDiagnostic(
                    JSONObject()
                        .put("ok", false)
                        .put("status", "oauth_token_exchange_failed")
                        .put("statusCode", status)
                        .put("bodyRedacted", true),
                    proxyMode
                )
            }
            val response = JSONObject(responseText)
            val idToken = response.optString("id_token", "")
            val accessToken = response.optString("access_token", "")
            val refreshToken = response.optString("refresh_token", "")
            if (accessToken.isBlank() || refreshToken.isBlank()) {
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_token_response_incomplete")
                    .put("bodyRedacted", true)
            }
            val accountId = chatGptOAuthAccountId(idToken, accessToken)
            if (accountId.isBlank()) {
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_account_id_missing")
                    .put("bodyRedacted", true)
            }
            val expiresIn = response.optLong("expires_in", 0L).takeIf { it > 0L }
                ?: (8L * 24L * 60L * 60L)
            addMobileProviderOAuthSurfaces(JSONObject()
                .put("ok", true)
                .put("idToken", idToken)
                .put("accessToken", accessToken)
                .put("refreshToken", refreshToken)
                .put("accountId", accountId)
                .put("expiresAtEpochMillis", System.currentTimeMillis() + expiresIn * 1000L)
                .put("bodyRedacted", true), definition.providerId
            )
        } catch (error: Exception) {
            addProviderProxyDiagnostic(
                JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_token_exchange_failed")
                    .put("errorClass", error.javaClass.simpleName)
                    .put("bodyRedacted", true),
                proxyMode
            )
        }
    }

    private fun writeMobileProviderOAuthCredential(
        providerId: String,
        mobileAccountId: String,
        exchanged: JSONObject
    ): JSONObject {
        val definition = mobileProviderOAuthDefinition(providerId)
        val source = firstNonBlank(exchanged.optString("source", ""), "$providerId-oauth")
        val credential = JSONObject()
            .put("providerId", providerId)
            .put("mobileAccountId", mobileAccountId)
            .put("credentialKind", "oauth-pkce")
            .put("authSurface", definition.authSurface)
            .put("conversationSurface", definition.conversationSurface)
            .put("idToken", exchanged.optString("idToken", ""))
            .put("accessToken", exchanged.optString("accessToken", ""))
            .put("refreshToken", exchanged.optString("refreshToken", ""))
            .put("accountId", exchanged.optString("accountId", ""))
            .put("expiresAtEpochMillis", exchanged.optLong("expiresAtEpochMillis", 0L))
            .put("source", source)
            .put("updatedAtEpochMillis", System.currentTimeMillis())
        val recordFile = androidProviderOAuthCredentialFile(providerId, mobileAccountId)
        val secret = credential.toString().toByteArray(Charsets.UTF_8)
        try {
            secureMeshAndroidSecretStore.writeAndroidSecureStoreRecordToFile(
                ANDROID_PROVIDER_OAUTH_CREDENTIAL_KIND,
                androidProviderOAuthCredentialLabel(providerId, mobileAccountId),
                androidProviderOAuthCredentialChallenge(providerId, mobileAccountId),
                secret,
                recordFile
            )
        } finally {
            secret.fill(0)
        }
        return addMobileProviderOAuthSurfaces(JSONObject()
            .put("ok", true)
            .put("providerId", providerId)
            .put("mobileAccountId", mobileAccountId)
            .put("credentialPresent", true)
            .put("credentialKind", "oauth-pkce")
            .put("credentialHint", "OAuth")
            .put("source", source)
            .put(
                "secureStore",
                secureMeshAndroidSecretStore.secureMeshAndroidGeneralCustodyBackend()
            )
            .put("bodyRedacted", true), providerId
        )
    }

    private fun readMobileProviderOAuthCredential(
        providerId: String,
        mobileAccountId: String
    ): JSONObject {
        val secret = secureMeshAndroidSecretStore.readAndroidSecureStoreRecord(
            ANDROID_PROVIDER_OAUTH_CREDENTIAL_KIND,
            androidProviderOAuthCredentialLabel(providerId, mobileAccountId),
            androidProviderOAuthCredentialChallenge(providerId, mobileAccountId),
            androidProviderOAuthCredentialReadableFile(providerId, mobileAccountId)
        )
        val credential = try {
            JSONObject(String(secret, Charsets.UTF_8))
        } finally {
            secret.fill(0)
        }
        return normalizeReadMobileProviderOAuthCredential(
            providerId,
            mobileAccountId,
            credential
        )
    }

    private fun normalizeReadMobileProviderOAuthCredential(
        providerId: String,
        mobileAccountId: String,
        credential: JSONObject
    ): JSONObject {
        if (providerId != "chatgpt") {
            return credential
        }
        val existingAccountId = credential.optString("accountId", "")
        if (existingAccountId.isNotBlank()) {
            return credential
        }
        val accessToken = credential.optString("accessToken", "")
        val idToken = credential.optString("idToken", "")
        val derivedAccountId = chatGptOAuthAccountId(idToken, accessToken)
        if (derivedAccountId.isBlank()) {
            return credential
        }
        val normalized = JSONObject(credential.toString())
            .put("accountId", derivedAccountId)
        return try {
            writeMobileProviderOAuthCredential(providerId, mobileAccountId, normalized)
            normalized
        } catch (_: Exception) {
            normalized
        }
    }

    private fun refreshMobileProviderOAuthCredentialIfNeeded(
        providerId: String,
        mobileAccountId: String,
        credential: JSONObject
    ): JSONObject {
        return refreshChatGptOAuthCredentialIfNeeded(
            providerId,
            mobileAccountId,
            credential
        )
    }

    private fun refreshChatGptOAuthCredentialIfNeeded(
        providerId: String,
        mobileAccountId: String,
        credential: JSONObject
    ): JSONObject {
        val definition = mobileProviderOAuthDefinition(providerId)
        val expiresAt = credential.optLong("expiresAtEpochMillis", 0L)
        if (expiresAt <= 0L ||
            expiresAt - System.currentTimeMillis() > CHATGPT_OAUTH_REFRESH_SKEW_MS
        ) {
            return credential
        }
        val refreshToken = credential.optString("refreshToken", "")
        if (refreshToken.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_refresh_token_missing")
                .put("providerId", providerId)
                .put("bodyRedacted", true)
        }
        val body = listOf(
            "grant_type" to "refresh_token",
            "refresh_token" to refreshToken,
            "client_id" to definition.clientId
        ).joinToString("&") { (key, value) ->
            "${urlEncode(key)}=${urlEncode(value)}"
        }
        var proxyMode = "direct"
        return try {
            val opened = openProviderHttpsConnection(definition.tokenUrl)
            proxyMode = opened.proxyMode
            val connection = opened.connection
            connection.requestMethod = "POST"
            connection.connectTimeout = 30_000
            connection.readTimeout = 30_000
            connection.doOutput = true
            connection.setRequestProperty(
                "Content-Type",
                "application/x-www-form-urlencoded"
            )
            connection.outputStream.use {
                it.write(body.toByteArray(Charsets.UTF_8))
            }
            val status = connection.responseCode
            val responseText = readHttpText(connection)
            if (status !in 200..299) {
                return addProviderProxyDiagnostic(
                    JSONObject()
                        .put("ok", false)
                        .put("status", "oauth_token_refresh_failed")
                        .put("statusCode", status)
                        .put("providerId", providerId)
                        .put("bodyRedacted", true),
                    proxyMode
                )
            }
            val response = JSONObject(responseText)
            val accessToken = response.optString("access_token", "")
            if (accessToken.isBlank()) {
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_token_refresh_incomplete")
                    .put("providerId", providerId)
                    .put("bodyRedacted", true)
            }
            val idToken = firstNonBlank(
                response.optString("id_token", ""),
                credential.optString("idToken", "")
            )
            val nextRefreshToken = firstNonBlank(
                response.optString("refresh_token", ""),
                refreshToken
            )
            val expiresIn = response.optLong("expires_in", 0L).takeIf { it > 0L }
                ?: (8L * 24L * 60L * 60L)
            val accountId = firstNonBlank(
                chatGptOAuthAccountId(idToken, accessToken),
                credential.optString("accountId", "")
            )
            if (accountId.isBlank()) {
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_account_id_missing")
                    .put("providerId", providerId)
                    .put("bodyRedacted", true)
            }
            val refreshed = addMobileProviderOAuthSurfaces(JSONObject()
                .put("ok", true)
                .put("idToken", idToken)
                .put("accessToken", accessToken)
                .put("refreshToken", nextRefreshToken)
                .put("accountId", accountId)
                .put("expiresAtEpochMillis", System.currentTimeMillis() + expiresIn * 1000L)
                .put("bodyRedacted", true), providerId
            )
            writeMobileProviderOAuthCredential(providerId, mobileAccountId, refreshed)
            refreshed
        } catch (error: Exception) {
            addProviderProxyDiagnostic(
                JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_token_refresh_failed")
                    .put("providerId", providerId)
                    .put("errorClass", error.javaClass.simpleName)
                    .put("bodyRedacted", true),
                proxyMode
            )
        }
    }

    private fun secureMeshNativeLibraryUnavailable(): Map<String, Any?> {
        return mapOf(
            "ok" to false,
            "code" to "secure_mesh_native_library_unavailable",
            "library" to SECURE_MESH_NATIVE_LIBRARY
        )
    }

    private fun setMobileProviderCredential(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
        if (isDeferredAndroidMobileProvider(providerId)) {
            return deferredAndroidMobileProvider(providerId, "local_credential_set")
        }
        if (!isSupportedMobileProvider(providerId)) {
            return unsupportedMobileProvider(providerId)
        }
        val mobileAccountId = mobileAccountIdFromParams(params, providerId)
        val apiKey = firstNonBlank(
            params.optString("apiKey", ""),
            params.optString("credential", "")
        )
        if (apiKey.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "credential_missing")
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("bodyRedacted", true)
        }
        val source = firstNonBlank(params.optString("source", ""), "local-api-key")
        return writeMobileProviderCredential(providerId, mobileAccountId, apiKey, source)
    }

    private fun mobileProviderCredentialStatus(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
        if (isDeferredAndroidMobileProvider(providerId)) {
            return deferredAndroidMobileProvider(providerId, "local_credential_status")
        }
        if (!isSupportedMobileProvider(providerId)) {
            return unsupportedMobileProvider(providerId)
        }
        val mobileAccountId = mobileAccountIdFromParams(params, providerId)
        val recordFile = androidProviderCredentialReadableFile(providerId, mobileAccountId)
        if (!secureMeshAndroidSecretStore.androidSecureStoreRecordExists(
                ANDROID_PROVIDER_CREDENTIAL_KIND,
                androidProviderCredentialLabel(providerId, mobileAccountId),
                androidProviderCredentialChallenge(providerId, mobileAccountId),
                recordFile
            )
        ) {
            return JSONObject()
                .put("ok", true)
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("credentialPresent", false)
                .put("bodyRedacted", true)
        }
        return try {
            val credential = readMobileProviderCredential(providerId, mobileAccountId)
            JSONObject()
                .put("ok", true)
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("credentialPresent", credential.isNotBlank())
                .put("credentialHint", credentialHint(credential))
                .put(
                    "source",
                    secureMeshAndroidSecretStore.secureMeshAndroidGeneralCustodyBackend()
                )
                .put("bodyRedacted", true)
        } catch (error: Exception) {
            JSONObject()
                .put("ok", false)
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("credentialPresent", false)
                .put("status", "credential_unreadable")
                .put("errorClass", error.javaClass.simpleName)
                .put("bodyRedacted", true)
        }
    }

    private fun deleteMobileProviderCredential(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
        if (isDeferredAndroidMobileProvider(providerId)) {
            return deferredAndroidMobileProvider(providerId, "local_credential_delete")
        }
        if (!isSupportedMobileProvider(providerId)) {
            return unsupportedMobileProvider(providerId)
        }
        val mobileAccountId = mobileAccountIdFromParams(params, providerId)
        val records = mutableListOf(
            androidProviderCredentialRecord(providerId, mobileAccountId),
            androidProviderOAuthCredentialRecord(providerId, mobileAccountId),
            androidV2ProviderCredentialRecord(providerId, mobileAccountId),
            androidV2ProviderOAuthCredentialRecord(providerId, mobileAccountId)
        )
        if (mobileAccountId == providerId) {
            records.add(androidLegacyProviderCredentialRecord(providerId))
            records.add(androidLegacyProviderOAuthCredentialRecord(providerId))
        }
        var deleted = false
        var deletionFailed = false
        records.forEach { record ->
            if (secureMeshAndroidSecretStore.androidSecureStoreRecordExists(
                    record.kind,
                    record.label,
                    record.challenge,
                    record.file
                )
            ) {
                val removed = secureMeshAndroidSecretStore.deleteAndroidSecureStoreRecord(
                    record.kind,
                    record.label,
                    record.challenge,
                    record.file
                )
                deleted = removed || deleted
                deletionFailed = !removed || deletionFailed
            }
        }
        return JSONObject()
            .put("ok", !deletionFailed)
            .put("providerId", providerId)
            .put("mobileAccountId", mobileAccountId)
            .put("deleted", deleted)
            .put(
                "status",
                if (deletionFailed) "credential_delete_failed" else "credential_deleted"
            )
            .put("bodyRedacted", true)
    }

    private fun syncMobileProviderCredentialFromRelay(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
        if (isDeferredAndroidMobileProvider(providerId)) {
            return deferredAndroidMobileProvider(providerId, "local_credential_sync")
        }
        if (!isSupportedMobileProvider(providerId)) {
            return unsupportedMobileProvider(providerId)
        }
        val mobileAccountId = mobileAccountIdFromParams(params, providerId)
        val profileId = firstNonBlank(
            params.optString("profileId", ""),
            params.optString("profile", ""),
            params.optString("modelProfile", "")
        )
        val body = JSONObject().put("providerId", providerId)
        if (profileId.isNotBlank()) {
            body
                .put("profile", profileId)
                .put("modelProfile", profileId)
                .put("profileId", profileId)
        }
        val createParams = JSONObject()
            .put("commandKind", "provider.credential.export")
            .put("workspaceId", firstNonBlank(params.optString("workspaceId", ""), "default"))
            .put("body", body)
        val created = runNativeSecureMeshJsonObject(
            "mobile.relay.commands.createSecure",
            createParams
        )
        if (!created.optBoolean("ok", false)) {
            return redactProviderCredentialSyncFailure(
                created,
                "provider_credential_sync_create_failed",
                providerId
            )
        }
        val commandId = created.optJSONObject("command")?.optString("commandId", "")
            ?: created.optString("commandId", "")
        if (commandId.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("status", "provider_credential_sync_missing_command_id")
                .put("bodyRedacted", true)
        }
        val maxAttempts = params.optInt("maxAttempts", 60).coerceIn(1, 120)
        val pollIntervalMs = params.optLong("pollIntervalMs", 1000L).coerceIn(250L, 5000L)
        repeat(maxAttempts) {
            Thread.sleep(pollIntervalMs)
            val result = runNativeSecureMeshJsonObject(
                "mobile.relay.commands.resultSecure",
                JSONObject().put("commandId", commandId)
            )
            val credentialPayload = providerCredentialPayloadFromSecureResult(result, providerId)
            if (credentialPayload != null) {
                val credentialKind = normalizeProviderCredentialKind(
                    credentialPayload.optString("credentialKind", "api-key")
                )
                if (credentialKind.startsWith("oauth")) {
                    val saved = writeMobileProviderOAuthCredential(
                        providerId,
                        mobileAccountId,
                        credentialPayload
                    )
                    saved
                        .put("mobileAccountId", mobileAccountId)
                        .put("profileId", profileId)
                        .put("syncedFromRelay", true)
                        .put("commandId", commandId)
                    return saved
                }
                val apiKey = firstNonBlank(
                    credentialPayload.optString("apiKey", ""),
                    credentialPayload.optString("credential", "")
                )
                if (apiKey.isBlank()) {
                    return JSONObject()
                        .put("ok", false)
                        .put("providerId", providerId)
                        .put("status", "provider_credential_sync_empty_credential")
                        .put("bodyRedacted", true)
                }
                val saved = writeMobileProviderCredential(
                    providerId,
                    mobileAccountId,
                    apiKey,
                    firstNonBlank(credentialPayload.optString("source", ""), "desktop-relay")
                )
                saved
                    .put("mobileAccountId", mobileAccountId)
                    .put("profileId", profileId)
                    .put("syncedFromRelay", true)
                    .put("commandId", commandId)
                return saved
            }
            val status = result.optJSONObject("response")
                ?.optJSONObject("command")
                ?.optString("status", "")
                ?: ""
            if (status == "failed") {
                return redactProviderCredentialSyncFailure(
                    result,
                    "provider_credential_sync_failed",
                    providerId
                )
            }
        }
        return JSONObject()
            .put("ok", false)
            .put("providerId", providerId)
            .put("status", "provider_credential_sync_timed_out")
            .put("commandId", commandId)
            .put("bodyRedacted", true)
    }

    private fun mobileProviderChatCanRunWithoutNativeRuntime(params: JSONObject): Boolean {
        val providerId = mobileProviderIdFromParams(params)
        if (isDeferredAndroidMobileProvider(providerId)) {
            return true
        }
        if (providerId != "chatgpt") {
            return false
        }
        val mobileAccountId = mobileAccountIdFromParams(params, providerId)
        val apiKey = try {
            readMobileProviderCredential(providerId, mobileAccountId)
        } catch (_: Exception) {
            ""
        }
        return apiKey.isBlank()
    }

    private fun mobileProviderIdFromParams(params: JSONObject): String {
        return normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
    }

    private fun sendMobileProviderChat(params: JSONObject): JSONObject {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", "")
            )
        )
        if (isDeferredAndroidMobileProvider(providerId)) {
            return deferredAndroidMobileProvider(providerId, "local_chat")
        }
        if (!isSupportedMobileProvider(providerId)) {
            return unsupportedMobileProvider(providerId)
        }
        val mobileAccountId = mobileAccountIdFromParams(params, providerId)
        val apiKey = try {
            readMobileProviderCredential(providerId, mobileAccountId)
        } catch (_: Exception) {
            ""
        }
        if (apiKey.isBlank()) {
            if (providerId == "chatgpt") {
                val oauthCredential = try {
                    readMobileProviderOAuthCredential(providerId, mobileAccountId)
                } catch (_: Exception) {
                    null
                }
                if (oauthCredential != null &&
                    oauthCredential.optString("accessToken", "").isNotBlank()
                ) {
                    return sendMobileProviderOAuthChat(
                        providerId,
                        mobileAccountId,
                        oauthCredential,
                        params
                    )
                }
                return JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_credential_missing")
                    .put("providerId", providerId)
                    .put("mobileAccountId", mobileAccountId)
                    .put("credentialKind", "oauth-pkce")
                    .put("message", "ChatGPT OAuth authorization is missing on this phone.")
                    .put("bodyRedacted", true)
            }
            return JSONObject()
                .put("ok", false)
                .put("status", "credential_missing")
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("message", "${mobileProviderLabel(providerId)} API Key is not configured on this phone.")
                .put("bodyRedacted", true)
        }
        val forwarded = JSONObject(params.toString())
            .put("providerId", providerId)
            .put("apiKey", apiKey)
        return runNativeSecureMeshJsonObject("provider.chat.send", forwarded)
    }

    private fun sendMobileProviderOAuthChat(
        providerId: String,
        mobileAccountId: String,
        credential: JSONObject,
        params: JSONObject
    ): JSONObject {
        val text = firstNonBlank(
            params.optString("text", ""),
            params.optString("message", ""),
            params.optString("prompt", ""),
            params.optString("input", "")
        )
        if (text.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("providerId", providerId)
                .put("mobileAccountId", mobileAccountId)
                .put("status", "message_missing")
                .put("bodyRedacted", true)
        }
        val activeCredential = refreshMobileProviderOAuthCredentialIfNeeded(
            providerId,
            mobileAccountId,
            credential
        )
        if (!activeCredential.optBoolean("ok", true)) {
            return activeCredential
        }
        val accessToken = activeCredential.optString("accessToken", "")
        val accountId = activeCredential.optString("accountId", "")
            val requestedModel = firstNonBlank(
                params.optString("model", ""),
                params.optString("modelId", ""),
                CHATGPT_OAUTH_DEFAULT_MODEL
            )
            val reasoningEffort = normalizeChatGptReasoningEffort(
                firstNonBlank(
                    params.optString("reasoningEffort", ""),
                    params.optString("reasoning_effort", "")
                )
            )
            val selectedModel = selectChatGptCodexResponsesModel(
                accessToken = accessToken,
                accountId = accountId,
                requestedModel = requestedModel
            )
            return sendChatGptCodexResponsesMessage(
                accessToken = accessToken,
                accountId = accountId,
                modelSelection = selectedModel,
                reasoningEffort = reasoningEffort,
                text = text
            )
            .put("providerId", providerId)
            .put("mobileAccountId", mobileAccountId)
    }

    private fun sendChatGptCodexResponsesMessage(
        accessToken: String,
        accountId: String,
        modelSelection: ChatGptCodexModelSelection,
        reasoningEffort: String,
        text: String
    ): JSONObject {
        if (accessToken.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_access_token_missing")
                .put("bodyRedacted", true)
        }
        if (accountId.isBlank()) {
            return JSONObject()
                .put("ok", false)
                .put("status", "oauth_account_id_missing")
                .put("bodyRedacted", true)
        }
        val model = modelSelection.model
        var proxyMode = "direct"
        return try {
            val opened = openProviderHttpsConnection(CHATGPT_CODEX_RESPONSES_URL)
            proxyMode = opened.proxyMode
            val connection = opened.connection
            connection.requestMethod = "POST"
            connection.connectTimeout = 30_000
            connection.readTimeout = CHATGPT_OAUTH_CHAT_TIMEOUT_MS.toInt()
            connection.doOutput = true
            connection.setRequestProperty("Authorization", "Bearer $accessToken")
            connection.setRequestProperty("Accept", "text/event-stream")
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("User-Agent", CHATGPT_OAUTH_USER_AGENT)
            connection.setRequestProperty("originator", CHATGPT_OAUTH_ORIGINATOR)
            connection.setRequestProperty("version", CHATGPT_OAUTH_VERSION)
            connection.outputStream.use {
                it.write(
                    chatGptCodexResponsesRequest(
                        model = model,
                        reasoningEffort = reasoningEffort,
                        text = text
                    ).toString().toByteArray(Charsets.UTF_8)
                )
            }
            val status = connection.responseCode
            val responseText = readHttpText(connection)
            if (status !in 200..299) {
                val errorSummary = chatGptCodexResponsesErrorSummary(responseText)
                return addProviderProxyDiagnostic(
                    JSONObject()
                        .put("ok", false)
                        .put("status", "oauth_chat_failed")
                        .put("statusCode", status)
                        .put("mode", "chatgpt-oauth-codex-responses")
                        .put("credentialKind", "oauth-pkce")
                        .put("model", model)
                        .put("requestedModel", modelSelection.requestedModel)
                        .put("reasoningEffort", reasoningEffort)
                        .put("modelDiscoveryStatus", modelSelection.discoveryStatus)
                        .put("discoveredModelCount", modelSelection.discoveredModelCount)
                        .put("error", errorSummary.optString("message", ""))
                        .put("message", errorSummary.optString("message", ""))
                        .put("errorCode", errorSummary.optString("code", ""))
                        .put("bodyRedacted", true),
                    proxyMode
                )
            }
            val parsed = chatGptCodexResponsesResponse(responseText)
            val parsedStatus = parsed.optString("status", "")
            if (parsedStatus.isNotBlank()) {
                return addProviderProxyDiagnostic(
                    JSONObject()
                        .put("ok", false)
                        .put("status", parsedStatus)
                        .put("error", parsed.optString("error", ""))
                        .put("errorCode", parsed.optString("errorCode", ""))
                        .put("mode", "chatgpt-oauth-codex-responses")
                        .put("credentialKind", "oauth-pkce")
                        .put("model", model)
                        .put("requestedModel", modelSelection.requestedModel)
                        .put("reasoningEffort", reasoningEffort)
                        .put("modelDiscoveryStatus", modelSelection.discoveryStatus)
                        .put("discoveredModelCount", modelSelection.discoveredModelCount)
                        .put("responseId", parsed.optString("responseId", ""))
                        .put("bodyRedacted", true),
                    proxyMode
                )
            }
            val content = parsed.optString("content", "")
            addProviderProxyDiagnostic(
                JSONObject()
                    .put("ok", content.isNotBlank())
                    .put(
                        "status",
                        if (content.isBlank()) "oauth_chat_failed" else ""
                    )
                    .put("mode", "chatgpt-oauth-codex-responses")
                    .put("credentialKind", "oauth-pkce")
                    .put("model", model)
                    .put("requestedModel", modelSelection.requestedModel)
                    .put("reasoningEffort", reasoningEffort)
                    .put("modelDiscoveryStatus", modelSelection.discoveryStatus)
                    .put("discoveredModelCount", modelSelection.discoveredModelCount)
                    .put("responseId", parsed.optString("responseId", ""))
                    .put("output", content)
                    .put("content", content)
                    .put("bodyRedacted", true),
                proxyMode
            )
        } catch (error: Exception) {
            addProviderProxyDiagnostic(
                JSONObject()
                    .put("ok", false)
                    .put("status", "oauth_chat_transport_failed")
                    .put("mode", "chatgpt-oauth-codex-responses")
                    .put("errorClass", error.javaClass.simpleName)
                    .put("bodyRedacted", true),
                proxyMode
            )
        }
    }

    private fun chatGptCodexResponsesRequest(
        model: String,
        reasoningEffort: String,
        text: String
    ): JSONObject {
        val inputContent = JSONArray().put(
            JSONObject()
                .put("type", "input_text")
                .put("text", text)
        )
        val input = JSONArray().put(
            JSONObject()
                .put("role", "user")
                .put("content", inputContent)
        )
        val request = JSONObject()
            .put("model", model)
            .put("store", false)
            .put("stream", true)
            .put("instructions", "Follow the user request.")
            .put("input", input)
        if (reasoningEffort.isNotBlank()) {
            request.put("reasoning", JSONObject().put("effort", reasoningEffort))
        }
        return request
    }

    private fun normalizeChatGptReasoningEffort(value: String): String {
        return when (value.trim().lowercase()) {
            "low" -> "low"
            "medium" -> "medium"
            "high" -> "high"
            else -> ""
        }
    }

    private fun selectChatGptCodexResponsesModel(
        accessToken: String,
        accountId: String,
        requestedModel: String
    ): ChatGptCodexModelSelection {
        val normalizedRequested = firstNonBlank(requestedModel, CHATGPT_OAUTH_DEFAULT_MODEL)
        return try {
            val opened = openProviderHttpsConnection(CHATGPT_CODEX_MODELS_URL)
            val connection = opened.connection
            connection.requestMethod = "GET"
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Authorization", "Bearer $accessToken")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", CHATGPT_OAUTH_USER_AGENT)
            connection.setRequestProperty("originator", CHATGPT_OAUTH_ORIGINATOR)
            connection.setRequestProperty("version", CHATGPT_OAUTH_VERSION)
            connection.setRequestProperty("ChatGPT-Account-ID", accountId)
            val status = connection.responseCode
            val responseText = readHttpText(connection)
            if (status !in 200..299) {
                return ChatGptCodexModelSelection(
                    model = normalizedRequested,
                    requestedModel = normalizedRequested,
                    discoveryStatus = "http_$status"
                )
            }
            val models = chatGptCodexModelIds(responseText)
            val selected = chooseChatGptCodexModel(models, normalizedRequested)
            ChatGptCodexModelSelection(
                model = selected,
                requestedModel = normalizedRequested,
                discoveryStatus = "ok",
                discoveredModelCount = models.size
            )
        } catch (_: Exception) {
            ChatGptCodexModelSelection(
                model = normalizedRequested,
                requestedModel = normalizedRequested,
                discoveryStatus = "unavailable"
            )
        }
    }

    private fun chatGptCodexModelIds(rawText: String): List<String> {
        if (rawText.isBlank()) {
            return emptyList()
        }
        val parsed = JSONObject(rawText)
        val rows = parsed.optJSONArray("models") ?: parsed.optJSONArray("data") ?: JSONArray()
        val models = mutableListOf<String>()
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            val visibility = row.optString("visibility", "").trim().lowercase()
            if (visibility == "hide" || visibility == "none") {
                continue
            }
            val id = firstNonBlank(
                row.optString("slug", ""),
                row.optString("id", ""),
                row.optString("model", "")
            )
            if (id.isNotBlank() && !models.contains(id)) {
                models.add(id)
            }
        }
        return models
    }

    private fun chooseChatGptCodexModel(
        models: List<String>,
        requestedModel: String
    ): String {
        if (models.isEmpty()) {
            return requestedModel
        }
        val preferred = listOf(
            requestedModel,
            CHATGPT_OAUTH_DEFAULT_MODEL,
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.4-nano",
            "chat-latest"
        )
        for (candidate in preferred) {
            val match = models.firstOrNull { it.equals(candidate, ignoreCase = true) }
            if (match != null) {
                return match
            }
        }
        return models.first()
    }

    private fun chatGptCodexResponsesErrorSummary(rawText: String): JSONObject {
        val summary = JSONObject()
        if (rawText.isBlank()) {
            return summary
        }
        try {
            val parsed = JSONObject(rawText)
            val error = parsed.optJSONObject("error")
            val code = firstNonBlank(
                error?.optString("code", "") ?: "",
                error?.optString("type", "") ?: "",
                parsed.optString("code", ""),
                parsed.optString("type", "")
            )
            val message = boundedDiagnosticText(
                firstNonBlank(
                    error?.optString("message", "") ?: "",
                    parsed.optString("message", "")
                )
            )
            if (code.isNotBlank()) {
                summary.put("code", boundedDiagnosticText(code, 80))
            }
            if (message.isNotBlank()) {
                summary.put("message", message)
            }
            return summary
        } catch (_: Exception) {
            val text = boundedDiagnosticText(rawText)
            if (text.isNotBlank()) {
                summary.put("message", text)
            }
            return summary
        }
    }

    private fun chatGptCodexResponsesResponse(rawText: String): JSONObject {
        val deltas = StringBuilder()
        var completedContent = ""
        var responseId = ""
        var failureStatus = ""
        var failureMessage = ""
        var failureCode = ""
        for (line in rawText.lineSequence()) {
            val trimmed = line.trim()
            if (!trimmed.startsWith("data:")) {
                continue
            }
            val payload = trimmed.removePrefix("data:").trim()
            if (payload.isBlank() || payload == "[DONE]") {
                continue
            }
            try {
                val event = JSONObject(payload)
                responseId = firstNonBlank(
                    event.optString("response_id", ""),
                    event.optJSONObject("response")?.optString("id", "") ?: "",
                    event.optString("id", ""),
                    responseId
                )
                val eventType = event.optString("type", "")
                when (eventType) {
                    "error" -> {
                        val error = event.optJSONObject("error")
                        failureStatus = "oauth_chat_failed"
                        failureCode = firstNonBlank(
                            error?.optString("code", "") ?: "",
                            event.optString("code", ""),
                            failureCode
                        )
                        failureMessage = firstNonBlank(
                            error?.optString("message", "") ?: "",
                            event.optString("message", ""),
                            failureMessage
                        )
                    }
                    "response.failed" -> {
                        val response = event.optJSONObject("response")
                        val error = response?.optJSONObject("error")
                        failureStatus = "oauth_chat_failed"
                        failureCode = firstNonBlank(
                            error?.optString("code", "") ?: "",
                            response?.optString("status", "") ?: "",
                            response?.optJSONObject("incomplete_details")
                                ?.optString("reason", "") ?: "",
                            failureCode
                        )
                        failureMessage = firstNonBlank(
                            error?.optString("message", "") ?: "",
                            response?.optString("status_details", "") ?: "",
                            response?.optJSONObject("incomplete_details")
                                ?.optString("reason", "") ?: "",
                            failureMessage
                        )
                    }
                    "response.output_text.delta",
                    "response.text.delta",
                    "response.refusal.delta" -> {
                        deltas.append(event.optString("delta", ""))
                    }
                    "response.output_text.done" -> {
                        completedContent = firstNonBlank(
                            event.optString("text", ""),
                            completedContent
                        )
                    }
                    "response.output_item.done" -> {
                        val itemText = chatGptCodexResponsesText(event.optJSONObject("item"))
                        if (itemText.isNotBlank()) {
                            completedContent = itemText
                        }
                    }
                    "response.completed" -> {
                        val response = event.optJSONObject("response")
                        val responseText = chatGptCodexResponsesText(response)
                        if (responseText.isNotBlank()) {
                            completedContent = responseText
                        }
                    }
                }
                if (completedContent.isBlank()) {
                    val fallback = chatGptCodexResponsesText(event)
                    if (fallback.isNotBlank()) {
                        completedContent = fallback
                    }
                }
            } catch (_: Exception) {
                continue
            }
        }
        val content = firstNonBlank(completedContent, deltas.toString()).trim()
        return JSONObject()
            .put("content", content)
            .put("responseId", responseId)
            .put("status", failureStatus)
            .put("error", failureMessage)
            .put("errorCode", failureCode)
    }

    private fun chatGptCodexResponsesText(value: Any?): String {
        return when (value) {
            is JSONObject -> chatGptCodexResponsesObjectText(value)
            is JSONArray -> chatGptCodexResponsesArrayText(value)
            is String -> ""
            else -> ""
        }
    }

    private fun chatGptCodexResponsesObjectText(value: JSONObject): String {
        val type = value.optString("type", "")
        if (type == "output_text" || type == "summary_text" || type == "text" || type == "refusal") {
            val text = firstNonBlank(
                value.optString("text", ""),
                value.optString("refusal", "")
            )
            if (text.isNotBlank()) {
                return text.trim()
            }
        }
        val texts = mutableListOf<String>()
        val output = value.optJSONArray("output")
        if (output != null) {
            val outputText = chatGptCodexResponsesArrayText(output)
            if (outputText.isNotBlank()) {
                texts.add(outputText)
            }
        }
        val content = value.opt("content")
        when (content) {
            is JSONArray -> {
                val contentText = chatGptCodexResponsesArrayText(content)
                if (contentText.isNotBlank()) {
                    texts.add(contentText)
                }
            }
            is JSONObject -> {
                val contentText = chatGptCodexResponsesObjectText(content)
                if (contentText.isNotBlank()) {
                    texts.add(contentText)
                }
            }
        }
        return texts.joinToString("\n").trim()
    }

    private fun chatGptCodexResponsesArrayText(values: JSONArray): String {
        val texts = mutableListOf<String>()
        for (index in 0 until values.length()) {
            val text = chatGptCodexResponsesText(values.opt(index))
            if (text.isNotBlank()) {
                texts.add(text)
            }
        }
        return texts.joinToString("\n").trim()
    }

    private fun runNativeSecureMeshJsonObject(action: String, params: JSONObject): JSONObject {
        secureMeshAndroidSecretStore.redactPersistedMobileRelaySecrets()
        val requestJson = JSONObject()
            .put("action", action)
            .put("params", params)
            .toString()
        val effectiveRequestJson =
            secureMeshAndroidSecretStore.requestTextWithMobileRelaySecretOverrides(
                requestJson,
                action
            )
        val response = nativeSecureMeshJson(
            effectiveRequestJson,
            filesDir.absolutePath,
            secureMeshAndroidSecretStore
        )
        val responseJson = JSONObject(response)
        secureMeshAndroidSecretStore.captureMobileRelaySecretsFromNativeResponse(responseJson)
        secureMeshAndroidSecretStore.redactPersistedMobileRelaySecrets()
        return responseJson
    }

    private fun providerCredentialPayloadFromSecureResult(
        result: JSONObject,
        expectedProviderId: String
    ): JSONObject? {
        val opened = result.optJSONObject("openedResult") ?: return null
        val execution = opened.optJSONObject("execution") ?: return null
        val wrapper = execution.optJSONObject("output") ?: return null
        val output = wrapper.optJSONObject("output") ?: return null
        if (output.optBoolean("ok", false) &&
            normalizeMobileProviderId(output.optString("providerId", "")) == expectedProviderId
        ) {
            return output
        }
        return null
    }

    private fun redactProviderCredentialSyncFailure(
        source: JSONObject,
        status: String,
        providerId: String
    ): JSONObject {
        return JSONObject()
            .put("ok", false)
            .put("providerId", providerId)
            .put("status", status)
            .put("code", source.optString("code", ""))
            .put("detailCode", providerCredentialSyncDetailCode(source))
            .put("detail", redactedProviderCredentialSyncDetail(source))
            .put("bodyRedacted", true)
    }

    private fun redactedProviderCredentialSyncDetail(source: JSONObject): String {
        val detail = firstNonBlank(
            source.optString("status", ""),
            source.optString("error", ""),
            source.optString("errorClass", "")
        )
        return detail
            .replace(Regex("(?i)(bearer|api[_-]?key|token|secret)[^\\s,}]{0,120}"), "$1=***")
            .take(180)
    }

    private fun providerCredentialSyncDetailCode(source: JSONObject): String {
        val code = source.optString("code", "").lowercase()
        val error = source.optString("error", "").lowercase()
        val status = source.optString("status", "").lowercase()
        val combined = "$code $status $error"
        return when {
            "pairing_not_found" in combined || "配对不存在" in combined ->
                "pairing_not_found"
            "mobile-token" in combined || "mobile token" in combined ->
                "mobile_token_missing"
            "peer" in combined && "verified" in combined ->
                "secure_mesh_peer_not_verified"
            "private key" in combined || "privatekey" in combined ->
                "secure_mesh_private_key_missing"
            "pairing" in combined && "id" in combined ->
                "pairing_id_missing"
            else -> ""
        }
    }

    private fun unsupportedMobileProvider(providerId: String): JSONObject {
        return JSONObject()
            .put("ok", false)
            .put("status", "unsupported_provider")
            .put("providerId", providerId)
            .put("message", "Unsupported mobile provider.")
            .put("bodyRedacted", true)
    }

    private fun deferredAndroidMobileProvider(
        providerId: String,
        capability: String,
    ): JSONObject {
        return JSONObject()
            .put("ok", false)
            .put("status", "android_provider_deferred")
            .put("code", "android_provider_deferred")
            .put("providerId", providerId)
            .put("capability", capability)
            .put("supportState", "deferred_optional_service")
            .put("bodyRedacted", true)
    }

    private fun writeMobileProviderCredential(
        providerId: String,
        mobileAccountId: String,
        apiKey: String,
        source: String
    ): JSONObject {
        val recordFile = androidProviderCredentialFile(providerId, mobileAccountId)
        val secret = apiKey.toByteArray(Charsets.UTF_8)
        try {
            secureMeshAndroidSecretStore.writeAndroidSecureStoreRecordToFile(
                ANDROID_PROVIDER_CREDENTIAL_KIND,
                androidProviderCredentialLabel(providerId, mobileAccountId),
                androidProviderCredentialChallenge(providerId, mobileAccountId),
                secret,
                recordFile
            )
        } finally {
            secret.fill(0)
        }
        return JSONObject()
            .put("ok", true)
            .put("providerId", providerId)
            .put("mobileAccountId", mobileAccountId)
            .put("credentialPresent", true)
            .put("credentialHint", credentialHint(apiKey))
            .put("source", source)
            .put(
                "secureStore",
                secureMeshAndroidSecretStore.secureMeshAndroidGeneralCustodyBackend()
            )
            .put("bodyRedacted", true)
    }

    private fun readMobileProviderCredential(
        providerId: String,
        mobileAccountId: String
    ): String {
        val secret = secureMeshAndroidSecretStore.readAndroidSecureStoreRecord(
            ANDROID_PROVIDER_CREDENTIAL_KIND,
            androidProviderCredentialLabel(providerId, mobileAccountId),
            androidProviderCredentialChallenge(providerId, mobileAccountId),
            androidProviderCredentialReadableFile(providerId, mobileAccountId)
        )
        return try {
            String(secret, Charsets.UTF_8).trim()
        } finally {
            secret.fill(0)
        }
    }

    private fun normalizeMobileProviderId(value: String): String {
        return when (value.trim().lowercase().replace('_', '-')) {
            "chatgpt", "chat-gpt", "openai", "gpt" -> "chatgpt"
            "gemini", "google", "google-gemini" -> "gemini"
            "kimi", "moonshot", "moonshot-ai" -> "kimi"
            "deepseek", "deep-seek" -> "deepseek"
            else -> value.trim().lowercase()
        }
    }

    private fun isSupportedMobileProvider(providerId: String): Boolean {
        return providerId == "chatgpt" || providerId == "deepseek"
    }

    private fun isDeferredAndroidMobileProvider(providerId: String): Boolean {
        return providerId == "gemini" || providerId == "kimi"
    }

    private fun mobileProviderLabel(providerId: String): String {
        return when (providerId) {
            "chatgpt" -> "ChatGPT"
            "gemini" -> "Gemini"
            "kimi" -> "Kimi"
            "deepseek" -> "DeepSeek"
            else -> providerId
        }
    }

    private fun androidProviderCredentialLabel(
        providerId: String,
        mobileAccountId: String
    ): String {
        return "provider-$providerId-${MobileProviderAccountIdentity.accountRecordId(mobileAccountId)}-api-key"
    }

    private fun androidProviderCredentialChallenge(
        providerId: String,
        mobileAccountId: String
    ): String {
        return "licolite.mobile-provider-credential.v3:$providerId:$mobileAccountId"
    }

    private fun androidProviderOAuthCredentialLabel(
        providerId: String,
        mobileAccountId: String
    ): String {
        return "provider-$providerId-${MobileProviderAccountIdentity.accountRecordId(mobileAccountId)}-oauth"
    }

    private fun androidProviderOAuthCredentialChallenge(
        providerId: String,
        mobileAccountId: String
    ): String {
        return "licolite.mobile-provider-oauth.v3:$providerId:$mobileAccountId"
    }

    private fun mobileAccountIdFromParams(params: JSONObject, fallback: String): String {
        val providerId = normalizeMobileProviderId(
            firstNonBlank(
                params.optString("providerId", ""),
                params.optString("provider", ""),
                params.optString("id", ""),
                fallback
            )
        )
        return MobileProviderAccountIdentity.accountIdFromFields(
            mapOf(
                "credentialRef" to params.optString("credentialRef", ""),
                "credential_ref" to params.optString("credential_ref", ""),
                "mobileAccountId" to params.optString("mobileAccountId", ""),
                "accountId" to params.optString("accountId", ""),
                "localAccountId" to params.optString("localAccountId", ""),
                "accountDraftId" to params.optString("accountDraftId", "")
            ),
            providerId = providerId,
            fallback = fallback
        )
    }

    private fun firstNonBlank(vararg values: String): String {
        return values.firstOrNull { it.trim().isNotEmpty() }?.trim() ?: ""
    }

    private fun boundedDiagnosticText(value: String, maxChars: Int = 180): String {
        val normalized = value.replace(Regex("\\s+"), " ").trim()
        return if (normalized.length <= maxChars) {
            normalized
        } else {
            normalized.take(maxChars)
        }
    }

    private fun credentialHint(value: String): String {
        val compact = value.replace(Regex("\\s+"), "")
        return if (compact.length <= 4) {
            "****"
        } else {
            "**** ${compact.takeLast(4)}"
        }
    }

    private fun normalizeProviderCredentialKind(value: String): String {
        val normalized = value.trim().lowercase().replace('_', '-')
        return when (normalized) {
            "oauth", "oauth2", "oauth-pkce", "oauth-credential" -> "oauth-pkce"
            "api", "api-key", "apikey" -> "api-key"
            else -> normalized.ifBlank { "api-key" }
        }
    }

    private data class DecodedReleaseAcceptanceParams(
        val value: JSONObject?,
        val byteCount: Int,
        val valid: Boolean,
    )

    private fun consumeReleaseAcceptanceIngress(): Intent? {
        return ReleaseAcceptanceIngress
            .consume(SystemClock.elapsedRealtime())
            ?.toInternalIntent(this)
    }

    private fun handleSecureMeshAdbIntent(intent: Intent?) {
        val sourceIntent = intent ?: return
        val nativeAction = sourceIntent
            .getStringExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_EXTRA)
            ?: return
        val closureChallenge = sourceIntent
            .getStringExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA)
            .orEmpty()
        val invocationNonce = sourceIntent
            .getStringExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA)
            .orEmpty()
        val requestNonce = sourceIntent
            .getStringExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_NONCE_EXTRA)
            .orEmpty()
        val requestSequence = sourceIntent.getLongExtra(
            ReleaseAcceptanceIngress.RELEASE_REQUEST_SEQUENCE_EXTRA,
            0L,
        )
        val decodedParams = decodeReleaseAcceptanceParams(
            sourceIntent
                .getStringExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_PARAMS_EXTRA)
                .orEmpty(),
        )
        val acceptanceRequest = ReleaseAcceptanceRequest(
            action = nativeAction,
            closureChallenge = closureChallenge,
            invocationNonce = invocationNonce,
            requestNonce = requestNonce,
            sequence = requestSequence,
            paramsByteCount = decodedParams.byteCount,
            paramsJsonValid = decodedParams.valid,
        )
        val initialBinding = ReleaseAcceptanceChannel.bindingFor(acceptanceRequest)
        clearReleaseAcceptanceIntentExtras(sourceIntent)
        Thread {
            synchronized(releaseAcceptanceDispatchLock) {
                try {
                    val approval = loadReleaseAcceptanceApproval()
                    when (
                        val decision = ReleaseAcceptanceChannel.evaluate(
                            acceptanceRequest,
                            approval,
                            System.currentTimeMillis(),
                        )
                    ) {
                        is ReleaseAcceptanceDecision.Rejected -> {
                            writeSecureMeshAdbResult(
                                releaseAcceptanceFailure(decision.binding, decision.code)
                            )
                        }
                        is ReleaseAcceptanceDecision.AuthorizationRequired -> {
                            writeSecureMeshAdbResult(
                                releaseAcceptanceFailure(
                                    decision.binding,
                                    "authorization_required",
                                    decision.reason,
                                ).put(
                                    "userActionRequired",
                                    "approve_local_release_acceptance_in_lico_arc",
                                )
                            )
                            requestReleaseAcceptanceAuthorization(
                                closureChallenge,
                                invocationNonce,
                                acceptanceRequest,
                            )
                        }
                        is ReleaseAcceptanceDecision.Authorized -> {
                            persistReleaseAcceptanceApproval(decision.advancedApproval)
                            val params = decodedParams.value
                                ?: throw IllegalArgumentException(
                                    "validated release acceptance params are missing"
                                )
                            val request = JSONObject()
                                .put("action", nativeAction)
                                .put("params", params)
                            val response = JSONObject(runSecureMeshNativeJson(request.toString()))
                            val sanitized = sanitizeSecureMeshAdbValue(response) as JSONObject
                            val boundResult = addReleaseAcceptanceBinding(
                                sanitized,
                                decision.binding,
                            )
                            val serializedBytes = boundResult.toString()
                                .toByteArray(Charsets.UTF_8)
                            writeSecureMeshAdbResult(
                                if (serializedBytes.size <= MAX_EXTERNAL_NATIVE_ACTION_RESULT_BYTES) {
                                    boundResult
                                } else {
                                    releaseAcceptanceFailure(
                                        decision.binding,
                                        "native_action_result_too_large",
                                    )
                                }
                            )
                        }
                    }
                } catch (error: Exception) {
                    writeSecureMeshAdbResult(
                        releaseAcceptanceFailure(
                            initialBinding,
                            "secure_mesh_native_action_failed",
                        ).put("errorClass", error.javaClass.simpleName)
                    )
                }
            }
        }.start()
    }

    private fun decodeReleaseAcceptanceParams(
        encoded: String
    ): DecodedReleaseAcceptanceParams {
        if (encoded.isEmpty()) {
            return DecodedReleaseAcceptanceParams(null, 0, false)
        }
        val maximumEncodedLength =
            ((ReleaseAcceptanceChannel.MAX_PARAMS_JSON_BYTES + 2) / 3) * 4
        if (
            encoded.length > maximumEncodedLength ||
            !CANONICAL_BASE64_URL_PATTERN.matches(encoded)
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
                return DecodedReleaseAcceptanceParams(
                    null,
                    decoded.size,
                    false,
                )
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

    private fun clearReleaseAcceptanceIntentExtras(intent: Intent) {
        intent.removeExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.NATIVE_ACTION_PARAMS_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_NONCE_EXTRA)
        intent.removeExtra(ReleaseAcceptanceIngress.RELEASE_REQUEST_SEQUENCE_EXTRA)
    }

    private fun releaseAcceptanceFailure(
        binding: ReleaseAcceptanceBinding,
        code: String,
        authorizationReason: String = "",
    ): JSONObject {
        val value = JSONObject()
            .put("ok", false)
            .put("code", code)
            .put("status", code)
        if (authorizationReason.isNotEmpty()) {
            value.put("authorizationReason", authorizationReason)
        }
        return addReleaseAcceptanceBinding(value, binding)
    }

    private fun addReleaseAcceptanceBinding(
        value: JSONObject,
        binding: ReleaseAcceptanceBinding,
    ): JSONObject {
        return value
            .put("releaseAcceptanceChannel", RELEASE_ACCEPTANCE_CHANNEL_VERSION)
            .put("closureChallengeDigest", binding.closureChallengeDigest)
            .put("invocationNonceDigest", binding.invocationNonceDigest)
            .put("requestNonceDigest", binding.requestNonceDigest)
            .put("actionDigest", binding.actionDigest)
            .put("sequence", binding.sequence)
            .put("bodyRedacted", true)
    }

    private fun writeSecureMeshAdbResult(value: JSONObject) {
        try {
            val output = File(
                getExternalFilesDir(null),
                "secure-mesh/adb-last-result.json"
            )
            writeAtomicRuntimeStatus(output, value.toString(2))
        } catch (_: Exception) {
            Log.w(SECURE_MESH_ADB_TAG, "failed to write redacted native-action result")
        }
    }

    private fun sanitizeSecureMeshAdbValue(value: Any?): Any? {
        return when (value) {
            is JSONObject -> {
                val output = JSONObject()
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    output.put(
                        key,
                        if (isSensitiveSecureMeshAdbKey(key)) {
                            "[redacted]"
                        } else {
                            sanitizeSecureMeshAdbValue(value.opt(key))
                        }
                    )
                }
                output
            }
            is JSONArray -> {
                val output = JSONArray()
                for (index in 0 until value.length()) {
                    output.put(sanitizeSecureMeshAdbValue(value.opt(index)))
                }
                output
            }
            is Map<*, *> -> {
                val output = JSONObject()
                value.entries
                    .map { entry ->
                        val key = entry.key as? String
                            ?: throw IllegalArgumentException(
                                "secure mesh ADB response map key must be a string"
                            )
                        key to entry.value
                    }
                    .sortedBy { (key, _) -> key }
                    .forEach { (key, nestedValue) ->
                        output.put(
                            key,
                            if (isSensitiveSecureMeshAdbKey(key)) {
                                "[redacted]"
                            } else {
                                sanitizeSecureMeshAdbValue(nestedValue)
                            }
                        )
                    }
                output
            }
            is Iterable<*> -> {
                val output = JSONArray()
                value.forEach { nestedValue ->
                    output.put(sanitizeSecureMeshAdbValue(nestedValue))
                }
                output
            }
            is Array<*> -> {
                val output = JSONArray()
                value.forEach { nestedValue ->
                    output.put(sanitizeSecureMeshAdbValue(nestedValue))
                }
                output
            }
            else -> value
        }
    }

    private fun isSensitiveSecureMeshAdbKey(key: String): Boolean {
        val normalized = key.lowercase()
        if (SAFE_SECURE_MESH_ADB_STATUS_KEYS.contains(key)) {
            return false
        }
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

    private fun jsonObjectToMap(value: JSONObject): Map<String, Any?> {
        val output = linkedMapOf<String, Any?>()
        val keys = value.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            output[key] = jsonValueToPlatform(value.opt(key))
        }
        return output
    }

    private fun jsonArrayToList(value: JSONArray): List<Any?> {
        val output = mutableListOf<Any?>()
        for (index in 0 until value.length()) {
            output.add(jsonValueToPlatform(value.opt(index)))
        }
        return output
    }

    private fun jsonValueToPlatform(value: Any?): Any? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonObjectToMap(value)
            is JSONArray -> jsonArrayToList(value)
            else -> value
        }
    }

    private fun secureMeshAndroidNativeRuntimeStatus(): Map<String, Any?> {
        if (!nativeSecureMeshRuntimeLibraryLoaded) {
            return mapOf(
                "provider" to "lico-client-native",
                "library" to SECURE_MESH_NATIVE_LIBRARY,
                "ffiBoundary" to "jni",
                "loaded" to false,
                "selfTestPassed" to false,
                "mlsRuntimeFeatureEnabled" to false,
                "usesSharedRustCore" to false,
                "productionReady" to false
            )
        }
        return try {
            val nativeFeatureFlags = nativeSecureMeshRuntimeFeatureFlags()
            val productFeatureFlags =
                nativeFeatureFlags and SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS
            val unexpectedFeatureFlagsPresent = nativeFeatureFlags != productFeatureFlags
            val protocolHash = nativeSecureMeshRuntimeProtocolHash()
            mapOf(
                "provider" to "lico-client-native",
                "library" to SECURE_MESH_NATIVE_LIBRARY,
                "ffiBoundary" to "jni",
                "loaded" to true,
                "selfTestPassed" to (
                    nativeSecureMeshRuntimeSelfTest() == 1 &&
                        !unexpectedFeatureFlagsPresent
                    ),
                "featureFlags" to productFeatureFlags,
                "expectedFeatureFlags" to SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS,
                "featureFlagsComplete" to (
                    productFeatureFlags ==
                        SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS
                    ),
                "unexpectedDiagnosticFeatureFlagsPresent" to unexpectedFeatureFlagsPresent,
                "mlsRuntimeFeatureEnabled" to true,
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
                "mlsRuntimeFeatureEnabled" to false,
                "usesSharedRustCore" to false,
                "errorClass" to error.javaClass.simpleName,
                "productionReady" to false
            )
        }
    }

    private fun writeSecureMeshAndroidRuntimeStatusFile(): Map<String, Any?> {
        return try {
            prunePersistentSecureMeshDiagnostics()
            val payload = secureMeshAndroidStatus().toMutableMap()
            val closureChallengeDigest = currentReleaseClosureChallengeDigest
            payload["runtimeStatusFile"] = mapOf(
                "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                "exists" to true,
                "appPrivateFilesDir" to true,
                "externalReportRelativePath" to
                    SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH,
                "writtenByAppProcess" to true,
                "writtenAtEpochMillis" to System.currentTimeMillis(),
                "closureChallengeDigest" to closureChallengeDigest,
                "invocationNonceDigest" to currentReleaseInvocationNonceDigest
            )
            writeSecureMeshAndroidRuntimeStatusPayload(payload)
            mapOf(
                "ok" to true,
                "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                "externalReportRelativePath" to
                    SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH,
                "writtenByAppProcess" to true
            )
        } catch (error: Exception) {
            val failurePayload = mapOf(
                "ok" to false,
                "closureChallengeDigest" to currentReleaseClosureChallengeDigest,
                "invocationNonceDigest" to currentReleaseInvocationNonceDigest,
                "protocolVersion" to SECURE_MESH_PROTOCOL_VERSION,
                "endpointKind" to "mobile",
                "platform" to "android",
                "bridge" to mapOf(
                    "methodChannel" to SECURE_MESH_ANDROID_CHANNEL,
                    "statusMethod" to true,
                    "writeRuntimeStatusMethod" to true,
                    "nativeJsonMethod" to true
                ),
                "secureStore" to mapOf(
                    "provider" to "selected-custody-unavailable",
                    "available" to false,
                    "privateMaterialExported" to false,
                    "errorClass" to error.javaClass.simpleName
                ),
                "nativeRuntime" to mapOf(
                    "provider" to "lico-client-native",
                    "library" to SECURE_MESH_NATIVE_LIBRARY,
                    "ffiBoundary" to "jni",
                    "loaded" to nativeSecureMeshRuntimeLibraryLoaded,
                    "selfTestPassed" to false,
                    "mlsRuntimeFeatureEnabled" to false,
                    "usesSharedRustCore" to nativeSecureMeshRuntimeLibraryLoaded,
                    "secretsPassedThroughFfi" to false,
                    "productionReady" to false
                ),
                "runtimeStatusFile" to mapOf(
                    "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                    "exists" to false,
                    "appPrivateFilesDir" to true,
                    "externalReportRelativePath" to
                        SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH,
                    "writtenByAppProcess" to true,
                    "writeFailed" to true,
                    "errorClass" to error.javaClass.simpleName,
                    "closureChallengeDigest" to currentReleaseClosureChallengeDigest,
                    "invocationNonceDigest" to currentReleaseInvocationNonceDigest
                ),
                "productionReady" to false
            )
            try {
                writeSecureMeshAndroidRuntimeStatusPayload(failurePayload)
            } catch (_: Exception) {
            }
            mapOf(
                "ok" to false,
                "relativePath" to SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH,
                "errorClass" to error.javaClass.simpleName
            )
        }
    }

    private fun writeSecureMeshAndroidRuntimeStatusPayload(payload: Map<String, Any?>) {
        val serialized = JSONObject(payload).toString(2)
        val runtimeStatusFile = secureMeshAndroidRuntimeStatusFile()
        writeAtomicRuntimeStatus(runtimeStatusFile, serialized)
        val externalRuntimeStatusFile = secureMeshAndroidExternalRuntimeStatusFile()
        if (externalRuntimeStatusFile != null) {
            writeAtomicRuntimeStatus(externalRuntimeStatusFile, serialized)
        }
    }

    private fun writeAtomicRuntimeStatus(target: File, serialized: String) {
        target.parentFile?.mkdirs()
        val atomicFile = AtomicFile(target)
        val output = atomicFile.startWrite()
        try {
            output.write(serialized.toByteArray(Charsets.UTF_8))
            output.fd.sync()
            atomicFile.finishWrite(output)
        } catch (error: Exception) {
            atomicFile.failWrite(output)
            throw error
        }
    }

    private fun maybeRequestReleaseAcceptanceAuthorization(sourceIntent: Intent?) {
        val challenge = sourceIntent
            ?.getStringExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA)
            .orEmpty()
        val invocationNonce = sourceIntent
            ?.getStringExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA)
            .orEmpty()
        val closureDigest = ReleaseClosureBinding.digest(challenge)
        val invocationDigest = ReleaseClosureBinding.digest(invocationNonce)
        if (closureDigest.isEmpty() || invocationDigest.isEmpty()) {
            return
        }
        val now = System.currentTimeMillis()
        val maximumExpiry = if (
            now > 0L &&
            now <= Long.MAX_VALUE - ReleaseAcceptanceChannel.APPROVAL_VALIDITY_MILLIS
        ) {
            now + ReleaseAcceptanceChannel.APPROVAL_VALIDITY_MILLIS
        } else {
            0L
        }
        val approval = synchronized(releaseAcceptanceDispatchLock) {
            loadReleaseAcceptanceApproval()
        }
        if (
            approval?.isStructurallyValid() == true &&
            approval.closureChallengeDigest == closureDigest &&
            approval.invocationNonceDigest == invocationDigest &&
            approval.expiresAtEpochMillis > now &&
            approval.expiresAtEpochMillis <= maximumExpiry
        ) {
            return
        }
        requestReleaseAcceptanceAuthorization(challenge, invocationNonce, null)
    }

    private fun requestReleaseAcceptanceAuthorization(
        closureChallenge: String,
        invocationNonce: String,
        request: ReleaseAcceptanceRequest?,
    ) {
        val closureDigest = ReleaseClosureBinding.digest(closureChallenge)
        val invocationDigest = ReleaseClosureBinding.digest(invocationNonce)
        if (closureDigest.isEmpty() || invocationDigest.isEmpty()) {
            return
        }
        val promptKey = "$closureDigest:$invocationDigest"
        synchronized(releaseAcceptancePromptLock) {
            if (pendingReleaseAcceptancePromptKey.isNotEmpty()) {
                return
            }
            pendingReleaseAcceptancePromptKey = promptKey
        }
        runOnUiThread {
            if (isFinishing || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && isDestroyed)) {
                clearPendingReleaseAcceptancePrompt(promptKey)
                return@runOnUiThread
            }
            AlertDialog.Builder(this)
                .setTitle("Allow local release acceptance?")
                .setMessage(
                    "A locally connected verifier requested access to the release-safe " +
                        "acceptance channel. Approval is bound to this invocation, expires " +
                        "automatically, and never exposes keys or message content.\n\n" +
                        "Requested operation: " +
                        (request?.action ?: "release verification session")
                )
                .setPositiveButton("Allow") { _, _ ->
                    completeReleaseAcceptanceAuthorization(
                        promptKey,
                        closureChallenge,
                        invocationNonce,
                        request,
                    )
                }
                .setNegativeButton("Deny") { _, _ ->
                    denyReleaseAcceptanceAuthorization(promptKey, request, "user_denied")
                }
                .setOnCancelListener {
                    denyReleaseAcceptanceAuthorization(promptKey, request, "user_cancelled")
                }
                .show()
        }
    }

    private fun completeReleaseAcceptanceAuthorization(
        promptKey: String,
        closureChallenge: String,
        invocationNonce: String,
        request: ReleaseAcceptanceRequest?,
    ) {
        Thread {
            var approved = false
            try {
                val selectedUserAuthentication =
                    secureMeshAndroidSecretStore.userAuthenticationSelected() ||
                        secureMeshAndroidSecretStore.generalUserAuthenticationSelected()
                val userPresenceApproved = if (selectedUserAuthentication) {
                    val authentication = secureMeshAndroidUserAuthenticator
                        .authorizeSensitiveAction(
                            RELEASE_ACCEPTANCE_AUTHORIZATION_ACTION,
                            forcePrompt = true,
                        )
                    authentication.optBoolean("ok", false) &&
                        authentication.optBoolean("authenticated", false)
                } else {
                    true
                }
                if (userPresenceApproved) {
                    synchronized(releaseAcceptanceDispatchLock) {
                        val now = System.currentTimeMillis()
                        val existing = loadReleaseAcceptanceApproval()
                        val next = if (request == null) {
                            ReleaseAcceptanceChannel.renewedApprovalForInvocation(
                                closureChallenge,
                                invocationNonce,
                                existing,
                                now,
                            )
                        } else {
                            ReleaseAcceptanceChannel.renewedApproval(
                                request,
                                existing,
                                now,
                            )
                        }
                        if (next != null) {
                            persistReleaseAcceptanceApproval(next)
                            approved = true
                        }
                    }
                }
            } catch (_: Exception) {
                approved = false
            } finally {
                clearPendingReleaseAcceptancePrompt(promptKey)
                if (request != null) {
                    writeSecureMeshAdbResult(
                        releaseAcceptanceFailure(
                            ReleaseAcceptanceChannel.bindingFor(request),
                            if (approved) "authorization_approved" else "authorization_denied",
                            if (approved) {
                                "user_approved"
                            } else {
                                "system_authentication_failed"
                            },
                        ),
                    )
                }
                runOnUiThread {
                    Toast.makeText(
                        this,
                        if (approved) {
                            "Local release acceptance approved. Rerun the verifier."
                        } else {
                            "Local release acceptance was not approved."
                        },
                        Toast.LENGTH_LONG,
                    ).show()
                }
            }
        }.start()
    }

    private fun denyReleaseAcceptanceAuthorization(
        promptKey: String,
        request: ReleaseAcceptanceRequest?,
        reason: String,
    ) {
        clearPendingReleaseAcceptancePrompt(promptKey)
        if (request == null) return
        Thread {
            writeSecureMeshAdbResult(
                releaseAcceptanceFailure(
                    ReleaseAcceptanceChannel.bindingFor(request),
                    "authorization_denied",
                    reason,
                ),
            )
        }.start()
    }

    private fun clearPendingReleaseAcceptancePrompt(promptKey: String) {
        synchronized(releaseAcceptancePromptLock) {
            if (pendingReleaseAcceptancePromptKey == promptKey) {
                pendingReleaseAcceptancePromptKey = ""
            }
        }
    }

    private fun releaseAcceptanceApprovalFile(): File {
        return File(filesDir, RELEASE_ACCEPTANCE_APPROVAL_RELATIVE_PATH)
    }

    private fun loadReleaseAcceptanceApproval(): ReleaseAcceptanceApproval? {
        val file = releaseAcceptanceApprovalFile()
        if (!file.isFile || file.length() !in 1L..MAX_RELEASE_ACCEPTANCE_APPROVAL_BYTES) {
            return null
        }
        return try {
            val text = AtomicFile(file).openRead().bufferedReader(Charsets.UTF_8).use {
                it.readText()
            }
            val value = JSONObject(text)
            val keys = mutableSetOf<String>()
            val iterator = value.keys()
            while (iterator.hasNext()) {
                keys.add(iterator.next())
            }
            if (keys != RELEASE_ACCEPTANCE_APPROVAL_KEYS) {
                return null
            }
            if (value.optInt("schemaVersion", 0) != ReleaseAcceptanceChannel.SCHEMA_VERSION) {
                return null
            }
            ReleaseAcceptanceApproval(
                closureChallengeDigest = value.optString("closureChallengeDigest", ""),
                invocationNonceDigest = value.optString("invocationNonceDigest", ""),
                lastRequestNonceDigest = value.optString("lastRequestNonceDigest", ""),
                expiresAtEpochMillis = value.optLong("expiresAtEpochMillis", 0L),
                lastSequence = value.optLong("lastSequence", -1L),
            ).takeIf(ReleaseAcceptanceApproval::isStructurallyValid)
        } catch (_: Exception) {
            null
        }
    }

    private fun persistReleaseAcceptanceApproval(approval: ReleaseAcceptanceApproval) {
        check(approval.isStructurallyValid()) {
            "release acceptance approval is invalid"
        }
        val value = JSONObject()
            .put("schemaVersion", ReleaseAcceptanceChannel.SCHEMA_VERSION)
            .put("closureChallengeDigest", approval.closureChallengeDigest)
            .put("invocationNonceDigest", approval.invocationNonceDigest)
            .put("lastRequestNonceDigest", approval.lastRequestNonceDigest)
            .put("expiresAtEpochMillis", approval.expiresAtEpochMillis)
            .put("lastSequence", approval.lastSequence)
        writeAtomicRuntimeStatus(releaseAcceptanceApprovalFile(), value.toString())
    }

    private fun consumeReleaseClosureChallenge(sourceIntent: Intent?) {
        val challenge = sourceIntent
            ?.getStringExtra(ReleaseAcceptanceIngress.RELEASE_CLOSURE_CHALLENGE_EXTRA)
            ?: ""
        val invocationNonce = sourceIntent
            ?.getStringExtra(ReleaseAcceptanceIngress.RELEASE_INVOCATION_NONCE_EXTRA)
            ?: ""
        currentReleaseClosureChallengeDigest = ReleaseClosureBinding.digest(challenge)
        currentReleaseInvocationNonceDigest = ReleaseClosureBinding.digest(invocationNonce)
    }

    private fun sha256(bytes: ByteArray): ByteArray {
        return MessageDigest.getInstance("SHA-256").digest(bytes)
    }

    private fun sha256Hex(bytes: ByteArray): String {
        return sha256(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun unsignedIntHex(value: Int): String {
        return java.lang.Long.toHexString(value.toLong() and 0xffffffffL).padStart(8, '0')
    }

    private fun base64UrlDecode(value: String): ByteArray {
        return Base64.decode(value, BASE64_URL_FLAGS)
    }

    private fun base64UrlEncode(value: ByteArray): String {
        return Base64.encodeToString(value, BASE64_URL_FLAGS)
    }

    private fun randomBase64Url(byteCount: Int): String {
        val bytes = ByteArray(byteCount)
        SecureRandom().nextBytes(bytes)
        return base64UrlEncode(bytes)
    }

    private fun urlEncode(value: String): String {
        return URLEncoder.encode(value, Charsets.UTF_8.name())
    }

    private fun readHttpText(connection: HttpURLConnection): String {
        return String(readHttpResponseBody(connection, 1_048_576), Charsets.UTF_8)
    }

    private fun readHttpResponseBody(
        connection: HttpURLConnection,
        maximumByteCount: Int
    ): ByteArray {
        require(maximumByteCount > 0) { "HTTP response body limit must be positive" }
        val stream = if (connection.responseCode in 200..399) {
            connection.inputStream
        } else {
            connection.errorStream ?: connection.inputStream
        }
        return stream.use { input ->
            val output = ByteArrayOutputStream(minOf(maximumByteCount, 16 * 1024))
            val buffer = ByteArray(8 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) {
                    break
                }
                total = Math.addExact(total, count)
                require(total <= maximumByteCount) { "HTTP response body exceeds limit" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    private fun chatGptOAuthAccountId(idToken: String, accessToken: String): String {
        return firstNonBlank(
            jwtOpenAICodexAccountId(accessToken),
            jwtOpenAICodexAccountId(idToken),
            jwtStringClaim(accessToken, "chatgpt_account_id"),
            jwtStringClaim(idToken, "chatgpt_account_id")
        )
    }

    private fun jwtOpenAICodexAccountId(jwt: String): String {
        return try {
            val payload = jwtPayloadJson(jwt) ?: return ""
            payload.optJSONObject("https://api.openai.com/auth")
                ?.optString("chatgpt_account_id", "")
                ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    private fun jwtStringClaim(jwt: String, claim: String): String {
        return try {
            jwtPayloadJson(jwt)?.optString(claim, "") ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    private fun jwtPayloadJson(jwt: String): JSONObject? {
        val parts = jwt.split(".")
        if (parts.size < 2) {
            return null
        }
        val payload = String(base64UrlDecode(parts[1]), Charsets.UTF_8)
        return JSONObject(payload)
    }

    private fun secureMeshAndroidRuntimeStatusFile(): File {
        return File(filesDir, "secure-mesh/android-runtime-status.json")
    }

    private fun secureMeshAndroidExternalRuntimeStatusFile(): File? {
        return getExternalFilesDir(null)?.let {
            File(it, "secure-mesh/android-runtime-status.json")
        }
    }

    private fun prunePersistentSecureMeshDiagnostics() {
        listOfNotNull(
            File(filesDir, "secure-mesh"),
            getExternalFilesDir(null)?.let { File(it, "secure-mesh") }
        ).forEach(::prunePersistentSecureMeshDiagnostics)
    }

    private fun prunePersistentSecureMeshDiagnostics(directory: File) {
        if (!directory.exists() || !directory.isDirectory) {
            return
        }
        val now = System.currentTimeMillis()
        val diagnostics = directory
            .listFiles()
            .orEmpty()
            .asSequence()
            .filter { it.isFile && it.name in SECURE_MESH_DIAGNOSTIC_FILE_NAMES }
            .sortedByDescending { it.lastModified() }
            .toList()
        diagnostics
            .filter { now - it.lastModified() > SECURE_MESH_DIAGNOSTIC_MAX_AGE_MILLIS }
            .forEach { it.delete() }
        diagnostics
            .drop(SECURE_MESH_DIAGNOSTIC_MAX_FILES)
            .forEach { it.delete() }
    }

    private fun androidProviderCredentialFile(
        providerId: String,
        mobileAccountId: String
    ): File {
        val safeProvider = safeAndroidRecordId(providerId)
        val accountRecordId = MobileProviderAccountIdentity.accountRecordId(mobileAccountId)
        return File(
            filesDir,
            "secure-mesh/android-provider-credentials-by-account-v3/" +
                "$safeProvider/$accountRecordId.json"
        )
    }

    private fun androidProviderCredentialRecord(
        providerId: String,
        mobileAccountId: String
    ): AndroidSecureRecordIdentity {
        return AndroidSecureRecordIdentity(
            kind = ANDROID_PROVIDER_CREDENTIAL_KIND,
            label = androidProviderCredentialLabel(providerId, mobileAccountId),
            challenge = androidProviderCredentialChallenge(providerId, mobileAccountId),
            file = androidProviderCredentialFile(providerId, mobileAccountId)
        )
    }

    private fun androidProviderCredentialReadableFile(
        providerId: String,
        mobileAccountId: String
    ): File {
        val current = androidProviderCredentialRecord(providerId, mobileAccountId)
        if (androidSecureRecordExists(current)) {
            return current.file
        }
        val migrationCandidates = mutableListOf(
            androidV2ProviderCredentialRecord(providerId, mobileAccountId)
        )
        if (mobileAccountId == providerId) {
            migrationCandidates.add(androidLegacyProviderCredentialRecord(providerId))
        }
        migrationCandidates.firstOrNull(::androidSecureRecordExists)?.let { legacy ->
            migrateAndroidSecureRecord(legacy, current) { it.copyOf() }
            if (!androidSecureRecordExists(current)) {
                throw IllegalStateException("Provider credential migration did not complete")
            }
            return current.file
        }
        return current.file
    }

    private fun androidLegacyProviderCredentialFile(providerId: String): File {
        val safeProvider = safeAndroidRecordId(providerId)
        return File(
            filesDir,
            "secure-mesh/android-provider-credentials/$safeProvider.json"
        )
    }

    private fun androidLegacyProviderCredentialRecord(
        providerId: String
    ): AndroidSecureRecordIdentity {
        return AndroidSecureRecordIdentity(
            kind = ANDROID_PROVIDER_CREDENTIAL_KIND,
            label = "provider-$providerId-api-key",
            challenge = "licolite.mobile-provider-credential.v1:$providerId",
            file = androidLegacyProviderCredentialFile(providerId)
        )
    }

    private fun androidV2ProviderCredentialRecord(
        providerId: String,
        mobileAccountId: String
    ): AndroidSecureRecordIdentity {
        val safeProvider = safeAndroidRecordId(providerId)
        val safeAccount = safeAndroidRecordId(mobileAccountId)
        return AndroidSecureRecordIdentity(
            kind = ANDROID_PROVIDER_CREDENTIAL_KIND,
            label = "provider-$providerId-$safeAccount-api-key",
            challenge = "licolite.mobile-provider-credential.v2:$providerId:$mobileAccountId",
            file = File(
                filesDir,
                "secure-mesh/android-provider-credentials-by-account/" +
                    "$safeProvider/$safeAccount.json"
            )
        )
    }

    private fun androidProviderOAuthCredentialFile(
        providerId: String,
        mobileAccountId: String
    ): File {
        val safeProvider = safeAndroidRecordId(providerId)
        val accountRecordId = MobileProviderAccountIdentity.accountRecordId(mobileAccountId)
        return File(
            filesDir,
            "secure-mesh/android-provider-oauth-credentials-by-account-v3/" +
                "$safeProvider/$accountRecordId.json"
        )
    }

    private fun androidProviderOAuthCredentialRecord(
        providerId: String,
        mobileAccountId: String
    ): AndroidSecureRecordIdentity {
        return AndroidSecureRecordIdentity(
            kind = ANDROID_PROVIDER_OAUTH_CREDENTIAL_KIND,
            label = androidProviderOAuthCredentialLabel(providerId, mobileAccountId),
            challenge = androidProviderOAuthCredentialChallenge(providerId, mobileAccountId),
            file = androidProviderOAuthCredentialFile(providerId, mobileAccountId)
        )
    }

    private fun androidProviderOAuthCredentialReadableFile(
        providerId: String,
        mobileAccountId: String
    ): File {
        val current = androidProviderOAuthCredentialRecord(providerId, mobileAccountId)
        if (androidSecureRecordExists(current)) {
            return current.file
        }
        val migrationCandidates = mutableListOf(
            androidV2ProviderOAuthCredentialRecord(providerId, mobileAccountId)
        )
        if (mobileAccountId == providerId) {
            migrationCandidates.add(androidLegacyProviderOAuthCredentialRecord(providerId))
        }
        migrationCandidates.firstOrNull(::androidSecureRecordExists)?.let { legacy ->
            migrateAndroidSecureRecord(legacy, current) { secret ->
                val credential = JSONObject(String(secret, Charsets.UTF_8))
                val existingProvider = credential.optString("providerId", "")
                check(existingProvider.isBlank() || existingProvider == providerId) {
                    "Legacy OAuth credential provider mismatch"
                }
                credential
                    .put("providerId", providerId)
                    .put("mobileAccountId", mobileAccountId)
                    .put("credentialKind", "oauth-pkce")
                    .put("updatedAtEpochMillis", System.currentTimeMillis())
                    .toString()
                    .toByteArray(Charsets.UTF_8)
            }
            if (!androidSecureRecordExists(current)) {
                throw IllegalStateException("Provider OAuth credential migration did not complete")
            }
            return current.file
        }
        return current.file
    }

    private fun androidLegacyProviderOAuthCredentialFile(providerId: String): File {
        val safeProvider = safeAndroidRecordId(providerId)
        return File(
            filesDir,
            "secure-mesh/android-provider-oauth-credentials/$safeProvider.json"
        )
    }

    private fun androidLegacyProviderOAuthCredentialRecord(
        providerId: String
    ): AndroidSecureRecordIdentity {
        return AndroidSecureRecordIdentity(
            kind = ANDROID_PROVIDER_OAUTH_CREDENTIAL_KIND,
            label = "provider-$providerId-oauth",
            challenge = "licolite.mobile-provider-oauth.v1:$providerId",
            file = androidLegacyProviderOAuthCredentialFile(providerId)
        )
    }

    private fun androidV2ProviderOAuthCredentialRecord(
        providerId: String,
        mobileAccountId: String
    ): AndroidSecureRecordIdentity {
        val safeProvider = safeAndroidRecordId(providerId)
        val safeAccount = safeAndroidRecordId(mobileAccountId)
        return AndroidSecureRecordIdentity(
            kind = ANDROID_PROVIDER_OAUTH_CREDENTIAL_KIND,
            label = "provider-$providerId-$safeAccount-oauth",
            challenge = "licolite.mobile-provider-oauth.v2:$providerId:$mobileAccountId",
            file = File(
                filesDir,
                "secure-mesh/android-provider-oauth-credentials-by-account/" +
                    "$safeProvider/$safeAccount.json"
            )
        )
    }

    private fun androidProviderOAuthAttemptFile(providerId: String, state: String): File {
        val safeProvider = safeAndroidRecordId(providerId)
        val stateDigest = sha256Hex(state.toByteArray(Charsets.UTF_8))
        return File(
            filesDir,
            "secure-mesh/android-provider-oauth-attempts/$safeProvider/$stateDigest.json"
        )
    }

    private fun androidProviderOAuthAttemptLabel(providerId: String, state: String): String {
        val stateDigest = sha256Hex(state.toByteArray(Charsets.UTF_8))
        return "provider-$providerId-oauth-attempt-$stateDigest"
    }

    private fun androidProviderOAuthAttemptChallenge(providerId: String, state: String): String {
        return "licolite.mobile-provider-oauth-attempt.v1:$providerId:$state"
    }

    private fun androidSecureRecordExists(record: AndroidSecureRecordIdentity): Boolean {
        return secureMeshAndroidSecretStore.androidSecureStoreRecordExists(
            record.kind,
            record.label,
            record.challenge,
            record.file
        )
    }

    private fun migrateAndroidSecureRecord(
        legacy: AndroidSecureRecordIdentity,
        current: AndroidSecureRecordIdentity,
        transform: (ByteArray) -> ByteArray
    ) {
        if (!androidSecureRecordExists(legacy) || androidSecureRecordExists(current)) {
            return
        }
        val legacySecret = secureMeshAndroidSecretStore.readAndroidSecureStoreRecord(
            legacy.kind,
            legacy.label,
            legacy.challenge,
            legacy.file
        )
        var migratedSecret: ByteArray? = null
        try {
            val transformed = transform(legacySecret)
            migratedSecret = transformed
            secureMeshAndroidSecretStore.writeAndroidSecureStoreRecordToFile(
                current.kind,
                current.label,
                current.challenge,
                transformed,
                current.file
            )
            val verified = secureMeshAndroidSecretStore.readAndroidSecureStoreRecord(
                current.kind,
                current.label,
                current.challenge,
                current.file
            )
            val verifiedEqual = try {
                MessageDigest.isEqual(transformed, verified)
            } finally {
                verified.fill(0)
            }
            check(verifiedEqual) { "Migrated Android secure record verification failed" }
            val legacyDeleted = secureMeshAndroidSecretStore.deleteAndroidSecureStoreRecord(
                legacy.kind,
                legacy.label,
                legacy.challenge,
                legacy.file
            )
            if (!legacyDeleted) {
                secureMeshAndroidSecretStore.deleteAndroidSecureStoreRecord(
                    current.kind,
                    current.label,
                    current.challenge,
                    current.file
                )
                throw IllegalStateException("Legacy Android secure record could not be removed")
            }
        } finally {
            legacySecret.fill(0)
            migratedSecret?.fill(0)
        }
    }

    private fun safeAndroidRecordId(value: String): String {
        val safe = value.replace(Regex("[^a-zA-Z0-9_.-]"), "_")
        return if (safe.isBlank()) "account" else safe
    }

    companion object {
        private val nativeSecureMeshRuntimeLibraryLoaded: Boolean = try {
            System.loadLibrary("lico_client_native")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }

        private const val SECURE_MESH_ANDROID_CHANNEL = "licolite.secure_mesh.android"
        private const val SECURE_MESH_ADB_TAG = "LicoSecureMeshAdb"
        private const val SECURE_MESH_NATIVE_LIBRARY = "liblico_client_native.so"
        private const val SECURE_MESH_NATIVE_EXPECTED_FEATURE_FLAGS = 255
        private const val SECURE_MESH_PROTOCOL_VERSION = "licolite.secure-mesh.v1"
        private const val RELEASE_ACCEPTANCE_CHANNEL_VERSION =
            "licolite.android.release-acceptance.v1"
        private const val RELEASE_ACCEPTANCE_AUTHORIZATION_ACTION =
            "secure_mesh.android.releaseAcceptance.authorize"
        private const val RELEASE_ACCEPTANCE_APPROVAL_RELATIVE_PATH =
            "secure-mesh/release-acceptance-approval.json"
        private const val MAX_RELEASE_ACCEPTANCE_APPROVAL_BYTES = 4096L
        private const val MAX_EXTERNAL_NATIVE_ACTION_RESULT_BYTES = 2 * 1024 * 1024
        private val CANONICAL_BASE64_URL_PATTERN = Regex("^[A-Za-z0-9_-]+$")
        private val RELEASE_ACCEPTANCE_APPROVAL_KEYS = setOf(
            "schemaVersion",
            "closureChallengeDigest",
            "invocationNonceDigest",
            "lastRequestNonceDigest",
            "expiresAtEpochMillis",
            "lastSequence",
        )
        private val SAFE_SECURE_MESH_ADB_STATUS_KEYS = setOf(
            "secretStore",
            "mobileRelaySecretStore",
            "secretTransport",
            "secretStoreBackend",
            "secretStoreContract",
            "secretStoreAccountPrefix",
            "secretStoreNamespace",
            "secretStoreHandlePattern",
            "sharedRustSecretStoreHandleContract",
            "applicationAuthorizationGrantRequired",
            "rawJsonSecretOverridesUsed",
            "rawJsonSecretOverridesProvenAbsent",
            "capabilityReport",
            "custodyOperational",
            "selectedBackend",
            "privateKeyInSelectedCustody",
            "signingKeyInSelectedCustody",
            "signedPrekeyPrivateKeyInSelectedCustody",
            "oneTimePrekeyPrivateKeyInSelectedCustody",
            "allPrivateKeysInSelectedCustody",
            "pairingSecretInSelectedCustody",
            "unsafePersistenceDetected",
            "portableConfigPrivateKeyPresent",
            "portableConfigSigningKeyPresent",
            "portableConfigSignedPrekeyPrivateKeyPresent",
            "portableConfigOneTimePrekeyPrivateKeyPresent",
            "portableConfigPairingSecretPresent",
            "productionBlocker"
        )
        private const val ANDROID_PROVIDER_CREDENTIAL_KIND = "provider_credential"
        private const val ANDROID_PROVIDER_OAUTH_CREDENTIAL_KIND = "provider_oauth_credential"
        private const val ANDROID_PROVIDER_OAUTH_ATTEMPT_KIND = "provider_oauth_attempt"
        private const val MOBILE_PROVIDER_OAUTH_CALLBACK_ACTION =
            "com.liko.arc.MOBILE_PROVIDER_OAUTH_CALLBACK"
        private const val CHATGPT_OAUTH_ISSUER = "https://auth.openai.com"
        private const val CHATGPT_OAUTH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
        private const val CHATGPT_OAUTH_SCOPE =
            "openid profile email offline_access"
        private const val CHATGPT_OAUTH_ORIGINATOR = "openclaw"
        private const val CHATGPT_OAUTH_CALLBACK_HOST = "localhost"
        private const val CHATGPT_OAUTH_CALLBACK_BIND_HOST = "127.0.0.1"
        private const val CHATGPT_OAUTH_CALLBACK_PORT = 1455
        private const val CHATGPT_OAUTH_CALLBACK_PATH = "/auth/callback"
        private const val CHATGPT_OAUTH_CALLBACK_TIMEOUT_MS = 600_000
        private const val CHATGPT_OAUTH_CALLBACK_PENDING_TIMEOUT_MS = 900_000L
        private const val CHATGPT_OAUTH_CALLBACK_ACCEPT_POLL_MS = 5_000
        private const val CHATGPT_OAUTH_CALLBACK_SOCKET_READ_TIMEOUT_MS = 5_000
        private const val CHATGPT_OAUTH_CALLBACK_SOCKET_WRITE_TIMEOUT_MS = 5_000
        private const val CHATGPT_OAUTH_CALLBACK_READ_BUFFER_BYTES = 1024
        private const val CHATGPT_OAUTH_CALLBACK_MAX_REQUEST_BYTES = 8192
        private const val CHATGPT_OAUTH_CALLBACK_BACKLOG = 16
        private const val CHATGPT_OAUTH_CALLBACK_BIND_ATTEMPTS = 8
        private const val CHATGPT_OAUTH_CALLBACK_BIND_RETRY_DELAY_MS = 125L
        private const val CHATGPT_OAUTH_DUPLICATE_CALLBACK_SETTLE_MS = 3_000L
        private const val CHATGPT_OAUTH_DUPLICATE_CALLBACK_POLL_MS = 100L
        private const val CHATGPT_OAUTH_REFRESH_SKEW_MS = 60_000L
        private const val CHATGPT_OAUTH_CHAT_TIMEOUT_MS = 90_000L
        private const val CHATGPT_OAUTH_DEFAULT_MODEL = "gpt-5.5"
        private const val CHATGPT_CODEX_RESPONSES_URL =
            "https://chatgpt.com/backend-api/codex/responses"
        private const val CHATGPT_CODEX_MODELS_URL =
            "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0"
        private const val CHATGPT_OAUTH_USER_AGENT = "openclaw (android; LicoArc)"
        private const val CHATGPT_OAUTH_VERSION = "lico-arc-android"
        private const val SECURE_MESH_ANDROID_RUNTIME_STATUS_RELATIVE_PATH =
            "files/secure-mesh/android-runtime-status.json"
        private const val SECURE_MESH_ANDROID_EXTERNAL_RUNTIME_STATUS_RELATIVE_PATH =
            "Android/data/com.liko.arc/files/secure-mesh/android-runtime-status.json"
        private const val SECURE_MESH_DIAGNOSTIC_MAX_FILES = 32
        private const val SECURE_MESH_DIAGNOSTIC_MAX_AGE_MILLIS = 7L * 24L * 60L * 60L * 1000L
        private val SECURE_MESH_DIAGNOSTIC_FILE_NAMES = setOf(
            "android-runtime-status.json",
            "adb-last-result.json",
            "adb-user-auth-status.json"
        )
        private const val BASE64_URL_FLAGS =
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
    }
}

class ChatGptWebActivity : Activity() {
    private lateinit var webView: WebView
    private val handler = Handler(Looper.getMainLooper())
    private val snapshotRunnable = object : Runnable {
        override fun run() {
            captureSnapshot()
            handler.postDelayed(this, SNAPSHOT_INTERVAL_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        webView = WebView(this)
        setContentView(
            webView,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.databaseEnabled = true
        webView.settings.userAgentString =
            "${webView.settings.userAgentString} LicoArc/0.0.1"
        webView.webChromeClient = WebChromeClient()
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                super.onPageFinished(view, url)
                scheduleSnapshot()
            }
        }
        webView.loadUrl(CHATGPT_WEB_URL)
    }

    override fun onResume() {
        super.onResume()
        scheduleSnapshot()
    }

    override fun onPause() {
        captureSnapshot()
        handler.removeCallbacks(snapshotRunnable)
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacks(snapshotRunnable)
        webView.destroy()
        super.onDestroy()
    }

    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            super.onBackPressed()
        }
    }

    private fun scheduleSnapshot() {
        handler.removeCallbacks(snapshotRunnable)
        handler.postDelayed(snapshotRunnable, SNAPSHOT_INITIAL_DELAY_MS)
    }

    private fun captureSnapshot() {
        if (!::webView.isInitialized) {
            return
        }
        val url = webView.url ?: return
        if (!url.startsWith(CHATGPT_WEB_URL)) {
            return
        }
        webView.evaluateJavascript(CHATGPT_SNAPSHOT_SCRIPT) { encoded ->
            val jsonText = decodeJavascriptString(encoded)
            if (jsonText.isBlank()) {
                return@evaluateJavascript
            }
            try {
                val snapshot = JSONObject(jsonText)
                if (snapshot.optJSONArray("messages")?.length() == 0) {
                    return@evaluateJavascript
                }
                val file = File(getExternalFilesDir(null), SNAPSHOT_RELATIVE_PATH)
                file.parentFile?.mkdirs()
                file.writeText(snapshot.toString(2), Charsets.UTF_8)
            } catch (error: Exception) {
                Log.w(TAG, "failed to persist ChatGPT web snapshot", error)
            }
        }
    }

    private fun decodeJavascriptString(value: String?): String {
        val raw = value?.trim().orEmpty()
        if (raw.isBlank() || raw == "null") {
            return ""
        }
        return try {
            JSONObject("{\"value\":$raw}").optString("value", "")
        } catch (_: Exception) {
            raw.trim('"')
        }
    }

    companion object {
        const val SNAPSHOT_RELATIVE_PATH =
            "secure-mesh/chatgpt-web-conversation-snapshot.json"
        private const val CHATGPT_WEB_URL = "https://chatgpt.com/"
        private const val SNAPSHOT_INITIAL_DELAY_MS = 1_500L
        private const val SNAPSHOT_INTERVAL_MS = 3_000L
        private const val TAG = "LicoChatGptWeb"
        private const val CHATGPT_SNAPSHOT_SCRIPT = """
            (function() {
              const nodes = Array.from(document.querySelectorAll('[data-message-author-role]'));
              const messages = nodes.map((node, index) => {
                const role = (node.getAttribute('data-message-author-role') || '').trim();
                const text = (node.innerText || node.textContent || '').replace(/\s+\n/g, '\n').trim();
                return { index, role, text: text.slice(0, 8000) };
              }).filter((item) => item.role && item.text);
              return JSON.stringify({
                providerId: 'chatgpt',
                source: 'chatgpt-webview-dom',
                capturedAt: new Date().toISOString(),
                url: location.href,
                title: document.title || '',
                messages
              });
            })();
        """
    }
}
