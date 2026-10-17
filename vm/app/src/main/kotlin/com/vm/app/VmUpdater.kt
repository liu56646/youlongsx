package com.vm.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * 版本检查与自更新（走 GitHub Releases）。
 *
 * 为什么用 `version.txt` 资产而不是 GitHub API：
 *   - `api.github.com` 在国内经常连不上，匿名请求还有频率限制；
 *   - Release 资产里的 `version.txt` 是纯文本，经 gh-proxy 加速后一次 GET 就能拿到，
 *     省掉 JSON / 重定向解析的坑。
 *
 * 约定：发布时 Release 里除了 APK 和镜像，还要放一个 `version.txt`（内容就是 versionName）。
 */
object VmUpdater {

    private const val REPO = "liu56646/youlong-sandbox"

    /** 国内加速前缀；置空则走 GitHub 直连。 */
    private const val PROXY = "https://gh-proxy.org/"

    /** release 资产基址（latest 永远指向最新一版）。 */
    private val BASE = PROXY + "https://github.com/" + REPO + "/releases/latest/download"

    data class UpdateInfo(
        val version: String,
        val apkUrl: String
    )

    /**
     * 查最新版本。
     * 返回 null 表示：已是最新，或者网络/解析失败 —— 两种情况都不打扰用户。
     */
    fun check(context: Context, currentVersion: String): UpdateInfo? {
        val latest = runCatching { httpGetText("$BASE/version.txt") }
            .getOrNull()?.trim()?.takeIf { it.isNotEmpty() } ?: return null

        if (!isNewer(latest, currentVersion)) return null

        // APK 命名约定：youlong-sandbox-<version>.apk
        // （0.1.0 用的是 -debug 后缀，这里保留兼容，老 Release 仍可被识别。）
        val apk = "$BASE/youlong-sandbox-$latest.apk"
        return UpdateInfo(latest, apk)
    }

    /** 下载新版本 APK 到 cacheDir/update/。失败返回 null。 */
    fun download(
        context: Context,
        info: UpdateInfo,
        onProgress: (downloaded: Long, total: Long) -> Unit
    ): File? {
        val dir = File(context.cacheDir, "update").apply { mkdirs() }
        val out = File(dir, "youlong-sandbox-${info.version}.apk")
        return runCatching {
            httpDownload(info.apkUrl, out, onProgress)
            out
        }.getOrNull()
    }

    /** 调起系统安装器。需要调用方确保已声明 REQUEST_INSTALL_PACKAGES 与 FileProvider。 */
    fun install(context: Context, apk: File): Boolean = runCatching {
        val uri: Uri = FileProvider.getUriForFile(
            context,
            context.packageName + ".fileprovider",
            apk
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    }.getOrDefault(false)

    // ------------------------------------------------------------------
    // 内部工具
    // ------------------------------------------------------------------

    /** 版本比较：按点号分段做数值比较（0.1.0 vs 0.2.0）。 */
    private fun isNewer(latest: String, current: String): Boolean {
        val a = latest.split('.').mapNotNull { it.trim().toIntOrNull() }
        val b = current.split('.').mapNotNull { it.trim().toIntOrNull() }
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    private fun httpGetText(url: String): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30000
            readTimeout = 30000
            instanceFollowRedirects = true
        }
        return try {
            conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    private fun httpDownload(
        url: String,
        out: File,
        onProgress: (Long, Long) -> Unit
    ) {
        /*
         * 超时放宽（实测）：经 gh-proxy 下载 33MB 的 APK 约需 65 秒，
         * 其中"代理首次回源"就可能超过 15 秒。之前 connectTimeout=15s
         * 会导致连接阶段直接失败，表现为"下载失败"但日志里什么都没有。
         */
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30000
            readTimeout = 180000
            instanceFollowRedirects = true
        }
        try {
            val total = conn.contentLengthLong
            conn.inputStream.use { input ->
                out.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    var done = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        done += n
                        onProgress(done, total)
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
    }
}
