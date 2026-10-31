package com.vm.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class VmLogStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val store: VmLogStore by lazy { VmLogStore(temp.root) }

    @After
    fun resetClock() {
        VmLogStore.now = { System.currentTimeMillis() }
    }

    // ------------------------------------------------------------------
    // 单行写入与格式
    // ------------------------------------------------------------------

    @Test
    fun recordWritesFormattedLine() {
        VmLogStore.now = { 1_760_000_000_000L }
        assertTrue(store.record(1, VmLogLevel.WARN, "Launcher", "内存不足，已下调"))
        val lines = store.tail(1, 10)
        assertEquals(1, lines.size)
        // 格式：日期 时间 级别/标签 内容
        assertTrue(lines[0].startsWith("2025-10-09 "))
        assertTrue(lines[0].contains(" W/Launcher 内存不足，已下调"))
    }

    @Test
    fun formatLineUsesLogcatStyleLevelLetter() {
        val line = VmLogStore.formatLine(0L, VmLogLevel.ERROR, "Engine", "boom")
        // 1970-01-01 08:00:00.000（本地时区差异由格式断言规避，只看尾部）
        assertTrue(line.endsWith(" E/Engine boom\n"))
        assertTrue(line.substringBefore(' ').matches(Regex("\\d{4}-\\d{2}-\\d{2}")))
    }

    @Test
    fun tagIsSanitized() {
        store.record(2, "a b\tc", "msg")
        val line = store.tail(2, 1).single()
        assertTrue("标签里的空白应替换为下划线：$line", line.contains("I/a_b_c"))
    }

    @Test
    fun multilineMessageIndentsContinuation() {
        store.record(3, "Boot", "第一行\n第二行")
        val lines = store.tail(3, 10)
        assertEquals(2, lines.size)
        assertTrue(lines[1].startsWith("    第二行"))
    }

    @Test
    fun tailOfMissingVmIsEmpty() {
        assertTrue(store.tail(42, 50).isEmpty())
    }

    // ------------------------------------------------------------------
    // 轮转
    // ------------------------------------------------------------------

    @Test
    fun rotateNowShiftsActiveToFirstSlot() {
        store.record(1, "T", "hello")
        assertTrue(store.rotateNow(1))
        assertTrue(store.activeFile(1).length() == 0L || !store.activeFile(1).exists())
        assertTrue(File(store.logDir(1), "events.log.1").isFile)
        assertEquals(1, store.tail(1, 100).size)
    }

    @Test
    fun rotateNowIsNoopWithoutActiveFile() {
        assertFalse(store.rotateNow(7))
    }

    @Test
    fun rotationChainDropsOldestBeyondKeepSegments() {
        store.record(1, "T", "seed")
        // 连续轮转 KEEP_SEGMENTS + 2 次：最早的段应被挤出链。
        repeat(VmLogStore.KEEP_SEGMENTS + 2) {
            assertTrue(store.rotateNow(1))
            store.record(1, "T", "段内容 $it")
        }
        val dir = store.logDir(1)
        for (i in 1..VmLogStore.KEEP_SEGMENTS) {
            assertTrue("第 $i 段应存在", File(dir, "events.log.$i").isFile)
        }
        val overflow = VmLogStore.KEEP_SEGMENTS + 1
        assertFalse("超出保留份数的段应被删除", File(dir, "events.log.$overflow").exists())
    }

    @Test
    fun recordAutoRotatesWhenSegmentFull() {
        // 直接把当前段撑到上限（内容仍是合法文本行，不污染 tail），
        // 再 record 一条 → 应自动轮转且新段只有这一条。
        val active = store.activeFile(1).apply { parentFile!!.mkdirs() }
        active.writeBytes(ByteArray(VmLogStore.MAX_SEGMENT_BYTES.toInt()) { '\n'.code.toByte() })
        store.record(1, "T", "触发轮转的一条")
        assertTrue(File(store.logDir(1), "events.log.1").isFile)
        val last = store.tail(1, 1).single()
        assertTrue("最新一条应在新段里：$last", last.contains("触发轮转的一条"))
        // 轮转后当前段是全新文件（远小于上限）。
        assertTrue(store.activeFile(1).length() < 1024)
    }

    // ------------------------------------------------------------------
    // tail 跨段拼接
    // ------------------------------------------------------------------

    @Test
    fun tailSpansRotationChainChronologically() {
        store.record(1, "T", "第一段-行1")
        store.record(1, "T", "第一段-行2")
        store.rotateNow(1)
        store.record(1, "T", "第二段-行1")
        store.rotateNow(1)
        store.record(1, "T", "当前段-行1")

        val all = store.tail(1, 100)
        assertEquals(4, all.size)
        // 所有打点都用 tag=T，行格式为「时间 I/T 消息」——按该标记取消息体。
        fun msg(line: String) = line.substringAfter("I/T ")
        assertEquals(
            "时间序应为 最老段 → 最新段",
            listOf("第一段-行1", "第一段-行2", "第二段-行1", "当前段-行1"),
            all.map { msg(it) }
        )

        // maxLines 截尾：只保留最后 2 行。
        val lastTwo = store.tail(1, 2)
        assertEquals(2, lastTwo.size)
        assertTrue(lastTwo[0].contains("第二段-行1"))
        assertTrue(lastTwo[1].contains("当前段-行1"))
    }

    // ------------------------------------------------------------------
    // 按天清理
    // ------------------------------------------------------------------

    @Test
    fun pruneOlderThanDaysDeletesOnlyStaleRotatedSegments() {
        store.record(1, "T", "old")
        store.rotateNow(1)
        store.record(1, "T", "recent")
        val old = File(store.logDir(1), "events.log.1")
        val keep = store.activeFile(1)

        val now = System.currentTimeMillis()
        old.setLastModified(now - 10L * 24 * 60 * 60 * 1000)
        keep.setLastModified(now)

        assertEquals(1, store.pruneOlderThanDays(7))
        assertFalse(old.exists())
        assertTrue("活跃段永不被清理", keep.isFile)
    }

    @Test
    fun pruneKeepsSegmentsNewerThanCutoff() {
        store.record(1, "T", "a")
        store.rotateNow(1)
        store.record(1, "T", "b")
        store.rotateNow(1)
        assertEquals(0, store.pruneOlderThanDays(7))
        assertTrue(File(store.logDir(1), "events.log.1").isFile)
        assertTrue(File(store.logDir(1), "events.log.2").isFile)
    }

    // ------------------------------------------------------------------
    // 统计与并发
    // ------------------------------------------------------------------

    @Test
    fun totalBytesCoversWholeChain() {
        store.record(1, "T", "x")
        store.rotateNow(1)
        store.record(1, "T", "y")
        val expected = File(store.logDir(1), "events.log.1").length() +
            store.activeFile(1).length()
        assertEquals(expected, store.totalBytes(1))
    }

    @Test
    fun concurrentRecordsAreAllPersisted() {
        val threads = 4
        val perThread = 250
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(threads)
        try {
            repeat(threads) { t ->
                pool.submit {
                    start.await()
                    repeat(perThread) { i -> store.record(1, "T$t", "line-$i") }
                }
            }
            start.countDown()
        } finally {
            pool.shutdown()
            while (!pool.isTerminated) Thread.sleep(10)
        }
        assertEquals(
            "并发写入不得丢行（串行化临界区生效）",
            threads * perThread,
            store.tail(1, threads * perThread).size
        )
    }
}
