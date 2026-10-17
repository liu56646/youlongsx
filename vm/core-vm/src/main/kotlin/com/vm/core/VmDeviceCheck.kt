package com.vm.core

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.StatFs

/**
 * 宿主设备兼容性预检。
 *
 * 分发给他人时设备千差万别：ABI 不对直接装不上；内存太小会被系统 OOM 杀掉；
 * 存储不足会让镜像下载/解压失败；GLES 版本太低则宿主渲染起不来。
 * 与其让用户撞上黑屏或闪退，不如在启动前把原因讲清楚。
 *
 * 所有检测都容错：拿不到某项数据时按"未知"处理，**不阻断**流程
 * （宁可能用但有风险，也不要因为读不到就误判成不支持）。
 */
object VmDeviceCheck {

    /** guest 需要的最小空闲存储（镜像 zip + 解压后镜像 + 4GB 实例数据盘，留冗余）。 */
    private const val MIN_FREE_STORAGE_MB = 6 * 1024L

    private const val MB = 1024L * 1024L

    data class Report(
        val abi: String,
        val abiOk: Boolean,
        val totalMemMb: Long,
        val availMemMb: Long,
        /** 依据宿主内存推导出的 guest 建议内存（MB）。 */
        val suggestedGuestMemMb: Int,
        val freeStorageMb: Long,
        val glesVersion: String,
        /** 致命问题：不满足就没法跑。 */
        val problems: List<String>,
        /** 非致命提醒：能跑，但体验会打折。 */
        val warnings: List<String>
    ) {
        val ok: Boolean get() = problems.isEmpty()
    }

    fun check(context: Context): Report {
        val problems = mutableListOf<String>()
        val warnings = mutableListOf<String>()

        // ---- ABI：引擎目前只交叉编译了 arm64-v8a ----
        val abi = Build.SUPPORTED_ABIS.firstOrNull().orEmpty()
        val abiOk = Build.SUPPORTED_ABIS.any { it == "arm64-v8a" }
        if (!abiOk) {
            problems += "本机 ABI 是 $abi，而引擎只提供 arm64-v8a 版本，无法运行。"
        }

        // ---- 内存：决定 guest 内存，也决定会不会被 OOM ----
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val memInfo = ActivityManager.MemoryInfo()
        var totalMb = 0L
        var availMb = 0L
        runCatching {
            if (am != null) {
                am.getMemoryInfo(memInfo)
                totalMb = memInfo.totalMem / MB
                availMb = memInfo.availMem / MB
            }
        }
        val suggested = when {
            totalMb <= 0L -> VmConfig.DEFAULT_MEMORY_MB
            totalMb < 6 * 1024L -> 1536
            totalMb < 8 * 1024L -> 2048
            else -> VmConfig.DEFAULT_MEMORY_MB
        }
        if (totalMb in 1..(4 * 1024L)) {
            problems += "本机总内存约 ${totalMb}MB，低于运行访客的下限（建议 6GB+），很可能被系统 OOM。"
        } else if (totalMb in 1..(6 * 1024L)) {
            warnings += "本机总内存约 ${totalMb}MB，属低配，会把访客内存下调到 ${suggested}MB。"
        }

        // ---- 存储 ----
        var freeMb = 0L
        runCatching {
            val st = StatFs(context.filesDir.absolutePath)
            freeMb = st.availableBytes / MB
        }
        if (freeMb in 1..MIN_FREE_STORAGE_MB) {
            problems += "可用存储约 ${freeMb}MB，装不下访客镜像（约 500MB）+ 实例数据盘（4GB）。"
        }

        // ---- GLES：宿主渲染需要 3.x ----
        val gles = runCatching { am?.deviceConfigurationInfo?.glEsVersion.orEmpty() }
            .getOrDefault("")
        val major = gles.substringBefore('.').toIntOrNull() ?: 0
        if (major in 1..2) {
            problems += "本机 GLES 版本为 $gles，需要 3.x 才能把访客画面渲染上屏。"
        }

        return Report(
            abi = abi,
            abiOk = abiOk,
            totalMemMb = totalMb,
            availMemMb = availMb,
            suggestedGuestMemMb = suggested,
            freeStorageMb = freeMb,
            glesVersion = gles,
            problems = problems,
            warnings = warnings
        )
    }
}
