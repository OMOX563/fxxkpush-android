package cc.omox.fxxkpush

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import cc.omox.fxxkpush.PushService.Companion.CHANNEL_MESSAGES
import cc.omox.fxxkpush.PushService.Companion.CHANNEL_STATUS

/**
 * 通知构造。
 *
 * 两条通道：
 *  - CHANNEL_STATUS：前台服务的常驻通知（低优先级，不打扰）
 *  - CHANNEL_MESSAGES：真正的推送消息（按 ntfy priority 映射）
 */
object Notifier {

    private const val STATUS_NOTIF_ID = 1001
    private const val MSG_NOTIF_BASE = 2000

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return

        // 常驻通知：静默、最低优先级
        val status = NotificationChannel(
            CHANNEL_STATUS,
            "服务状态",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "保持推送连接的前台服务通知"
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
        }

        // 消息通道：默认优先级，交给用户按消息内容调
        val msgs = NotificationChannel(
            CHANNEL_MESSAGES,
            "推送消息",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "收到的推送消息"
        }

        nm.createNotificationChannel(status)
        nm.createNotificationChannel(msgs)
    }

    /** 前台服务的常驻通知 */
    fun statusNotification(ctx: Context, text: String): Notification {
        val pi = PendingIntent.getActivity(
            ctx, 0,
            Intent(ctx, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(ctx, CHANNEL_STATUS)
            .setContentTitle("FxxkPush")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(pi)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    /**
     * 推送消息通知。
     *
     * @param msgId  ntfy 消息 id，用作通知 id 的种子 —— 同一消息重复到达不叠通知
     * @param deepLink 点击后跳转的 fxxkpush:// 深链（带上消息 id）
     */
    fun messageNotification(
        ctx: Context,
        msgId: String,
        title: String,
        body: String,
        priority: Int,
        tags: List<String>
    ): Notification {
        // 深链：点通知直接进详情页
        val deepLink = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("fxxkpush://message/$msgId"),
            ctx,
            MainActivity::class.java
        ).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            ctx, msgId.hashCode(), deepLink,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val p = priority.coerceIn(1, 5)
        val chanPriority = when {
            p >= 5 -> NotificationCompat.PRIORITY_MAX
            p == 4 -> NotificationCompat.PRIORITY_HIGH
            p == 1 -> NotificationCompat.PRIORITY_MIN
            else -> NotificationCompat.PRIORITY_DEFAULT
        }

        return NotificationCompat.Builder(ctx, CHANNEL_MESSAGES)
            .setContentTitle(if (title.isNotEmpty()) title else "FxxkPush")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setPriority(chanPriority)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .apply {
                // ntfy 的 tags 里带 emoji（如 warning / skull_and_crossbones）
                val emoji = tags.firstOrNull { it.isNotEmpty() && it.length <= 4 }
                if (emoji != null) setContentTitle("${title.ifEmpty { "FxxkPush" }} $emoji")
            }
            .build()
    }

    fun notifyMessage(
        ctx: Context,
        msgId: String,
        title: String,
        body: String,
        priority: Int,
        tags: List<String>
    ) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        val id = MSG_NOTIF_BASE + (msgId.hashCode() and 0x7fffffff) % 100000
        nm.notify(id, messageNotification(ctx, msgId, title, body, priority, tags))
    }
}
