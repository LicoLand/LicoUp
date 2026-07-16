package com.liko.arc

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureMeshAndroidBridgeBoundaryTest {
    private val mainSourceRoot = listOf(
        File("src/main/kotlin/com/liko/arc"),
        File("app/src/main/kotlin/com/liko/arc"),
        File("apps/desktop/android/app/src/main/kotlin/com/liko/arc"),
    ).firstOrNull { it.isDirectory }
        ?: error("Android Kotlin source root is unavailable")
    private val debugSourceRoot = listOf(
        File("src/debug/kotlin/com/liko/arc"),
        File("app/src/debug/kotlin/com/liko/arc"),
        File("apps/desktop/android/app/src/debug/kotlin/com/liko/arc"),
    ).firstOrNull { it.isDirectory }
        ?: error("Android debug Kotlin source root is unavailable")
    private val manifestRoot = listOf(
        File("src"),
        File("app/src"),
        File("apps/desktop/android/app/src"),
    ).firstOrNull { it.isDirectory }
        ?: error("Android manifest source root is unavailable")

    @Test
    fun mainActivityKeepsOnlyLifecycleAndJniBindings() {
        val main = source("MainActivity.kt")
        assertTrue(main.lineSequence().count() < 150)
        assertTrue(main.contains("external fun nativeSecureMeshJson"))
        assertTrue(main.contains("SecureMeshAndroidCommandRouter("))
        assertTrue(main.contains("onLocalVerificationCreate"))
        assertTrue(main.contains("MethodChannel("))
        assertTrue(main.contains("SecureMeshAndroidNativeDispatchQueue"))
        assertFalse(main.contains("\"nativeJson\" -> Thread"))
        assertFalse(main.contains("AlertDialog.Builder"))
        assertFalse(main.contains("Cipher.getInstance"))
        assertFalse(main.contains("ReleaseAcceptance"))
    }

    @Test
    fun commandRouterOwnsActionsWithoutReleaseSessionState() {
        val router = source("SecureMeshAndroidCommandRouter.kt")
        assertTrue(router.lineSequence().count() < 400)
        assertTrue(router.contains("private fun authorizeAction"))
        assertTrue(router.contains("nativeRuntime.invoke("))
        assertTrue(router.contains("openExternalUrl"))
        assertFalse(router.contains("AlertDialog.Builder"))
        assertFalse(router.contains("ReleaseAcceptanceChannel.evaluate"))
        assertFalse(router.contains("pendingPromptKey"))
    }

    @Test
    fun releaseCoordinatorOwnsApprovalSessionAndPrompt() {
        val release = debugSource("SecureMeshAndroidReleaseAcceptanceCoordinator.kt")
        assertTrue(release.lineSequence().count() < 600)
        assertTrue(release.contains("ReleaseAcceptanceChannel.evaluate"))
        assertTrue(release.contains("AlertDialog.Builder"))
        assertTrue(release.contains("persistApproval"))
        assertTrue(release.contains("ReleaseAcceptanceDebugCodec"))
        assertFalse(release.contains("external fun"))
        assertFalse(release.contains("MethodChannel("))
    }

    @Test
    fun codecAndRuntimeStoreRemainLeafModules() {
        val codec = source("SecureMeshAndroidJsonCodec.kt")
        val debugCodec = debugSource("ReleaseAcceptanceDebugCodec.kt")
        val status = source("SecureMeshAndroidRuntimeStatusStore.kt")
        assertTrue(codec.lineSequence().count() < 250)
        assertTrue(status.lineSequence().count() < 150)
        assertFalse(codec.contains("ReleaseAcceptance"))
        assertTrue(debugCodec.contains("fun sanitize"))
        assertTrue(debugCodec.contains("fun decodeParams"))
        assertFalse(codec.contains("FlutterActivity"))
        assertFalse(codec.contains("File("))
        assertTrue(status.contains("AtomicFile"))
        assertTrue(status.contains("pruneDiagnostics"))
        assertFalse(status.contains("externalFilesDir"))
        assertFalse(status.contains("MethodChannel"))
        assertFalse(status.contains("ReleaseAcceptanceChannel"))
    }

    @Test
    fun releaseSourceSetHasNoAcceptanceReceiverOrImplementation() {
        val mainManifest = File(manifestRoot, "main/AndroidManifest.xml").readText()
        val debugManifest = File(manifestRoot, "debug/AndroidManifest.xml").readText()
        val mainSources = mainSourceRoot.walkTopDown()
            .filter(File::isFile)
            .joinToString("\n") { it.readText(Charsets.UTF_8) }

        assertFalse(mainManifest.contains("ReleaseAcceptanceReceiver"))
        assertFalse(mainManifest.contains("com.liko.arc.RELEASE_ACCEPTANCE"))
        assertTrue(mainManifest.contains("android:allowBackup=\"false\""))
        assertTrue(mainManifest.contains("android:dataExtractionRules=\"@xml/backup_rules\""))
        assertTrue(mainManifest.contains("android:fullBackupContent=\"@xml/backup_rules_legacy\""))
        assertTrue(debugManifest.contains("ReleaseAcceptanceReceiver"))
        assertTrue(debugManifest.contains("android.permission.DUMP"))
        assertFalse(mainSources.contains("ReleaseAcceptanceChannel"))
        assertFalse(mainSources.contains("ReleaseAcceptanceReceiver"))
        assertTrue(File(debugSourceRoot, "DebugMainActivity.kt").isFile)
    }

    private fun source(name: String): String =
        File(mainSourceRoot, name).readText(Charsets.UTF_8)

    private fun debugSource(name: String): String =
        File(debugSourceRoot, name).readText(Charsets.UTF_8)
}
