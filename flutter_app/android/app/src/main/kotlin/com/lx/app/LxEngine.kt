package com.lx.app

/**
 * 全局常量：FlutterEngine 在 FlutterEngineCache 中使用的键名。
 *
 * 常驻保活的核心是“同一个缓存的 FlutterEngine 被 Activity 与前台服务共享”：
 * - MainActivity.provideFlutterEngine() 创建/取出它，并在销毁时【不】销毁它；
 * - LxForegroundService 启动时读取它，确认 Dart isolate 仍在运行。
 * 两处必须使用同一个键，因此提取到这里，避免拼写不一致导致引擎被重复创建。
 */
object LxEngine {
    const val MAIN_ENGINE_ID = "lx_main_engine"
}
