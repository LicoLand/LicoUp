package com.liko.arc

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureMeshAndroidNativeDispatchQueueTest {
    @Test
    fun commandsExecuteOnOneLaneInSubmissionOrder() {
        val queue = SecureMeshAndroidNativeDispatchQueue(capacity = 4)
        val output = Collections.synchronizedList(mutableListOf<Int>())
        val complete = CountDownLatch(3)
        try {
            repeat(3) { value ->
                assertTrue(queue.submit {
                    output += value
                    complete.countDown()
                })
            }
            assertTrue(complete.await(2, TimeUnit.SECONDS))
            assertEquals(listOf(0, 1, 2), output)
        } finally {
            queue.close()
        }
    }

    @Test
    fun saturationFailsFastWithoutSpawningAnotherLane() {
        val queue = SecureMeshAndroidNativeDispatchQueue(capacity = 1)
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        try {
            assertTrue(queue.submit {
                started.countDown()
                release.await(2, TimeUnit.SECONDS)
            })
            assertTrue(started.await(2, TimeUnit.SECONDS))
            assertTrue(queue.submit {})
            assertFalse(queue.submit {})
        } finally {
            release.countDown()
            queue.close()
        }
    }
}
