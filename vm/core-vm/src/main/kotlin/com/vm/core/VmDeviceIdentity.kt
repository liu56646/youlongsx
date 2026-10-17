package com.vm.core

import android.util.Log
import java.io.File
import java.io.RandomAccessFile

/**
 * 把 [VmDeviceProfile] 写进某个分区镜像的 build.prop（product.img / system.img）。
 *
 * 设计要点（真机镜像实测，见 docs/方案B排障交接.md）：
 *  - product.img 的 `/build.prop`（937B）与 system.img 的 `/system/build.prop`（2208B）
 *    都是**单 extent、连续、明文**，且所在 4KB 块内还有富余；
 *  - build.prop 里形如 `# begin <x> build properties` … `# end <x> build properties`
 *    的段，就是身份字段所在；
 *  - 所以这里**不做任何 ext4 解析**：搜索段标记，在**段内原地重写并用 `#` 注释补足**，
 *    段长保持不变 ⇒ 文件大小 / extent / inode 全都不变，天然不破坏文件系统，
 *    也不需要 root 或外部工具。
 *
 * 同一份规则同时适用于两个分区：product 段里是 `ro.product.product.*`，
 * system 段里是 `ro.product.system.*` / `ro.system.build.*` / `ro.build.*`。
 */
object VmDeviceIdentity {

    private const val TAG = "VmDeviceIdentity"
    private const val BEGIN_MARK = "# begin "
    private const val END_MARK = "# end "

    /** 段查找窗口：build.prop 只有 1–2KB，64KB 足够覆盖全部段。 */
    private const val WINDOW = 64 * 1024

    /**
     * 就地把 [profile] 应用到分区镜像 [image]（product.img 或 system.img）。
     *
     * @return 成功与否。失败时镜像保持原样（只在全部校验通过后才落笔）。
     */
    fun applyToImage(image: File, profile: VmDeviceProfile): Boolean {
        if (!image.isFile || image.length() == 0L) {
            Log.e(TAG, "镜像不存在或为空：$image")
            return false
        }
        return try {
            RandomAccessFile(image, "rw").use { raf ->
                val anchor = findNeedle(raf, BEGIN_MARK.toByteArray(Charsets.ISO_8859_1))
                if (anchor == null) {
                    return applyUnmarkedBuildProps(raf, image, profile)
                }
                raf.seek(anchor)
                val win = ByteArray(WINDOW)
                val n = raf.read(win)
                if (n <= 0) return false
                val text = String(win, 0, n, Charsets.ISO_8859_1)
                val imageRelease = imageReleaseOf(text)

                var cursor = 0
                var segCount = 0
                while (true) {
                    val b = text.indexOf(BEGIN_MARK, cursor)
                    if (b < 0) break
                    val e = text.indexOf(END_MARK, b + BEGIN_MARK.length)
                    if (e < 0) break
                    val nl = text.indexOf('\n', e)
                    val segEnd = if (nl < 0) text.length else nl + 1

                    val oldSeg = text.substring(b, segEnd)
                    if (looksLikeBuildProps(oldSeg)) {
                        val newSeg = rewriteSegment(oldSeg, profile, imageRelease)
                        if (newSeg.length > oldSeg.length) {
                            Log.w(TAG, "${image.name}：段变长，跳过（${newSeg.length} > ${oldSeg.length}）")
                        } else {
                            val out = newSeg + padding(oldSeg.length - newSeg.length)
                            raf.seek(anchor + b)
                            raf.write(out.toByteArray(Charsets.ISO_8859_1))
                            segCount++
                        }
                    }
                    cursor = segEnd
                }

                // p13 的 system build.prop 顶部还有 ro.product.system.* 和
                // ro.system.build.fingerprint，它们不在 # begin 段内。文件头
                // 存在时再做一次整文件同长度改写，覆盖段外字段。
                val headerNeedle =
                    "# from generate-common-build-props"
                        .toByteArray(Charsets.ISO_8859_1)
                if (findNeedle(raf, headerNeedle) != null &&
                    applyUnmarkedBuildProps(raf, image, profile)
                ) {
                    return true
                }

                if (segCount == 0) {
                    Log.e(TAG, "${image.name}：没有可改写的身份段")
                    return false
                }
                raf.fd.sync()
                Log.i(TAG, "${image.name}：设备身份已写入 ${profile.displayName}（$segCount 段）")
                true
            }
        } catch (t: Throwable) {
            Log.e(TAG, "改写 ${image.name} 失败", t)
            false
        }
    }

