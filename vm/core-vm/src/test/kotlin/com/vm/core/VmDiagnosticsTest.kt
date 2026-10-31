package com.vm.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.zip.ZipFile

class VmDiagnosticsTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun readEntry(zip: File, name: String): ByteArray =
        ZipFile(zip).use { zf ->
            val entry = zf.getEntry(name) ?: error("zip 里没有 $name：${zf.entries().toList().map { it.name }}")
            zf.getInputStream(entry).use { it.readBytes() }
        }

    private fun entryNames(zip: File): List<String> =
        ZipFile(zip).use { zf -> zf.entries().toList().map { it.name } }

    // ------------------------------------------------------------------
    // 打包与清单
    // ------------------------------------------------------------------

    @Test
    fun buildPacksSectionsWithStableOrderAndManifest() {
        val bigLog = temp.newFile("console.log").apply {
            writeText((1..30_000).joinToString("\n") { "line $it" })
        }
        val config = temp.newFile("config.json").apply { writeText("""{"vmId":1}""") }

        val target = File(temp.root, "diag.zip")
        val built = VmDiagnostics.builder()
            .addText("intro", "诊断包说明")
            .addJson("meta", """{"a":1}""")
            .addFile("vm1_config", config)
            .addFileTail("vm1_console", bigLog, tailBytes = 10_000)
            .build(target, generatedAt = 1_760_000_000_000L)

        assertNotNull(built)
        assertEquals(target, built)
        assertEquals(
            listOf(
                "01_intro.txt", "02_meta.json", "03_vm1_config.json",
                "04_vm1_console.log", "manifest.json"
            ),
            entryNames(built!!).sorted()
        )

        val manifest = JSONObject(readEntry(built, "manifest.json").decodeToString())
        assertEquals(VmDiagnostics.MANIFEST_FORMAT, manifest.getString("format"))
        assertEquals(1_760_000_000_000L, manifest.getLong("generatedAt"))
        val sections = manifest.getJSONArray("sections")
        assertEquals(4, sections.length())
        assertEquals("01_intro.txt", sections.getJSONObject(0).getString("entry"))
        assertEquals("ok", sections.getJSONObject(0).getString("status"))
    }

    @Test
    fun emptyBuilderProducesNothing() {
        assertNull(VmDiagnostics.builder().build(File(temp.root, "empty.zip")))
        assertFalse(File(temp.root, "empty.zip").exists())
    }

    @Test
    fun missingOptionalFileIsRecordedNotFatal() {
        val target = File(temp.root, "diag.zip")
        val built = VmDiagnostics.builder()
            .addText("alive", "我在")
            .addFile("ghost", File(temp.root, "不存在的文件"))
            .build(target)

        assertNotNull("缺一节不影响整包", built)
        val manifest = JSONObject(readEntry(built!!, "manifest.json").decodeToString())
            .getJSONArray("sections")
        assertEquals("ok", manifest.getJSONObject(0).getString("status"))
        assertEquals("missing", manifest.getJSONObject(1).getString("status"))
        assertEquals("打包里不应有幽灵节", listOf("01_alive.txt", "manifest.json"), entryNames(built).sorted())
    }

    // ------------------------------------------------------------------
    // 尾部截取
    // ------------------------------------------------------------------

    @Test
    fun tailSectionKeepsOnlyRecentBytesAndDropsPartialLine() {
        val lines = (1..5000).joinToString("\n") { "row-$it" }
        val log = temp.newFile("big.log").apply { writeText(lines) }

        val target = File(temp.root, "diag.zip")
        VmDiagnostics.builder()
            .addFileTail("recent", log, tailBytes = 5_000)
            .build(target)

        val content = readEntry(target, "01_recent.log").decodeToString()
        assertTrue("应从残行之后开始：$content", content.startsWith("row-"))
        val firstNo = content.substringBefore('\n').removePrefix("row-").toInt()
        // 文件 ~40KB，尾部 5000 字节 ≈ 最后 600 行：截断点前的整块都被丢弃。
        assertTrue("只保留尾部：首行 row-$firstNo", firstNo > 4000)
        // 截断点落在某行中间时，那一行被丢弃 → 首尾都是完整行。
        assertEquals("row-5000", content.trimEnd().substringAfterLast('\n'))
        assertTrue(content.length <= 5_000)
    }

    @Test
    fun tailOfSmallFileIsEverything() {
        val log = temp.newFile("small.log").apply { writeText("only-line\n") }
        val target = File(temp.root, "diag.zip")
        VmDiagnostics.builder().addFileTail("small", log).build(target)
        assertEquals("only-line\n", readEntry(target, "01_small.log").decodeToString())
    }

    // ------------------------------------------------------------------
    // 节名与健壮性
    // ------------------------------------------------------------------

    @Test
    fun sectionNamesAreSanitized() {
        val target = File(temp.root, "diag.zip")
        VmDiagnostics.builder()
            .addText("events/vm 1", "x")
            .build(target)
        // 非法字符（空格 / 斜杠）归一成下划线，防 zip 路径问题与乱码。
        assertEquals(listOf("01_events_vm_1.txt", "manifest.json"), entryNames(target).sorted())
    }

    @Test
    fun invalidSectionNameIsRejectedEagerly() {
        val builder = VmDiagnostics.builder()
        var rejected = false
        try {
            builder.addText("///", "x")
        } catch (e: IllegalArgumentException) {
            rejected = true
        }
        assertTrue("清洗后为空的节名应立即拒绝", rejected)
        assertEquals("失败的名节不进入清单", 0, builder.sectionCount())
    }

    @Test
    fun deviceCheckSectionSerializesFullReport() {
        val report = VmDeviceCheck.Report(
            abi = "arm64-v8a", abiOk = true,
            totalMemMb = 11_000, availMemMb = 4_000, suggestedGuestMemMb = 3072,
            freeStorageMb = 90_000, glesVersion = "3.2",
            problems = listOf("问题A"), warnings = listOf("提醒B")
        )
        val target = File(temp.root, "diag.zip")
        VmDiagnostics.builder().addDeviceCheck(report).build(target)

        val json = JSONObject(readEntry(target, "01_device.json").decodeToString())
        assertEquals("arm64-v8a", json.getString("abi"))
        assertEquals(3072, json.getInt("suggestedGuestMemMb"))
        assertEquals("问题A", json.getJSONArray("problems").getString(0))
        assertEquals("提醒B", json.getJSONArray("warnings").getString(0))
    }

    @Test
    fun storageReportSectionIsHumanReadable() {
        val report = VmStorageReport(
            entries = listOf(
                VmStorageEntry(VmStorageKind.IMAGE, "images/p11_arm64", 500L * 1024, "基础镜像"),
                VmStorageEntry(VmStorageKind.STAGING, "images/.x-import", 200L * 1024, "导入暂存目录")
            )
        )
        val target = File(temp.root, "diag.zip")
        VmDiagnostics.builder().addStorageReport(report).build(target)

        val text = readEntry(target, "01_storage.txt").decodeToString()
        assertTrue(text.contains("镜像：500.0 KB"))
        assertTrue(text.contains("导入暂存"))
    }
}
