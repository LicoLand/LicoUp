package land.lico.licoup

internal object SecureMeshAndroidBridgeContract {
    const val METHOD_CHANNEL = "licomesh.secure_mesh.android"
    const val NATIVE_LIBRARY = "liblicoup_native.so"
    const val NATIVE_EXPECTED_FEATURE_FLAGS = 255
    const val PROTOCOL_VERSION = "licomesh.secure-mesh.v1"
    const val LOG_TAG = "LicoSecureMesh"
    const val RUNTIME_STATUS_RELATIVE_PATH =
        "files/secure-mesh/android-runtime-status.json"
    const val DIAGNOSTIC_MAX_FILES = 32
    const val DIAGNOSTIC_MAX_AGE_MILLIS = 7L * 24L * 60L * 60L * 1000L

    val diagnosticFileNames = setOf(
        "android-runtime-status.json",
        "user-auth-status.json",
    )
}
