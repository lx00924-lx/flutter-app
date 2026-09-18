package com.lx.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.lx.app/app_launcher"
    private val NOTIFICATION_CHANNEL_ID = "lx_app_update_channel"
    private val NOTIFICATION_ID = 2026
    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 1002

    /**
     * 提供【缓存复用的】FlutterEngine：
     * - 引擎存放在 FlutterEngineCache 中，跨 Activity 生命周期存活；
     * - 配合 shouldDestroyEngineWithHost() = false，划掉任务栏销毁 Activity 后
     *   Dart isolate 不会被销毁，SyncService 的中继轮询与 WebSocket 得以继续运行；
     * - Activity 重建（如从后台回来）时直接复用同一个引擎，状态不丢、也不会重复初始化。
     */
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(LxEngine.MAIN_ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(context)
        engine.dartExecutor.executeDartEntrypoint(
            io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint.createDefault()
        )
        setupMethodChannel(engine)
        FlutterEngineCache.getInstance().put(LxEngine.MAIN_ENGINE_ID, engine)
        return engine
    }

    /** 宿主销毁时不销毁引擎，交由常驻前台服务维持。 */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupMethodChannel(flutterEngine)
    }

    private fun setupMethodChannel(flutterEngine: FlutterEngine) {
        createNotificationChannel()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    val granted = requestNotificationPermissionIfNeeded()
                    result.success(granted)
                }
                "checkNotificationPermission" -> {
                    val granted = isNotificationPermissionGranted()
                    result.success(granted)
                }
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (!url.isNullOrEmpty()) {
                        try {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.localizedMessage, null)
                        }
                    } else {
                        result.error("INVALID_URL", "URL is null or empty", null)
                    }
                }
                "showDownloadNotification" -> {
                    val progress = call.argument<Int>("progress") ?: 0
                    val max = call.argument<Int>("max") ?: 100
                    val title = call.argument<String>("title") ?: "正在下载安装包"
                    val content = call.argument<String>("content") ?: "$progress%"
                    updateProgressNotification(progress, max, title, content)
                    result.success(true)
                }
                "completeDownloadNotification" -> {
                    val title = call.argument<String>("title") ?: "下载完成"
                    val content = call.argument<String>("content") ?: "点击立即安装新版本"
                    val apkPath = call.argument<String>("apkPath") ?: ""
                    completeNotification(title, content, apkPath)
                    result.success(true)
                }
                "cancelNotification" -> {
                    cancelNotification()
                    result.success(true)
                }
                "installApk" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (!apkPath.isNullOrEmpty()) {
                        val success = triggerInstallApk(apkPath)
                        result.success(success)
                    } else {
                        result.error("INVALID_PATH", "APK path is null or empty", null)
                    }
                }
                "startKeepAliveService" -> {
                    setKeepAliveFlag(true)
                    val granted = requestNotificationPermissionIfNeeded()
                    LxForegroundService.start(this)
                    // granted=false 表示正在向用户申请通知权限，服务仍已拉起
                    result.success(granted)
                }
                "stopKeepAliveService" -> {
                    setKeepAliveFlag(false)
                    LxForegroundService.stop(this)
                    result.success(true)
                }
                "isKeepAliveRunning" -> {
                    result.success(isServiceRunning(LxForegroundService::class.java))
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizationsInternal()
                    // 该操作会跳转系统弹窗，返回值不代表用户已同意，仅表示已发起请求
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isNotificationPermissionGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun requestNotificationPermissionIfNeeded(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST_CODE
                )
                return false
            }
        }
        return true
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "应用更新下载"
            val descriptionText = "显示应用更新下载进度与安装通知"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(NOTIFICATION_CHANNEL_ID, name, importance).apply {
                description = descriptionText
                enableVibration(false)
                setSound(null, null)
            }
            val notificationManager: NotificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun updateProgressNotification(progress: Int, max: Int, title: String, content: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(content)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(max, progress, false)

        notificationManager.notify(NOTIFICATION_ID, builder.build())
    }

    private fun completeNotification(title: String, content: String, apkPath: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val installIntent = getInstallIntent(apkPath)

        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            installIntent,
            pendingFlags
        )

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(content)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setOngoing(false)
            .setAutoCancel(true)
            .setProgress(0, 0, false)
            .setContentIntent(pendingIntent)

        notificationManager.notify(NOTIFICATION_ID, builder.build())
    }

    private fun cancelNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(NOTIFICATION_ID)
    }

    private fun getInstallIntent(apkPath: String): Intent {
        val file = File(apkPath)
        val intent = Intent(Intent.ACTION_VIEW)
        val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } else {
            Uri.fromFile(file)
        }
        intent.setDataAndType(uri, "application/vnd.android.package-archive")
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return intent
    }

    private fun triggerInstallApk(apkPath: String): Boolean {
        try {
            val file = File(apkPath)
            if (!file.exists() || file.length() == 0L) {
                return false
            }

            // Android 8.0+ 未知应用安装权限提示
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (!packageManager.canRequestPackageInstalls()) {
                    val manageIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                        data = Uri.parse("package:$packageName")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(manageIntent)
                }
            }

            val installIntent = getInstallIntent(apkPath)
            startActivity(installIntent)
            return true
        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }

    // ==================== 常驻保活相关 ====================

    /** 记录“是否开启常驻”，供 BootReceiver 在开机后决定是否自启。 */
    private fun setKeepAliveFlag(enabled: Boolean) {
        getSharedPreferences(LxForegroundService.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(LxForegroundService.KEY_KEEP_ALIVE, enabled)
            .apply()
    }

    /** 常驻前台服务是否正在运行（读取进程内共享状态，比 getRunningServices 可靠）。 */
    private fun isServiceRunning(serviceClass: Class<*>): Boolean {
        return if (serviceClass == LxForegroundService::class.java) {
            LxForegroundService.isRunning
        } else {
            false
        }
    }

    /** 当前是否已加入电池优化白名单（未加入时系统更容易在后台回收进程）。 */
    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        val manager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        return manager.isIgnoringBatteryOptimizations(packageName)
    }

    /** 拉起系统“忽略电池优化”授权弹窗。 */
    private fun requestIgnoreBatteryOptimizationsInternal() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        if (isIgnoringBatteryOptimizations()) {
            return
        }
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (e: Exception) {
            // 部分 ROM 屏蔽该 Intent，降级到电池优化设置列表页
            try {
                startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (e2: Exception) {
                e2.printStackTrace()
            }
        }
    }
}

