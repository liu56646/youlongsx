package com.vm.core

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Properties
import java.util.UUID

/**
 * 访客镜像供给。
 *
 * 镜像包结构（zip 根目录直接放，不套一层目录）：
 * ```
 * kernel  system.img  vendor.img  ramdisk.img  userdata.img
 * ```
 * 解压到 `files/images/<tag>/`，多实例共享同一份只读基础镜像。
 *
 * 镜像来源有两条：
 *  - [download] 从 https 直链下载（首启一键跑的主路径，支持断点续传）
 *  - [importFromZip] 导入本地 zip（从文件管理器选，或下载失败时的兜底）
 */
class VmImageProvider(private val context: Context) {

    fun imagesRoot(): File = File(context.filesDir, "images").apply { mkdirs() }

    fun imageDir(tag: String): File {
        require(tag.matches(Regex("[A-Za-z0-9_-]{1,80}"))) { "非法镜像标识" }
        return File(imagesRoot(), tag)
    }

    @Volatile var lastImportError: String? = null
        private set

    /** External images have immutable unique tags; never replace a built-in or live image. */
    fun importExternal(input: java.io.InputStream, name: String): VmGuestImage {
        val tag = "external_" + UUID.randomUUID().toString().replace("-", "")
        val stage = File(imagesRoot(), ".$tag-import").apply { check(mkdir()) }
        try {
            VmImageArchive.extract(input, stage)
            val info = VmImageArchive.describe(stage, name)
            Properties().apply {
                setProperty("schema", "1")
                setProperty("arch", "arm64")
                setProperty("board", "ranchu")
                setProperty("profile", info.profile)
                setProperty("api", info.api.toString())
                setProperty("name", info.name)
                setProperty("experimental", info.experimental.toString())
                File(stage, "vmhost-image.properties").outputStream().use { store(it, null) }
            }
            check(stage.renameTo(imageDir(tag))) { "无法发布导入的镜像" }
            return VmGuestImage(tag, info.name, info.api, 0, supportsDeviceProfile = false)
        } finally {
            stage.deleteRecursively()
        }
    }

    fun importedImages(): List<VmGuestImage> = imagesRoot().listFiles().orEmpty()
        .filter { it.isDirectory && it.name.startsWith("external_") && isReady(it.name) }
        .mapNotNull { dir -> runCatching {
            val p = Properties().apply {
                File(dir, "vmhost-image.properties").inputStream().use { load(it) }
            }
            VmGuestImage(dir.name, p.getProperty("name", dir.name),
                p.getProperty("api").toInt(), 0, supportsDeviceProfile = false)
        }.getOrNull() }.sortedBy { it.displayName }

    /** 镜像是否已就绪（kernel 与 system.img 均存在且非空）。 */
    fun isReady(tag: String): Boolean {
        val dir = imageDir(tag)
        return nonEmpty(File(dir, "kernel")) && nonEmpty(File(dir, "system.img"))
    }

    /** 数据盘模板（SDK 提供的已格式化空镜像），用于创建实例的可写数据盘。 */
    fun userDataTemplate(tag: String): File = File(imageDir(tag), "userdata.img")

    /**
     * Android 9 FDE 的加密 footer/key 盘模板（16MB raw）。
     * 没有这个文件的镜像（p11/p13/p71）返回不存在的 File，调用方按可选处理。
     */
    fun encryptionKeyTemplate(tag: String): File = File(imageDir(tag), "encryptionkey.img")

    /**
     * product / system 分区镜像模板（含 build.prop 设备身份）。
     * 实例选择自定义机型时会以它们为模板复制再改写，见 [VmDiskStore.ensureDeviceImages]。
     */
    fun productTemplate(tag: String): File = File(imageDir(tag), "product.img")

    fun systemTemplate(tag: String): File = File(imageDir(tag), "system.img")

    /**
     * metadata 盘模板（FBE 元数据分区，Android 11+ 必需）。
     * 实例必须各有一份可写副本，见 [VmDiskStore.ensureMetadata]。
     */
    fun metadataTemplate(tag: String): File = File(imageDir(tag), "metadata.img")

    /** 已就绪镜像占用的空间（字节）。 */
    fun sizeOnDisk(tag: String): Long {
        val dir = imageDir(tag)
        if (!dir.exists()) return 0L
        return dir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
    }

