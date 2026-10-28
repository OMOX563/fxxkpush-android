package cc.omox.fxxkpush

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject

/**
 * 消息本地缓存（sqlite）。
 *
 * 为什么存原生而不是 Dart 侧：
 *   消息是**后台**收到的（Dart isolate 可能根本没跑），落地必须在原生，
 *   否则冷启动打开 app 会看到空列表 —— 而用户明明收到过通知。
 *
 * 只留最近 [MAX_ROWS] 条，防止无限增长。
 */
class MessageStore(context: Context) :
    SQLiteOpenHelper(context, DB_NAME, null, DB_VERSION) {

    companion object {
        private const val DB_NAME = "fxxkpush.db"
        private const val DB_VERSION = 1
        private const val TABLE = "messages"

        /**
         * 条数上限（双保险）。
         * 单靠它不够 —— 500 条里可能全是一年前的消息。
         */
        private const val MAX_ROWS = 500

        /**
         * 消息保留天数：超过 7 天的删掉。
         *
         * 为什么按时间也要删：条数上限管的是"条数"，管不了"年龄"。
         * 低频用户可能半年只收 20 条 —— 条数没超上限，但半年前的记录
         * 会一直躺在库里，手机存储和列表长度都在浪费。
         */
        private const val RETENTION_DAYS = 7L
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE $TABLE (
                id TEXT PRIMARY KEY,
                topic TEXT,
                title TEXT,
                body TEXT,
                priority INTEGER,
                tags TEXT,
                time INTEGER,
                received_at INTEGER
            )"""
        )
        db.execSQL("CREATE INDEX idx_time ON $TABLE(time DESC)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS $TABLE")
        onCreate(db)
    }

    /** 插入或更新一条消息 */
    fun upsert(
        id: String,
        topic: String,
        title: String,
        body: String,
        priority: Int,
        tags: List<String>,
        time: Long
    ) {
        // 防御：万一调用方塞了毫秒级时间戳，统一成秒。
        // 写入端和清理端的单位必须一致 —— 这是上一版 bug 的根，
        // 在入口挡一道，比在清理端猜来猜去可靠。
        // 1e11 秒 ≈ 公元 5138 年，超过它只可能是毫秒。
        val timeSec = if (time > 100_000_000_000L) time / 1000 else time
        val cv = ContentValues().apply {
            put("id", id)
            put("topic", topic)
            put("title", title)
            put("body", body)
            put("priority", priority)
            put("tags", tags.joinToString(","))
            put("time", timeSec)
            put("received_at", System.currentTimeMillis())
        }
        writableDatabase.insertWithOnConflict(
            TABLE, null, cv, SQLiteDatabase.CONFLICT_REPLACE
        )
        purgeExpired()
        trim()
    }

    /**
     * 删掉超过保留期（[RETENTION_DAYS] 天）的消息。
     *
     * 按消息自带的 `time` 算，不用 received_at —— 后者是手机收到的时间，
     * 跨时区/时钟漂移会错。
     *
     * **单位必须是 epoch 秒，和写入端一致。**
     *
     * 这里曾经写成毫秒（`System.currentTimeMillis() - ... * 1000L`），
     * 而写入端存的是 ntfy 原生的时间戳 —— **秒**（见 PushService.handleMessage
     * 的 `jo.optLong("time", ... / 1000)`，Dart 侧 NtfyMessage.time 也是秒）。
     * 于是 `time < cutoff` **恒成立**：秒的量级 1.8e9 永远小于毫秒的
     * cutoff 1.8e12，每条消息一插入就被删掉。
     *
     * 表现极具迷惑性：**系统通知照常弹出**（通知走独立路径，不查库），
     * 但 app 里的列表永远是空的，副标题一直显示「订阅已连接，等待推送…」。
     *
     * 为什么没被测出来：instrumentation 单测里的 time 用的是 100L/200L 这种
     * 小数字（确实会被删，但那些测试从没被执行过）；而手工做的「7 天零 1 毫秒」
     * 边界验证用的是**毫秒级**造的数据，单位假设跟真 ntfy 数据不一致。
     * 单位这种事只能拿真实数据的量级来验。
     */
    fun purgeExpired(): Int {
        val cutoffSec =
            System.currentTimeMillis() / 1000 - RETENTION_DAYS * 24L * 60L * 60L
        return writableDatabase.delete(
            TABLE, "time < ?", arrayOf(cutoffSec.toString())
        )
    }

    /**
     * 删掉「标题和正文都为空」的记录。
     *
     * 那是历史遗留：ntfy 的 `{"event":"open"}` 控制帧**带 id**，
     * 以前 `handleMessage` 把它当消息处理，于是每次重连都往库里插一条
     * 标题正文全空的假消息。用户看到的就是列表里一排空白卡片。
     * 现在 open 帧不再入库（PushService 只收 event=="message"），
     * 这里负责把历史数据清掉。
     */
    fun purgeEmptyFrames(): Int {
        return writableDatabase.delete(
            TABLE, "COALESCE(title,'')='' AND COALESCE(body,'')=''", null
        )
    }

    /** 超出上限时删最旧的 */
    private fun trim() {
        writableDatabase.execSQL(
            """DELETE FROM $TABLE WHERE id NOT IN (
                 SELECT id FROM $TABLE ORDER BY time DESC LIMIT $MAX_ROWS
               )"""
        )
    }

    /** 取最近的消息（JSON 字符串列表，给 Dart 解析） */
    fun fetch(limit: Int): List<String> {
        // 长期没收到消息时 upsert 不会触发，过期消息就没人清了 ——
        // 这里补一刀：打开 app 读列表前先回收。
        try {
            purgeExpired()
            purgeEmptyFrames()
        } catch (e: Exception) {
            // 清理失败不该挡住读列表
        }
        val out = ArrayList<String>()
        readableDatabase.rawQuery(
            "SELECT id, topic, title, body, priority, tags, time FROM $TABLE ORDER BY time DESC LIMIT ?",
            arrayOf(limit.toString())
        ).use { c ->
            while (c.moveToNext()) {
                val jo = JSONObject()
                jo.put("id", c.getString(0))
                jo.put("topic", c.getString(1))
                jo.put("title", c.getString(2))
                jo.put("message", c.getString(3))
                jo.put("priority", c.getInt(4))
                // **必须显式建 JSONArray。**
                // `jo.put("tags", someList)` 走的是 JSONObject.put(String, Object)，
                // 空列表在 Android 的 org.json 上会被存成**字符串 "[]"**，
                // Dart 侧 `j['tags'] as List?` 直接抛
                // "type 'String' is not a subtype of type 'List<dynamic>?'"，
                // 每条消息都解析失败 → 列表永远是空的。
                val tagsArr = JSONArray()
                for (tg in parseTags(c.getString(5))) tagsArr.put(tg)
                jo.put("tags", tagsArr)
                jo.put("time", c.getLong(6))
                out.add(jo.toString())
            }
        }
        return out
    }

    private fun parseTags(s: String?): List<String> =
        if (s.isNullOrEmpty()) emptyList() else s.split(",").filter { it.isNotEmpty() }

    fun clear() {
        writableDatabase.delete(TABLE, null, null)
    }

    fun count(): Int = readableDatabase.rawQuery(
        "SELECT COUNT(*) FROM $TABLE", null
    ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }
}
