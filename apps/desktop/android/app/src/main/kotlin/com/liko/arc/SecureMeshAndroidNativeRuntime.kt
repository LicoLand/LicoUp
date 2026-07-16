package com.liko.arc

internal interface SecureMeshAndroidNativeRuntime {
    val libraryLoaded: Boolean

    fun selfTest(): Int

    fun featureFlags(): Int

    fun protocolHash(): Int

    fun invoke(
        requestJson: String,
        filesDir: String,
        secretStoreBridge: SecureMeshAndroidSecretStore,
    ): String
}
