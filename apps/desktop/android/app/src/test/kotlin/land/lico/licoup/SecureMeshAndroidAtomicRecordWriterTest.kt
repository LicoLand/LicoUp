package land.lico.licoup

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SecureMeshAndroidAtomicRecordWriterTest {
    @Test
    fun validatorFailurePreservesCommittedRecord() = withFixture { target, factory ->
        target.writeText("old")
        val writer = SecureMeshAndroidAtomicRecordWriter(factory)

        runCatching {
            writer.write(target, "new".toByteArray()) {
                error("injected validation failure")
            }
        }

        assertEquals("old", target.readText())
        assertFalse(File("${target.path}.new").exists())
    }

    @Test
    fun commitFailurePreservesCommittedRecord() = withFixture { target, _ ->
        target.writeText("old")
        val writer = SecureMeshAndroidAtomicRecordWriter(
            fakeFactory(failCommit = true),
        )

        runCatching {
            writer.write(target, "new".toByteArray()) { pending ->
                assertEquals("new", pending.readText())
            }
        }

        assertEquals("old", target.readText())
        assertFalse(File("${target.path}.new").exists())
    }

    @Test
    fun successfulValidationCommitsWholeRecord() = withFixture { target, factory ->
        target.writeText("old")
        val writer = SecureMeshAndroidAtomicRecordWriter(factory)

        writer.write(target, "new".toByteArray()) { pending ->
            assertEquals("new", pending.readText())
        }

        assertEquals("new", target.readText())
        assertFalse(File("${target.path}.new").exists())
    }

    private fun withFixture(
        body: (File, SecureMeshAndroidAtomicRecordTransactionFactory) -> Unit,
    ) {
        val directory = Files.createTempDirectory("licoup-android-atomic-record").toFile()
        try {
            body(File(directory, "record.json"), fakeFactory())
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun fakeFactory(
        failCommit: Boolean = false,
    ) = SecureMeshAndroidAtomicRecordTransactionFactory { target ->
        object : SecureMeshAndroidAtomicRecordTransaction {
            override val pendingFile = File("${target.path}.new")

            override fun writeAndSync(bytes: ByteArray) {
                FileOutputStream(pendingFile).use { output ->
                    output.write(bytes)
                    output.fd.sync()
                }
            }

            override fun commit() {
                if (failCommit) error("injected commit failure")
                check(pendingFile.renameTo(target))
            }

            override fun rollback() {
                check(!pendingFile.exists() || pendingFile.delete())
            }
        }
    }
}
