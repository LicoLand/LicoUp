package land.lico.licoup

import android.util.AtomicFile
import java.io.File
import org.json.JSONObject

internal class SecureMeshAndroidRuntimeStatusStore(
    private val filesDir: File,
) {
    fun runtimeStatusFile(): File =
        File(filesDir, "secure-mesh/android-runtime-status.json")

    fun pruneDiagnostics() {
        pruneDiagnostics(File(filesDir, "secure-mesh"))
    }

    fun writePayload(payload: Map<String, Any?>) {
        val serialized = JSONObject(payload).toString(2)
        writeAtomic(runtimeStatusFile(), serialized)
    }

    fun writeAtomic(target: File, serialized: String) {
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

    private fun pruneDiagnostics(directory: File) {
        if (!directory.isDirectory) return
        val now = System.currentTimeMillis()
        val diagnostics = directory
            .listFiles()
            .orEmpty()
            .asSequence()
            .filter {
                it.isFile &&
                    it.name in SecureMeshAndroidBridgeContract.diagnosticFileNames
            }
            .sortedByDescending(File::lastModified)
            .toList()
        diagnostics
            .filter {
                now - it.lastModified() >
                    SecureMeshAndroidBridgeContract.DIAGNOSTIC_MAX_AGE_MILLIS
            }
            .forEach(File::delete)
        diagnostics
            .drop(SecureMeshAndroidBridgeContract.DIAGNOSTIC_MAX_FILES)
            .forEach(File::delete)
    }
}
