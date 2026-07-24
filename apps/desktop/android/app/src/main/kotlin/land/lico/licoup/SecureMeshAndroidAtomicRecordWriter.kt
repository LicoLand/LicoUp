package land.lico.licoup

import android.util.AtomicFile
import java.io.File
import java.io.FileOutputStream

internal interface SecureMeshAndroidAtomicRecordTransaction {
    val pendingFile: File

    fun writeAndSync(bytes: ByteArray)

    fun commit()

    fun rollback()
}

internal fun interface SecureMeshAndroidAtomicRecordTransactionFactory {
    fun create(target: File): SecureMeshAndroidAtomicRecordTransaction
}

/** Writes and verifies the pending encrypted record before the atomic rename. */
internal class SecureMeshAndroidAtomicRecordWriter(
    private val transactionFactory: SecureMeshAndroidAtomicRecordTransactionFactory =
        SecureMeshAndroidAtomicRecordTransactionFactory(::AndroidAtomicRecordTransaction),
) {
    fun write(
        target: File,
        bytes: ByteArray,
        validatePending: (File) -> Unit,
    ) {
        val parent = target.parentFile
            ?: error("secure mesh Android encrypted record has no parent directory")
        check((parent.isDirectory || parent.mkdirs()) && parent.isDirectory) {
            "secure mesh Android encrypted record directory is unavailable"
        }
        val transaction = transactionFactory.create(target)
        try {
            transaction.writeAndSync(bytes)
            validatePending(transaction.pendingFile)
            transaction.commit()
        } catch (error: Exception) {
            try {
                transaction.rollback()
            } catch (_: Exception) {
            }
            throw error
        }
    }
}

private class AndroidAtomicRecordTransaction(target: File) :
    SecureMeshAndroidAtomicRecordTransaction {
    private val atomicFile = AtomicFile(target)
    private var output: FileOutputStream? = null

    override val pendingFile = File("${target.path}.new")

    override fun writeAndSync(bytes: ByteArray) {
        check(output == null) { "secure mesh Android atomic write already started" }
        val opened = atomicFile.startWrite()
        output = opened
        opened.write(bytes)
        opened.fd.sync()
    }

    override fun commit() {
        val opened = output
            ?: error("secure mesh Android atomic write was not started")
        atomicFile.finishWrite(opened)
        output = null
    }

    override fun rollback() {
        val opened = output
        if (opened != null) {
            atomicFile.failWrite(opened)
            output = null
        }
    }
}
