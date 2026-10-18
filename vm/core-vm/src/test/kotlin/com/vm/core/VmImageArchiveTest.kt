package com.vm.core

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import java.util.zip.GZIPOutputStream

class VmImageArchiveTest {
    @get:Rule val temp = TemporaryFolder()

    private fun zip(vararg entries: Pair<String, ByteArray>): ByteArrayInputStream {
        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { out -> entries.forEach { (name, data) ->
            out.putNextEntry(ZipEntry(name)); out.write(data); out.closeEntry()
        } }
        return ByteArrayInputStream(bytes.toByteArray())
    }

    private fun reject(block: () -> Unit): Exception {
        try { block() } catch (e: Exception) { return e }
        fail("Invalid input was accepted")
        error("unreachable")
    }

    private fun sparse(vararg chunks: Triple<Int, Int, ByteArray>, blocks: Int = 4): ByteArray {
        val b = ByteBuffer.allocate(4096).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(0xed26ff3a.toInt()).putShort(1).putShort(0).putShort(28).putShort(12)
            .putInt(4).putInt(blocks).putInt(chunks.size).putInt(0)
        chunks.forEach { (type, count, bytes) ->
            b.putShort(type.toShort()).putShort(0).putInt(count).putInt(12 + bytes.size).put(bytes)
        }
        return b.array().copyOf(b.position())
    }

    private fun expand(bytes: ByteArray): File {
        val src = temp.newFile().apply { writeBytes(bytes) }
        val dst = File(temp.root, "raw-${System.nanoTime()}")
        VmImageArchive.expandSparse(src, dst)
        return dst
    }

    private fun complete(profile: String = "p11"): File {
        val dir = temp.newFolder()
        File(dir, "kernel").writeBytes(ByteArray(64).also { "ARMd".toByteArray().copyInto(it, 56) })
        File(dir, "ramdisk.img").writeBytes(byteArrayOf(1))
        for (name in listOf("system", "vendor", "product", "system_ext", "metadata", "userdata")) {
            File(dir, "$name.img").writeBytes(ByteArray(2048).also { it[1080] = 0x53; it[1081] = 0xef.toByte() })
        }
        File(dir, "vmhost-image.properties").writeText("schema=1\nboard=ranchu\narch=arm64\nprofile=$profile\nname=Example\n")
        return dir
    }

    @Test fun rawFillHoleAndCrc() {
        val raw = expand(sparse(Triple(0xcac1, 1, byteArrayOf(1, 2, 3, 4)),
            Triple(0xcac2, 2, byteArrayOf(5, 6, 7, 8)), Triple(0xcac3, 1, byteArrayOf()),
            Triple(0xcac4, 0, byteArrayOf(0, 0, 0, 0))))
        assertArrayEquals(byteArrayOf(1,2,3,4,5,6,7,8,5,6,7,8,0,0,0,0), raw.readBytes())
    }

    @Test fun zeroFillExtendsFile() {
        assertArrayEquals(ByteArray(16), expand(sparse(Triple(0xcac2, 4, ByteArray(4)))).readBytes())
    }

    @Test fun rejectOverflow() { reject { expand(sparse(Triple(0xcac3, 5, byteArrayOf()))) } }
    @Test fun rejectTruncatedRaw() { reject { expand(sparse(Triple(0xcac1, 4, byteArrayOf(1,2)))) } }
    @Test fun rejectUnknownChunk() { reject { expand(sparse(Triple(0x1234, 4, byteArrayOf()))) } }
    @Test fun rejectMissingBlocks() { reject { expand(sparse(Triple(0xcac3, 3, byteArrayOf()))) } }
    @Test fun preserveExistingConversionTarget() {
        val src = temp.newFile().apply { writeBytes(sparse(Triple(0xcac3, 4, byteArrayOf()))) }
        val target = temp.newFile().apply { writeText("keep") }
        reject { VmImageArchive.expandSparse(src, target) }
        assertEquals("keep", target.readText())
    }

