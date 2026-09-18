package com.lx.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 开机自启接收器。
 *
 * 行为：设备开机（或应用被更新）后，只有当用户【已登录且开启常驻】时，
 * 才拉起前台服务；否则什么都不做，避免未登录用户看到无意义的常驻通知。
 *
 * 说明：Android 12+ 允许应用在收到 BOOT_COMPLETED 后启动前台服务
 * （属于系统豁免场景），因此这里可以直接调用 startForegroundService。
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "LxBootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }

        val prefs = context.getSharedPreferences(
            LxForegroundService.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        val keepAliveEnabled = prefs.getBoolean(LxForegroundService.KEY_KEEP_ALIVE, false)

        Log.i(TAG, "收到开机广播($action)，常驻开关=$keepAliveEnabled")

        if (keepAliveEnabled) {
            LxForegroundService.start(context)
        }
    }
}
