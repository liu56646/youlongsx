package com.vm.core

import android.content.Context
import java.io.File

/** 存储条目的业务归类，决定它是否可回收、以及为什么。 */
enum class VmStorageKind(val recyclable: Boolean, val label: String) {
    /** 镜像目录（基础镜像，多实例共享只读）。 */
    IMAGE(false, "访客镜像"),

    /** 实例业务盘：可写 userdata / metadata / encryptionkey / config。 */
    INSTANCE_DATA(false, "实例数据盘"),

    /** 实例设备身份盘（选了机型才有的 product/system 副本）。 */
    INSTANCE_IDENTITY(false, "设备身份副本"),

    /** 实例快照存档（snapshots/ 子树）。 */
    INSTANCE_SNAPSHOT(false, "快照存档"),

    /** 实例 live 快照与 vmstate 盘。 */
    INSTANCE_VMSTATE(false, "快照状态"),

    /** 实例日志（console.log / events.log 及轮转段）。不可在此一键清理：有专用路径（[VmLogStore.pruneOlderThanDays]），避免误删排障证据。 */
    INSTANCE_LOGS(false, "实例日志"),

    /** 下载到一半的镜像包残段（cacheDir 里的 `<tag>.zip.part`）。 */
    CACHE_PARTIAL(true, "下载残段"),

    /** 导入中断留下的暂存目录（`images/.import-*` / `images/.<tag>-import`）。 */
    STAGING(true, "导入暂存"),

    /** 索引里不存在的实例目录 —— index 丢失或半途创建失败。 */
    ORPHAN_INSTANCE(true, "孤儿实例目录"),

    /** 无任何实例与目录引用的镜像目录。 */
    ORPHAN_IMAGE(true, "孤儿镜像目录")
}

/** 单个可盘点的存储条目（目录或文件聚合成一项）。 */
data class VmStorageEntry(
    val kind: VmStorageKind,
    /** 展示用路径（相对各自根目录），比绝对路径短且可读。 */
    val displayPath: String,
    val bytes: Long,
    /** 为什么可回收 / 为什么不能动 —— 清理确认对话框直接展示。 */
    val reason: String
)

/** 一次全盘扫描的结果。 */
data class VmStorageReport(
    val entries: List<VmStorageEntry>
) {
    val imagesBytes: Long get() = sumOf(VmStorageKind.IMAGE)
    val instancesBytes: Long
        get() = entries.filter {
            it.kind == VmStorageKind.INSTANCE_DATA ||
                it.kind == VmStorageKind.INSTANCE_IDENTITY ||
                it.kind == VmStorageKind.INSTANCE_SNAPSHOT ||
                it.kind == VmStorageKind.INSTANCE_VMSTATE ||
                it.kind == VmStorageKind.INSTANCE_LOGS
        }.sumOf { it.bytes }

    /** 可直接安全回收的字节数（残段 + 暂存，无需确认即默认勾选）。 */
    val safeGarbageBytes: Long
        get() = entries.filter { it.kind == VmStorageKind.CACHE_PARTIAL || it.kind == VmStorageKind.STAGING }
            .sumOf { it.bytes }

    /** 需要用户额外确认才可回收的字节数（孤儿目录）。 */
    val orphanBytes: Long
        get() = entries.filter {
            it.kind == VmStorageKind.ORPHAN_INSTANCE || it.kind == VmStorageKind.ORPHAN_IMAGE
        }.sumOf { it.bytes }

    private fun sumOf(kind: VmStorageKind): Long =
        entries.filter { it.kind == kind }.sumOf { it.bytes }

    /**
     * 人类可读盘点文本（清理确认对话框 / 诊断包共用）。
     * 只列非零项，避免一屏全是「0 B」。
     */
    fun toReportText(): String = buildString {
        appendLine("镜像：${VmStorageStats.humanBytes(imagesBytes)}")
        appendLine("实例：${VmStorageStats.humanBytes(instancesBytes)}")
        appendLine("可清理（残段/暂存）：${VmStorageStats.humanBytes(safeGarbageBytes)}")
        appendLine("可清理（孤儿目录，需确认）：${VmStorageStats.humanBytes(orphanBytes)}")
        val garbage = entries.filter { it.kind.recyclable && it.bytes > 0 }
        if (garbage.isNotEmpty()) {
            appendLine()
            garbage.sortedByDescending { it.bytes }.forEach {
                appendLine("· [${it.kind.label}] ${it.displayPath}（${VmStorageStats.humanBytes(it.bytes)}）")
            }
        }
    }
}