    @Test fun nestedArchiveAndKernelAlias() {
        val dir = temp.newFolder()
        VmImageArchive.extract(zip("arm64-v8a/kernel-ranchu" to byteArrayOf(7),
            "arm64-v8a/system.img" to byteArrayOf(8)), dir)
        assertEquals(7, File(dir, "kernel").readBytes()[0].toInt())
        assertEquals(8, File(dir, "system.img").readBytes()[0].toInt())
    }
    @Test fun rejectTraversalAndDuplicateArchitecture() {
        reject { VmImageArchive.extract(zip("../escape/kernel" to byteArrayOf(1)), temp.newFolder()) }
        reject { VmImageArchive.extract(zip("a/system.img" to byteArrayOf(1), "b/system.img" to byteArrayOf(2)), temp.newFolder()) }
        reject { VmImageArchive.extract(zip("..\\escape\\kernel" to byteArrayOf(1)), temp.newFolder()) }
    }
    @Test fun phonePayloadHasActionableError() {
        val dir = temp.newFolder()
        VmImageArchive.extract(zip("payload.bin" to byteArrayOf(1)), dir)
        assertTrue(reject { VmImageArchive.describe(dir, "Phone ROM") }.message!!.contains("刷机包"))
    }
    @Test fun validBundleAndWrongArchitecture() {
        val dir = complete()
        assertEquals("Example", VmImageArchive.describe(dir, "fallback").name)
        File(dir, "vmhost-image.properties").appendText("arch=x86_64\n")
        assertTrue(reject { VmImageArchive.describe(dir, "fallback") }.message!!.contains("ARM64"))
    }
    @Test fun rejectPhoneBootImageAsKernel() {
        val dir = complete()
        File(dir, "kernel").writeBytes(ByteArray(4096).also { "ANDROID!".toByteArray().copyInto(it) })
        reject { VmImageArchive.describe(dir, "phone") }
    }
    @Test fun gzipKernelAndSdkDataPlaceholder() {
        val dir = complete()
        val bytes = ByteArrayOutputStream()
        GZIPOutputStream(bytes).use { it.write(File(dir, "kernel").readBytes()) }
        File(dir, "kernel").writeBytes(bytes.toByteArray())
        File(dir, "userdata.img").writeBytes(ByteArray(1048576))
        assertEquals("p11", VmImageArchive.describe(dir, "SDK").profile)
        val damaged = bytes.toByteArray().also { it[it.size - 8] = (it[it.size - 8].toInt() xor 1).toByte() }
        File(dir, "kernel").writeBytes(damaged)
        reject { VmImageArchive.describe(dir, "broken gzip") }
    }
    @Test fun rejectNonzeroUnformattedPlaceholder() {
        val dir = complete()
        File(dir, "userdata.img").writeBytes(ByteArray(1048576).also { it[8192] = 1 })
        reject { VmImageArchive.describe(dir, "bad template") }
    }
    @Test fun rejectMissingDiskAndQcow() {
        val dir = complete()
        File(dir, "metadata.img").delete()
        reject { VmImageArchive.describe(dir, "missing disk") }
        File(dir, "metadata.img").writeBytes(ByteArray(2048))
        reject { VmImageArchive.describe(dir, "wrong format") }
    }
    @Test fun p71DoesNotRequireVendor() {
        val dir = complete("p71")
        File(dir, "vendor.img").delete()
        assertEquals(25, VmImageArchive.describe(dir, "old").api)
        assertTrue(File(dir, "vmhost_guest_p71").exists())
    }
    @Test fun rejectConflictingBootMarkers() {
        val dir = complete()
        File(dir, "vmhost_guest_p71").createNewFile()
        reject { VmImageArchive.describe(dir, "wrong layout") }
    }
    @Test fun p9GptLayoutAndFooter() {
        val dir = complete("p9")
        for (name in listOf("system", "vendor")) File(dir, "$name.img").writeBytes(ByteArray(2048).also {
            "EFI PART".toByteArray().copyInto(it, 512)
        })
        File(dir, "encryptionkey.img").writeBytes(ByteArray(2048))
        assertEquals("p9", VmImageArchive.describe(dir, "old").profile)
    }
}
