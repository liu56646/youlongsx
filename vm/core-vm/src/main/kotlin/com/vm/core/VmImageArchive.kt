package com.vm.core

import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.io.DataInputStream
import java.util.Properties
import java.util.zip.ZipInputStream
import java.util.zip.GZIPInputStream

/** Normalizes external bundles in a private staging directory, never in a live image. */
object VmImageArchive {
    data class Description(val name: String, val profile: String, val api: Int, val experimental: Boolean)

    private val disks = setOf("system.img", "vendor.img", "product.img", "system_ext.img",
        "userdata.img", "metadata.img", "encryptionkey.img")
    private val accepted = disks + setOf("kernel", "ramdisk.img", "vmhost-image.properties",
        "vmhost_guest_p9", "vmhost_guest_p71")
    private const val MAX_BYTES = 48L * 1024 * 1024 * 1024

    fun extract(input: InputStream, stage: File) {
        require(stage.isDirectory && stage.list().isNullOrEmpty()) { "导入临时目录必须为空" }
        val seen = mutableSetOf<String>()
        var bytes = 0L
        var entries = 0
        val buffer = ByteArray(256 * 1024)
        ZipInputStream(input.buffered()).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                require(++entries <= 10000) { "镜像包文件数量超过 10000" }
                val parts = entry.name.replace('\\', '/').split('/')
                require(!entry.name.startsWith('/') && ':' !in entry.name && ".." !in parts) {
                    "镜像包含越界路径：${entry.name}"
                }
                val leaf = parts.last()
                val name = if (leaf == "kernel-ranchu" || leaf == "kernel-ranchu-64") "kernel" else leaf
                if (!entry.isDirectory && name in accepted) {
                    require(seen.add(name)) { "镜像包包含多份 $name，请仅打包一个系统/架构" }
                    File(stage, name).outputStream().use { output ->
                        while (true) {
                            val count = zip.read(buffer)
                            if (count < 0) break
                            bytes += count
                            require(bytes <= MAX_BYTES) { "镜像解压大小超过 48GB" }
                            require(stage.usableSpace > count + 16L * 1024 * 1024) { "存储空间不足" }
                            output.write(buffer, 0, count)
                        }
                    }
                } else if (!entry.isDirectory) {
                    // Drain with a limit too: ZipInputStream.closeEntry otherwise expands
                    // ignored compressed data without any budget or cancellation bound.
                    while (true) {
                        val count = zip.read(buffer)
                        if (count < 0) break
                        bytes += count
                        require(bytes <= MAX_BYTES) { "镜像解压大小超过 48GB" }
                    }
                    if (leaf == "payload.bin" || leaf == "super.img" || leaf == "boot.img" ||
                        leaf.endsWith(".new.dat") || leaf.endsWith(".new.dat.br")) {
                        File(stage, ".source-${leaf.substringAfterLast('.')}-${leaf.substringBefore('.')}").createNewFile()
                    }
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
        for (name in disks) {
            val file = File(stage, name)
            if (file.isFile && isSparse(file)) {
                val raw = File(stage, "$name.raw")
                expandSparse(file, raw)
                check(file.delete() && raw.renameTo(file)) { "转换 $name 失败" }
            }
        }
    }

    fun describe(dir: File, fallbackName: String, strict: Boolean = true): Description {
        val props = Properties().apply {
            File(dir, "vmhost-image.properties").takeIf { it.isFile }?.inputStream()?.use { load(it) }
        }
        if (props.isNotEmpty()) {
            require(props.getProperty("schema") == "1") { "不支持的镜像描述版本" }
            require(props.getProperty("arch") == "arm64" && props.getProperty("board") == "ranchu") {
                "当前引擎仅支持 ARM64 ranchu 虚拟硬件；不能直接运行 x86 或手机专用内核"
            }
        }
        val profile = props.getProperty("profile") ?: when {
            File(dir, "vmhost_guest_p9").exists() -> "p9"
            File(dir, "vmhost_guest_p71").exists() -> "p71"
            else -> "p11"
        }
        require(profile in setOf("p71", "p9", "p11", "p13")) { "未知的启动布局：$profile" }
        require((!File(dir, "vmhost_guest_p9").exists() || profile == "p9") &&
            (!File(dir, "vmhost_guest_p71").exists() || profile == "p71")) { "启动布局描述与 p9/p71 标记冲突" }
        val required = when (profile) {
            "p9" -> setOf("kernel", "system.img", "vendor.img", "userdata.img", "encryptionkey.img")
            "p71" -> setOf("kernel", "ramdisk.img", "system.img", "userdata.img")
            else -> setOf("kernel", "ramdisk.img") + disks.minus("encryptionkey.img")
        }
        val missing = (if (strict) required else setOf("kernel", "system.img"))
            .filter { !File(dir, it).isFile || File(dir, it).length() == 0L }
        require(missing.isEmpty()) {
            val source = dir.list().orEmpty().any { it.startsWith(".source-") }
            (if (source) "这是尚未适配的刷机包。请先用电脑转换工具提取分区并适配虚拟硬件。\n" else "镜像组件不完整。\n") +
                "缺少：${missing.joinToString()}"
        }
        if (strict) {
            validateKernel(File(dir, "kernel"))
            for (name in disks.filter { File(dir, it).isFile }) {
                RandomAccessFile(File(dir, name), "r").use {
                    require(it.length() >= 1082) { "$name 为空或损坏" }
                    it.seek(1024 + 56)
                    val ext4 = it.readUnsignedByte() == 0x53 && it.readUnsignedByte() == 0xef
                    it.seek(512)
                    val signature = ByteArray(8).also(it::readFully)
                    val gpt = signature.contentEquals("EFI PART".toByteArray(Charsets.US_ASCII))
                    // Official p11/p13 templates carry a 1 MiB zero placeholder;
                    // their formattable /data fstab creates the filesystem on boot.
                    val sdkPlaceholder = name == "userdata.img" && profile in setOf("p11", "p13") &&
                        it.length() == 1048576L && isZeroFile(it)
                    // p9 encryptionkey is intentionally an empty raw footer disk.
                    require(name == "encryptionkey.img" || sdkPlaceholder || (if (profile == "p9" && name == "system.img") gpt
                        else if (profile == "p9" && name == "vendor.img") gpt || ext4 else ext4)) {
                        "$name 的文件系统/分区布局不兼容（当前要求 ext4，p9 system 要求 GPT）；不能直接挂载 qcow2、EROFS 或 sparse 原文件"
                    }
                }
            }
        }
        if (profile == "p9") File(dir, "vmhost_guest_p9").createNewFile()
        if (profile == "p71") File(dir, "vmhost_guest_p71").createNewFile()
        dir.listFiles()?.filter { it.name.startsWith(".source-") }?.forEach { it.delete() }
        val api = props.getProperty("api")?.toIntOrNull() ?: when (profile) {
            "p71" -> 25; "p9" -> 28; "p13" -> 33; else -> 30
        }
        require(api in 25..36) { "不支持的 Android API：$api" }
        return Description(props.getProperty("name", fallbackName).take(100), profile, api,
            props.getProperty("experimental", "false") == "true" || props.isEmpty())
    }

    private fun uint(file: RandomAccessFile): Long = Integer.reverseBytes(file.readInt()).toLong() and 0xffffffffL
    private fun ushort(file: RandomAccessFile): Int = java.lang.Short.reverseBytes(file.readShort()).toInt() and 0xffff

    private fun isZeroFile(file: RandomAccessFile): Boolean {
        file.seek(0)
        val buffer = ByteArray(65536)
        while (true) {
            val n = file.read(buffer)
            if (n < 0) return true
            if ((0 until n).any { buffer[it] != 0.toByte() }) return false
        }
    }

    private fun validateKernel(file: File) {
        require(file.length() in 18..(512L * 1024 * 1024)) { "内核文件为空、损坏或过大" }
        file.inputStream().buffered().use { raw ->
            raw.mark(2)
            val gzip = raw.read() == 0x1f && raw.read() == 0x8b
            raw.reset()
            DataInputStream(if (gzip) GZIPInputStream(raw) else raw).use { input ->
                val header = ByteArray(64)
                input.readFully(header)
                require(header.sliceArray(56..59).contentEquals(byteArrayOf(0x41, 0x52, 0x4d, 0x64))) {
                    "需要 ARM64 Linux Image 内核（raw/gzip）；手机 boot.img、x86 内核不能直接启动"
                }
                if (gzip) {
                    var bytes = 64L
                    val buffer = ByteArray(65536)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break // Drain to verify the gzip trailer/CRC too.
                        bytes += n
                        require(bytes <= 512L * 1024 * 1024) { "内核解压大小超过 512MB" }
                    }
                }
            }
        }
    }