/** 一次清理的结果。 */
data class VmCleanResult(
    val dryRun: Boolean,
    val freedBytes: Long,
    val deletedCount: Int,
    val failedCount: Int
) {
    val allSucceeded: Boolean get() = failedCount == 0
}

/**
 * 存储盘点与清理。
 *
 * ## 为什么需要它
 * 一套镜像 ~500MB、一个实例 4GB 起步、快照存档几百 MB 一份 —— 这类应用
 * 的差评榜第一永远是「存储去哪了」。本类把 `files/images`、`files/vms`、
 * `cacheDir` 三棵树统一盘点成带业务语义的条目（哪是镜像、哪是实例数据、
 * 哪是垃圾），并区分两档可回收物：
 *
 *  - **残段 / 暂存**（下载中断、导入失败）：目录里没有任何用户数据，
 *    默认即可安全清理；
 *  - **孤儿目录**（索引丢失的实例目录 / 无引用的镜像目录）：可能装着
 *    用户数据（index.json 损坏后实例还在就是这种形态），必须用户逐项确认。
 *
 * ## 安全边界
 * [clean] 只删 [scan] 产出的条目、且只删 [VmStorageKind.recyclable] 的，
 * 永远不碰 IMAGE / INSTANCE_* —— 调用方传错参数也不会误删业务数据。
 * 删除动作本身按条目统计成败，单个失败不中断整批。
 *
 * 构造直接收三个根目录（而非 Context）：逻辑纯 java.io，可本地 JVM 单测。
 * 生产侧用 [from]。
 */
