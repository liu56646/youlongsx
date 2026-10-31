package com.vm.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class VmSnapshotStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val vmsRoot: File by lazy { temp.newFolder("vms") }

    private fun store(running: (Int) -> Boolean = { false }): VmSnapshotStore =
        VmSnapshotStore(vmsRoot, running)

    /** 造一份 live 快照（引擎退出时写出的那份），返回其内容指纹。 */
    private fun seedLive(vmId: Int, payload: String = "SNAPSHOT-A"): File {
        val dir = File(vmsRoot, "vm_$vmId").apply { mkdirs() }
        return File(dir, "snapshot.bin").apply { writeText(payload) }
    }

    @After
    fun resetClock() {
        VmSnapshotStore.now = { System.currentTimeMillis() }
    }

    // ------------------------------------------------------------------
    // save
    // ------------------------------------------------------------------

    @Test
    fun saveRejectedWithoutLiveSnapshot() {
        assertEquals(VmSnapshotStore.SaveResult.NoLiveSnapshot, store().save(1, "存档"))
    }

    @Test
    fun saveRejectedWhileVmRunning() {
        seedLive(1)
        val result = store(running = { true }).save(1, "存档")
        assertTrue("运行中必须拒绝：$result", result is VmSnapshotStore.SaveResult.VmRunning)
    }

    @Test
    fun saveCopiesPayloadAndRecordsMetadata() {
        seedLive(1, "SNAPSHOT-A")
        VmSnapshotStore.now = { 1_000L }
        val result = store().save(1, "打完第一章", note = "手动存档")
        assertTrue("应保存成功：$result", result is VmSnapshotStore.SaveResult.Saved)
        val saved = (result as VmSnapshotStore.SaveResult.Saved).snapshot

        assertEquals(1_000L, saved.createdAt)
        assertEquals("SNAPSHOT-A".length.toLong(), saved.sizeBytes)
        val payload = File(File(vmsRoot, "vm_1/snapshots"), "${saved.id}/snapshot.bin")
        assertEquals("SNAPSHOT-A", payload.readText())
        assertEquals("元数据与载荷一致", listOf(saved), store().list(1))
    }

    @Test
    fun duplicateNamesGetSuffix() {
        seedLive(1)
        val s = store()
        s.save(1, "存档")
        VmSnapshotStore.now = { 2_000L }
        val second = s.save(1, "存档") as VmSnapshotStore.SaveResult.Saved
        assertEquals("存档 (2)", second.snapshot.name)
        assertEquals(2, s.list(1).size)
    }

    @Test
    fun blankNameFallsBackToDefault() {
        seedLive(1)
        val result = store().save(1, "   ") as VmSnapshotStore.SaveResult.Saved
        assertEquals("未命名存档", result.snapshot.name)
    }

    // ------------------------------------------------------------------
    // list / 对账
    // ------------------------------------------------------------------

    @Test
    fun listIsNewestFirstWithLivePayloadState() {
        seedLive(1)
        val s = store()
        VmSnapshotStore.now = { 1_000L }
        val old = s.save(1, "旧") as VmSnapshotStore.SaveResult.Saved
        VmSnapshotStore.now = { 2_000L }
        val new = s.save(1, "新") as VmSnapshotStore.SaveResult.Saved
        // 外部删掉新存档的载荷（模拟系统清理），list 应如实标记。
        File(File(vmsRoot, "vm_1/snapshots"), "${new.snapshot.id}/snapshot.bin").delete()

        val listed = s.list(1)
        assertEquals(listOf("新", "旧"), listed.map { it.name })
        assertFalse("载荷已丢的应标记", listed.first { it.name == "新" }.payloadPresent)
        assertTrue(listed.first { it.name == "旧" }.payloadPresent)
        // 元数据仍在（仅探测，不自动清理）；reconcile 才动它。
        assertEquals(old.snapshot.id, listed.last().id)
    }

    @Test
    fun reconcileDropsEntriesWithoutPayload() {
        seedLive(1)
        val s = store()
        s.save(1, "在")
        s.save(1, "丢")
        val victim = s.list(1).first { it.name == "丢" }
        File(File(vmsRoot, "vm_1/snapshots"), victim.id).deleteRecursively()

        assertEquals(listOf(victim.id), s.reconcile(1))
        assertEquals(listOf("在"), s.list(1).map { it.name })
    }

    @Test
    fun corruptedIndexReadsAsEmpty() {
        seedLive(1)
        val s = store()
        s.save(1, "好")
        File(vmsRoot, "vm_1/snapshots/index.json").writeText("{ 不是 JSON")
        assertTrue("index 损坏时按无存档处理，不得抛异常", s.list(1).isEmpty())
    }

    // ------------------------------------------------------------------
    // restore / discard
    // ------------------------------------------------------------------

    @Test
    fun restorePutsPayloadBackAndBacksUpCurrent() {
        seedLive(1, "OLD-STATE")
        val s = store()
        VmSnapshotStore.now = { 1_000L }; s.save(1, "存档点")

        // 引擎又存了一次：live 变成 NEW-STATE。
        seedLive(1, "NEW-STATE")

        val entry = s.list(1).single()
        assertTrue(s.restore(1, entry.id) is VmSnapshotStore.RestoreResult.Restored)
        assertEquals("OLD-STATE", File(vmsRoot, "vm_1/snapshot.bin").readText())
        assertEquals("恢复前先备份当时的 live", "NEW-STATE",
            File(vmsRoot, "vm_1/snapshot.bin.bak").readText())
    }

    @Test
    fun restoreRejectsUnknownId() {
        seedLive(1)
        assertEquals(VmSnapshotStore.RestoreResult.NotFound, store().restore(1, "snap_nope"))
    }

    @Test
    fun restoreRejectsWhileRunning() {
        seedLive(1)
        val s = store()
        s.save(1, "存档")
        val entry = s.list(1).single()
        val result = store(running = { true }).restore(1, entry.id)
        assertTrue(result is VmSnapshotStore.RestoreResult.VmRunning)
    }

    @Test
    fun restoreDetectsMissingPayload() {
        seedLive(1)
        val s = store()
        s.save(1, "存档")
        val entry = s.list(1).single()
        File(File(vmsRoot, "vm_1/snapshots"), entry.id).deleteRecursively()
        assertEquals(VmSnapshotStore.RestoreResult.PayloadMissing, s.restore(1, entry.id))
    }

    // ------------------------------------------------------------------
    // live 快照观测 / 丢弃
    // ------------------------------------------------------------------

    @Test
    fun liveSnapshotReflectsFileState() {
        assertNull("没有快照时为 null", store().liveSnapshot(2))
        val live = seedLive(3, "x")
        val info = store().liveSnapshot(3)
        assertNotNull(info)
        assertEquals(live.length(), info!!.sizeBytes)
        assertEquals(live.lastModified(), info.savedAt)
    }

    @Test
    fun discardLiveRemovesSnapshotForColdBoot() {
        seedLive(1)
        assertTrue(store().discardLive(1))
        assertFalse(File(vmsRoot, "vm_1/snapshot.bin").exists())
        assertFalse("再丢一次就是无事发生", store().discardLive(1))
    }

    @Test
    fun discardLiveRejectedWhileRunning() {
        seedLive(1)
        assertFalse(store(running = { true }).discardLive(1))
    }

    // ------------------------------------------------------------------
    // delete / prune / 统计
    // ------------------------------------------------------------------

    @Test
    fun deleteRemovesEntryAndPayloadDir() {
        seedLive(1)
        val s = store()
        s.save(1, "要删的")
        val entry = s.list(1).single()
        val payloadDir = File(vmsRoot, "vm_1/snapshots/${entry.id}")
        assertTrue(payloadDir.isDirectory)

        assertTrue(s.delete(1, entry.id))
        assertFalse(payloadDir.exists())
        assertTrue(s.list(1).isEmpty())
        assertFalse("删不存在的 id 返回 false", s.delete(1, entry.id))
    }

    @Test
    fun pruneKeepsNewestCount() {
        seedLive(1)
        val s = store()
        var t = 1_000L
        VmSnapshotStore.now = { t }
        s.save(1, "第一"); t += 1
        s.save(1, "第二"); t += 1
        s.save(1, "第三")

        assertEquals(2, s.prune(1, keepCount = 1))
        assertEquals(listOf("第三"), s.list(1).map { it.name })
        assertEquals("载荷目录要一并删掉", 1,
            File(vmsRoot, "vm_1/snapshots").listFiles()!!.count { it.isDirectory })
    }

    @Test
    fun totalBytesOnlyCountsPresentPayloads() {
        seedLive(1, "12345")
        val s = store()
        s.save(1, "在")
        val gone = s.save(1, "丢") as VmSnapshotStore.SaveResult.Saved
        File(File(vmsRoot, "vm_1/snapshots"), gone.snapshot.id).deleteRecursively()

        assertEquals(5L, s.totalBytes(1))
    }
}
