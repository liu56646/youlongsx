package com.vm.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 快照存档（命名副本）管理。
 *
 * ## 背景：引擎侧的快照是什么
 * 引擎退出时把整机执行状态存到 `<dataDir>/snapshot.bin`（aemu 快照链路，
 * 实测保存 ~1.3s / 恢复 ~3.7s）；下次启动看到这个文件就 `-incoming` 快启，
 * 恢复失败会自动删档回退冷启动。也就是说引擎只维护**一份无名、滚动覆盖**
 * 的「最近状态」，用户没有「回到某个更早的存档点」的能力。
 *
 * ## 本类补上的能力
 * 在不改动引擎的前提下，用「**复制存档**」实现命名的存档点：
 *  - [save]：把当前 live 快照复制为 `snapshots/<id>/snapshot.bin` 并登记元数据；
 *  - [restore]：把某个存档复制回 live 位（原 live 先备份，可反悔）；
 *  - [list] / [delete] / [prune] / [reconcile]：目录、保留策略与孤儿对账。
 *
 * ## 明确的能力边界（诚实声明，避免误期待）
 * 快照只包含**执行状态**（RAM / 设备状态），不含数据盘内容。若存档后访客
 * 又写入了 userdata，恢复执行状态不会回滚这些写入 —— 与「游戏存档 ≠ 磁盘
 * 时光机」同理。真要做磁盘级回滚需要同时复制 4GB 数据盘，成本完全不同。
 *
 * ## 一致性与安全
 *  - 元数据先写临时文件再原子 rename（半途断电不会留下写了一半的 index）；
 *  - 任何目录操作都只动 `snapshots/` 子树与 `snapshot.bin`，**绝不**碰
 *    userdata / metadata / product 等业务盘；
 *  - 运行中的实例禁止 save / restore（复制执行状态时 QEMU 正在改写它，
 *    得到的必然是自相矛盾的流）—— 是否运行由构造时注入的 [isVmRunning]
 *    判定，宿主 App 传 [VmRuntime] 的实现，测试传恒假。
 */