    /**
     * 从 https 直链下载镜像并解压。
     *
     * 支持断点续传：下载到 `<tag>.zip.part`，中断后重来会带 Range 头续传。
     *
     * @param onProgress  (已下载, 总大小)；总大小未知时为 -1
     * @param isCancelled 返回 true 时中止，已下载的部分会保留供续传
     * @return 是否最终可用
     */
    fun download(
        tag: String,
        url: String,
        onProgress: (Long, Long) -> Unit = { _, _ -> },
        isCancelled: () -> Boolean = { false }
    ): Boolean {
        val partFile = File(context.cacheDir, "$tag.zip.part")
        var existing = partFile.length()

        try {
            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 30_000
                readTimeout = 60_000
                instanceFollowRedirects = true
                if (existing > 0) {
                    setRequestProperty("Range", "bytes=$existing-")
                }
            }

            val code = connection.responseCode
            Log.i(TAG, "下载响应码 $code（已存在 $existing 字节）")

            when (code) {
                HttpURLConnection.HTTP_PARTIAL -> Unit          // 206，续传
                HttpURLConnection.HTTP_OK -> existing = 0        // 200，服务端不支持续传，从头来
                else -> {
                    Log.e(TAG, "下载失败，HTTP $code")
                    connection.disconnect()
                    return false
                }
            }

            val total = if (connection.contentLengthLong > 0) {
                existing + connection.contentLengthLong
            } else {
                -1L
            }

            connection.inputStream.use { input ->
                FileOutputStream(partFile, existing > 0).use { output ->
                    val buffer = ByteArray(1 shl 16)
                    var downloaded = existing
                    while (true) {
                        if (isCancelled()) {
                            Log.i(TAG, "下载被取消，已下载 $downloaded 字节（保留以便续传）")
                            return false
                        }
                        val n = input.read(buffer)
                        if (n <= 0) break
                        output.write(buffer, 0, n)
                        downloaded += n
                        onProgress(downloaded, total)
                    }
                }
            }
            connection.disconnect()
        } catch (t: Throwable) {
            Log.e(TAG, "下载异常", t)
            return false
        }

        val ok = importFromZip(partFile, tag)
        if (ok) {
            partFile.delete()
            Log.i(TAG, "镜像 $tag 就绪")
        }
        return ok
    }

    /** 导入本地 zip（下载完成后走这里，或用户从文件管理器选文件）。 */
    fun importFromZip(zipFile: File, tag: String): Boolean {
        if (!zipFile.isFile || zipFile.length() == 0L) {
            Log.e(TAG, "镜像包不存在或为空：$zipFile")
            return false
        }
        return try {
            zipFile.inputStream().buffered().use { importFromStream(it, tag) }
        } catch (t: Throwable) {
            Log.e(TAG, "解压失败", t)
            false
        }
    }

    /**
     * 从任意输入流导入（SAF 选中的文件只能拿到 Uri → InputStream，
     * 507 MB 的文件先拷成临时文件再解压太浪费，直接流式解压）。
     */
    fun importFromStream(zip: java.io.InputStream, tag: String): Boolean {
        val dir = imageDir(tag)
        val stage = File(imagesRoot(), ".import-${UUID.randomUUID()}").apply { check(mkdir()) }
        lastImportError = null
        return try {
            check(!dir.exists() || dir.list().isNullOrEmpty()) { "镜像目录已有内容，请使用独立的外部镜像导入，避免破坏已有实例" }
            VmImageArchive.extract(zip, stage)
            check(File(stage, "kernel").length() > 0 && File(stage, "system.img").length() > 0) { "缺少 kernel / system.img" }
            if (dir.exists()) check(dir.delete())
            check(stage.renameTo(dir)) { "无法发布导入的镜像" }
            isReady(tag)
        } catch (t: Throwable) {
            lastImportError = t.message
            Log.e(TAG, "解压失败", t)
            false
        } finally {
            stage.deleteRecursively()
        }
    }

    private fun nonEmpty(file: File): Boolean = file.exists() && file.length() > 0L

    companion object {
        private const val TAG = "VmImageProvider"
    }
}
