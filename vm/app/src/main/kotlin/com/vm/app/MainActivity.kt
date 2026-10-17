package com.vm.app

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.net.VpnService
import android.os.Bundle
import android.text.format.Formatter
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import com.vm.app.databinding.ActivityMainBinding
import com.vm.app.net.VmNetworkService
import com.vm.core.BackendReport
import com.vm.core.VmBackend
import com.vm.core.VmBackendProbe
import com.vm.core.VmBackendStore
import com.vm.core.VmConstants
import com.vm.core.VmDeviceCatalog
import com.vm.core.VmDeviceCheck
import com.vm.core.VmDiskStore
import com.vm.core.VmGuestCatalog
import com.vm.core.VmGuestImage
import com.vm.core.VmImageProvider
import com.vm.core.VmInfo
import com.vm.core.VmRepository
import com.vm.engine.VmEngine
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 宿主主界面。
 *
 * 核心入口是「一键启动」：把「确保镜像 → 确保实例 → 启动」三步串起来，
 * 用户只需要点一次。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var repository: VmRepository
    private lateinit var imageProvider: VmImageProvider
    private lateinit var diskStore: VmDiskStore
    private lateinit var adapter: VmAdapter

    private lateinit var backendStore: VmBackendStore

    /** 宿主兼容性预检结果（onCreate 时算一次，启动前据此决定是否放行）。 */
    private lateinit var deviceReport: VmDeviceCheck.Report

    /** 最近一次加速探测结果（进程内缓存，落盘副本见 [VmBackendStore]）。 */
    private var lastReport: BackendReport? = null

    /** 镜像就绪后要继续做的动作；下载/导入是异步的，先记下来 */
    private var pendingAfterImage: (() -> Unit)? = null

    /** 当前正在准备哪个版本的镜像 */
    private var pendingTag: String = VmConstants.DEFAULT_IMAGE_TAG

    /** 正在下载/导入，避免重入 */
    private val busy = AtomicBoolean(false)

    private var downloadDialog: AlertDialog? = null
    private val downloadCancelled = AtomicBoolean(false)

    private val vpnConsent =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == RESULT_OK) {
                markNetworkReady()
                startService(Intent(this, VmNetworkService::class.java))
                toast(getString(R.string.network_started))
            } else {
                toast(getString(R.string.network_denied))
            }
        }

    private val pickLocalImage =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            if (uri == null) {
                pendingAfterImage = null
                return@registerForActivityResult
            }
            importPickedImage(uri)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        repository = VmRepository(this)
        imageProvider = VmImageProvider(this)
        diskStore = VmDiskStore(this)
        backendStore = VmBackendStore(this)
        lastReport = backendStore.load()
        deviceReport = VmDeviceCheck.check(this)

        adapter = VmAdapter(
            onClick = { startVm(it) },
            onLongClick = { showVmMenu(it) }
        )
        binding.vmList.layoutManager = LinearLayoutManager(this)
        binding.vmList.adapter = adapter

        // 顶部按钮已移除：网络 / 解压 / 探测 / 更新 / 一键启动全部改为自动
        // （镜像缺失自动下载、每次打开自动探测、启动时自动引导网络授权）。
        binding.fabCreate.setOnClickListener { createVm() }

        // 后端自动选择：本机有什么用哪个（有 KVM 用 KVM，没有用 TCG），
        // 不设手动开关，直接追求本机最佳性能。
        VmBackend.ACTIVE = resolveBackend()

        // 供自动化 / 远程验证使用：带对应 extra 启动即自动执行
        if (intent?.getBooleanExtra(EXTRA_AUTO_PROBE, false) == true) {
            binding.root.post { probeBackends() }
        } else if (intent?.getBooleanExtra(EXTRA_AUTO_START_VM, false) == true) {
            // 自动化路径直接建/启动，跳过首次引导弹窗（它是模态的，会卡住无头测试）。
            binding.root.post { startOrCreate() }
        } else if (intent?.getBooleanExtra(EXTRA_AUTO_CHECK_UPDATE, false) == true) {
            binding.root.post { checkUpdate() }
        } else {
            // 正常打开：镜像缺失自动从云端下载 + 静默探测一次。
            binding.root.post {
                autoEnsureImage()
                autoProbe()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    // ------------------------------------------------------------------
    // 自动：镜像就绪 + 探测
    // ------------------------------------------------------------------

    /**
     * 确保默认版本镜像就绪：缺失则自动从云端下载（进度放状态栏 toast），
     * 不需要用户手动点「解压镜像」。
     */
    private fun autoEnsureImage() {
        val tag = VmConstants.DEFAULT_IMAGE_TAG
        if (imageProvider.isReady(tag)) return
        val url = imageUrlFor(tag)
        if (url.isBlank()) {
            toast(getString(R.string.image_url_missing))
            return
        }
        downloadImage(url, tag)
    }

    /** 每次打开应用静默探测一次加速后端（不弹报告，只落盘并更新状态栏）。 */
    private fun autoProbe() {
        Thread {
            val report = VmBackendProbe.probeAll()
            backendStore.save(report)
            // 探测结果不自动切换后端：LibOS 是否启用只由开关门控，
            // 这里仅用探测结论刷新「实际将使用的后端」的展示。
            VmBackend.ACTIVE = resolveBackend()
            runOnUiThread {
                lastReport = report
                refresh()
            }
        }.start()
    }

    /**
     * 自动选择本机最优后端：
     * 探测确认宿主 KVM 可用 → KVM（ARM 指令原生执行，免 TCG 二进制翻译损耗）；
     * 否则 → TCG 纯软件模拟。与 [VmLauncher] 启动时的判定保持一致。
     */
    private fun resolveBackend(): VmBackend {
        val kvmOk = lastReport?.resultOf(VmBackend.KVM)?.available == true
        return if (kvmOk) VmBackend.KVM else VmBackend.QEMU_TCG
    }
    // ------------------------------------------------------------------

    /** 某个版本对应的下载地址：优先用服务器基址拼，其次用单版本直链。 */
    private fun imageUrlFor(tag: String): String {
        val base = BuildConfig.GUEST_IMAGE_BASE_URL
        if (base.isNotBlank()) {
            return VmGuestCatalog.downloadUrl(base, tag)
        }
        return if (tag == VmConstants.DEFAULT_IMAGE_TAG) BuildConfig.GUEST_IMAGE_URL else ""
    }

    /** 确保指定版本的镜像就绪，然后就绪回调；否则走下载或本地导入。 */
    private fun ensureImageThen(tag: String, action: () -> Unit) {
        if (imageProvider.isReady(tag)) {
            action()
            return
        }

        pendingTag = tag
        pendingAfterImage = action

        val url = imageUrlFor(tag)
        if (url.isBlank()) {
            toast(getString(R.string.image_url_missing))
            importLocalImage()
            return
        }
        downloadImage(url, tag)
    }

    private fun downloadImage(url: String, tag: String) {
        if (!busy.compareAndSet(false, true)) {
            return
        }
        downloadCancelled.set(false)

        val bar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progress = 0
        }
        val label = TextView(this).apply {
            text = getString(R.string.download_waiting)
            setPadding(48, 40, 48, 0)
        }
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label)
            addView(bar)
        }

        downloadDialog = AlertDialog.Builder(this)
            .setTitle(R.string.download_title)
            .setView(container)
            .setCancelable(false)
            .setNegativeButton(R.string.action_cancel) { _, _ -> downloadCancelled.set(true) }
            .show()

        Thread {
            val ok = imageProvider.download(
                tag = tag,
                url = url,
                onProgress = { downloaded, total ->
                    runOnUiThread {
                        if (total > 0) {
                            bar.progress = (downloaded * 1000 / total).toInt()
                            label.text = getString(
                                R.string.download_progress,
                                Formatter.formatFileSize(this, downloaded),
                                Formatter.formatFileSize(this, total)
                            )
                        } else {
                            label.text = Formatter.formatFileSize(this, downloaded)
                        }
                    }
                },
                isCancelled = { downloadCancelled.get() }
            )
            runOnUiThread {
                downloadDialog?.dismiss()
                downloadDialog = null
                busy.set(false)
                if (ok) {
                    refresh()
                    pendingAfterImage?.invoke()
                } else if (!downloadCancelled.get()) {
                    toast(getString(R.string.download_fail))
                }
                pendingAfterImage = null
            }
        }.start()
    }

    private fun importLocalImage() {
        pickLocalImage.launch(arrayOf("*/*"))
    }

    private fun importPickedImage(uri: Uri) {
        if (!busy.compareAndSet(false, true)) {
            return
        }
        val tag = pendingTag
        toast(getString(R.string.image_extracting, tag))

        Thread {
            val ok = runCatching {
                contentResolver.openInputStream(uri).use { input ->
                    input != null && imageProvider.importFromStream(input, tag)
                }
            }.getOrDefault(false)

            runOnUiThread {
                busy.set(false)
                toast(getString(if (ok) R.string.import_ok else R.string.import_fail))
                if (ok) {
                    refresh()
                    pendingAfterImage?.invoke()
                }
                pendingAfterImage = null
            }
        }.start()
    }

    /** 有实例就启动第一个，没有就先建一个再启动。 */
    private fun startOrCreate() {
        var items = repository.list()
        if (items.isEmpty()) {
            val created = repository.create()
            if (created == null) {
                toast(getString(R.string.no_free_instance))
                return
            }
            items = repository.list()
            toast(getString(R.string.created_fmt, created.name))
        }
        refresh()
        items.firstOrNull()?.let { startVm(it) }
    }

    // ------------------------------------------------------------------
    // 列表 / 实例管理
    // ------------------------------------------------------------------

    private fun refresh() {
        adapter.submit(repository.list())
        binding.emptyView.visibility = if (adapter.itemCount == 0) View.VISIBLE else View.GONE

        val engine = if (VmEngine.isAvailable) {
            getString(R.string.engine_ok, VmEngine.version())
        } else {
            getString(R.string.engine_missing)
        }
        val tag = VmConstants.DEFAULT_IMAGE_TAG
        val image = getString(
            if (imageProvider.isReady(tag)) R.string.image_ready else R.string.image_missing
        )
        val recommended = lastReport?.recommended?.displayName ?: getString(R.string.backend_not_probed)
        val deviceLine = getString(
            R.string.device_line_fmt,
            deviceReport.abi,
            deviceReport.totalMemMb,
            deviceReport.freeStorageMb,
            deviceReport.glesVersion.ifBlank { "?" }
        )
        binding.engineStatus.text = getString(R.string.status_fmt, engine, tag, image) +
            "\n" + getString(R.string.status_backend_fmt, VmBackend.ACTIVE.displayName, recommended) +
            "\n" + deviceLine
    }

    private fun createVm() {
        val versions = VmGuestCatalog.ALL
        if (versions.isEmpty()) {
            toast(getString(R.string.err_no_image, VmConstants.DEFAULT_IMAGE_TAG))
            return
        }

        // 创建流程：先选系统版本，再选模拟机型。
        if (versions.size > 1) {
            val labels = versions.map { image ->
                val state = getString(
                    if (imageProvider.isReady(image.tag)) R.string.version_ready
                    else R.string.version_need_download
                )
                getString(
                    R.string.version_item_fmt,
                    image.displayName, image.apiLevel, image.zipMb, state
                )
            }.toTypedArray()

            AlertDialog.Builder(this)
                .setTitle(R.string.pick_guest_version)
                .setItems(labels) { _, which -> pickDevice(versions[which]) }
                .setNegativeButton(R.string.action_cancel, null)
                .show()
        } else {
            // 只有一个系统版本：系统已确定，直接进入机型选择。
            pickDevice(versions.first())
        }
    }

    /** 第二步：选模拟机型（写进实例自己那份 product.img 的设备身份）。 */
    private fun pickDevice(image: VmGuestImage) {
        val profiles = VmDeviceCatalog.ALL
        val labels = ArrayList<String>(profiles.size + 1)
        labels.add(getString(R.string.device_default_fmt, VmDeviceCatalog.default.displayName))
        profiles.forEach { labels.add(getString(R.string.device_item_fmt, it.displayName, it.model)) }

        AlertDialog.Builder(this)
            .setTitle(R.string.pick_device)
            .setItems(labels.toTypedArray()) { _, which ->
                createVmWithImage(image, if (which == 0) null else profiles[which - 1].id)
            }
            .setNegativeButton(R.string.action_cancel, null)
            .show()
    }

    /**
     * 建实例。选了机型时要复制一份 200MB+ 的 product.img 并改写身份，是重 IO，
     * 因此放后台线程并显示进度。
     */
    private fun createVmWithImage(image: VmGuestImage, deviceProfileId: String? = null) {
        if (!busy.compareAndSet(false, true)) return

        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.action_create)
            .setMessage(
                if (deviceProfileId != null) R.string.device_applying else R.string.preparing_instance
            )
            .setCancelable(false)
            .show()

        Thread {
            val info = repository.create(imageTag = image.tag, deviceProfileId = deviceProfileId)
            // 选了机型却拿不到实例 product/system 镜像，说明复制或改写失败（会回落到默认身份）
            val applied = info != null && (deviceProfileId == null ||
                (diskStore.productImage(info.vmId).exists() &&
                    diskStore.systemImage(info.vmId).exists()))
            runOnUiThread {
                dialog.dismiss()
                busy.set(false)
                if (info == null) {
                    toast(getString(R.string.err_limit, VmConstants.MAX_INSTANCES))
                } else {
                    toast(getString(R.string.created_fmt, info.name))
                    if (!applied) toast(getString(R.string.device_apply_fail))
                    refresh()
                }
            }
        }.start()
    }

    /** 启动前先确保该实例所用版本的镜像就绪。 */
    private fun startVm(info: VmInfo) {
        if (!VmEngine.isAvailable) {
            toast(getString(R.string.err_no_engine))
            return
        }
        ensureImageThen(info.imageTag) { doStartVm(info) }
    }

    private fun doStartVm(info: VmInfo) {
        // 网络自动准备：首次启动自动引导 VPN 授权（之后系统记住，无需再点按钮）。
        prepareNetworkIfNeeded()
        when (VmLauncher.start(this, info, imageProvider, diskStore)) {
            VmLauncher.Result.Started -> {
                VmRuntime.markRunning(info.vmId)
                refresh()
            }

            VmLauncher.Result.NoEngine -> toast(getString(R.string.err_no_engine))
            VmLauncher.Result.NoImage -> toast(getString(R.string.err_no_image, info.imageTag))
            VmLauncher.Result.Unsupported -> toast(getString(R.string.err_unsupported))
        }
    }

    private fun showVmMenu(info: VmInfo) {
        val running = VmRuntime.isRunning(info.vmId)
        val labels = listOf(
            getString(if (running) R.string.action_stop else R.string.action_start),
            getString(R.string.action_rename),
            getString(R.string.action_delete)
        )

        AlertDialog.Builder(this)
            .setTitle(info.name)
            .setItems(labels.toTypedArray()) { _, which ->
                when (which) {
                    0 -> if (running) stopVm(info) else startVm(info)
                    1 -> renameVm(info)
                    else -> confirmDelete(info)
                }
            }
            .show()
    }

    private fun stopVm(info: VmInfo) {
        VmLauncher.stop(this, info.vmId)
        VmRuntime.markStopped(info.vmId)
        refresh()
    }

    private fun renameVm(info: VmInfo) {
        val input = EditText(this).apply {
            setText(info.name)
            setSelection(text.length)
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.action_rename)
            .setView(input)
            .setPositiveButton(R.string.action_ok) { _, _ ->
                val name = input.text.toString().trim().ifEmpty { info.name }
                repository.rename(info.vmId, name)
                refresh()
            }
            .setNegativeButton(R.string.action_cancel, null)
            .show()
    }

    private fun confirmDelete(info: VmInfo) {
        AlertDialog.Builder(this)
            .setTitle(info.name)
            .setMessage(R.string.confirm_delete)
            .setPositiveButton(R.string.action_delete) { _, _ ->
                VmRuntime.markStopped(info.vmId)
                repository.delete(info.vmId)
                refresh()
            }
            .setNegativeButton(R.string.action_cancel, null)
            .show()
    }

    // ------------------------------------------------------------------
    // 兼容性提示
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // 版本更新（走 GitHub Releases + gh-proxy 加速）
    // ------------------------------------------------------------------

    private fun checkUpdate() {
        if (!busy.compareAndSet(false, true)) return
        toast(getString(R.string.update_checking))

        Thread {
            val info = VmUpdater.check(this, BuildConfig.VERSION_NAME)
            runOnUiThread {
                busy.set(false)
                if (info == null) {
                    // 已是最新，或者网络失败 —— 两种情况都按"已是最新"回复，不制造焦虑
                    toast(getString(R.string.update_latest, BuildConfig.VERSION_NAME))
                } else {
                    showUpdateDialog(info)
                }
            }
        }.start()
    }

    private fun showUpdateDialog(info: VmUpdater.UpdateInfo) {
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.update_available_title, info.version))
            .setMessage(getString(R.string.update_available_msg, BuildConfig.VERSION_NAME))
            .setPositiveButton(R.string.update_download) { _, _ -> downloadUpdate(info) }
            .setNegativeButton(R.string.update_later, null)
            .show()
    }

    private fun downloadUpdate(info: VmUpdater.UpdateInfo) {
        if (!busy.compareAndSet(false, true)) return

        val bar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progress = 0
        }
        val label = TextView(this).apply {
            text = getString(R.string.update_downloading)
            setPadding(48, 40, 48, 0)
        }
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label)
            addView(bar)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.update_downloading)
            .setView(container)
            .setCancelable(false)
            .show()

        Thread {
            val file = VmUpdater.download(this, info) { done, total ->
                runOnUiThread {
                    if (total > 0) {
                        bar.progress = (done * 1000 / total).toInt()
                        label.text = getString(
                            R.string.update_download_progress,
                            Formatter.formatFileSize(this, done),
                            Formatter.formatFileSize(this, total)
                        )
                    } else {
                        label.text = Formatter.formatFileSize(this, done)
                    }
                }
            }
            runOnUiThread {
                dialog.dismiss()
                busy.set(false)
                if (file == null) {
                    toast(getString(R.string.update_download_fail))
                } else if (!VmUpdater.install(this, file)) {
                    toast(getString(R.string.update_install_fail))
                }
            }
        }.start()
    }

    // ------------------------------------------------------------------
    // 加速能力探测（只收集数据，不切换后端）
    // ------------------------------------------------------------------

    private fun probeBackends() {
        if (!busy.compareAndSet(false, true)) return
        toast(getString(R.string.probe_running))

        Thread {
            val report = VmBackendProbe.probeAll()
            backendStore.save(report)
            // 探测即选择：把「引擎能跑」的推荐后端应用到当前 ACTIVE，
            // 之后启动实例（VmLauncher）会沿用同一逻辑从缓存选出并写入 config。
            VmBackend.ACTIVE = report.recommended
            runOnUiThread {
                busy.set(false)
                lastReport = report
                refresh()
                showReportDialog(report)
            }
        }.start()
    }

    private fun showReportDialog(report: BackendReport) {
        val content = TextView(this).apply {
            text = report.toReportText()
            typeface = Typeface.MONOSPACE
            textSize = 11f
            setPadding(40, 32, 40, 32)
        }
        val scroll = ScrollView(this).apply { addView(content) }

        AlertDialog.Builder(this)
            .setTitle(R.string.probe_title)
            .setView(scroll)
            .setPositiveButton(R.string.action_copy) { _, _ -> copyReport(report.toReportText()) }
            .setNeutralButton(R.string.action_export) { _, _ -> exportReport(report) }
            .setNegativeButton(R.string.action_cancel, null)
            .show()
    }

    private fun copyReport(text: String) {
        val cm = getSystemService(ClipboardManager::class.java)
        cm?.setPrimaryClip(ClipData.newPlainText(getString(R.string.probe_title), text))
        toast(getString(R.string.probe_copied))
    }

    private fun exportReport(report: BackendReport) {
        val file = backendStore.export(report)
        if (file != null) toast(getString(R.string.probe_exported_fmt, file.absolutePath))
        else toast(getString(R.string.probe_export_fail))
    }

    /**
     * 网络自动准备：已授权过就直接拉起 VPN 服务（幂等），否则引导一次系统授权
     * （结果在 [vpnConsent] 回调里记录）。
     */
    private fun prepareNetworkIfNeeded() {
        val sp = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (sp.getBoolean(KEY_NET_READY, false)) {
            startService(Intent(this, VmNetworkService::class.java))
            return
        }
        val consent = VpnService.prepare(this)
        if (consent != null) {
            vpnConsent.launch(consent)
        } else {
            markNetworkReady()
            startService(Intent(this, VmNetworkService::class.java))
        }
    }

    private fun markNetworkReady() {
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit().putBoolean(KEY_NET_READY, true).apply()
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {

        /** 启动时附带该 extra=true，则自动执行一次加速探测（自动化验证用）。 */
        const val EXTRA_AUTO_PROBE = "com.vm.app.extra.AUTO_PROBE"

        /** 启动时附带该 extra=true，则自动执行「一键启动」（自动化验证用）。 */
        const val EXTRA_AUTO_START_VM = "com.vm.app.extra.AUTO_START_VM"

        /** 启动时附带该 extra=true，则自动执行一次「检查更新」（自动化验证用）。 */
        const val EXTRA_AUTO_CHECK_UPDATE = "com.vm.app.extra.AUTO_CHECK_UPDATE"

        private const val PREFS = "vm_host"

        /** VPN 网络是否已授权并可用（启动 VM 时自动准备用）。 */
        private const val KEY_NET_READY = "net_ready"
    }
}
