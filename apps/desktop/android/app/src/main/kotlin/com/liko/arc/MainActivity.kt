package com.liko.arc

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

open class MainActivity : FlutterActivity() {
    private external fun nativeSecureMeshRuntimeSelfTest(): Int
    private external fun nativeSecureMeshRuntimeFeatureFlags(): Int
    private external fun nativeSecureMeshRuntimeProtocolHash(): Int
    private external fun nativeSecureMeshJson(
        requestJson: String,
        filesDir: String,
        secretStoreBridge: SecureMeshAndroidSecretStore,
    ): String

    internal val authenticator by lazy { SecureMeshAndroidUserAuthenticator(this) }
    internal val secretStore by lazy {
        SecureMeshAndroidSecretStore(this, filesDir) {
            authenticator.hasActiveAuthorizationGrant()
        }
    }
    internal val runtimeStatusStore by lazy { SecureMeshAndroidRuntimeStatusStore(filesDir) }
    private val nativeDispatchQueueDelegate = lazy {
        SecureMeshAndroidNativeDispatchQueue()
    }
    private val nativeDispatchQueue: SecureMeshAndroidNativeDispatchQueue
        get() = nativeDispatchQueueDelegate.value
    private val nativeRuntime by lazy {
        object : SecureMeshAndroidNativeRuntime {
            override val libraryLoaded: Boolean
                get() = nativeSecureMeshRuntimeLibraryLoaded

            override fun selfTest(): Int = nativeSecureMeshRuntimeSelfTest()

            override fun featureFlags(): Int = nativeSecureMeshRuntimeFeatureFlags()

            override fun protocolHash(): Int = nativeSecureMeshRuntimeProtocolHash()

            override fun invoke(
                requestJson: String,
                filesDir: String,
                secretStoreBridge: SecureMeshAndroidSecretStore,
            ): String = nativeSecureMeshJson(requestJson, filesDir, secretStoreBridge)
        }
    }
    internal val commandRouter by lazy {
        SecureMeshAndroidCommandRouter(
            activity = this,
            filesDir = filesDir,
            secretStore = secretStore,
            authenticator = authenticator,
            nativeRuntime = nativeRuntime,
            runtimeStatusStore = runtimeStatusStore,
        )
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        onLocalVerificationCreate()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SecureMeshAndroidBridgeContract.METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(
                    commandRouter.status(localVerificationBindings()),
                )
                "writeRuntimeStatus" -> result.success(
                    commandRouter.writeRuntimeStatus(
                        localVerificationBindings(),
                    ),
                )
                "nativeJson" -> {
                    val accepted = nativeDispatchQueue.submit {
                        val output = commandRouter.run(call.arguments)
                        runOnUiThread { result.success(output) }
                    }
                    if (!accepted) {
                        result.error(
                            "secure_mesh_native_queue_busy",
                            "Secure Mesh native queue is busy.",
                            mapOf("bodyRedacted" to true),
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
        onLocalVerificationFlutterEngineConfigured()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        onLocalVerificationNewIntent()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        authenticator.onActivityResult(requestCode, resultCode)
    }

    override fun onDestroy() {
        if (nativeDispatchQueueDelegate.isInitialized()) {
            nativeDispatchQueue.close()
        }
        super.onDestroy()
    }

    /** Debug/acceptance variants may override these hooks from their own source set. */
    internal open fun localVerificationBindings() = SecureMeshAndroidDiagnosticBindings()

    internal open fun onLocalVerificationCreate() = Unit

    internal open fun onLocalVerificationFlutterEngineConfigured() = Unit

    internal open fun onLocalVerificationNewIntent() = Unit

    companion object {
        private val nativeSecureMeshRuntimeLibraryLoaded: Boolean = try {
            System.loadLibrary("lico_client_native")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }
}
