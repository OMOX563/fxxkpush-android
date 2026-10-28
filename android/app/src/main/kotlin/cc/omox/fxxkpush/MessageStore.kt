package cc.omox.fxxkpush

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
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
        val cv = ContentValues().apply {
            put("id", id)
            put("topic", topic)
            put("title", title)
            put("body", body)
            put("priority", priority)
            put("tags", tags.joinToString(","))
            put("time", time)
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
     * 按消息自带的 `time`（服务器给的时间戳，毫秒）算，
     * 不用 received_at —— 后者是手机收到的时间，跨时区/时钟漂移会错。
     */
    fun purgeExpired(): Int {
        val cutoff = System.currentTimeMillis() - RETENTION_DAYS * 24L * 60L * 60L * 1000L
        return writableDatabase.delete(
            TABLE, "time < ?", arrayOf(cutoff.toString())
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
                jo.put("tags", parseTags(c.getString(5)))
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
