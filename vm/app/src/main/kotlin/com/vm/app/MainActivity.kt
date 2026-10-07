package com.vm.app

import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Bundle
import android.text.format.Formatter
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import com.vm.app.databinding.ActivityMainBinding
import com.vm.app.net.VmNetworkService
import com.vm.core.VmConstants
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

        adapter = VmAdapter(
            onClick = { startVm(it) },
            onLongClick = { showVmMenu(it) }
        )
        binding.vmList.layoutManager = LinearLayoutManager(this)
        binding.vmList.adapter = adapter

        binding.btnOneClick.setOnClickListener { oneClickStart() }
        binding.fabCreate.setOnClickListener { createVm() }
        binding.btnNetwork.setOnClickListener { prepareNetwork() }
        binding.btnExtract.setOnClickListener { importLocalImage() }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    // ------------------------------------------------------------------
    // 一键启动
    // ------------------------------------------------------------------

    private fun oneClickStart() {
        if (!VmEngine.isAvailable) {
            toast(getString(R.string.err_no_engine))
            return
        }
        startOrCreate()
    }

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
        binding.engineStatus.text = getString(R.string.status_fmt, engine, tag, image)
    }

    private fun createVm() {
        val versions = VmGuestCatalog.ALL
        if (versions.isEmpty()) {
            toast(getString(R.string.err_no_image, VmConstants.DEFAULT_IMAGE_TAG))
            return
        }

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
            .setItems(labels) { _, which -> createVmWithImage(versions[which]) }
            .setNegativeButton(R.string.action_cancel, null)
            .show()
    }

    private fun createVmWithImage(image: VmGuestImage) {
        val info = repository.create(imageTag = image.tag)
        if (info == null) {
            toast(getString(R.string.err_limit, VmConstants.MAX_INSTANCES))
            return
        }
        toast(getString(R.string.created_fmt, info.name))
        refresh()
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

    private fun prepareNetwork() {
        val consent = VpnService.prepare(this)
        if (consent != null) {
            vpnConsent.launch(consent)
        } else {
            startService(Intent(this, VmNetworkService::class.java))
            toast(getString(R.string.network_started))
        }
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }
}
