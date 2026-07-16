package com.liko.arc

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** A bounded single lane for all stateful Rust/JNI commands. */
internal class SecureMeshAndroidNativeDispatchQueue(
    capacity: Int = DEFAULT_CAPACITY,
) : AutoCloseable {
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(capacity.coerceAtLeast(1)),
        ThreadFactory { task ->
            Thread(task, "licoarc-secure-mesh-native").apply { isDaemon = true }
        },
        ThreadPoolExecutor.AbortPolicy(),
    )

    fun submit(task: () -> Unit): Boolean = try {
        executor.execute(task)
        true
    } catch (_: RejectedExecutionException) {
        false
    }

    override fun close() {
        executor.shutdownNow()
    }

    internal companion object {
        const val DEFAULT_CAPACITY = 16
    }
}
