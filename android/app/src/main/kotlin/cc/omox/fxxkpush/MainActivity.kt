package cc.omox.fxxkpush

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Flutter 宿主 Activity。
 *
 * 职责：
 *  1. MethodChannel：把 Dart 的调用转给原生（启停前台服务、读缓存、发反馈）
 *  2. 深链：接住通知点击（fxxkpush://message/<id>）并转给 Dart
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "FxxkPush"
        const val CHANNEL = "cc.omox.fxxkpush/methods"
        const val EVENT_CHANNEL = "cc.omox.fxxkpush/events"
    }

    private var pendingDeepLink: String? = null
    private var eventSink: EventChannel.EventSink? = null

    /**
     * 消息存储单例 —— 与 PushService 共用同一个 sqlite 文件。
     *
     * 刻意**不**走 PushService.instance：服务没跑的时候（冷启动、被系统杀、
     * 用户手动断开）也要能读历史消息，否则冷启动打开看到空列表，
     * 而用户明明收到过通知。
     */
    private val store: MessageStore by lazy { MessageStore(applicationContext) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> onMethodCall(call, result) }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                    // 也交给 PushService —— 服务在连接状态变化时
                    // （connecting → connected → error）主动推给 Dart，
                    // 不用等 Dart 那 5 秒轮询。
                    PushService.eventSink = sink
                    // 有 pending 深链就先补发
                    pendingDeepLink?.let {
                        sink.success(mapOf("type" to "deeplink", "value" to it))
                        pendingDeepLink = null
                    }
                    // 补一个当前状态，免得 Dart 得等下一次轮询才知道
                    sink.success(mapOf("type" to "state",
                                       "value" to PushService.connectionState))
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    PushService.eventSink = null
                }
            })
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isServiceRunning" -> {
                    result.success(PushService.instance != null)
                }

                "startService" -> {
                    val baseUrl = call.argument<String>("baseUrl") ?: ""
                    val token = call.argument<String>("token") ?: ""
                    val topic = call.argument<String>("topic") ?: "fp-phone"

                    val intent = Intent(this, PushService::class.java).apply {
                        // Intent.action 是 val —— 必须 setAction()，不能 `action = ...`
                        setAction(PushService.ACTION_START)
                        putExtra("baseUrl", baseUrl)
                        putExtra("token", token)
                        putExtra("topic", topic)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }

                "stopService" -> {
                    val intent = Intent(this, PushService::class.java).apply {
                        setAction(PushService.ACTION_STOP)
                    }
                    startService(intent)
                    result.success(true)
                }

                "fetchMessages" -> {
                    val limit = call.argument<Int>("limit") ?: 200
                    val rows = store.fetch(limit)
                    Log.i(TAG, "fetchMessages limit=$limit -> ${rows.size} rows"
                            + (if (rows.isNotEmpty()) " first=${rows[0].take(120)}" else ""))
                    result.success(rows)
                }

                "clearMessages" -> {
                    store.clear()
                    result.success(true)
                }

                "connectionState" -> {
                    result.success(PushService.connectionState)
                }

                "publish" -> {
                    publishFeedback(call, result)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "method call failed: ${call.method}", e)
            result.error("ERR", e.message, null)
        }
    }

    /** 反馈（👍/👎）—— 直接 POST 到 ntfy 的 publish 接口 */
    private fun publishFeedback(call: MethodCall, result: MethodChannel.Result) {
        val baseUrl = call.argument<String>("baseUrl") ?: ""
        val token = call.argument<String>("token") ?: ""
        val topic = call.argument<String>("topic") ?: ""
        val message = call.argument<String>("message") ?: ""

        if (baseUrl.isBlank() || topic.isBlank()) {
            result.success(false)
            return
        }

        Thread {
            var ok = false
            try {
                // ntfy 的 JSON 发布必须 POST 到**根路径**，topic 放 body 里。
                //
                // POST 到 "/$topic" + JSON body 时，ntfy 会把整个 body 当成
                // message 的**纯文本**内容 —— 实测服务器上存下来的是：
                //   message = "{\"message\":\"👍 [fp-phone] ...\"}"
                // 而 title/priority/tags 全部丢失。
                // 反过来 POST "/" + {"topic":..., "message":...} 才是对的：
                //   title=FxxkPush 验证  priority=4  tags=["bell"]  全部正常。
                val json = JSONObject().apply {
                    put("topic", topic)
                    put("message", message)
                }
                val body = json.toString()
                    .toRequestBody("application/json; charset=utf-8".toMediaType())
                val b = baseUrl.trimEnd('/')
                val req = Request.Builder()
                    .url("$b/")
                    .post(body)
                    .apply { if (token.isNotEmpty()) header("Authorization", "Bearer $token") }
                    .build()
                val client = OkHttpClient.Builder()
                    .connectTimeout(10, TimeUnit.SECONDS)
                    .writeTimeout(10, TimeUnit.SECONDS)
                    .build()
                client.newCall(req).execute().use { resp ->
                    ok = resp.isSuccessful
                    if (!ok) Log.w(TAG, "publish feedback HTTP ${resp.code}")
                }
            } catch (e: Exception) {
                Log.w(TAG, "publish feedback failed: ${e.message}")
                ok = false
            }
            runOnUiThread { result.success(ok) }
        }
    }

    /** 深链：通知点击 → fxxkpush://message/<id> */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "fxxkpush") return
        val value = "${data.host}${data.path}"
        Log.i(TAG, "deep link: $value")
        val sink = eventSink
        if (sink != null) {
            sink.success(mapOf("type" to "deeplink", "value" to value))
        } else {
            pendingDeepLink = value
        }
    }
}
