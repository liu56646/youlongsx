package com.vm.core

import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 可用的虚拟化后端及其推荐优先级。
 *
 * 注意：这里只回答「这台设备的硬件 / 框架能力是否在位」，
 * **不等于**已经能跑 Android 访客 —— 硬件后端（Gunyah / GenieZone / KVM）公开验证过的
 * 场景都是 Linux / Windows 访客；跑完整 Android 访客还需要 VMM（crosvm / QEMU）与
 * gfxstream 的适配。当前真正能跑通完整 Android 访客的仍只有 QEMU TCG。
 */
enum class VmBackend(
    /** 展示名。 */
    val displayName: String,
    /** 推荐优先级，越小越优先被推荐。 */
    val priority: Int,
    /** 是否必须 root 才能真正打开并使用。 */
    val requiresRoot: Boolean,
    /**
     * 当前引擎（QEMU 封装）是否真的能把该后端跑起来。
     *
     * - QEMU_TCG：恒真，兜底；
     * - KVM：真 —— 引擎内置的 AOSP QEMU 已编译 kvm accel（libqemu_exec.so 含
     *   kvm_accel_class_init），宿主有可打开的 /dev/kvm 时 `-accel kvm` 即硬件加速；
     * - AVF / Gunyah / GenieZone：假 —— 它们是 Type-1 hypervisor 或系统框架，
     *   需要 crosvm 等独立 VMM 适配，当前引擎用不了，探测到也只作情报展示。
     */
    val engineSupported: Boolean
) {
    AVF("AVF（Android 虚拟化框架）", 0, false, false),
    KVM("Linux KVM", 1, true, true),
    GUNYAH("高通 Gunyah", 2, true, false),
    GENIEZONE("联发科 GenieZone", 3, true, false),
    QEMU_TCG("QEMU TCG（纯软件模拟，兜底）", 9, false, true);

    companion object {

        /**
         * 当前实际使用的后端。由探测 / 启动流程更新（探测到 KVM 可用即切 KVM，
         * 否则保持 TCG）；引擎侧会再核对一次 /dev/kvm 是否真能打开，打不开自动回退。
         */
        @Volatile
        var ACTIVE: VmBackend = QEMU_TCG

        /** 按推荐优先级排列。 */
        fun ordered(): List<VmBackend> = values().sortedBy { it.priority }
    }
}

/** 单条探测信号：命中的事实 + 证据详情。 */
data class ProbeSignal(
    val name: String,
    val hit: Boolean,
    val detail: String = ""
)

/** 探测置信度。 */
enum class ProbeConfidence(val label: String) {
    /** 有 root 实测打开 / ioctl 成功之类的硬证据。 */
    CONFIRMED("已确认可用"),

    /** 驱动与设备注册到位，但未做打开实测。 */
    LIKELY("很可能可用（驱动 / 节点在位）"),

    /** 只有孤立的节点，疑为占位（ueventd 静态节点）。 */
    WEAK("信号不足，疑为占位节点"),

    /** 明确不可用。 */
    UNAVAILABLE("不可用")
}

/** 单个后端的探测结论。 */
data class BackendProbeResult(
    val backend: VmBackend,
    val confidence: ProbeConfidence,
    val signals: List<ProbeSignal>,
    val note: String = ""
) {

    /** 是否认为该后端「可用」（CONFIRMED / LIKELY）。 */
    val available: Boolean
        get() = confidence == ProbeConfidence.CONFIRMED || confidence == ProbeConfidence.LIKELY

    val hitCount: Int get() = signals.count { it.hit }
}

/**
 * 一次完整探测的报告。
 *
 * 可 JSON 序列化落盘（[VmBackendStore]），也可转成人类可读文本用于复制 / 导出，
 * 便于在多台真实设备上收集后端可用性数据。
 */
