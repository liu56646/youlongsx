package com.vm.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [VmConfig] JSON 序列化的回归测试。
 *
 * 这份 JSON 是宿主进程 → 实例进程的唯一信使（Intent extra），序列化漂移
 * 直接表现为「实例起来配置不对」且难以归因 —— 用测试把它钉死。
 */
class VmConfigTest {

    private fun fullConfig() = VmConfig(
        vmId = 3,
        width = 1080,
        height = 1920,
        dpi = 480,
        memoryMb = 2048,
        cores = 4,
        gpuMode = GpuMode.OFF,
        netMode = NetMode.NONE,
        backend = VmBackend.KVM,
        imageDir = "/data/images/p11",
        dataDir = "/data/vms/vm_3"
    )

    @Test
    fun roundTripPreservesEveryField() {
        val original = fullConfig()
        val restored = VmConfig.fromJson(original.toJson())

        assertEquals(original.vmId, restored.vmId)
        assertEquals(original.width, restored.width)
        assertEquals(original.height, restored.height)
        assertEquals(original.dpi, restored.dpi)
        assertEquals(original.memoryMb, restored.memoryMb)
        assertEquals(original.cores, restored.cores)
        assertEquals(original.gpuMode, restored.gpuMode)
        assertEquals(original.netMode, restored.netMode)
        assertEquals(original.backend, restored.backend)
        assertEquals(original.imageDir, restored.imageDir)
        assertEquals(original.dataDir, restored.dataDir)
    }

    @Test
    fun minimalJsonFallsBackToDefaults() {
        // 只有 vmId 是必填，其余字段在旧版本 JSON / 字段缺失时取默认档位。
        val config = VmConfig.fromJson("""{"vmId":1}""")

        assertEquals(1, config.vmId)
        assertEquals(720, config.width)
        assertEquals(1280, config.height)
        assertEquals(320, config.dpi)
        assertEquals(VmConfig.DEFAULT_MEMORY_MB, config.memoryMb)
        assertEquals(VmConfig.DEFAULT_CORES, config.cores)
        assertEquals(GpuMode.GLES, config.gpuMode)
        assertEquals(NetMode.NAT, config.netMode)
        assertEquals(VmBackend.QEMU_TCG, config.backend)
        assertEquals("", config.imageDir)
        assertEquals("", config.dataDir)
    }

    @Test
    fun unknownEnumNamesDegradeInsteadOfCrashing() {
        // 枚举名是字符串：老安装包写入的值 / 手改的 JSON 可能不认识，
        // fromJson 必须给默认值而不是抛异常（实例起不来会很难排查）。
        val json = JSONObject()
            .put("vmId", 2)
            .put("gpuMode", "FUTURE_GL")
            .put("netMode", "WIREGUARD")
            .put("backend", "HVF")
            .toString()
        val config = VmConfig.fromJson(json)

        assertEquals(GpuMode.GLES, config.gpuMode)
        assertEquals(NetMode.NAT, config.netMode)
        assertEquals(VmBackend.QEMU_TCG, config.backend)
    }

    @Test
    fun defaultsMatchDocumentedOptimalProfile() {
        // 默认档位是实测结论（3072MB / 6 vCPU，见 VmConfig 注释），
        // 被无意改动时应在此被发现，而不是在真机启动时长上被发现。
        assertEquals(3072, VmConfig.DEFAULT_MEMORY_MB)
        assertEquals(6, VmConfig.DEFAULT_CORES)
    }
}
