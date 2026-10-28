package cc.omox.fxxkpush

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 原生侧 instrumentation 测试。
 *
 * 覆盖 Dart 测不到的部分：
 *  - MessageStore 的 sqlite 读写与去重
 *  - ntfy 消息 JSON 的字段提取（与 Dart 侧 NtfyMessage.fromJson 对齐）
 *  - WebSocket URL 的拼装（scheme 切换、端口保留、结尾斜杠处理）
 *
 * 跑法：
 *   flutter test integration_test/   # 或
 *   ./gradlew :app:connectedDebugAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class MessageStoreTest {

    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext

    /**
     * 当前 epoch **秒**（ntfy 的 time 就是秒级时间戳）。
     *
     * 测试数据必须用真实量级 —— 上一版用 100L/200L 这种小数字，
     * 它们比过期 cutoff 老得多，在单位错误时会被立刻删掉，
     * 断言「应存进一条」就该红了；但那些 instrumentation 测试
     * 从来没被执行过，所以 bug 一路漏到真机。
     */
    private val nowSec = System.currentTimeMillis() / 1000

    @Test
    fun storeAndFetch_roundTripsFields() {
        val store = MessageStore(ctx)
        store.clear()

        store.upsert(
            id = "msg-1",
            topic = "fp-phone",
            title = "FxxkPush 验证",
            body = "验证消息 02:50:35",
            priority = 4,
            tags = listOf("bell"),
            time = nowSec - 3600
        )

        val rows = store.fetch(10)
        assertEquals("应存进一条", 1, rows.size)

        val o = JSONObject(rows[0])
        assertEquals("msg-1", o.getString("id"))
        assertEquals("fp-phone", o.getString("topic"))
        assertEquals("FxxkPush 验证", o.getString("title"))
        assertEquals("验证消息 02:50:35", o.getString("message"))
        assertEquals(4, o.getInt("priority"))
        assertEquals(listOf("bell"), o.getJSONArray("tags").let { arr ->
            (0 until arr.length()).map { arr.getString(it) }
        })
        assertEquals(nowSec - 3600, o.getLong("time"))
    }

    @Test
    fun store_sameIdReplacesNotDuplicates() {
        val store = MessageStore(ctx)
        store.clear()

        store.upsert("dup", "fp-phone", "第一次", "a", 3, emptyList(), nowSec - 60)
        store.upsert("dup", "fp-phone", "第二次", "b", 5, listOf("bell"), nowSec - 30)

        val rows = store.fetch(10)
        assertEquals("同 id 应覆盖而不是新增", 1, rows.size)
        val o = JSONObject(rows[0])
        assertEquals("第二次", o.getString("title"))
        assertEquals(5, o.getInt("priority"))
    }

    @Test
    fun store_newestFirst() {
        val store = MessageStore(ctx)
        store.clear()

        store.upsert("old", "fp-phone", "旧", "a", 3, emptyList(), nowSec - 120)
        store.upsert("new", "fp-phone", "新", "b", 3, emptyList(), nowSec - 60)

        val rows = store.fetch(10)
        assertEquals(2, rows.size)
        assertEquals("new", JSONObject(rows[0]).getString("id"))
        assertEquals("old", JSONObject(rows[1]).getString("id"))
    }

    @Test
    fun store_clearEmpties() {
        val store = MessageStore(ctx)
        store.upsert("x", "fp-phone", "t", "b", 3, emptyList(), nowSec - 60)
        assertTrue(store.count() > 0)
        store.clear()
        assertEquals(0, store.count())
        assertTrue(store.fetch(10).isEmpty())
    }

    /**
     * 回归：真实 ntfy 数据（epoch 秒）必须留在库里。
     *
     * 曾经的 bug：purgeExpired 的 cutoff 按毫秒算，而写入端存的是秒，
     * 于是 `time < cutoff` 恒成立 —— 每条消息一插入就被删掉。
     * 表现是「系统通知照常弹，但列表永远空，副标题一直『等待推送』」。
     *
     * 这个测试必须用**真实量级的秒级时间戳**才有意义；
     * 拿 100L/200L 这种小数字去测，测的是「过期消息被删」，不是这个 bug。
     */
    @Test
    fun store_keepsRealNtfySecondTimestamps() {
        val store = MessageStore(ctx)
        store.clear()

        val now = System.currentTimeMillis() / 1000
        val day = 24L * 60L * 60L
        store.upsert("now", "fp-phone", "刚刚", "b", 3, emptyList(), now)
        store.upsert("1h", "fp-phone", "一小时前", "b", 3, emptyList(), now - 3600)
        store.upsert("6d", "fp-phone", "六天前", "b", 3, emptyList(), now - 6 * day)
        store.upsert("8d", "fp-phone", "八天前", "b", 3, emptyList(), now - 8 * day)

        val ids = store.fetch(20).map { JSONObject(it).getString("id") }
        assertTrue("刚到的消息必须保留（真实秒级时间戳）", ids.contains("now"))
        assertTrue("一小时前的必须保留", ids.contains("1h"))
        assertTrue("六天前的必须保留", ids.contains("6d"))
        assertFalse("八天前的必须删除", ids.contains("8d"))
    }

    /**
     * 回归：写入端收到毫秒级时间戳时，存储层要归一化成秒。
     *
     * 写入端和清理端的单位必须一致 —— 这正是上一版把消息全删掉的原因。
     * 入口归一化后，毫秒和秒两种输入都不会误删。
     */
    @Test
    fun store_normalizesMillisecondTimestamps() {
        val store = MessageStore(ctx)
        store.clear()

        val nowSec = System.currentTimeMillis() / 1000
        store.upsert("ms", "fp-phone", "毫秒戳", "b", 3, emptyList(), nowSec * 1000)

        val rows = store.fetch(10)
        assertEquals("毫秒戳应被存成一条", 1, rows.size)
        assertEquals("入库值应已归一化成秒", nowSec, JSONObject(rows[0]).getLong("time"))
    }

    @Test
    fun store_fetchRespectsLimit() {
        val store = MessageStore(ctx)
        store.clear()
        for (i in 1..10) {
            store.upsert("m$i", "fp-phone", "t$i", "b", 3, emptyList(), nowSec - i * 60L)
        }
        assertEquals(3, store.fetch(3).size)
    }
}
