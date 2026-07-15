package com.liko.arc

/** Process-lifetime fallback. Values are never serialized and replaced buffers are zeroed. */
internal class SecureMeshAndroidEphemeralSecretStore {
    private val lock = Any()
    private val values = mutableMapOf<String, ByteArray>()

    fun put(key: String, value: ByteArray) {
        val replacement = value.copyOf()
        synchronized(lock) {
            values.put(key, replacement)?.fill(0)
        }
    }

    fun get(key: String): ByteArray? {
        return synchronized(lock) {
            values[key]?.copyOf()
        }
    }

    fun delete(key: String): Boolean {
        return synchronized(lock) {
            values.remove(key)?.also { it.fill(0) } != null
        }
    }

    fun clear() {
        synchronized(lock) {
            values.values.forEach { it.fill(0) }
            values.clear()
        }
    }

    internal fun entryCountForTest(): Int = synchronized(lock) { values.size }
}
