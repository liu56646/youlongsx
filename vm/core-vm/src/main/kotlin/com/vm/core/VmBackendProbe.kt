package com.vm.core

import android.os.Build
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.TimeUnit

/**
 * 多后端可用性探测（只读，不改变任何运行状态）。
 *
 * 设计要点（源自真机踩坑）：
 * - **只看 /dev 节点存在会严重误判**：实测某骁龙设备上 `/dev/kvm` 节点存在、
 *   `/sys/module/kvm` 目录也存在，但 `/proc/misc` 无 kvm 条目、
 *   `/sys/devices/virtual/misc/kvm` 不存在，且 `open("/dev/kvm")` 直接返回 ENODEV
 *   —— 典型的 ueventd 静态占位节点。
 * - 因此每个后端都做**多信号交叉验证**并给出置信度，而不是单点判断。
 * - 所有探测都容错：单条信号失败只丢该信号，绝不抛出，也不阻塞主线程
 *   （调用方应放到后台线程）。
 */
object VmBackendProbe {

    private val PROP_RE = Regex("""\[(.+?)]:\s*\[(.*)]""")

    /** 执行一次完整探测。会启动子进程，务必在后台线程调用。 */
    fun probeAll(): BackendReport {
        val props = readAllProps()
        val misc = readMiscNames()
        val rootOut = runRootProbe()
        val hasRoot = rootOut?.contains("uid=0") == true

        val results = listOf(
            probeAvf(props, rootOut),
            probeKvm(misc, rootOut),
            probeGunyah(misc, rootOut),
            probeGenieZone(misc, rootOut),
            probeTcg()
        )

        return BackendReport(
            probedAt = System.currentTimeMillis(),
            sdkInt = Build.VERSION.SDK_INT,
            abi = Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
            model = "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            kernelRelease = System.getProperty("os.version").orEmpty(),
            hasRoot = hasRoot,
            results = results
        )
    }

    // ------------------------------------------------------------------
    // 各后端
    // ------------------------------------------------------------------

    /** AVF：Google 官方框架，靠系统服务与属性判断。 */
    private fun probeAvf(props: Map<String, String>, rootOut: String?): BackendProbeResult {
        val virtSvc = props.containsKey("init.svc.virtualizationservice")
        val protectedVm = props["ro.boot.hypervisor.protected_vm.supported"] == "true"
        val apex = exists("/apex/com.android.virt")
        val svcListed = rootOut?.contains("virtualizationservice") == true
        val version = props["ro.hypervisor.version"].orEmpty()

        val signals = listOf(
            ProbeSignal("系统服务 virtualizationservice 已定义", virtSvc),
            ProbeSignal("ro.boot.hypervisor.protected_vm.supported=true", protectedVm),
            ProbeSignal("AVF 组件包 /apex/com.android.virt 存在", apex),
            ProbeSignal("service list 中有 virtualizationservice", svcListed),
            ProbeSignal("hypervisor 版本属性", version.isNotBlank(), version)
        )

        val score = listOf(virtSvc, protectedVm, apex).count { it }
        val confidence = when {
            score >= 2 -> ProbeConfidence.LIKELY
            score == 1 -> ProbeConfidence.WEAK
            else -> ProbeConfidence.UNAVAILABLE
        }
        val note = "AVF 官方主要面向 Linux microVM（如 Android 16 Terminal 的 Debian）；" +
            "跑完整 Android 访客需要额外适配，不能直接复用。"
        return BackendProbeResult(VmBackend.AVF, confidence, signals, note)
    }

    /** KVM：需要 misc 注册 + 可打开才算数。 */
    private fun probeKvm(misc: Set<String>?, rootOut: String?): BackendProbeResult {
        val node = "/dev/kvm"
        val nodeExists = exists(node)
        val sysfsHit = sysfsMiscExists("kvm")
        val miscHit = misc?.contains("kvm") == true
        val modLive = moduleLive("kvm")
        val modDir = exists("/sys/module/kvm")
        val open = tryOpen(node)
        val rootOpen = rootOpenResult(rootOut, "kvm")

        val signals = listOf(
            ProbeSignal("设备节点 $node 存在", nodeExists),
            ProbeSignal("sysfs 已注册 /sys/devices/virtual/misc/kvm", sysfsHit),
            ProbeSignal("/proc/misc 含 kvm 条目", miscHit, if (misc == null) "读取失败（权限）" else ""),
            ProbeSignal(
                "内核模块 kvm 处于 live",
                modLive,
                if (modDir && !modLive) "目录存在但非 live（builtin / 残留）" else ""
            ),
            ProbeSignal("应用内 open($node)", open.ok, open.detail),
            ProbeSignal("root open($node)", rootOpen == true, rootOutDetail(rootOut, rootOpen))
        )

        val registered = sysfsHit || miscHit
        val confidence = judgeConfidence(registered, nodeExists, modLive, rootOpen)
        val note = if (confidence == ProbeConfidence.UNAVAILABLE && nodeExists) {
            "节点存在但内核未注册 misc 设备，open 返回 ENODEV，属 ueventd 静态占位节点。"
        } else {
            ""
        }
        return BackendProbeResult(VmBackend.KVM, confidence, signals, note)
    }

