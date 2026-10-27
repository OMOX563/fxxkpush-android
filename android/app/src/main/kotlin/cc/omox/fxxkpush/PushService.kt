package cc.omox.fxxkpush

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * 前台服务：持有 ntfy WebSocket 订阅，负责「消息落地 + 发通知」。
 *
 * **为什么必须是原生前台服务**（而不是纯 Dart）：
 *   Android 8 之后，息屏 / 息屏一段时间后系统会冻结甚至杀掉 Dart isolate，
 *   纯 Dart 的 WebSocket 撑不过几分钟。原生 ForegroundService 带常驻通知，
 *   系统会把它当成「用户可见的服务」而不轻易回收 —— 这是 Android 上唯一
 *   官方认可的保活手段。
 *
 * **root 能做什么**（用户手机有 root）：
 *   root 能加的是「保活保险」：
 *     - 忽略电池优化（`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`）—— 前台服务
 *       本来就豁免，但 root 可以直接 `dumpsys deviceidle whitelist +包名`，
 *       把 app 加进 Doze 白名单，连 doze 都不进。
 *     - 关闭厂商的「自启动管理」/「后台活动限制」——各家 ROM 的杀进程
 *       名单在 /data/system 下，root 能直接改。
 *     - 但**根治办法仍然是前台服务**：root 改白名单是让系统不主动杀，
 *       前台服务是让系统必须留着。
 *   本服务两者都做：前台服务 + 开机自启 + (root 可用时) 加 Doze 白名单。
 */
class PushService : Service() {

    companion object {
        const val CHANNEL_STATUS = "fxxkpush_status"
        const val CHANNEL_MESSAGES = "fxxkpush_messages"
        private const val TAG = "FxxkPush"
        const val ACTION_START = "cc.omox.fxxkpush.START"
        const val ACTION_STOP = "cc.omox.fxxkpush.STOP"

        @Volatile
        var instance: PushService? = null

        @Volatile
        var connectionState: String = "disconnected"

        private const val RECONNECT_BASE_MS = 1000L
        private const val RECONNECT_MAX_MS = 30000L
    }

    private var client: OkHttpClient? = null
    private var socket: WebSocket? = null
    private var reconnectDelay = RECONNECT_BASE_MS
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var store: MessageStore

    private var baseUrl = ""
    private var token = ""
    private var topic = "fp-phone"