class VmSnapshotStore(
    private val vmsRoot: File,
    private val isVmRunning: (vmId: Int) -> Boolean = { false }
) {

    /** 存档根目录：`vm_<id>/snapshots/`。 */
    fun snapshotsDir(vmId: Int): File = File(vmDir(vmId), "snapshots")

    /** 元数据索引：`vm_<id>/snapshots/index.json`。 */
    fun indexFile(vmId: Int): File = File(snapshotsDir(vmId), "index.json")

    /** live 快照（引擎维护的那份）。 */
    fun liveSnapshotFile(vmId: Int): File = File(vmDir(vmId), "snapshot.bin")

    /**
     * live 快照的当前状态。不存在返回 null。
     * 排障时「文件在不在 / 多大 / 什么时候存的」是最常问的三个问题。
     */
    fun liveSnapshot(vmId: Int): LiveSnapshotInfo? {
        val file = liveSnapshotFile(vmId)
        if (!file.isFile || file.length() == 0L) return null
        return LiveSnapshotInfo(sizeBytes = file.length(), savedAt = file.lastModified())
    }

    /**
     * 丢弃 live 快照，下次启动强制冷启动。
     *
     * 典型场景：快启后访客行为异常，怀疑快照本身坏了 —— 引擎的自动回退只在
     * 「恢复明确失败」时触发，症状是「能起来但不正常」时就得手动丢弃。
     *
     * @return live 快照本就不存在时返回 false（无事发生），删掉返回 true。
     */
    fun discardLive(vmId: Int): Boolean {
        if (isVmRunning(vmId)) return false
        val file = liveSnapshotFile(vmId)
        return file.isFile && file.delete()
    }

    /**
     * 把当前 live 快照存为命名存档。
     *
     * @param name 展示名；与已有存档重名时自动追加「 (2)」「 (3)」……
     * @return 拒绝原因或新存档。见 [SaveResult] 各分支。
     */
    fun save(vmId: Int, name: String, note: String = ""): SaveResult {
        if (isVmRunning(vmId)) return SaveResult.VmRunning
        val live = liveSnapshotFile(vmId)
        if (!live.isFile || live.length() == 0L) return SaveResult.NoLiveSnapshot

        val dir = snapshotsDir(vmId)
        if (!dir.isDirectory && !dir.mkdirs()) return SaveResult.IoFailed

        return synchronized(lock) {
            val id = newSnapshotId(dir)
            val payloadDir = File(dir, id)
            if (!payloadDir.mkdir()) return@synchronized SaveResult.IoFailed
            val payload = File(payloadDir, PAYLOAD_NAME)
            val copied = try {
                live.copyTo(payload, overwrite = true)
            } catch (t: Throwable) {
                payloadDir.deleteRecursively()
                return@synchronized SaveResult.IoFailed
            }
            val entry = VmSnapshot(
                id = id,
                name = dedupName(vmId, name.trim().ifEmpty { DEFAULT_NAME }),
                createdAt = now(),
                sizeBytes = copied.length(),
                note = note
            )
            writeIndex(vmId, readIndex(vmId) + entry)
            SaveResult.Saved(entry)
        }
    }

    /**
     * 把某个存档恢复到 live 位。
     *
     * 先把现有 live 快照备份为 `snapshot.bin.bak`（只保留最近一份）：
     * 恢复后访客状态不对时，还能用 [restore] 之外的手段找回来，也避免
     * 「恢复到一半断电，原快照已没了」的最坏情况。
     *
     * @return 见 [RestoreResult] 各分支。
     */
    fun restore(vmId: Int, snapshotId: String): RestoreResult {
        if (isVmRunning(vmId)) return RestoreResult.VmRunning
        val entry = synchronized(lock) { readIndex(vmId) }.firstOrNull { it.id == snapshotId }
            ?: return RestoreResult.NotFound
        val payload = File(File(snapshotsDir(vmId), entry.id), PAYLOAD_NAME)
        if (!payload.isFile || payload.length() == 0L) return RestoreResult.PayloadMissing

        return try {
            val live = liveSnapshotFile(vmId)
            if (live.isFile) {
                val backup = File(live.parentFile, BACKUP_NAME)
                if (backup.exists()) backup.delete()
                live.copyTo(backup, overwrite = true)
            }
            payload.copyTo(live, overwrite = true)
            RestoreResult.Restored(entry)
        } catch (t: Throwable) {
            RestoreResult.IoFailed
        }
    }

    /**
     * 列出实例的全部存档（新 → 旧），并合并「元数据在、载荷还在不在」的实时事实。
     * UI 据此能把已被 SD 卡清理等外部因素删掉载荷的存档标灰。
     */
    fun list(vmId: Int): List<VmSnapshot> = synchronized(lock) { readIndex(vmId) }
        .map { it.copy(payloadPresent = payloadOf(vmId, it.id).isFile) }
        .sortedByDescending { it.createdAt }

    /** 删除单个存档（元数据 + 载荷目录）。不存在返回 false。 */
    fun delete(vmId: Int, snapshotId: String): Boolean = synchronized(lock) {
        val items = readIndex(vmId)
        val target = items.firstOrNull { it.id == snapshotId } ?: return false
        File(snapshotsDir(vmId), target.id).deleteRecursively()
        writeIndex(vmId, items - target)
        true
    }

    /**
     * 只保留最近 [keepCount] 份存档（按 createdAt 新 → 旧）。
     * 供「一键瘦身」或存档数超限时调用；返回被删掉的份数。
     */
    fun prune(vmId: Int, keepCount: Int): Int {
        if (keepCount < 0) return 0
        return synchronized(lock) {
            val ordered = readIndex(vmId).sortedByDescending { it.createdAt }
            val victims = ordered.drop(keepCount)
            victims.forEach { File(snapshotsDir(vmId), it.id).deleteRecursively() }
            if (victims.isNotEmpty()) writeIndex(vmId, ordered.take(keepCount))
            victims.size
        }
    }

    /**
     * 对账：清掉「元数据在、载荷已丢失」的条目（保留载荷、只删元数据的情况不存在
     * —— 载荷目录本身就归元数据管辖）。外部清理工具 / 用户手动删文件后调用。
     *
     * @return 被清掉的条目 id。
     */
    fun reconcile(vmId: Int): List<String> = synchronized(lock) {
        val items = readIndex(vmId)
        val (present, missing) = items.partition { payloadOf(vmId, it.id).isFile }
        if (missing.isNotEmpty()) writeIndex(vmId, present)
        missing.map { it.id }
    }

    /** 实例存档的总占用（字节）。存储统计用。 */
    fun totalBytes(vmId: Int): Long = list(vmId)
        .filter { it.payloadPresent }
        .sumOf { it.sizeBytes }

    // ------------------------------------------------------------------
    // 结果类型
    // ------------------------------------------------------------------

    /** [save] 的结果。 */
    sealed interface SaveResult {
        /** 成功，带回新存档。 */
        data class Saved(val snapshot: VmSnapshot) : SaveResult

        /** 实例在运行，复制执行状态必然自相矛盾，拒绝。 */
        data object VmRunning : SaveResult

        /** live 快照不存在（从未保存过 / 已被丢弃 / 已被引擎回退删除）。 */
        data object NoLiveSnapshot : SaveResult

        /** 复制或建目录失败（磁盘满 / 权限）。 */
        data object IoFailed : SaveResult
    }

    /** [restore] 的结果。 */
    sealed interface RestoreResult {
        /** 成功，带回恢复的存档。 */
        data class Restored(val snapshot: VmSnapshot) : RestoreResult

        /** 实例在运行。 */
        data object VmRunning : RestoreResult

        /** 没有这个 id 的存档（可能已被并发删除）。 */
        data object NotFound : RestoreResult

        /** 元数据在但载荷文件没了 —— 正是 [reconcile] 要清理的状态。 */
        data object PayloadMissing : RestoreResult

        /** 复制失败。 */
        data object IoFailed : RestoreResult
    }

    // ------------------------------------------------------------------
    // 内部实现
    // ------------------------------------------------------------------

    private fun vmDir(vmId: Int): File = File(vmsRoot, "vm_$vmId")

    private fun payloadOf(vmId: Int, id: String): File =
        File(File(snapshotsDir(vmId), id), PAYLOAD_NAME)

    /** `snap_20261031_120001`（秒级 + 序号防同秒碰撞）。 */
    private fun newSnapshotId(existingDir: File): String {
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(now()))
        var candidate = "snap_$stamp"
        var suffix = 1
        while (File(existingDir, candidate).exists()) {
            candidate = "snap_${stamp}_$suffix"
            suffix++
        }
        return candidate
    }

    private fun dedupName(vmId: Int, name: String): String {
        val taken = synchronized(lock) { readIndex(vmId) }.map { it.name }.toSet()
        if (name !in taken) return name
        var i = 2
        while ("$name ($i)" in taken) i++
        return "$name ($i)"
    }

    private fun readIndex(vmId: Int): List<VmSnapshot> {
        val file = indexFile(vmId)
        if (!file.isFile) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            List(arr.length()) { i ->
                val o = arr.getJSONObject(i)
                VmSnapshot(
                    id = o.optString("id"),
                    name = o.optString("name", DEFAULT_NAME),
                    createdAt = o.optLong("createdAt", 0L),
                    sizeBytes = o.optLong("sizeBytes", 0L),
                    note = o.optString("note")
                )
            }
        } catch (t: Throwable) {
            // index 损坏的兜底：当作没有存档。载荷目录还在，损失的是名字与时间，
            // 比「整个功能不可用」好；reconcile 也不会误删载荷（它只认元数据）。
            emptyList()
        }
    }

    /** 临时文件 + 原子 rename，避免半写的 index。必须在 [lock] 内调用。 */
    private fun writeIndex(vmId: Int, items: List<VmSnapshot>) {
        val file = indexFile(vmId)
        file.parentFile?.mkdirs()
        val arr = JSONArray()
        items.forEach { s ->
            arr.put(
                JSONObject()
                    .put("id", s.id)
                    .put("name", s.name)
                    .put("createdAt", s.createdAt)
                    .put("sizeBytes", s.sizeBytes)
                    .put("note", s.note)
            )
        }
        val tmp = File(file.parentFile, file.name + ".tmp")
        try {
            tmp.writeText(arr.toString())
            if (!tmp.renameTo(file)) {
                // 跨文件系统 rename 会失败（tmp 与目标同目录，正常不会走到）。
                tmp.copyTo(file, overwrite = true)
                tmp.delete()
            }
        } catch (t: Throwable) {
            tmp.delete()
        }
    }

    companion object {
        private const val PAYLOAD_NAME = "snapshot.bin"
        private const val BACKUP_NAME = "snapshot.bin.bak"
        private const val DEFAULT_NAME = "未命名存档"

        /** 单实例存档数上限（prune 的默认档位；UI 瘦身按钮用）。 */
        const val DEFAULT_KEEP_COUNT = 8

        /** 实例级锁即可：不同实例的并发操作互不影响。 */
        private val lock = Any()

        /** 生产入口：宿主 App 注入 [VmRuntime] 的运行判定。 */
        fun from(context: Context, isVmRunning: (vmId: Int) -> Boolean): VmSnapshotStore =
            VmSnapshotStore(
                vmsRoot = File(context.applicationContext.filesDir, "vms"),
                isVmRunning = isVmRunning
            )

        internal var now: () -> Long = { System.currentTimeMillis() }
    }
}

/** live 快照（引擎维护的最近执行状态）的观测信息。 */
data class LiveSnapshotInfo(
    val sizeBytes: Long,
    val savedAt: Long
)

/**
 * 一份命名存档的元数据。
 *
 * @param payloadPresent 载荷文件当前是否还在（[VmSnapshotStore.list] 时实时探测；
 *   落盘的 index.json 不含该字段）。false 表示元数据成了孤儿，等待
 *   [VmSnapshotStore.reconcile] 清理。
 */
data class VmSnapshot(
    val id: String,
    val name: String,
    val createdAt: Long,
    val sizeBytes: Long,
    val note: String = "",
    val payloadPresent: Boolean = true
)
