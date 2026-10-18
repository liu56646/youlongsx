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

    /**
     * 实例自己的 product.img（设备身份改写后的副本，可选）。
     *
     * 只有实例选择了非默认机型时才会存在；不存在时引擎回落到 base 镜像里
     * 那份共享的 product.img（见 vm_engine.c）。
     */
    fun productImage(vmId: Int): File = File(vmDir(vmId), "product.img")

    /** 实例自己的 system.img（设备身份改写后的副本，可选）。 */
    fun systemImage(vmId: Int): File = File(vmDir(vmId), "system.img")

    /** metadata 盘（Android 11+ 的 FBE 元数据分区）。 */
    fun metadataImage(vmId: Int): File = File(vmDir(vmId), "metadata.img")

    /** 快照用的 vmstate 盘（qcow2）。见 [ensureVmstate]。 */
    fun vmstateImage(vmId: Int): File = File(vmDir(vmId), "vmstate.qcow2")

    /** Android 9 FDE 的加密 footer/key 盘（每个实例一份，绝不能跨实例共享）。 */
    fun encryptionKeyImage(vmId: Int): File = File(vmDir(vmId), "encryptionkey.img")

    /**
     * 确保实例有独立的 encryptionkey 盘。
     *
     * p11/p13/p71 没有这个模板，返回 null 即可（它们的 fstab 不需要）。
     * p9 的 vendor fstab 是 `forceencrypt=/dev/block/vdd`，首次启动会把
     * crypto footer 写进这块盘，因此必须每个实例一份。
     */
    fun ensureEncryptionKey(vmId: Int, template: File?): File? {
        val dst = encryptionKeyImage(vmId)
        if (dst.exists()) return dst
        if (template == null || !template.isFile || template.length() == 0L) return null
        template.copyTo(dst, overwrite = true)
        return dst
    }

    /**
     * 确保实例有快照用的 **qcow2** vmstate 盘。
     *
     * 为什么需要：QEMU 的 `savevm` 要一块"支持快照"的块设备
     * （`bdrv_all_find_vmstate_bs()` 只认 qcow2/qcow 这类驱动），而我们的
     * system/vendor/userdata 全是 raw（官方模拟器是靠 drive-share 把镜像转成
     * qcow2 overlay 才满足这个前提）。QEMU 又**不会**自己创建 qcow2 文件
     * （实测：文件不存在时直接报 "Could not open ... No such file or directory"
     * 并退出），所以随 APK 带一个空的 512MB 模板（`assets/vmstate.qcow2`，
     * 实际只有 ~190KB），这里复制一份给实例用。
     *
     * @return 是否就绪；false 表示模板缺失/复制失败（此时只是快照不可用，
     *         冷启动路径不受影响）
     */
    fun ensureVmstate(vmId: Int): Boolean {
        val dst = vmstateImage(vmId)
        if (dst.exists() && dst.length() > 0L) {
            return true
        }
        return runCatching {
            context.assets.open("vmstate.qcow2").use { input ->
                dst.outputStream().use { output -> input.copyTo(output) }
            }
            true
        }.getOrDefault(false)
    }

    /**
     * 确保实例有 metadata 盘。
     *
     * **必须存在**：引擎只在文件存在时才挂这块盘（`add_blk_dev`），缺了会让后面所有
     * 盘整体前移一位 —— `/metadata` 与 `/data` 全挂错，guest 起来后 zygote 建不了
     * `/data/dalvik-cache` 直接 SIGABRT（实测：`app_process64 ... signal=6`，
     * `/metadata` 报 `__mount(...)=-1: Invalid argument`）。
     *
     * @return 实例 metadata 盘；null 表示模板缺失（此时该实例起不来）
     */
    fun ensureMetadata(vmId: Int, template: File?): File? {
        val dst = metadataImage(vmId)
        if (dst.exists()) return dst
        if (template == null || !template.isFile || template.length() == 0L) return null
        template.copyTo(dst, overwrite = true)
        return dst
    }

    /**
     * 确保实例有自己的 product.img / system.img，并把 [profile] 作为设备身份写进去。
     *
     * 两份镜像合计 1GB+，没必要每个实例都复制；[profile] 为 null（"保持镜像默认身份"）
     * 时直接返回 true，交给引擎用 base 那份。
     *
     * 身份必须同时落在两个分区才自洽：product 决定型号/品牌，system 决定 fingerprint
     * 里的版本段（见 [VmDeviceCatalog] 的说明）。
     *
     * @return 是否全部就绪；false 表示已回落到默认身份
     */
    fun ensureDeviceImages(
        vmId: Int,
        baseProduct: File?,
        baseSystem: File?,
        profile: VmDeviceProfile?
    ): Boolean {
        if (profile == null) return true
        // 缺任一模板都无法完成身份改写。提前返回，避免先复制几百 MB 的
        // system.img 再失败（p71/p9 的镜像包就没有 product.img）。
        if (baseProduct == null || !baseProduct.isFile || baseProduct.length() == 0L) return false
        if (baseSystem == null || !baseSystem.isFile || baseSystem.length() == 0L) return false
        val okProduct = ensureIdentityImage(productImage(vmId), baseProduct, profile)
        val okSystem = ensureIdentityImage(systemImage(vmId), baseSystem, profile)
        return okProduct && okSystem
    }

    private fun ensureIdentityImage(dst: File, base: File?, profile: VmDeviceProfile): Boolean {
        if (base == null || !base.isFile || base.length() == 0L) return false
        if (!dst.exists()) {
            base.copyTo(dst, overwrite = true)
            if (!VmDeviceIdentity.applyToImage(dst, profile)) {
                dst.delete()
                return false
            }
        }
        return true
    }

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
        // 外部镜像的数据盘可能大于默认值，绝不能把已有文件系统尾部截断。
        RandomAccessFile(file, "rw").use { if (it.length() < sizeBytes) it.setLength(sizeBytes) }
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
