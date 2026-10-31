package com.vm.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class VmStorageStatsTest {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var imagesRoot: File
    private lateinit var vmsRoot: File
    private lateinit var cacheDir: File

    private val stats: VmStorageStats by lazy {
        VmStorageStats(imagesRoot, vmsRoot, cacheDir)
    }

    @Before
    fun setUp() {
        imagesRoot = temp.newFolder("images")
        vmsRoot = temp.newFolder("vms")
        cacheDir = temp.newFolder("cache")
    }

    /** 写一块定长内容，让字节数可预测。 */
    private fun File.fill(bytes: Int): File = apply {
        if (isDirectory) File(this, "payload.bin").writeBytes(ByteArray(bytes))
        else writeBytes(ByteArray(bytes))
    }

    private fun buildTypicalTree() {
        // 在册镜像 p11_arm64（500KB）+ 孤儿镜像 old_p9（300KB）+ 导入暂存（200KB）
        File(imagesRoot, "p11_arm64").apply { mkdirs() }.fill(500 * 1024)
        File(imagesRoot, "old_p9").apply { mkdirs() }.fill(300 * 1024)
        File(imagesRoot, ".external_x-import").apply { mkdirs() }.fill(200 * 1024)
        // 在册实例 vm_1：数据盘 + 身份副本 + 快照存档 + live 快照 + 日志
        val vm1 = File(vmsRoot, "vm_1").apply { mkdirs() }
        File(vm1, "userdata.img").fill(100 * 1024)
        File(vm1, "metadata.img").fill(10 * 1024)
        File(vm1, "config.json").fill(1 * 1024)
        File(vm1, "product.img").fill(80 * 1024)
        File(vm1, "system.img").fill(70 * 1024)
        File(vm1, "snapshots").apply { mkdirs() }.fill(400 * 1024)
        File(vm1, "vmstate.qcow2").fill(4 * 1024)
        File(vm1, "snapshot.bin").fill(150 * 1024)
        File(vm1, "logs").apply { mkdirs() }.fill(20 * 1024)
        // 孤儿实例 vm_9（index 里没有 9 号）
        File(vmsRoot, "vm_9").apply { mkdirs() }.fill(600 * 1024)
        // 下载残段
        File(cacheDir, "p11_arm64.zip.part").fill(120 * 1024)
        File(cacheDir, "unrelated.tmp").fill(50 * 1024)
    }

    private fun scan() = stats.scan(knownVmIds = setOf(1), knownImageTags = setOf("p11_arm64"))

    // ------------------------------------------------------------------
    // scan：分类与字节账本
    // ------------------------------------------------------------------

    @Test
    fun scanClassifiesEveryTreeIntoKinds() {
        buildTypicalTree()
        val report = scan()

        val kinds = report.entries.map { it.kind }.toSet()
        assertEquals(
            setOf(
                VmStorageKind.IMAGE, VmStorageKind.ORPHAN_IMAGE, VmStorageKind.STAGING,
                VmStorageKind.INSTANCE_DATA, VmStorageKind.INSTANCE_IDENTITY,
                VmStorageKind.INSTANCE_SNAPSHOT, VmStorageKind.INSTANCE_VMSTATE,
                VmStorageKind.INSTANCE_LOGS,
                VmStorageKind.ORPHAN_INSTANCE, VmStorageKind.CACHE_PARTIAL
            ),
            kinds
        )
    }

    @Test
    fun scanAccountsBytesByBucket() {
        buildTypicalTree()
        val report = scan()

        assertEquals(500L * 1024, report.imagesBytes)
        assertEquals(
            // 数据盘 100+10+1 + 身份 80+70 + 快照存档 400 + live/vmstate 4+150 + 日志 20
            (100 + 10 + 1 + 80 + 70 + 400 + 4 + 150 + 20) * 1024L,
            report.instancesBytes
        )
        assertEquals("残段 + 暂存", (120 + 200) * 1024L, report.safeGarbageBytes)
        assertEquals("孤儿实例 + 孤儿镜像", (600 + 300) * 1024L, report.orphanBytes)
    }

    @Test
    fun nonImageCacheFilesAreIgnored() {
        buildTypicalTree()
        // 无关缓存不该被盘点成「可清理」——它不归本应用的业务语义管。
        val names = scan().entries.filter { it.kind == VmStorageKind.CACHE_PARTIAL }.map { it.displayPath }
        assertEquals(listOf("cache/p11_arm64.zip.part"), names)
    }

    @Test
    fun scanOnEmptyRootsIsReportOfNothing() {
        val report = scan()
        assertTrue(report.entries.isEmpty())
        assertEquals(0L, report.imagesBytes)
        assertEquals(0L, report.safeGarbageBytes)
    }

    @Test
    fun reportTextListsRecyclablesOnlyWhenNonZero() {
        val report = scan()
        val text = report.toReportText()
        assertTrue(text.contains("镜像：0 B"))
        assertFalse("没有垃圾时不应列条目", text.contains("·"))

        buildTypicalTree()
        val full = scan().toReportText()
        assertTrue(full.contains("导入暂存"))
        assertTrue(full.contains("孤儿实例目录"))
    }

    // ------------------------------------------------------------------
    // clean：安全边界
    // ------------------------------------------------------------------

    @Test
    fun cleanDryRunCountsButDeletesNothing() {
        buildTypicalTree()
        val report = scan()
        val result = stats.clean(report, dryRun = true)

        assertTrue(result.dryRun)
        assertEquals(2, result.deletedCount)   // 残段 + 暂存
        assertEquals((120 + 200) * 1024L, result.freedBytes)
        assertTrue(File(cacheDir, "p11_arm64.zip.part").isFile)
        assertTrue(File(imagesRoot, ".external_x-import").isDirectory)
    }

    @Test
    fun cleanDefaultsToSafeGarbageOnly() {
        buildTypicalTree()
        val report = scan()
        val result = stats.clean(report)

        assertTrue(result.allSucceeded)
        assertFalse("残段应删除", File(cacheDir, "p11_arm64.zip.part").exists())
        assertFalse("暂存应删除", File(imagesRoot, ".external_x-import").exists())
        // 业务数据一律不动。
        assertTrue(File(imagesRoot, "p11_arm64").isDirectory)
        assertTrue(File(imagesRoot, "old_p9").isDirectory)
        assertTrue(File(vmsRoot, "vm_1").isDirectory)
        assertTrue("孤儿目录默认保留（需用户确认）", File(vmsRoot, "vm_9").isDirectory)
        assertTrue("无关缓存不是本类的事", File(cacheDir, "unrelated.tmp").isFile)
    }

    @Test
    fun cleanWithOrphansRemovesThemAfterConfirmation() {
        buildTypicalTree()
        val report = scan()
        val result = stats.clean(report, includeOrphans = true)

        assertEquals(4, result.deletedCount)
        assertEquals((120 + 200 + 600 + 300) * 1024L, result.freedBytes)
        assertFalse(File(imagesRoot, "old_p9").exists())
        assertFalse(File(vmsRoot, "vm_9").exists())
        // 在册的依旧不动。
        assertTrue(File(vmsRoot, "vm_1").isDirectory)
        assertTrue(File(imagesRoot, "p11_arm64").isDirectory)
    }

    @Test
    fun instanceLogsHaveDedicatedPathNotBulkClean() {
        buildTypicalTree()
        val report = scan()
        val logs = report.entries.single { it.kind == VmStorageKind.INSTANCE_LOGS }
        // 日志是排障证据：不进一键清理（专用路径是 VmLogStore.pruneOlderThanDays），
        // 报告文本也不把它列进「可清理」清单。
        assertFalse(logs.kind.recyclable)
        assertFalse(report.toReportText().contains("vm_1/logs"))

        stats.clean(report, includeOrphans = true)
        assertTrue("任何档位的一键清理都不动日志", File(vmsRoot, "vm_1/logs").isDirectory)
    }

    // ------------------------------------------------------------------
    // 展示辅助
    // ------------------------------------------------------------------

    @Test
    fun humanBytesUses1024Progression() {
        assertEquals("0 B", VmStorageStats.humanBytes(0))
        assertEquals("512 B", VmStorageStats.humanBytes(512))
        assertEquals("1.0 KB", VmStorageStats.humanBytes(1024))
        assertEquals("1.5 KB", VmStorageStats.humanBytes(1024 + 512))
        assertEquals("1.0 MB", VmStorageStats.humanBytes(1024L * 1024))
        assertEquals("4.0 GB", VmStorageStats.humanBytes(4L * 1024 * 1024 * 1024))
    }
}