    /**
     * p13 的 product.img 里 build.prop 没有 p11 那种 `# begin` 段标记。
     *
     * 这里从 build.prop 文件头开始读一个窗口，逐行改写身份字段，并用
     * 文件头部的 `#` 注释行补齐/缩短到原始字节数。文件大小、extent 和
     * 后续字节都不变，因此不需要解析 ext4，也不会破坏分区。
     */
    private fun applyUnmarkedBuildProps(
        raf: RandomAccessFile,
        image: File,
        profile: VmDeviceProfile
    ): Boolean {
        val headerNeedle =
            "# from generate-common-build-props".toByteArray(Charsets.ISO_8859_1)
        val headerOffset = findNeedle(raf, headerNeedle) ?: run {
            Log.e(TAG, "${image.name}：找不到 build.prop 文件头")
            return false
        }

        // 文件头形如：
        //   ####################################
        //   # from generate-common-build-props
        // 从 header 往前扫描连续 '#'，得到第一行的起点。
        var pos = headerOffset - 1
        if (pos >= 0) pos-- // 跳过 header 行前的换行
        while (pos >= 0) {
            raf.seek(pos)
            if (raf.read() != '#'.code) break
            pos--
        }
        val fileStart = pos + 1
        val maxWindow = 64 * 1024
        val windowLen = minOf(
            maxWindow.toLong(),
            (raf.length() - fileStart).coerceAtLeast(0L)
        ).toInt()
        if (windowLen <= 0) return false

        val window = ByteArray(windowLen)
        raf.seek(fileStart)
        var read = 0
        while (read < windowLen) {
            val n = raf.read(window, read, windowLen - read)
            if (n <= 0) break
            read += n
        }
        if (read <= 0) return false

        var contentEnd = window.indexOf(0.toByte())
        if (contentEnd < 0) {
            // 文件后面不是零填充时，找到第一段非 ASCII 文本的位置。
            val textEnd = window.indexOfFirst {
                it < 0x09 || (it > 0x0D && it < 0x20) || it > 0x7E
            }.let { if (it < 0) window.size else it }
            var lastNl = -1
            for (i in textEnd - 1 downTo 0) {
                if (window[i] == '\n'.code.toByte()) {
                    lastNl = i
                    break
                }
            }
            contentEnd = if (lastNl >= 0) lastNl + 1 else textEnd
        }
        if (contentEnd <= 0) return false

        val original = String(window, 0, contentEnd, Charsets.ISO_8859_1)
        val imageRelease = imageReleaseOf(original)
        val rewritten = StringBuilder(original.length)
        var lineStart = 0
        while (lineStart < original.length) {
            val nl = original.indexOf('\n', lineStart)
            val lineEnd = if (nl < 0) original.length else nl
            rewritten.append(
                rewriteUnmarkedLine(
                    original.substring(lineStart, lineEnd),
                    profile,
                    imageRelease
                )
            )
            if (nl < 0) break
            rewritten.append('\n')
            lineStart = nl + 1
        }

        var text = rewritten.toString()
        val delta = text.length - original.length
        if (delta < 0) {
            val firstNl = text.indexOf('\n')
            if (firstNl < 0) return false
            text = text.substring(0, firstNl) +
                "#".repeat(-delta) +
                text.substring(firstNl)
        } else if (delta > 0) {
            val firstNl = text.indexOf('\n')
            if (firstNl < 0) return false
            val first = text.substring(0, firstNl)
            val remove = minOf(delta, first.length)
            if (remove <= 0) return false
            val shortened = first.dropLast(remove)
            if (!shortened.startsWith("#")) return false
            text = shortened + text.substring(firstNl)
        }
        if (text.length != original.length) {
            Log.w(TAG, "${image.name}：build.prop 无法保持原长度，跳过")
            return false
        }

        raf.seek(fileStart)
        raf.write(text.toByteArray(Charsets.ISO_8859_1))
        raf.fd.sync()
        Log.i(TAG, "${image.name}：build.prop 身份已写入 ${profile.displayName}")
        return true
    }

    private fun rewriteUnmarkedLine(
        line: String,
        p: VmDeviceProfile,
        imageRelease: String?
    ): String {
        val eq = line.indexOf('=')
        if (eq <= 0) return line
        val key = line.substring(0, eq)
        val current = line.substring(eq + 1)
        val value = newValue(key, current, p, imageRelease) ?: return line
        return "$key=$value"
    }

    /** 段内必须真有属性行，避免误改镜像里别的相似文本。 */
    private fun looksLikeBuildProps(seg: String): Boolean =
        seg.contains("=") && seg.contains("ro.")

    /**
     * 逐行替换身份字段。若替换后段变长，则进一步丢弃段内的注释行/空行来腾空间
     * （`# begin`/`# end` 必须保留，它们是下次改写的锚点）。
     */
    private fun rewriteSegment(
        seg: String,
        p: VmDeviceProfile,
        imageRelease: String?
    ): String {
        val lines = ArrayList<String>()
        var i = 0
        while (i < seg.length) {
            val nl = seg.indexOf('\n', i)
            val lineEnd = if (nl < 0) seg.length else nl
            lines.add(seg.substring(i, lineEnd))
            i = if (nl < 0) seg.length else nl + 1
        }

        val replaced = lines.map { rewriteLine(it, p, imageRelease) }
        val sb = StringBuilder(seg.length)
        replaced.forEach { sb.append(it).append('\n') }
        if (sb.length <= seg.length) return sb.toString()

        // 还是太长：丢掉注释行与空行（只保留 begin/end 锚点与属性行）再试
        val sb2 = StringBuilder(seg.length)
        replaced.forEach { line ->
            val t = line.trim()
            val drop = t.isEmpty() ||
                (t.startsWith("#") && !t.startsWith("# begin") && !t.startsWith("# end"))
            if (!drop) sb2.append(line).append('\n')
        }
        return sb2.toString()
    }

