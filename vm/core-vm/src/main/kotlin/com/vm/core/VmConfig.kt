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
    val width: Int = 720,
    val height: Int = 1280,
    val dpi: Int = 320,
    // 实测（真机 cc96ded5，11GB 宿主，见 docs/方案B排障交接.md §21）：
    // -m 4096 会把宿主压进 swap（系统自身常占 ~10GB），缺页变磁盘 I/O，boot 明显变慢；
    // 3072 是当前实测最优档位（到 create package manager 提速约 1.36x），2048 有 OOM 风险未采用。
    val memoryMb: Int = 3072,
    // 6 vCPU 为设备实测配置；TCG 已开 MTTCG（thread=multi），每个 vCPU 一条宿主线程。
    val cores: Int = 6,
    val gpuMode: GpuMode = GpuMode.GLES,
    val netMode: NetMode = NetMode.NAT,
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
        .put("imageDir", imageDir)
        .put("dataDir", dataDir)
        .toString()

    companion object {

        const val EXTRA_CONFIG = "com.vm.core.extra.CONFIG"

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
                imageDir = o.optString("imageDir", ""),
                dataDir = o.optString("dataDir", "")
            )
        }
    }
}