    override fun onCreate() {
        super.onCreate()
        instance = this
        store = MessageStore(this)
        Notifier.ensureChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        baseUrl = intent?.getStringExtra("baseUrl") ?: baseUrl
        token = intent?.getStringExtra("token") ?: token
        topic = intent?.getStringExtra("topic") ?: topic

        Notifier.ensureChannels(this)
        startForegroundCompat()

        acquireWakeLock()
        connect()

        // START_STICKY：进程被杀后系统会重新拉起（intent 为 null，用已有配置）
        return START_STICKY
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        val notif = Notifier.statusNotification(this, statusText())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                1001, notif,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(1001, notif)
        }
    }

    private fun statusText(): String = when (connectionState) {
        "connected" -> "已连接 · $topic"
        "connecting" -> "连接中…"
        else -> "未连接"
    }

    private fun updateStatusNotification() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.notify(1001, Notifier.statusNotification(this, statusText()))
    }

    /**
     * 尝试把本 app 加进 Doze 白名单。
     *
     * 无 root 时靠 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 弹窗让用户手动放行；
     * 有 root 时直接 `dumpsys deviceidle whitelist +<包名>` 静默生效。
     * 失败不致命 —— 前台服务本身已经豁免 doze。
     */
    private fun tryWhitelistDoze() {
        try {
            // 方式1：root（su）—— 静默加白名单
            val cmd = arrayOf(
                "su", "-c",
                "dumpsys deviceidle whitelist +$packageName"
            )
            val p = ProcessBuilder(cmd).redirectErrorStream(true).start()
            p.inputStream.use { it.readBytes() }
            p.waitFor()
            Log.i(TAG, "doze whitelist via su: exit=${p.exitValue()}")
        } catch (e: Exception) {
            Log.w(TAG, "doze whitelist via su failed: ${e.message}")
        }

        // 方式2：官方 API —— 前台服务本身已豁免 doze，这里只是读一下状态供日志
        try {
            val lm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val ignoring = lm.isIgnoringBatteryOptimizations(packageName)
            Log.i(TAG, "ignoring battery optimizations: $ignoring")
        } catch (_: Exception) {
        }
    }

    private fun acquireWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "FxxkPush::push"
            ).apply { acquire() }
        } catch (e: Exception) {
            Log.w(TAG, "wakeLock failed: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun wsUrl(): String {
        val b = baseUrl.trim().trimEnd('/')
        val scheme = if (b.startsWith("https")) "wss" else "ws"
        val hostPort = b.replaceFirst(Regex("^https?://"), "")
        return "$scheme://$hostPort/$topic/ws"
    }

    private fun connect() {
        if (baseUrl.isBlank()) {
            Log.w(TAG, "no baseUrl configured, not connecting")
            connectionState = "disconnected"
            return
        }
        connectionState = "connecting"
        updateStatusNotification()

        try {
            client?.dispatcher?.executorService?.shutdown()
        } catch (_: Exception) {
        }

        val c = OkHttpClient.Builder()
            .readTimeout(0, TimeUnit.MILLISECONDS)   // WS 长连不设读超时
            .connectTimeout(15, TimeUnit.SECONDS)
            .pingInterval(30, TimeUnit.SECONDS)     // 心跳，防中间设备掐连接
            .retryOnConnectionFailure(true)
            .build()
        client = c

        val req = Request.Builder()
            .url(wsUrl())
            .apply {
                if (token.isNotEmpty()) header("Authorization", "Bearer $token")
            }
            .build()

        socket = c.newWebSocket(req, object : WebSocketListener() {

            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.i(TAG, "ws connected: ${wsUrl()}")
                connectionState = "connected"
                reconnectDelay = RECONNECT_BASE_MS
                updateStatusNotification()
                tryWhitelistDoze()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.i(TAG, "ws closing: $code $reason")
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.i(TAG, "ws closed: $code $reason")
                connectionState = "disconnected"
                updateStatusNotification()
                scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "ws failure: ${t.message}")
                connectionState = "error"
                updateStatusNotification()
                scheduleReconnect()
            }
        })
    }

    private fun scheduleReconnect() {
        val delay = reconnectDelay
        reconnectDelay = (reconnectDelay * 2).coerceAtMost(RECONNECT_MAX_MS)
        android.os.Handler(mainLooper).postDelayed({
            if (instance != null) connect()
        }, delay)
    }

    private fun handleMessage(text: String) {
        try {
            val jo = JSONObject(text)
            val event = jo.optString("event", "")
            // keepalive / poll_request 是协议控制帧，不落地
            if (event != "message" && event != "open") return

            val id = jo.optString("id", "")
            if (id.isEmpty()) return

            val topic = jo.optString("topic", this.topic)
            val body = jo.optString("message", "")
            val title = jo.optString("title", "")
            val priority = jo.optInt("priority", 3)
            val timeSec = jo.optLong("time", System.currentTimeMillis() / 1000)
            val tagsArr = jo.optJSONArray("tags")
            val tags = ArrayList<String>()
            if (tagsArr != null) {
                for (i in 0 until tagsArr.length()) tags.add(tagsArr.optString(i))
            }

            store.upsert(id, topic, title, body, priority, tags, timeSec)

            Notifier.notifyMessage(this, id, title, body, priority, tags)
            Log.i(TAG, "message stored+notified: id=$id topic=$topic")
        } catch (e: Exception) {
            Log.w(TAG, "handleMessage failed: ${e.message}")
        }
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")
        connectionState = "disconnected"
        try {
            socket?.close(1000, null)
        } catch (_: Exception) {
        }
        try {
            client?.dispatcher?.executorService?.shutdown()
        } catch (_: Exception) {
        }
        releaseWakeLock()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    fun fetchMessages(limit: Int): List<String> = store.fetch(limit)
    fun clearMessages() = store.clear()
}
