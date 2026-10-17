package com.vm.core

import android.content.Context
import java.io.File

/**
 * 探测报告的持久化与导出。
 *
 * - 落盘 `files/backend/report.json`：下次进入应用可直接读缓存展示，避免每次重探；
 * - 导出人类可读文本到应用外部文件目录：便于在多台真实设备上收集后端可用性
 *   （`adb pull` 或分享），这正是本框架当前要收集的核心数据。
 */
class VmBackendStore(context: Context) {

    private val appContext = context.applicationContext
    private val reportFile = File(appContext.filesDir, "backend/report.json")

    fun save(report: BackendReport) {
        runCatching {
            reportFile.parentFile?.mkdirs()
            reportFile.writeText(report.toJson())
        }
    }

    fun load(): BackendReport? = runCatching {
        if (!reportFile.exists()) null else BackendReport.fromJson(reportFile.readText())
    }.getOrNull()

    /** 导出人类可读报告；返回导出文件，失败返回 null。 */
    fun export(report: BackendReport): File? = runCatching {
        val dir = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        val out = File(dir, "backend_report.txt")
        out.writeText(report.toReportText())
        out
    }.getOrNull()
}
