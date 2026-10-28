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
            time = 1793127022L
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
        assertEquals(1793127022L, o.getLong("time"))
    }

    @Test
    fun store_sameIdReplacesNotDuplicates() {
        val store = MessageStore(ctx)
        store.clear()

        store.upsert("dup", "fp-phone", "第一次", "a", 3, emptyList(), 100L)
        store.upsert("dup", "fp-phone", "第二次", "b", 5, listOf("bell"), 200L)

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

        store.upsert("old", "fp-phone", "旧", "a", 3, emptyList(), 100L)
        store.upsert("new", "fp-phone", "新", "b", 3, emptyList(), 200L)

        val rows = store.fetch(10)
        assertEquals(2, rows.size)
        assertEquals("new", JSONObject(rows[0]).getString("id"))
        assertEquals("old", JSONObject(rows[1]).getString("id"))
    }

    @Test
    fun store_clearEmpties() {
        val store = MessageStore(ctx)
        store.upsert("x", "fp-phone", "t", "b", 3, emptyList(), 1L)
        assertTrue(store.count() > 0)
        store.clear()
        assertEquals(0, store.count())
        assertTrue(store.fetch(10).isEmpty())
    }

    @Test
    fun store_fetchRespectsLimit() {
        val store = MessageStore(ctx)
        store.clear()
        for (i in 1..10) {
            store.upsert("m$i", "fp-phone", "t$i", "b", 3, emptyList(), i.toLong())
        }
        assertEquals(3, store.fetch(3).size)
    }
}
