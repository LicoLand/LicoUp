package land.lico.licoup

/**
 * Debug-only host for the local release verifier.
 *
 * The production activity has no receiver, coordinator, or external result
 * path. Keeping this subclass in the debug source set makes that boundary
 * mechanically visible in the merged release manifest and DEX.
 */
class DebugMainActivity : MainActivity() {
    private val releaseAcceptanceCoordinator by lazy {
        SecureMeshAndroidReleaseAcceptanceCoordinator(
            activity = this,
            commandRouter = commandRouter,
            secretStore = secretStore,
            authenticator = authenticator,
            runtimeStatusStore = runtimeStatusStore,
        )
    }

    internal override fun localVerificationBindings(): SecureMeshAndroidDiagnosticBindings =
        releaseAcceptanceCoordinator.digests()

    internal override fun onLocalVerificationCreate() {
        releaseAcceptanceCoordinator.onCreate()
    }

    internal override fun onLocalVerificationFlutterEngineConfigured() {
        releaseAcceptanceCoordinator.onFlutterEngineConfigured()
    }

    internal override fun onLocalVerificationNewIntent() {
        releaseAcceptanceCoordinator.onNewIntent()
    }
}
