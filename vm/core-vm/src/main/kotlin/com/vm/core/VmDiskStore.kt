package com.vm.core

import android.content.Context
import java.io.File
import java.io.RandomAccessFile

/**
 * 实例磁盘管理。
 *
 * 目录布局：
 * ```
 * files/vms/vm_<id>/userdata.img    可写数据盘（由镜像模板拷贝并扩容而来）
 * files/vms/vm_<id>/config.json     实例配置快照
 * files/vms/vm_<id>/logs/           引擎日志
 * ```
 * 基础镜像为只读共享，见 [VmImageProvider]。
 */
class VmDiskStore(private val context: Context) {

    fun vmsRoot(): File = File(context.filesDir, "vms").apply { mkdirs() }

    fun vmDir(vmId: Int): File = File(vmsRoot(), "vm_$vmId").apply { mkdirs() }

    /** 可写数据盘。文件名是 .img：内容是 raw 分区镜像，不是 qcow2。 */
    fun userDataImage(vmId: Int): File = File(vmDir(vmId), "userdata.img")

    fun configFile(vmId: Int): File = File(vmDir(vmId), "config.json")

    fun logDir(vmId: Int): File = File(vmDir(vmId), "logs").apply { mkdirs() }

    /**
     * 创建实例的可写数据盘。
     *
     * Android 的 /data 分区必须是**已格式化**的 ext4/f2fs，直接给一个全零文件
     * 访客第一关就卡在挂载上。所以这里以镜像包里的 `userdata.img`
     * （SDK 提供的已格式化空镜像）为模板拷贝一份，再扩容到目标大小。
     *
     * @param template    镜像目录里的 userdata.img；为 null 时退化为全零文件并告警
     * @param sizeBytes   目标大小（稀疏扩容，不实际占盘）
     */
    fun ensureUserData(
        vmId: Int,
        template: File? = null,
        sizeBytes: Long = DEFAULT_USERDATA_SIZE
    ): File {
        val file = userDataImage(vmId)
        if (file.exists()) {
            return file
        }

        if (template != null && template.isFile && template.length() > 0) {
            template.copyTo(file, overwrite = true)
        }

        // 扩容：ext4 在访客首启时会按块设备大小自动 resize（fstab 里的 resize 标志）
        RandomAccessFile(file, "rw").use { it.setLength(sizeBytes) }
        return file
    }

    fun deleteVm(vmId: Int): Boolean = vmDir(vmId).deleteRecursively()

    /** 实例目录已用空间（字节）。 */
    fun usedBytes(vmId: Int): Long {
        val dir = vmDir(vmId)
        if (!dir.exists()) return 0L
        return dir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
    }

    companion object {
        /** 数据盘大小，4 GiB（稀疏文件，不会立刻占满磁盘）。 */
        const val DEFAULT_USERDATA_SIZE: Long = 4L * 1024 * 1024 * 1024
    }
}
