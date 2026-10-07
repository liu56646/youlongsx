package com.vm.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 实例元数据仓库，落盘为 `files/vms/index.json`。
 * 运行时状态（是否在跑）不在此持久化。
 */
class VmRepository(context: Context) {

    private val appContext = context.applicationContext
    private val disk = VmDiskStore(appContext)
    private val images = VmImageProvider(appContext)
    private val indexFile = File(appContext.filesDir, "vms/index.json")
    private val lock = Any()

    fun list(): List<VmInfo> = synchronized(lock) { readIndex() }

    fun get(vmId: Int): VmInfo? = list().firstOrNull { it.vmId == vmId }

    /** 分配一个空闲实例号（1..[VmConstants.MAX_INSTANCES]），无空闲则返回 null。 */
    fun create(name: String? = null, imageTag: String = VmConstants.DEFAULT_IMAGE_TAG): VmInfo? =
        synchronized(lock) {
            val items = readIndex().toMutableList()
            val used = items.map { it.vmId }.toSet()
            val id = (1..VmConstants.MAX_INSTANCES).firstOrNull { it !in used } ?: return null

            val info = VmInfo(
                vmId = id,
                name = name?.takeIf { it.isNotBlank() } ?: "虚拟机 $id",
                createdAt = System.currentTimeMillis(),
                imageTag = imageTag
            )
            items += info
            writeIndex(items)
            // 数据盘必须以镜像里的 userdata.img 为模板（已格式化的空分区），
            // 否则访客首启会卡在挂载 /data。
            disk.ensureUserData(id, images.userDataTemplate(imageTag))
            info
        }

    fun rename(vmId: Int, name: String): Boolean = synchronized(lock) {
        val items = readIndex().toMutableList()
        val idx = items.indexOfFirst { it.vmId == vmId }
        if (idx < 0) return false
        items[idx] = items[idx].copy(name = name)
        writeIndex(items)
        true
    }

    fun delete(vmId: Int): Boolean = synchronized(lock) {
        val items = readIndex().toMutableList()
        val removed = items.removeAll { it.vmId == vmId }
        if (removed) {
            writeIndex(items)
            disk.deleteVm(vmId)
        }
        removed
    }

    private fun readIndex(): MutableList<VmInfo> {
        if (!indexFile.exists()) return mutableListOf()
        return runCatching {
            val arr = JSONArray(indexFile.readText())
            MutableList(arr.length()) { i ->
                val o = arr.getJSONObject(i)
                VmInfo(
                    vmId = o.getInt("vmId"),
                    name = o.optString("name", "虚拟机 ${o.getInt("vmId")}"),
                    createdAt = o.optLong("createdAt", 0L),
                    imageTag = o.optString("imageTag", VmConstants.DEFAULT_IMAGE_TAG)
                )
            }
        }.getOrElse { mutableListOf() }
    }

    private fun writeIndex(items: List<VmInfo>) {
        indexFile.parentFile?.mkdirs()
        val arr = JSONArray()
        items.forEach { info ->
            arr.put(
                JSONObject()
                    .put("vmId", info.vmId)
                    .put("name", info.name)
                    .put("createdAt", info.createdAt)
                    .put("imageTag", info.imageTag)
            )
        }
        indexFile.writeText(arr.toString())
    }
}
