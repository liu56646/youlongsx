package com.vm.core

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 事件日志级别。字母代号与 logcat 一致，便于肉眼快速分档。
 */
enum class VmLogLevel(val letter: String) {
    VERBOSE("V"),
    DEBUG("D"),
    INFO("I"),
    WARN("W"),
    ERROR("E")
}

/**
 * 宿主侧**实例事件日志**：记录「发生在宿主 App 里、与某个实例相关」的关键节点
 * （创建、启动、停止、镜像准备、快照存档……）。
 *
 * 与引擎写的 `logs/console.log`（QEMU 串口 + stderr）互补：
 *  - console.log 是**访客侧**的证据，回答「guest 里发生了什么」；
 *  - events.log 是**宿主侧**的证据，回答「宿主对这个实例做了什么、当时配置是什么」。
 *    排查「起不来 / 起得慢」时两份日志按时间轴对齐，比单看一边高效得多。
 *
 * 持久化布局（复用 [VmDiskStore] 的实例目录，无需新增顶层目录）：
 * ```
 * files/vms/vm_<id>/logs/events.log      当前段（活跃写入）
 * files/vms/vm_<id>/logs/events.log.1    上一个轮转段（次新）
 * ...
 * files/vms/vm_<id>/logs/events.log.<N>  最老的段，超过保留份数即删除
 * ```
 *
 * 轮转按**单段大小上限**触发（写前检查，避免半行跨段）：写入前若当前段
 * 已达 [MAX_SEGMENT_BYTES]，先把 `.N-1` 提升为 `.N`、……、`events.log` 提升为
 * `.1`，再新开一段。移动用 [File.renameTo]，同目录内原子，断电最多丢当前段尾部。
 *
 * 单行格式：`2026-10-31 12:00:00.123 I/Launcher 启动 vm=1 backend=TCG mem=3072MB`。
 * 多行消息的续行统一缩进 4 空格，tail 回读时仍算一行（以换行计数，不解析语义）。
 *
 * 线程模型：所有写操作走 [lock] 串行化 —— 宿主侧会从主线程与后台线程同时
 * 打点（下载进度、启动编排），FileOutputStream 追加写虽由内核保证不撕裂，
 * 但「检查大小 + 轮转 + 写入」必须是临界区，否则两个线程会各自触发一次轮转。
 *
 * 构造入参直接收 [vmsRoot]（而非 Context）：所有逻辑只依赖 java.io.File，
 * 本地 JVM 单测（VmLogStoreTest）不需要 Android 运行时即可覆盖轮转 / 清理分支。
 * 生产侧用 [from] 从 Context 构造。
 */
class VmLogStore(private val vmsRoot: File) {

    /** 实例事件日志目录（与引擎的 console.log 同住 `vm_<id>/logs/`）。 */
    fun logDir(vmId: Int): File = File(vmDir(vmId), "logs")

    /** 当前活跃段。 */
    fun activeFile(vmId: Int): File = File(logDir(vmId), ACTIVE_NAME)

    /** 记一条 INFO 级事件（最常见的打点，省掉调用方的样板）。 */
    fun record(vmId: Int, tag: String, message: String): Boolean =
        record(vmId, VmLogLevel.INFO, tag, message)

