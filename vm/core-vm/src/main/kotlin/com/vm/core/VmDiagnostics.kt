package com.vm.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * 诊断包（bug report 套件）导出。
 *
 * ## 解决什么问题
 * 这个项目的排障信息散落四处：宿主事件日志（events.log）、引擎串口日志
 * （console.log）、实例配置快照（config.json）、设备预检报告、加速探测报告、
 * 存储盘点。用户报告「起不来 / 起得慢」时，来回索要每一份的效率极低。
 * [VmDiagnostics] 把它们一次性打成一个 zip，用户直接分享单个文件。
 *
 * ## 设计取舍
 *  - **构建器模式 + 分节**：调用方（宿主 App）决定收哪些节，本类只管
 *    「收集 → 命名 → 打包 → 清单」，不依赖任何 Android UI/Context，
 *    纯 JVM 可单测；
 *  - **顺序稳定**：节名加两位序号前缀（`01_device.json`、`02_vm1_events.log`），
 *    解包后的目录排序即阅读顺序 —— 排障时的对照顺序（环境 → 配置 → 日志）
 *    不随添加代码的书写顺序漂移；
 *  - **缺节不失败**：某一节文件不存在时写进 manifest 的 `missing` 列表
 *    （「console.log 不存在」本身就是有价值的线索），其余照常打包；
 *  - **大文件取尾**：引擎日志可能上百 MB，[addFileTail] 只收最后
 *    [DEFAULT_TAIL_BYTES] 字节 —— 排障几乎只关心「崩之前发生了什么」。
 *    （手动指定 full 的节仍可整文件收录。）
 *
 * zip 布局：
 * ```
 * manifest.json            生成时间 / 版本 / 各节状态
 * 01_device.json           设备预检（宿主 App 组装）
 * 02_backend.json          加速探测（机器可读版）
 * 03_backend.txt           加速探测（人类可读版）
 * 04_storage.txt           存储盘点
 * 05_vm1_config.json       实例 1 启动配置快照
 * 06_vm1_events.log        实例 1 宿主事件日志（尾部）
 * 07_vm1_console.log       实例 1 引擎串口日志（尾部）
 * ```
 */
class VmDiagnostics private constructor() {

    private val sections = mutableListOf<Section>()

    internal fun sectionCount(): Int = sections.size

    /** 加入一节纯文本。 */
    fun addText(name: String, content: String, extension: String = "txt"): VmDiagnostics = apply {
        sections += Section.Text(requireValid(name), content, extension)
    }

    /**
     * 加入一节 JSON 文本（与 [addText] 的区别只是扩展名，解包后便于工具解析）。
     */
    fun addJson(name: String, json: String): VmDiagnostics =
        apply { sections += Section.Text(requireValid(name), json, "json") }

    /**
     * 加入一个文件（整份收录）。文件可选：不存在时记入 manifest 的 missing，
     * 不算失败。
     */
    fun addFile(name: String, file: File, required: Boolean = false): VmDiagnostics = apply {
        sections += Section.FileRef(requireValid(name), file, required, tailBytes = -1L)
    }

    /**
     * 加入一个文件的**尾部**（大日志用）。文件不存在时按 [required] 决定
     * 记 missing 还是失败。
     */
    fun addFileTail(
        name: String,
        file: File,
        tailBytes: Long = DEFAULT_TAIL_BYTES
    ): VmDiagnostics = apply {
        sections += Section.FileRef(requireValid(name), file, required = false, tailBytes = tailBytes)
    }

    /** 设备预检报告 → JSON 节。字段即 [VmDeviceCheck.Report] 的列。 */
    fun addDeviceCheck(report: VmDeviceCheck.Report): VmDiagnostics = apply {
        val problems = JSONArray().apply { report.problems.forEach { put(it) } }
        val warnings = JSONArray().apply { report.warnings.forEach { put(it) } }
        addJson(
            "device",
            JSONObject()
                .put("abi", report.abi)
                .put("abiOk", report.abiOk)
                .put("totalMemMb", report.totalMemMb)
                .put("availMemMb", report.availMemMb)
                .put("suggestedGuestMemMb", report.suggestedGuestMemMb)
                .put("freeStorageMb", report.freeStorageMb)
                .put("glesVersion", report.glesVersion)
                .put("problems", problems)
                .put("warnings", warnings)
                .toString()
        )
    }

    /** 加速探测报告 → 机器可读 + 人类可读两节。 */
    fun addBackendReport(report: BackendReport): VmDiagnostics = apply {
        addJson("backend", report.toJson())
        addText("backend_readable", report.toReportText())
    }

    /** 存储盘点 → 文本节。 */
    fun addStorageReport(report: VmStorageReport): VmDiagnostics =
        addText("storage", report.toReportText())

