package com.vm.core

import org.json.JSONObject

/** 图形模式。 */
enum class GpuMode { OFF, GLES }

/** 网络模式。 */
enum class NetMode { NONE, NAT }

/**
 * 单个虚拟机实例的运行配置。
 * 宿主进程通过 Intent extra（JSON 字符串）传给实例进程。
 */
data class VmConfig(
    val vmId: Int,
    // 分辨率实测结论（真机 cc96ded5）：
    //   720x1280：能正常出帧（frame.rgba 有数据），启动与运行都验证过；
    //   540x960 ：**guest 从头到尾不 post 任何帧**（logs 里连 frame.seq 都不生成），
    //             怀疑是宽度 540 不是 16 的倍数，ranchu/gfxstream 的显示链路接受不了。
    //   且降分辨率对**启动时间没帮助**（SystemServer 288.1s vs 291.9s，在波动范围内）。
    // 结论：保持 720x1280。要压像素量得先确认尺寸对齐（宽高都是 16 的倍数）。
    val width: Int = 720,
    val height: Int = 1280,
    val dpi: Int = 320,
    // 实测（真机 cc96ded5，11GB 宿主，见 docs/方案B排障交接.md §21）：
    // -m 4096 会把宿主压进 swap（系统自身常占 ~10GB），缺页变磁盘 I/O，boot 明显变慢；
    // 3072 是当前实测最优档位（到 create package manager 提速约 1.36x），2048 有 OOM 风险未采用。
    val memoryMb: Int = DEFAULT_MEMORY_MB,
    // 6 vCPU 为设备实测配置；TCG 已开 MTTCG（thread=multi），每个 vCPU 一条宿主线程。
    // 低配宿机会被 VmLauncher 收敛到物理核数，避免 -smp 超过物理核导致过度调度。
    val cores: Int = DEFAULT_CORES,
    val gpuMode: GpuMode = GpuMode.GLES,
    val netMode: NetMode = NetMode.NAT,
    /**
     * 本次启动使用的后端。由 [com.vm.app.VmLauncher] 依据探测报告选定并写入，
     * 引擎 C 层据此决定 `-accel kvm` 还是 `-accel tcg,thread=multi`。
     */
    val backend: VmBackend = VmBackend.QEMU_TCG,
    val imageDir: String = "",
    val dataDir: String = ""
) {

    fun toJson(): String = JSONObject()
        .put("vmId", vmId)
        .put("width", width)
        .put("height", height)
        .put("dpi", dpi)
        .put("memoryMb", memoryMb)
        .put("cores", cores)
        .put("gpuMode", gpuMode.name)
        .put("netMode", netMode.name)
        .put("backend", backend.name)
        .put("imageDir", imageDir)
        .put("dataDir", dataDir)
        .toString()

    companion object {

        const val EXTRA_CONFIG = "com.vm.core.extra.CONFIG"

        /** 默认 guest 内存（MB）。低配宿机会被 [VmDeviceCheck] 推导出更小的值。 */
        const val DEFAULT_MEMORY_MB = 3072

        /** 默认 guest vCPU 数（设备实测最优），上限，不会超过宿主物理核数。 */
        const val DEFAULT_CORES = 6

        fun fromJson(json: String): VmConfig {
            val o = JSONObject(json)
            return VmConfig(
                vmId = o.getInt("vmId"),
                width = o.optInt("width", 720),
                height = o.optInt("height", 1280),
                dpi = o.optInt("dpi", 320),
                memoryMb = o.optInt("memoryMb", 3072),
                cores = o.optInt("cores", 6),
                gpuMode = runCatching { GpuMode.valueOf(o.optString("gpuMode", "GLES")) }
                    .getOrDefault(GpuMode.GLES),
                netMode = runCatching { NetMode.valueOf(o.optString("netMode", "NAT")) }
                    .getOrDefault(NetMode.NAT),
                backend = runCatching { VmBackend.valueOf(o.optString("backend", "QEMU_TCG")) }
                    .getOrDefault(VmBackend.QEMU_TCG),
                imageDir = o.optString("imageDir", ""),
                dataDir = o.optString("dataDir", "")
            )
        }
    }
}