    /** Gunyah：高通 Type-1 hypervisor。 */
    private fun probeGunyah(misc: Set<String>?, rootOut: String?): BackendProbeResult {
        val node = "/dev/gunyah"
        val nodeExists = exists(node)
        val sysfsHit = sysfsMiscExists("gunyah") || sysfsMiscExists("qgunyah")
        val miscHit = misc?.contains("gunyah") == true || misc?.contains("qgunyah") == true
        val loaderLive = moduleLive("gunyah_loader")
        val open = tryOpen(node)
        val rootOpen = rootOpenResult(rootOut, "gunyah")

        val signals = listOf(
            ProbeSignal("设备节点 $node 存在", nodeExists),
            ProbeSignal("sysfs 已注册 gunyah / qgunyah", sysfsHit),
            ProbeSignal("/proc/misc 含 gunyah / qgunyah 条目", miscHit, if (misc == null) "读取失败（权限）" else ""),
            ProbeSignal("内核模块 gunyah_loader 处于 live", loaderLive),
            ProbeSignal("应用内 open($node)", open.ok, open.detail),
            ProbeSignal("root open($node)", rootOpen == true, rootOutDetail(rootOut, rootOpen))
        )

        val registered = sysfsHit || miscHit
        val confidence = judgeConfidence(registered, nodeExists, loaderLive, rootOpen)
        val note = if (confidence != ProbeConfidence.UNAVAILABLE) {
            "Gunyah 常只放行 protected VM；跑非保护 Android 访客还需 crosvm 侧适配。"
        } else {
            ""
        }
        return BackendProbeResult(VmBackend.GUNYAH, confidence, signals, note)
    }

    /** GenieZone：联发科 Type-1 hypervisor。 */
    private fun probeGenieZone(misc: Set<String>?, rootOut: String?): BackendProbeResult {
        val node = "/dev/gzvm"
        val nodeExists = exists(node)
        val sysfsHit = sysfsMiscExists("gzvm")
        val miscHit = misc?.contains("gzvm") == true
        val modLive = moduleLive("gzvm") || moduleLive("geniezone")
        val open = tryOpen(node)
        val rootOpen = rootOpenResult(rootOut, "gzvm")

        val signals = listOf(
            ProbeSignal("设备节点 $node 存在", nodeExists),
            ProbeSignal("sysfs 已注册 /sys/devices/virtual/misc/gzvm", sysfsHit),
            ProbeSignal("/proc/misc 含 gzvm 条目", miscHit, if (misc == null) "读取失败（权限）" else ""),
            ProbeSignal("内核模块 gzvm / geniezone 处于 live", modLive),
            ProbeSignal("应用内 open($node)", open.ok, open.detail),
            ProbeSignal("root open($node)", rootOpen == true, rootOutDetail(rootOut, rootOpen))
        )

        val registered = sysfsHit || miscHit
        val confidence = judgeConfidence(registered, nodeExists, modLive, rootOpen)
        val note = if (!nodeExists && modLive) {
            "驱动模块已加载但未创建设备节点（非 MTK 平台常见），无法使用。"
        } else {
            ""
        }
        return BackendProbeResult(VmBackend.GENIEZONE, confidence, signals, note)
    }

    /** TCG：纯软件模拟，恒定可用，是当前唯一能跑完整 Android 访客的后端。 */
    private fun probeTcg(): BackendProbeResult {
        val abiOk = Build.SUPPORTED_ABIS.any { it == "arm64-v8a" }
        val signals = listOf(
            ProbeSignal("ABI 含 arm64-v8a（引擎已交叉编译的 ABI）", abiOk, Build.SUPPORTED_ABIS.joinToString())
        )
        return BackendProbeResult(
            backend = VmBackend.QEMU_TCG,
            confidence = ProbeConfidence.CONFIRMED,
            signals = signals,
            note = "不依赖任何硬件虚拟化，永远可用；也是当前唯一验证过能跑完整 Android 访客的后端。"
        )
    }

    // ------------------------------------------------------------------
    // 底层读取 / 执行
    // ------------------------------------------------------------------

    private data class OpenResult(val ok: Boolean, val enoDev: Boolean, val detail: String)