data class BackendReport(
    val probedAt: Long,
    val sdkInt: Int,
    val abi: String,
    val model: String,
    val kernelRelease: String,
    val hasRoot: Boolean,
    val results: List<BackendProbeResult>
) {

    /**
     * 推荐后端：按优先级取第一个「引擎能跑且探测为可用」的后端；
     * 硬件后端里 KVM 是唯一引擎（QEMU -accel kvm）能落地的；Gunyah / GenieZone /
     * AVF 即使探测到也只展示，不参与推荐（引擎暂未适配）。全不可用回退 TCG。
     */
    val recommended: VmBackend
        get() = VmBackend.ordered()
            .filter { it.engineSupported }
            .firstOrNull { resultOf(it)?.available == true } ?: VmBackend.QEMU_TCG

    fun resultOf(backend: VmBackend): BackendProbeResult? =
        results.firstOrNull { it.backend == backend }

    // ------------------------------------------------------------------
    // 序列化
    // ------------------------------------------------------------------

    fun toJson(): String {
        val arr = JSONArray()
        results.forEach { r ->
            val sigs = JSONArray()
            r.signals.forEach { s ->
                sigs.put(
                    JSONObject()
                        .put("name", s.name)
                        .put("hit", s.hit)
                        .put("detail", s.detail)
                )
            }
            arr.put(
                JSONObject()
                    .put("backend", r.backend.name)
                    .put("confidence", r.confidence.name)
                    .put("note", r.note)
                    .put("signals", sigs)
            )
        }
        return JSONObject()
            .put("probedAt", probedAt)
            .put("sdkInt", sdkInt)
            .put("abi", abi)
            .put("model", model)
            .put("kernelRelease", kernelRelease)
            .put("hasRoot", hasRoot)
            .put("active", VmBackend.ACTIVE.name)
            .put("recommended", recommended.name)
            .put("results", arr)
            .toString()
    }

    /** 人类可读报告：用于复制到剪贴板或导出文件。 */
    fun toReportText(): String {
        val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(probedAt))
        val sb = StringBuilder()
        sb.append("=== 游龙沙箱 加速能力探测报告 ===\n")
        sb.append("时间：$time\n")
        sb.append("设备：$model（API $sdkInt · $abi）\n")
        sb.append("内核：$kernelRelease\n")
        sb.append("root shell：${if (hasRoot) "可用" else "不可用"}\n")
        sb.append("当前后端：${VmBackend.ACTIVE.displayName}\n")
        sb.append("推荐后端：${recommended.displayName}\n")
        sb.append("\n")
        results.forEach { r ->
            sb.append("[${r.backend.displayName}] ${r.confidence.label}")
            sb.append("（命中 ${r.hitCount}/${r.signals.size}）\n")
            r.signals.forEach { s ->
                sb.append("  ${if (s.hit) "+" else "-"} ${s.name}")
                if (s.detail.isNotBlank()) sb.append("：${s.detail}")
                sb.append("\n")
            }
            if (r.note.isNotBlank()) sb.append("  备注：${r.note}\n")
            sb.append("\n")
        }
        sb.append("说明：当前引擎（QEMU）能实际切换的后端为 KVM（-accel kvm）与 TCG；\n")
        sb.append("Gunyah / GenieZone / AVF 属 Type-1 虚拟化或系统框架，探测到也只作情报，\n")
        sb.append("跑完整 Android 访客仍需 crosvm 等 VMM 适配，不会自动启用。\n")
        return sb.toString()
    }

    companion object {

        fun fromJson(json: String): BackendReport? = runCatching {
            val o = JSONObject(json)
            val arr = o.getJSONArray("results")
            val results = ArrayList<BackendProbeResult>(arr.length())
            for (i in 0 until arr.length()) {
                val ro = arr.getJSONObject(i)
                val backend = VmBackend.values().firstOrNull { it.name == ro.optString("backend") }
                    ?: continue
                val sigArr = ro.optJSONArray("signals") ?: JSONArray()
                val sigs = ArrayList<ProbeSignal>(sigArr.length())
                for (j in 0 until sigArr.length()) {
                    val so = sigArr.getJSONObject(j)
                    sigs += ProbeSignal(
                        name = so.optString("name"),
                        hit = so.optBoolean("hit"),
                        detail = so.optString("detail")
                    )
                }
                results += BackendProbeResult(
                    backend = backend,
                    confidence = ProbeConfidence.values()
                        .firstOrNull { it.name == ro.optString("confidence") }
                        ?: ProbeConfidence.UNAVAILABLE,
                    signals = sigs,
                    note = ro.optString("note")
                )
            }
            BackendReport(
                probedAt = o.optLong("probedAt", 0L),
                sdkInt = o.optInt("sdkInt", 0),
                abi = o.optString("abi"),
                model = o.optString("model"),
                kernelRelease = o.optString("kernelRelease"),
                hasRoot = o.optBoolean("hasRoot"),
                results = results
            )
        }.getOrNull()
    }
}
