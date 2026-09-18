package com.lx.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * 常驻保活前台服务。
 *
 * 作用：让进程在【划掉任务栏】之后依然存活，从而保住 FlutterEngine 与其中的
 * Dart isolate —— 这样 Dart 侧的中继轮询（SyncService 的 4 秒会话看门狗）与
 * WebSocket 长连接（LocalAgentService）才能继续维持，实现“后台仍能接收新消息”。
 *
 * 关键点：
 * 1. Manifest 中必须设置 android:stopWithTask="false"，否则划掉任务时服务会被一并停止；
 * 2. 仅靠 Service 不够：FlutterActivity 销毁时会连带销毁 FlutterEngine，因此
 *    MainActivity 必须覆写 provideFlutterEngine() 走 FlutterEngineCache，
 *    并让 shouldDestroyEngineWithHost() 返回 false（详见 MainActivity.kt）；
 * 3. 用户未登录或关闭常驻时，本服务不应运行（由 Dart 侧与 BootReceiver 控制）。
 */
class LxForegroundService : Service() {

    companion object {
        private const val TAG = "LxForegroundService"
        const val CHANNEL_ID = "lx_app_keep_alive_channel"
        const val NOTIFICATION_ID = 2027

        /** 常驻服务是否应在开机后自动拉起（由 Dart 侧在登录时写入，登出时清除）。 */
        const val PREFS_NAME = "lx_app_prefs"
        const val KEY_KEEP_ALIVE = "keep_alive_enabled"

        /**
         * 服务是否正在运行（进程内共享状态）。
         * 不用 ActivityManager.getRunningServices()：该方法自 Android 8.0 起已废弃，
         * 对自家应用以外仅返回空列表，判定不可靠。
         */
        @Volatile
        var isRunning: Boolean = false
            private set

        /** 统一入口：按系统版本选择正确的启动方式。 */
        fun start(context: Context) {
            val intent = Intent(context, LxForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ 在后台调用 startForegroundService 可能抛
                // ForegroundServiceStartNotAllowedException，此处兜底避免崩溃
                Log.w(TAG, "启动常驻服务失败: ${e.localizedMessage}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, LxForegroundService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "停止常驻服务失败: ${e.localizedMessage}")
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        isRunning = true

        // 若 FlutterEngine 已被系统回收，这里按需重建；
        // 引擎存活与否由 FlutterEngineCache 管理（MainActivity.provideFlutterEngine 放入）
        val cached: FlutterEngine? = FlutterEngineCache.getInstance().get(LxEngine.MAIN_ENGINE_ID)
        if (cached == null) {
            Log.i(TAG, "缓存中无 FlutterEngine，服务先以纯原生方式驻留，待 App 启动后再接管")
        } else {
            Log.i(TAG, "FlutterEngine 缓存命中，Dart 侧长连接与轮询可继续运行")
        }

        // START_STICKY：被系统杀死后尽量重建，配合电池优化白名单提高存活率
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        Log.i(TAG, "常驻服务已停止")
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "后台常驻服务",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "保持与中继服务器的连接，后台接收远程 Agent 的消息"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = PendingIntent.getActivity(this, 0, openIntent, pendingFlags)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("LxAI 正在后台运行")
            .setContentText("保持与中继服务器的连接，实时接收消息")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(contentIntent)
            .build()
    }
}