    /** 在应用进程内直接尝试打开节点，用于区分「权限不足」与「设备不存在」。 */
    private fun tryOpen(path: String): OpenResult = try {
        FileInputStream(path).use { OpenResult(true, false, "打开成功") }
    } catch (t: Throwable) {
        val msg = t.message ?: t.javaClass.simpleName
        val enoDev = msg.contains("No such device", true) || msg.contains("ENODEV", true)
        OpenResult(false, enoDev, msg)
    }

    private fun exists(path: String): Boolean =
        runCatching { File(path).exists() }.getOrDefault(false)

    private fun moduleLive(name: String): Boolean = runCatching {
        File("/sys/module/$name/initstate").readText().trim() == "live"
    }.getOrDefault(false)

    /** 内核是否把该字符设备注册为 misc：这是与访问权限无关的硬事实。 */
    private fun sysfsMiscExists(name: String): Boolean =
        exists("/sys/devices/virtual/misc/$name") || exists("/sys/class/misc/$name")

    /**
     * 统一置信度判定。
     *
     * 主依据是「内核是否有 misc 注册」——它与访问权限无关；而 `/proc/misc`、
     * `/sys/module/<m>/initstate` 在应用沙箱里常被 SELinux 拒绝读取，
     * 因此这两者只作辅助信号，不参与判定。
     */
    private fun judgeConfidence(
        registered: Boolean,
        nodeExists: Boolean,
        moduleLive: Boolean,
        rootOpen: Boolean?
    ): ProbeConfidence = when {
        rootOpen == true -> ProbeConfidence.CONFIRMED
        registered && nodeExists -> ProbeConfidence.LIKELY
        registered -> ProbeConfidence.WEAK
        moduleLive -> ProbeConfidence.WEAK
        else -> ProbeConfidence.UNAVAILABLE
    }

    /** 读 /proc/misc，返回注册的设备名集；null 表示读取失败（无权限）。 */
    private fun readMiscNames(): Set<String>? = runCatching {
        val f = File("/proc/misc")
        if (!f.exists()) return null
        f.readLines()
            .mapNotNull { line ->
                line.trim().split(Regex("\\s+")).lastOrNull()?.takeIf { it.isNotBlank() }
            }
            .toSet()
    }.getOrNull()

    /** 一次性读取全部系统属性。 */
    private fun readAllProps(): Map<String, String> =
        execAndRead(listOf("getprop"), 1500)
            ?.lineSequence()
            ?.mapNotNull { line ->
                PROP_RE.matchEntire(line.trim())?.let { it.groupValues[1] to it.groupValues[2] }
            }
            ?.toMap()
            .orEmpty()

    /**
     * 一次 root 会话做完所有需要特权的探测，避免反复触发授权弹窗。
     * 返回 null 表示没有可用的 `su`。
     */
    private fun runRootProbe(): String? = execAndRead(
        listOf(
            "su", "-c",
            """
            id 2>&1
            exec 3<>/dev/kvm 2>/dev/null && { echo "OPEN:kvm=OK"; exec 3>&-; } || echo "OPEN:kvm=FAIL"
            exec 4<>/dev/gunyah 2>/dev/null && { echo "OPEN:gunyah=OK"; exec 4>&-; } || echo "OPEN:gunyah=FAIL"
            exec 5<>/dev/gzvm 2>/dev/null && { echo "OPEN:gzvm=OK"; exec 5>&-; } || echo "OPEN:gzvm=FAIL"
            service list 2>/dev/null | grep -iE 'virtualizationservice'
            """.trimIndent()
        ),
        timeoutMs = 3000
    )

    private fun rootOpenResult(rootOut: String?, key: String): Boolean? =
        rootOut?.lineSequence()
            ?.firstOrNull { it.startsWith("OPEN:$key=") }
            ?.let { it.endsWith("=OK") }

    private fun rootOutDetail(rootOut: String?, ok: Boolean?): String = when {
        rootOut == null -> "无 root shell"
        ok == null -> "未返回结果"
        ok -> "打开成功"
        else -> "打开失败（ENODEV / 权限）"
    }

    /** 执行命令并在超时后强制结束；输出在线程里读取，避免管道阻塞。 */
    private fun execAndRead(cmd: List<String>, timeoutMs: Long): String? = runCatching {
        val process = ProcessBuilder(cmd).redirectErrorStream(true).start()
        val buffer = StringBuilder()
        val reader = Thread {
            runCatching { process.inputStream.bufferedReader().forEachLine { buffer.appendLine(it) } }
        }
        reader.isDaemon = true
        reader.start()

        if (!process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
            process.destroy()
            return null
        }
        reader.join(200)
        buffer.toString()
    }.getOrNull()
}