    /**
     * 打包。返回写好的 zip 文件；一个可打节的都没有时返回 null
     * （连 manifest 都写不出有价值的信息，调用方应提示「暂无可收集的诊断数据」）。
     *
     * zip 先写同目录的 `.tmp` 再原子 rename —— 分享目录被扫到半成品 zip
     * 比失败更糟（用户会把坏包发给开发者）。
     */
    fun build(target: File, generatedAt: Long = System.currentTimeMillis()): File? {
        if (sections.isEmpty()) return null
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, target.name + ".tmp")
        try {
            ZipOutputStream(BufferedOutputStream(FileOutputStream(tmp))).use { zip ->
                val manifest = JSONArray()
                sections.forEachIndexed { index, section ->
                    val entryName = "%02d_%s.%s".format(
                        Locale.US, index + 1, section.name, section.extension()
                    )
                    val outcome = writeSection(zip, entryName, section)
                    manifest.put(
                        JSONObject()
                            .put("entry", entryName)
                            .put("kind", section.kindName())
                            .put("status", outcome.status)
                            .put("bytes", outcome.bytes)
                    )
                }
                val manifestJson = JSONObject()
                    .put("format", MANIFEST_FORMAT)
                    .put("generatedAt", generatedAt)
                    .put("generatedAtText",
                        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(generatedAt)))
                    .put("sections", manifest)
                    .toString(2)
                zip.putNextEntry(ZipEntry("manifest.json"))
                zip.write(manifestJson.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
            if (!tmp.renameTo(target)) {
                tmp.copyTo(target, overwrite = true)
                tmp.delete()
            }
            return target
        } catch (t: Throwable) {
            tmp.delete()
            return null
        }
    }

    // ------------------------------------------------------------------
    // 内部实现
    // ------------------------------------------------------------------

    private sealed interface Section {
        val name: String

        fun extension(): String
        fun kindName(): String

        data class Text(
            override val name: String,
            val content: String,
            val ext: String
        ) : Section {
            override fun extension(): String = ext
            override fun kindName(): String = "text"
        }

        data class FileRef(
            override val name: String,
            val file: File,
            val required: Boolean,
            val tailBytes: Long
        ) : Section {
            override fun extension(): String =
                if (file.extension.isBlank()) "bin" else file.extension
            override fun kindName(): String = if (tailBytes >= 0) "file_tail" else "file"
        }
    }

    private data class Outcome(val status: String, val bytes: Long)

    private fun writeSection(zip: ZipOutputStream, entryName: String, section: Section): Outcome {
        return when (section) {
            is Section.Text -> {
                val bytes = section.content.toByteArray(Charsets.UTF_8)
                zip.putNextEntry(ZipEntry(entryName))
                zip.write(bytes)
                zip.closeEntry()
                Outcome("ok", bytes.size.toLong())
            }

            is Section.FileRef -> {
                val file = section.file
                if (!file.isFile) {
                    return Outcome(if (section.required) "missing_required" else "missing", 0L)
                }
                try {
                    RandomAccessFile(file, "r").use { raf ->
                        val start = if (section.tailBytes >= 0) {
                            (file.length() - section.tailBytes).coerceAtLeast(0L)
                        } else 0L
                        raf.seek(start)
                        // 从中段起读时丢掉第一个残行，避免半行误导解析。
                        val skipFirst = start > 0L && file.length() > 0
                        zip.putNextEntry(ZipEntry(entryName))
                        val buf = ByteArray(COPY_BUFFER)
                        var firstLine = skipFirst
                        var total = 0L
                        while (true) {
                            val n = raf.read(buf)
                            if (n <= 0) break
                            var off = 0
                            if (firstLine) {
                                val nl = buf.indexOf('\n'.code.toByte())
                                if (nl >= 0 && nl < n) {
                                    off = nl + 1
                                    firstLine = false
                                } else {
                                    continue   // 整个 buffer 都在残行里，跳过
                                }
                            }
                            zip.write(buf, off, n - off)
                            total += n - off
                        }
                        zip.closeEntry()
                        Outcome("ok", total)
                    }
                } catch (t: IOException) {
                    // 单节失败不拖垮整包：manifest 记 error，其余节继续。
                    try { zip.closeEntry() } catch (ignored: IOException) { /* 已关 */ }
                    Outcome("error", 0L)
                }
            }
        }
    }

    /** 节名只留安全字符，防 zip 路径穿越 / 乱码（日志名可能来自设备信息）。 */
    private fun requireValid(name: String): String {
        val cleaned = name.replace(UNSAFE_SECTION_CHARS, "_").trim('_')
        require(cleaned.isNotEmpty() && cleaned.length <= 48) { "非法节名：$name" }
        return cleaned
    }

    companion object {
        const val MANIFEST_FORMAT = "youlong-diagnostics/1"
        const val DEFAULT_TAIL_BYTES: Long = 256L * 1024

        private const val COPY_BUFFER = 64 * 1024
        private val UNSAFE_SECTION_CHARS = Regex("[^A-Za-z0-9_.-]")

        /** 起步：空构建器，随后按「环境 → 配置 → 日志」的排障阅读顺序添加。 */
        fun builder(): VmDiagnostics = VmDiagnostics()
    }
}