    private fun rewriteLine(
        line: String,
        p: VmDeviceProfile,
        imageRelease: String?
    ): String {
        val eq = line.indexOf('=')
        if (eq <= 0) return line
        val key = line.substring(0, eq)
        val current = line.substring(eq + 1)
        val v = newValue(key, current, p, imageRelease) ?: return line
        return "$key=$v"
    }

    private val releaseRegex =
        Regex("(?m)^ro\\.[^=\\n]*build\\.version\\.release=(\\d+)")

    private fun imageReleaseOf(text: String): String? =
        releaseRegex.find(text)?.groupValues?.get(1)

    private fun profileRelease(p: VmDeviceProfile): String? =
        Regex(":(\\d+)/").find(p.fingerprint)?.groupValues?.get(1)

    /**
     * profile 的 fingerprint 带自己的 Android 版本。镜像版本与 profile 版本
     * 不一致时（典型：p13 镜像 + p11 机型目录），保留镜像的版本/build ID 后缀，
     * 只把前缀换成目标机型，避免 Android 13 系统挂 Android 11 fingerprint。
     */
    private fun adaptFingerprint(current: String, p: VmDeviceProfile): String {
        val colon = current.indexOf(':')
        if (colon < 0) return p.fingerprint
        return "${p.brand}/${p.name}/${p.device}${current.substring(colon)}"
    }

    /**
     * 身份字段的取值规则。只覆盖**机型相关**字段：
     * 品牌/设备/厂商/型号/名（各分区）、fingerprint、build.id。
     * 刻意**不改** release / sdk —— 声明版本与真实框架版本必须一致。
     */
    private fun newValue(
        key: String,
        current: String,
        p: VmDeviceProfile,
        imageRelease: String?
    ): String? {
        val versionMismatch =
            imageRelease != null &&
                profileRelease(p) != null &&
                imageRelease != profileRelease(p)

        return when {
            key.startsWith("ro.product.") && key.endsWith(".brand") -> p.brand
            key.startsWith("ro.product.") && key.endsWith(".device") -> p.device
            key.startsWith("ro.product.") && key.endsWith(".manufacturer") -> p.manufacturer
            key.startsWith("ro.product.") && key.endsWith(".model") -> p.model
            key.startsWith("ro.product.") && key.endsWith(".name") -> p.name
            key.endsWith(".build.fingerprint") ->
                if (versionMismatch) adaptFingerprint(current, p) else p.fingerprint
            key == "ro.build.id" || key.endsWith(".build.id") ->
                if (versionMismatch) null else p.buildId
            else -> null
        }
    }

    /**
     * 生成恰好 [len] 字节的注释填充（保持段总长不变）。
     *
     * 尾部必须落在换行上：否则最后一个 `#` 会与**下一段**的首字符黏连，
     * 把 `# begin build properties` 写成 `## begin build properties`。
     */
    private fun padding(len: Int): String {
        if (len <= 0) return ""
        val sb = StringBuilder(len)
        if (len % 2 == 1) sb.append('#')
        repeat(len / 2) { sb.append("#\n") }
        return sb.toString()
    }

    // ---------------------------------------------------------------- 字节搜索

    /** 在 [raf] 中流式查找 [needle]，返回其绝对偏移；找不到返回 null。 */
    private fun findNeedle(raf: RandomAccessFile, needle: ByteArray): Long? {
        val chunk = 1 shl 20
        val buf = ByteArray(chunk)
        val carry = ByteArray(needle.size - 1)
        var carryLen = 0
        var pos = 0L

        raf.seek(0)
        while (true) {
            val n = raf.read(buf)
            if (n <= 0) return null
            val hay = ByteArray(carryLen + n)
            System.arraycopy(carry, 0, hay, 0, carryLen)
            System.arraycopy(buf, 0, hay, carryLen, n)

            val idx = indexOfBytes(hay, needle)
            if (idx >= 0) return pos - carryLen + idx

            carryLen = minOf(carry.size, hay.size)
            System.arraycopy(hay, hay.size - carryLen, carry, 0, carryLen)
            pos += n
        }
    }

    private fun indexOfBytes(hay: ByteArray, needle: ByteArray): Int {
        if (needle.isEmpty() || hay.size < needle.size) return -1
        val last = hay.size - needle.size
        outer@ for (i in 0..last) {
            for (j in needle.indices) {
                if (hay[i + j] != needle[j]) continue@outer
            }
            return i
        }
        return -1
    }
}
