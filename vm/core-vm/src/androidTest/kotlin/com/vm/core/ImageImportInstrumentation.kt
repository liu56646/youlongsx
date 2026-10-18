package com.vm.core

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import java.util.zip.GZIPOutputStream

/** Runs in the library's separate test APK, never in a user's VM process. */
class ImageImportInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    private fun archive(entries: List<Pair<String, ByteArray>>): ByteArray {
        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zip -> entries.forEach { (name, data) ->
            zip.putNextEntry(ZipEntry(name)); zip.write(data); zip.closeEntry()
        } }
        return bytes.toByteArray()
    }

    override fun onStart() {
        val provider = VmImageProvider(targetContext)
        val ownedTags = mutableListOf<String>()
        val testDir = File(context.cacheDir, "image-import-${System.nanoTime()}").apply { check(mkdir()) }
        val before = provider.imagesRoot().list().orEmpty().toSet()
        val result = Bundle()
        var code = Activity.RESULT_OK
        try {
            val kernel = ByteArray(64).also { "ARMd".toByteArray().copyInto(it, 56) }
            val ext4 = ByteArray(4096).also { it[1080] = 0x53; it[1081] = 0xef.toByte() }
            val compressedKernel = ByteArrayOutputStream().also { bytes ->
                GZIPOutputStream(bytes).use { it.write(kernel) }
            }.toByteArray()
            val entries = mutableListOf("nested/kernel-ranchu" to compressedKernel, "nested/ramdisk.img" to byteArrayOf(1))
            for (name in listOf("system", "vendor", "product", "system_ext", "userdata", "metadata")) {
                entries += "nested/$name.img" to if (name == "userdata") ByteArray(1048576) else ext4
            }
            entries += "nested/vmhost-image.properties" to
                "schema=1\narch=arm64\nboard=ranchu\nprofile=p11\napi=30\nname=Import fixture\nexperimental=true\n".toByteArray()
            val bytes = archive(entries)
            repeat(2) {
                val image = provider.importExternal(ByteArrayInputStream(bytes), "fallback")
                ownedTags += image.tag
                check(image.displayName == "Import fixture" && provider.isReady(image.tag))
                check(provider.importedImages().any { it.tag == image.tag })
            }
            check(ownedTags[0] != ownedTags[1])
            for (bad in listOf(
                archive(listOf("../escape/kernel" to kernel)),
                archive(listOf("payload.bin" to byteArrayOf(1))),
                "not a zip".toByteArray()
            )) {
                check(runCatching { provider.importExternal(ByteArrayInputStream(bad), "bad") }.isFailure)
                check(provider.imagesRoot().list().orEmpty().toSet() == before + ownedTags)
            }
            // The legacy download/import path also leaves an existing image untouched.
            val legacy = ownedTags[0]
            check(!provider.importFromStream(ByteArrayInputStream(bytes), legacy))
            check(provider.isReady(legacy))

            // Same production method, isolated filesDir: preserve an external data
            // filesystem larger than the default instead of truncating it to 4 GiB.
            val disk = VmDiskStore(targetContext)
            check(!disk.userDataImage(4).exists()) { "Test APK already has a scratch disk" }
            val scratch = disk.userDataImage(4)
            try {
                RandomAccessFile(scratch, "rw").use { it.setLength(5L * 1024 * 1024 * 1024) }
                disk.ensureUserData(4)
                check(scratch.length() == 5L * 1024 * 1024 * 1024)
                check(scratch.delete())
                val template = File(testDir, "userdata-template.img").apply { writeBytes(ext4) }
                // Exercise the copy branch, using a scaled default to avoid writing
                // 5 GiB of flash merely to prove that the length is never reduced.
                disk.ensureUserData(4, template, sizeBytes = 2048)
                check(scratch.length() == 4096L)
            } finally {
                scratch.delete()
                scratch.parentFile?.delete()
            }
            result.putString("stream", "\nPASS: two unique imports, registry, invalid/traversal cleanup, existing-image preservation, >4GiB data preservation\n")
        } catch (t: Throwable) {
            code = Activity.RESULT_CANCELED
            result.putString("stream", "\nFAIL: ${t.stackTraceToString()}\n")
        } finally {
            ownedTags.forEach { provider.imageDir(it).deleteRecursively() }
            testDir.deleteRecursively()
        }
        finish(code, result)
    }
}
