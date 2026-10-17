package com.vm.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.util.Log
import com.vm.app.instance.VmNativeActivity1
import com.vm.app.instance.VmNativeActivity2
import com.vm.app.instance.VmNativeActivity3
import com.vm.app.instance.VmNativeActivity4
import com.vm.core.VmBackend
import com.vm.core.VmBackendStore
import com.vm.core.VmConfig
import com.vm.core.VmDeviceCheck
import com.vm.core.VmDiskStore
import com.vm.core.VmImageProvider
import com.vm.core.VmInfo
import com.vm.engine.VmEngine

/**
 * 实例启动/停止编排：把 UI 意图翻译成"拉起 :vmN 进程"的 Intent。
 */
object VmLauncher {

    private const val TAG = "VmLauncher"

    const val EXTRA_STOP = "com.vm.app.extra.STOP"

    enum class Result { Started, NoEngine, NoImage, Unsupported }

    fun activityClass(vmId: Int): Class<out Activity>? = when (vmId) {
        1 -> VmNativeActivity1::class.java
        2 -> VmNativeActivity2::class.java
        3 -> VmNativeActivity3::class.java
        4 -> VmNativeActivity4::class.java
        else -> null
    }

    fun start(
        context: Context,
        info: VmInfo,
        imageProvider: VmImageProvider,
        diskStore: VmDiskStore
    ): Result {
        if (!VmEngine.isAvailable) {
            Log.w(TAG, "engine library not available")
            return Result.NoEngine
        }
        if (!imageProvider.isReady(info.imageTag)) {
            Log.w(TAG, "guest image not ready: ${info.imageTag}")
            return Result.NoImage
        }
        val cls = activityClass(info.vmId) ?: return Result.Unsupported

        // 快照用的 qcow2 vmstate 盘：QEMU 不会自己建，启动前从 assets 复制一份。
        // 失败不阻断启动（只是这次快照不可用）。
        if (!diskStore.ensureVmstate(info.vmId)) {
            Log.w(TAG, "vmstate.qcow2 准备失败，本次快照保存会失败（冷启动不受影响）")
        }

        // 按宿主能力自适应：低配设备下调 guest 内存与 vCPU 数，
        // 避免 -m 超出宿主可用内存被 OOM，或 -smp 超过物理核导致过度调度。
        val device = VmDeviceCheck.check(context)
        val cores = minOf(
            VmConfig.DEFAULT_CORES,
            Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
        )

        // 自动选择本机最优后端：探测确认宿主 KVM 可用 → KVM（ARM 指令原生执行，
        // 免 TCG 二进制翻译损耗）；否则 → TCG。引擎 C 层还会再核对一次
        // /dev/kvm 是否真能打开，打不开自动回退 TCG。
        val report = VmBackendStore(context).load()
        val backend = if (report?.resultOf(VmBackend.KVM)?.available == true) {
            VmBackend.KVM
        } else {
            VmBackend.QEMU_TCG
        }
        VmBackend.ACTIVE = backend

        val config = VmConfig(
            vmId = info.vmId,
            memoryMb = device.suggestedGuestMemMb,
            cores = cores,
            backend = backend,
            imageDir = imageProvider.imageDir(info.imageTag).absolutePath,
            dataDir = diskStore.vmDir(info.vmId).absolutePath
        )
        // 落一份配置快照，便于事后排查
        diskStore.configFile(info.vmId).writeText(config.toJson())

        val payload = config.toJson()
        val intent = Intent(context, cls)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(VmConfig.EXTRA_CONFIG, payload)
        context.startActivity(intent)

        Log.i(TAG, "start vm=${info.vmId} class=${cls.simpleName}")
        return Result.Started
    }

    /**
     * 停止实例：向已存在的实例 Activity 投递停止指令。
     * 实例 Activity 是 singleInstance，重复启动会走到 onNewIntent。
     */
    fun stop(context: Context, vmId: Int): Boolean {
        val cls = activityClass(vmId) ?: return false
        val intent = Intent(context, cls)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(EXTRA_STOP, true)
        context.startActivity(intent)
        Log.i(TAG, "stop vm=$vmId")
        return true
    }
}