    /**
     * 追加一条事件。目录不存在会自动创建；写失败**静默吞掉**并返回 false ——
     * 日志永远不能反过来阻断业务（启动 / 删除实例不能因为磁盘满而失败）。
     *
     * @return 是否真正落盘
     */
    fun record(vmId: Int, level: VmLogLevel, tag: String, message: String): Boolean {
        val line = formatLine(now(), level, safeTag(tag), message)
        return try {
            synchronized(lock) {
                val file = activeFile(vmId)
                file.parentFile?.mkdirs()
                if (file.length() >= MAX_SEGMENT_BYTES) rotate(vmId)
                FileOutputStream(file, true).use { it.write(line.toByteArray(Charsets.UTF_8)) }
            }
            true
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 读取实例最近的 [maxLines] 行（按时间正序：最老 → 最新）。
     *
     * 轮转链按 `.N`（最老）→ `.1` → 当前段的顺序拼接，再截尾 —— 用户要的是
     * 「最后发生了什么」，而不是「每段各自最后几行」。
     *
     * 文件缺失 / 读失败返回空列表（例如实例从未打过点），不抛异常：
     * 调用方是诊断包导出与排障 UI，缺日志本身就是一个可展示的结论。
     */
    fun tail(vmId: Int, maxLines: Int): List<String> {
        if (maxLines <= 0) return emptyList()
        val chain = rotationChain(vmId).asReversed()   // 最老在前
        // 初始容量只是提示值（避免 maxLines 很大时预分配巨数组），装满自动扩容。
        val out = ArrayDeque<String>(minOf(maxLines, 1024))
        for (file in chain) {
            val lines = try {
                if (file.isFile) file.readLines() else emptyList()
            } catch (t: Throwable) {
                emptyList()
            }
            for (line in lines) {
                if (out.size == maxLines) out.removeFirst()
                out.addLast(line)
            }
        }
        return out.toList()
    }

    /**
     * 按保留天数清理**已轮转**的旧段（活跃段永不删）。
     *
     * 「按天」用文件的 lastModified 判定：轮转时的 renameTo 不改 mtime，
     * 语义即「这一段最后一次写入是什么时候」。
     *
     * @return 删除的文件数
     */
    fun pruneOlderThanDays(keepDays: Int): Int {
        if (keepDays < 0) return 0
        val cutoff = now() - keepDays * DAY_MILLIS
        var deleted = 0
        synchronized(lock) {
            vmsRoot.listFiles { f -> f.isDirectory && f.name.startsWith(VM_DIR_PREFIX) }
                ?.forEach { vmDir ->
                    logDir(vmDir).listFiles { f -> f.isFile && f.name.startsWith(ROTATION_PREFIX) }
                        ?.forEach { rotated ->
                            if (rotated.lastModified() < cutoff && rotated.delete()) deleted++
                        }
                }
        }
        return deleted
    }

    /** 实例事件日志的总占用（当前段 + 所有轮转段）。诊断 / 存储统计用。 */
    fun totalBytes(vmId: Int): Long =
        rotationChain(vmId).filter { it.isFile }.sumOf { it.length() }

    /**
     * 立即轮转（通常是测试或「导出前归档」场景调用）。
     * 当前段不存在时是空操作；返回是否真的发生了轮转。
     */
    fun rotateNow(vmId: Int): Boolean = synchronized(lock) {
        val file = activeFile(vmId)
        if (!file.isFile || file.length() == 0L) false else rotate(vmId)
    }

    // ------------------------------------------------------------------
    // 内部实现
    // ------------------------------------------------------------------

    private fun vmDir(vmId: Int): File = File(vmsRoot, "$VM_DIR_PREFIX$vmId")

    /** [pruneOlderThanDays] 从 vmsRoot 枚举实例目录时的辅助（目录名已带前缀）。 */
    private fun logDir(vmDir: File): File = File(vmDir, "logs")

    /**
     * 轮转：`events.log.(i-1)` → `events.log.i`，从大到小逐个搬，最后
     * `events.log` → `events.log.1`。超出 [KEEP_SEGMENTS] 的最老段直接删。
     * 必须在 [lock] 内调用。
     */
    private fun rotate(vmId: Int): Boolean {
        val dir = logDir(vmId)
        for (i in KEEP_SEGMENTS downTo 2) {
            val from = File(dir, "$ROTATION_PREFIX${i - 1}")
            val to = File(dir, "$ROTATION_PREFIX$i")
            if (from.isFile) {
                if (to.exists()) to.delete()
                if (!from.renameTo(to)) return false
            }
        }
        val active = File(dir, ACTIVE_NAME)
        val first = File(dir, "$ROTATION_PREFIX" + 1)
        if (first.exists()) first.delete()
        return active.renameTo(first)
    }

    /** 当前段 + 全部轮转段（当前段在首位）。文件可能不存在，调用方自行过滤。 */
    private fun rotationChain(vmId: Int): List<File> {
        val dir = logDir(vmId)
        return buildList {
            add(File(dir, ACTIVE_NAME))
            for (i in 1..KEEP_SEGMENTS) add(File(dir, "$ROTATION_PREFIX$i"))
        }
    }

    private fun safeTag(tag: String): String =
        tag.trim().replace(WHITESPACE, "_").ifEmpty { "App" }

    companion object {
        private const val VM_DIR_PREFIX = "vm_"
        private const val ACTIVE_NAME = "events.log"
        private const val ROTATION_PREFIX = "events.log."

        /** 单段大小上限：256KB。段太大 tail 回读会变慢，太小则轮转过于频繁。 */
        const val MAX_SEGMENT_BYTES: Long = 256L * 1024

        /** 轮转保留份数（不含当前段）。共 KEEP_SEGMENTS+1 段，约 1MB / 实例。 */
        const val KEEP_SEGMENTS: Int = 3

        private const val DAY_MILLIS = 24L * 60 * 60 * 1000
        private val WHITESPACE = Regex("\\s+")

        /** 事件日志写入用单一全局锁：实例数上限只有 4，竞争可忽略。 */
        private val lock = Any()

        /** 生产入口：与 [VmDiskStore] 共用同一个 `files/vms` 根目录。 */
        fun from(context: Context): VmLogStore =
            VmLogStore(File(context.applicationContext.filesDir, "vms"))

        internal fun formatLine(
            at: Long,
            level: VmLogLevel,
            tag: String,
            message: String
        ): String {
            val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date(at))
            val body = message.lineSequence().joinToString("\n    ") { it }
            return "$time ${level.letter}/$tag $body\n"
        }

        /** 可注入的时钟（测试里用来构造跨天 / 递增时间戳）。 */
        internal var now: () -> Long = { System.currentTimeMillis() }
    }
}
