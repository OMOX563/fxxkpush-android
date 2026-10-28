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

        /**
         * Flutter 侧的事件通道 sink。
         *
         * MainActivity 在 EventChannel 的 onListen 里注册进来，
         * 服务在**连接状态变化**时通过它推送。
         */
        @Volatile
        var eventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

        /**
         * 主线程 Handler。
         *
         * **EventSink.success() 必须在主线程调用** ——
         * connectionState 是在 OkHttp 的 WebSocketListener 回调线程里改的
         * （onOpen/onFailure 都是后台线程），直接 success() 会抛
         * "Methods marked with @UiThread must be executed on the main thread"，
         * 状态就推不出去，UI 只能等 Dart 那 5 秒轮询。
         */
        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        private var _connectionState = "disconnected"

        /**
         * 连接状态。
         *
         * **setter 里主动推事件** —— Dart 侧原来只能靠 5 秒轮询
         * 才知道连上了，用户点「保存并连接」后要等好几秒小圆点才变绿。
         * 推送之后是即时的；轮询只作兜底（服务在 app 不在前台时启动，
         * 那时没有 sink，推不出去）。
         */
        var connectionState: String
            get() = _connectionState
            set(v) {
                if (_connectionState == v) return
                _connectionState = v
                // 切回主线程再推 —— setter 可能在 OkHttp 回调线程被调用
                mainHandler.post {
                    try {
                        eventSink?.success(mapOf("type" to "state", "value" to v))
                    } catch (e: Exception) {
                        Log.w(TAG, "emit state failed: ${e.message}")
                    }
                }
            }

        private const val RECONNECT_BASE_MS = 1000L
        private const val RECONNECT_MAX_MS = 30000L
    }

    private var client: OkHttpClient? = null
    private var socket: WebSocket? = null
    private var reconnectDelay = RECONNECT_BASE_MS

    /**
     * 连接代数（epoch）。
     *
     * **每次 connect() 自增**，用来识别「过期」的 WebSocket 回调。
     *
     * 为什么需要：OkHttp 的 `WebSocket.cancel()` **会触发**旧 socket 的
     * `onFailure`/`onClosed` 回调。而这两个回调里都会 `scheduleReconnect()`。
     * 于是形成自激循环：
     *
     *   connect() → socket.cancel() 旧 socket
     *             → 旧 socket 的 onClosed 触发 → scheduleReconnect() 排重连
     *             → 重连到点 → connect() → 又 cancel（这次是刚连上的好连接）
     *             → 循环往复
     *
     * 表现就是「连接→断开→再连接→再断开」无限循环，而且每次都把
     * **刚建立的正常连接** cancel 掉。
     *
     * 回调里比对 epoch，不等于当前值的直接忽略 —— 那是「我们主动取消的
     * 旧连接」，不是故障，不该重连。
     */
    @Volatile
    private var connectionEpoch = 0

    /** 待执行的重连任务。必须持有句柄 ——
     *  否则每次失败都 post 一个新 Runnable 而旧的还在队列里，
     *  失败几次就有几个重连同时触发 → 连接风暴。 */
    private val reconnectRunnable = Runnable { if (instance != null) connect() }
    private var wakeLock: PowerManager.WakeLock? = null

    private var baseUrl = ""
    private var token = ""
    private var topic = "fp-phone"

    override fun onCreate() {
        super.onCreate()
        instance = this
        Notifier.ensureChannels(this)
    }

    /** 消息存储单例。
     *
     * 不能只在 Service 里 new —— Service 没跑的时候（冷启动、被系统杀、
     * 用户手动断开）Dart 侧照样要能读历史消息。挂成单例，
     * MainActivity 与 Service 共用同一个 sqlite 句柄。
     */
    private val store: MessageStore by lazy { MessageStore(applicationContext) }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        // 先记下「配置变没变」，再覆盖字段
        val newBase = intent?.getStringExtra("baseUrl")
        val newToken = intent?.getStringExtra("token")
        val newTopic = intent?.getStringExtra("topic")
        val configChanged = (newBase != null && newBase != baseUrl) ||
            (newToken != null && newToken != token) ||
            (newTopic != null && newTopic != topic)
        baseUrl = newBase ?: baseUrl
        token = newToken ?: token
        topic = newTopic ?: topic

        Notifier.ensureChannels(this)
        startForegroundCompat()

        acquireWakeLock()

        // 配置没变且连接还活着 → 不用重建连接。
        // 重建就意味着 cancel 旧 socket 再建新的 —— 功能上没问题（epoch 守卫
        // 已经保证不会误触发重连），但白白断一次重连，用户会看到
        // 「已连接」闪一下变「连接中」。
        if (!configChanged && connectionState == "connected" && socket != null) {
            Log.i(TAG, "config unchanged and already connected, skip reconnect")
            return START_STICKY
        }

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
            // ProcessBuilder 只接受 List<String>，Array<String> 会类型不匹配
            val cmd = listOf(
                "su", "-c",
                "dumpsys deviceidle whitelist +$packageName"
            )
            val proc = ProcessBuilder(cmd).redirectErrorStream(true).start()
            proc.inputStream.use { it.readBytes() }
            proc.waitFor()
            Log.i(TAG, "doze whitelist via su: exit=${proc.exitValue()}")
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
            // 先释放旧的 ——
            // onStartCommand 会被重复调用（每次「保存并连接」一次），
            // 直接 new 一个覆盖字段的话旧锁永远不 release → wakelock 泄漏。
            releaseWakeLock()
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "FxxkPush::push"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
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
        // 自增代数：本轮创建的 socket 及其回调，只有代数匹配才算数
        val epoch = ++connectionEpoch
        connectionState = "connecting"
        updateStatusNotification()

        // 先把旧连接彻底断掉 ——
        // onStartCommand 可能被重复调用（用户反复点「保存并连接」），
        // 不 cancel 旧 socket 就会有两个 WebSocket 同时活着、同时收消息。
        try {
            socket?.cancel()
            socket = null
            client?.dispatcher?.executorService?.shutdown()
            client = null
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
                if (epoch != connectionEpoch) {
                    Log.i(TAG, "ws open but stale (epoch=$epoch vs $connectionEpoch), ignore")
                    return
                }
                Log.i(TAG, "ws connected: ${wsUrl()} (epoch=$epoch)")
                connectionState = "connected"
                reconnectDelay = RECONNECT_BASE_MS
                // **连接成功了就把排队的重连撤掉** ——
                // 不撤的话，之前某次失败排下的重连到点后照样 connect()，
                // 把这个刚建好的连接 cancel 掉，然后进入无限循环。
                android.os.Handler(mainLooper).removeCallbacks(reconnectRunnable)
                updateStatusNotification()
                tryWhitelistDoze()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (epoch != connectionEpoch) {
                    Log.i(TAG, "ws closing ignored (stale epoch=$epoch): $code $reason")
                    return
                }
                Log.i(TAG, "ws closing: $code $reason")
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (epoch != connectionEpoch) {
                    Log.i(TAG, "ws closed ignored (stale epoch=$epoch): $code $reason")
                    return
                }
                Log.i(TAG, "ws closed (epoch=$epoch): $code $reason")
                connectionState = "disconnected"
                updateStatusNotification()
                scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (epoch != connectionEpoch) {
                    // 我们自己 cancel 掉的旧连接 —— 不是故障，别重连
                    Log.i(TAG, "ws failure ignored (stale epoch=$epoch): ${t.message}")
                    return
                }
                Log.w(TAG, "ws failure (epoch=$epoch): ${t.message}")
                connectionState = "error"
                updateStatusNotification()
                scheduleReconnect()
            }
        })
    }

    private fun scheduleReconnect() {
        val delay = reconnectDelay
        reconnectDelay = (reconnectDelay * 2).coerceAtMost(RECONNECT_MAX_MS)
        val handler = android.os.Handler(mainLooper)
        // 先撤掉排队的那个 —— 只有**一个**重连在排队。
        // 不撤的话失败 N 次就有 N 个重连 Runnable 同时到点，
        // 每次又各自再排一个 → 指数级连接风暴。
        handler.removeCallbacks(reconnectRunnable)
        handler.postDelayed(reconnectRunnable, delay)
        Log.i(TAG, "reconnect scheduled in ${delay}ms")
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
        // 别让排队的重连在服务死后又跑起来
        android.os.Handler(mainLooper).removeCallbacks(reconnectRunnable)
        try {
            socket?.cancel()
            socket = null
        } catch (_: Exception) {
        }
        // 先把旧连接彻底断掉 ——
        // onStartCommand 可能被重复调用（用户反复点「保存并连接」），
        // 不 cancel 旧 socket 就会有两个 WebSocket 同时活着、同时收消息。
        try {
            socket?.cancel()
            socket = null
            client?.dispatcher?.executorService?.shutdown()
            client = null
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
