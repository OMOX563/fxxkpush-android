package cc.omox.fxxkpush

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import cc.omox.fxxkpush.PushService.Companion.ACTION_START

/**
 * 开机自启：重启后把前台服务拉起来。
 *
 * 配置（服务器/token/topic）从 SharedPreferences 读 ——
 * 与 Dart 侧 ConfigStore 写的是同一个 key（'fxxkpush.config'），
 * 因为 SharedPreferences 本来就是跨 Kotlin/Dart 共享的同一个存储。
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "FxxkPush"
        private const val PREFS = "fxxkpush.config"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        Log.i(TAG, "boot receiver: $action")

        val sp = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // 与 Dart 侧 ConfigStore 写的是同一个 key + 同一个 JSON 结构
        val raw = sp.getString("fxxkpush.config", "") ?: ""
        if (raw.isBlank()) {
            Log.i(TAG, "no config, not starting service")
            return
        }
        val baseUrl = jsonField(raw, "baseUrl")
        val token = jsonField(raw, "token")
        val topic = jsonField(raw, "topic").ifBlank { "fp-phone" }

        if (baseUrl.isBlank()) {
            Log.i(TAG, "no config, not starting service")
            return
        }

        val svcIntent = Intent(context, PushService::class.java).apply {
            // Intent.action 是 val —— 必须用 setAction()，不能 `action = ...`
            // （同名还会遮蔽掉 companion 的 ACTION_START 常量）
            setAction(ACTION_START)
            putExtra("baseUrl", baseUrl)
            putExtra("token", token)
            putExtra("topic", topic)
        }
        try {
            context.startForegroundService(svcIntent)
            Log.i(TAG, "service started on boot")
        } catch (e: Exception) {
            Log.w(TAG, "start on boot failed: ${e.message}")
        }
    }

    /** 从 JSON 字符串里取一个字符串字段（不引 org.json 的解析开销） */
    private fun jsonField(json: String, key: String): String {
        val needle = "\"$key\":\""
        val i = json.indexOf(needle)
        if (i < 0) return ""
        val start = i + needle.length
        val end = json.indexOf('"', start)
        if (end < 0) return ""
        return json.substring(start, end)
    }
}