    fun isSparse(file: File): Boolean = RandomAccessFile(file, "r").use {
        it.length() >= 4 && uint(it) == 0xed26ff3aL
    }

    /** Android sparse v1: RAW, FILL, DONT_CARE and CRC32 with bounded arithmetic. */
    fun expandSparse(source: File, target: File) {
        require(!target.exists()) { "转换目标已存在" }
        try {
            RandomAccessFile(source, "r").use { input ->
                require(uint(input) == 0xed26ff3aL && ushort(input) == 1) { "不支持的 sparse 版本" }
                ushort(input) // minor
                val header = ushort(input)
                val chunkHeader = ushort(input)
                val block = uint(input)
                val blocks = uint(input)
                val chunks = uint(input)
                uint(input) // image checksum is optional in the sparse format
                require(header >= 28 && chunkHeader >= 12 && block in 4..1048576 && block % 4 == 0L &&
                    blocks > 0 && blocks <= MAX_BYTES / block && chunks in 1..10000000) { "非法 sparse 头" }
                input.seek(header.toLong())
                RandomAccessFile(target, "rw").use { output ->
                    var written = 0L
                    val buffer = ByteArray(256 * 1024)
                    repeat(chunks.toInt()) {
                        val type = ushort(input)
                        ushort(input)
                        val count = uint(input)
                        val total = uint(input)
                        require(count <= blocks - written / block) { "sparse 分区大小溢出" }
                        val size = count * block
                        require(total >= chunkHeader && total - chunkHeader <= input.length() - input.filePointer - (chunkHeader - 12)) { "sparse 块截断" }
                        input.seek(input.filePointer + chunkHeader - 12)
                        val payload = total - chunkHeader
                        when (type) {
                            0xcac1 -> {
                                require(payload == size) { "RAW 块长度不匹配" }
                                require(target.usableSpace > size + 16L * 1024 * 1024) { "存储空间不足" }
                                var remaining = size
                                while (remaining > 0) {
                                    val n = minOf(remaining, buffer.size.toLong()).toInt()
                                    input.readFully(buffer, 0, n)
                                    output.write(buffer, 0, n)
                                    remaining -= n
                                }
                            }
                            0xcac2 -> {
                                require(payload == 4L) { "FILL 块长度不匹配" }
                                input.readFully(buffer, 0, 4)
                                for (i in 4 until buffer.size) buffer[i] = buffer[i % 4]
                                if (buffer.take(4).any { it != 0.toByte() }) {
                                    require(target.usableSpace > size + 16L * 1024 * 1024) { "存储空间不足" }
                                    var remaining = size
                                    while (remaining > 0) {
                                        val n = minOf(remaining, buffer.size.toLong()).toInt()
                                        output.write(buffer, 0, n)
                                        remaining -= n
                                    }
                                } else output.seek(output.filePointer + size)
                            }
                            0xcac3 -> {
                                require(payload == 0L) { "DONT_CARE 块长度不匹配" }
                                output.seek(output.filePointer + size)
                            }
                            0xcac4 -> {
                                require(payload == 4L && count == 0L) { "CRC32 块长度不匹配" }
                                uint(input)
                            }
                            else -> error("未知 sparse 块类型：$type")
                        }
                        written += size
                    }
                    require(written == block * blocks && input.filePointer == input.length()) { "sparse 总长度不匹配" }
                    output.setLength(written)
                }
            }
        } catch (t: Throwable) {
            target.delete()
            throw t
        }
    }
}