class VmStorageStats(
    private val imagesRoot: File,
    private val vmsRoot: File,
    private val cacheDir: File
) {

    /**
     * 全盘扫描。
     *
     * @param knownVmIds 索引在册的实例号（[VmRepository.list] 的 id 集合）
     * @param knownImageTags 在册镜像 tag（内置目录 + 已导入 + 仍有实例引用的历史 tag）
     */
    fun scan(knownVmIds: Set<Int>, knownImageTags: Set<String>): VmStorageReport {
        val entries = mutableListOf<VmStorageEntry>()

        // ---- 镜像树 ----
        imagesRoot.listFiles()?.filter { it.isDirectory }?.forEach { dir ->
            when {
                dir.name.startsWith(".") -> entries += entry(
                    VmStorageKind.STAGING, dir,
                    "images/${dir.name}", "导入中断的暂存目录，内容不完整"
                )

                dir.name !in knownImageTags -> entries += entry(
                    VmStorageKind.ORPHAN_IMAGE, dir,
                    "images/${dir.name}", "没有任何实例或目录引用这份镜像"
                )

                else -> entries += entry(
                    VmStorageKind.IMAGE, dir, "images/${dir.name}", "多实例共享的基础镜像"
                )
            }
        }

        // ---- 实例树 ----
        vmsRoot.listFiles()?.filter { it.isDirectory }?.forEach { dir ->
            val vmId = dir.name.removePrefix("vm_").toIntOrNull()
            when {
                vmId == null || vmId !in knownVmIds -> entries += entry(
                    VmStorageKind.ORPHAN_INSTANCE, dir,
                    "vms/${dir.name}", "实例索引里没有这个号（可能创建中断或 index 损坏）"
                )

                else -> entries += scanInstance(vmId, dir)
            }
        }

        // ---- 缓存树：只认下载残段，其余缓存文件归系统 / 其他模块管 ----
        cacheDir.listFiles()?.filter { it.isFile && it.name.endsWith(PART_SUFFIX) }?.forEach {
            entries += entry(
                VmStorageKind.CACHE_PARTIAL, it,
                "cache/${it.name}", "镜像下载中断的残段，可续传也可直接删"
            )
        }

        return VmStorageReport(entries.sortedByDescending { it.bytes })
    }

    /**
     * 执行清理。
     *
     * @param includeOrphans 是否连孤儿目录一起删（默认只清残段 + 暂存）。
     *        孤儿目录可能装着用户数据，UI 必须单独确认后才置 true。
     * @param dryRun 只统计不落刀；确认对话框先用 dryRun 算出「能腾出多少」。
     */
    fun clean(report: VmStorageReport, includeOrphans: Boolean = false, dryRun: Boolean = false): VmCleanResult {
        val targets = report.entries.filter {
            when (it.kind) {
                VmStorageKind.CACHE_PARTIAL, VmStorageKind.STAGING -> true
                else -> includeOrphans && (it.kind == VmStorageKind.ORPHAN_INSTANCE ||
                    it.kind == VmStorageKind.ORPHAN_IMAGE)
            }
        }
        var freed = 0L
        var deleted = 0
        var failed = 0
        for (item in targets) {
            val file = resolve(item) ?: continue
            if (dryRun) {
                freed += item.bytes
                deleted++
                continue
            }
            val ok = if (file.isDirectory) file.deleteRecursively() else file.delete()
            if (ok) {
                freed += item.bytes
                deleted++
            } else {
                failed++
            }
        }
        return VmCleanResult(dryRun = dryRun, freedBytes = freed, deletedCount = deleted, failedCount = failed)
    }

    // ------------------------------------------------------------------
    // 内部实现
    // ------------------------------------------------------------------

    /** 把实例目录按业务语义拆成多条目（数据盘 / 身份 / 快照 / 日志）。 */
    private fun scanInstance(vmId: Int, dir: File): List<VmStorageEntry> {
        val out = mutableListOf<VmStorageEntry>()
        var dataBytes = 0L
        var identityBytes = 0L
        var vmstateBytes = 0L

        dir.listFiles()?.forEach { f ->
            when (f.name) {
                "userdata.img", "metadata.img", "encryptionkey.img", "config.json" ->
                    dataBytes += sizeOf(f)

                "product.img", "system.img" -> identityBytes += sizeOf(f)

                "vmstate.qcow2", "snapshot.bin", "snapshot.bin.bak" -> vmstateBytes += sizeOf(f)

                "snapshots" -> out += entry(
                    VmStorageKind.INSTANCE_SNAPSHOT, f,
                    "vms/vm_$vmId/snapshots", "命名快照存档，可按份删除（见快照管理）"
                )

                "logs" -> out += entry(
                    VmStorageKind.INSTANCE_LOGS, f,
                    "vms/vm_$vmId/logs", "排障日志；按天清理走事件日志的 prune，不进一键清理"
                )
            }
        }
        out += entry(
            VmStorageKind.INSTANCE_DATA, null, "vms/vm_$vmId", "实例数据盘（访客的 /data 等）",
            overrideBytes = dataBytes
        )
        if (identityBytes > 0) out += entry(
            VmStorageKind.INSTANCE_IDENTITY, null, "vms/vm_$vmId", "设备身份改写副本（product/system）",
            overrideBytes = identityBytes
        )
        if (vmstateBytes > 0) out += entry(
            VmStorageKind.INSTANCE_VMSTATE, null, "vms/vm_$vmId", "live 快照与 vmstate 盘",
            overrideBytes = vmstateBytes
        )
        return out
    }

    private fun entry(
        kind: VmStorageKind,
        file: File?,
        displayPath: String,
        reason: String,
        overrideBytes: Long = -1L
    ): VmStorageEntry = VmStorageEntry(
        kind = kind,
        displayPath = displayPath,
        bytes = if (overrideBytes >= 0) overrideBytes else sizeOf(file ?: File("/nonexistent")),
        reason = reason
    )

    private fun sizeOf(file: File): Long {
        if (!file.exists()) return 0L
        return if (file.isDirectory) {
            file.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
        } else {
            file.length()
        }
    }

    /** clean 时按 displayPath 找回真实文件。两棵树的相对路径命名规则与 [scan] 对齐。 */
    private fun resolve(item: VmStorageEntry): File? = when (item.kind) {
        VmStorageKind.CACHE_PARTIAL -> File(cacheDir, item.displayPath.removePrefix("cache/"))
        VmStorageKind.STAGING, VmStorageKind.IMAGE, VmStorageKind.ORPHAN_IMAGE ->
            File(imagesRoot, item.displayPath.removePrefix("images/"))

        else -> File(vmsRoot, item.displayPath.removePrefix("vms/").substringBefore('/'))
    }

    companion object {
        private const val PART_SUFFIX = ".zip.part"

        /** 生产入口：三个根目录与 [VmImageProvider] / [VmDiskStore] 一致。 */
        fun from(context: Context): VmStorageStats = VmStorageStats(
            imagesRoot = File(context.applicationContext.filesDir, "images"),
            vmsRoot = File(context.applicationContext.filesDir, "vms"),
            cacheDir = context.applicationContext.cacheDir
        )

        /**
         * 人类可读字节数（中文语境，1024 进制）。
         * Android 有 Formatter.formatFileSize，但那是 Android API —— 本类要保持
         * 纯 JVM 可测，自带一份实现，语义与其对齐（1 KB = 1024 B）。
         */
        fun humanBytes(bytes: Long): String {
            if (bytes < 1024) return "$bytes B"
            var value = bytes.toDouble()
            var unit = -1
            val units = arrayOf("KB", "MB", "GB", "TB")
            while (value >= 1024 && unit < units.size - 1) {
                value /= 1024
                unit++
            }
            return String.format(java.util.Locale.US, "%.1f %s", value, units[unit])
        }
    }
}
