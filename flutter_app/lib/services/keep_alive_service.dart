import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 后台常驻保活（前台服务）的 Dart 侧封装。
///
/// 背景：划掉任务栏时 FlutterActivity 会被销毁，默认会连带销毁 FlutterEngine，
/// 导致 Dart isolate 中的中继轮询（SyncService 的 4 秒会话看门狗）与 WebSocket
/// 长连接（LocalAgentService）一并停止，表现为“划掉即失联、收不到新消息”。
///
/// 原生侧已实现（见 android/app/src/main/kotlin/com/lx/app/）：
/// - `LxForegroundService`：常驻前台服务（`stopWithTask="false"`，划掉任务后仍运行）；
/// - `MainActivity.provideFlutterEngine()` + `shouldDestroyEngineWithHost() = false`：
///   让 FlutterEngine 缓存复用、不随 Activity 销毁，从而保住 Dart isolate。
///
/// 本类只负责“通知原生侧开启/关闭常驻”以及“申请电池优化白名单”。
/// 仅在 Android 上生效，其它平台为空操作。
class KeepAliveService {
  KeepAliveService._();

  static const MethodChannel _channel = MethodChannel('com.lx.app/app_launcher');

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// 开启常驻保活：拉起前台服务（会显示一条常驻通知），并记录开关供开机自启使用。
  ///
  /// 返回值：true 表示通知权限已就绪；false 表示正在向用户申请通知权限
  /// （服务仍会拉起，但 Android 13+ 未授权时通知不可见）。
  static Future<bool> start() async {
    if (!_isAndroid) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('startKeepAliveService');
      return granted ?? false;
    } catch (e) {
      debugPrint('[KeepAlive] 启动常驻服务失败: $e');
      return false;
    }
  }

  /// 关闭常驻保活（例如用户主动退出登录时）。
  static Future<void> stop() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('stopKeepAliveService');
    } catch (e) {
      debugPrint('[KeepAlive] 停止常驻服务失败: $e');
    }
  }

  /// 常驻服务当前是否在运行。
  static Future<bool> isRunning() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isKeepAliveRunning') ?? false;
    } catch (e) {
      debugPrint('[KeepAlive] 查询常驻服务状态失败: $e');
      return false;
    }
  }

  /// 应用是否已加入电池优化白名单（未加入时系统更容易在后台回收进程）。
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } catch (e) {
      debugPrint('[KeepAlive] 查询电池优化状态失败: $e');
      return false;
    }
  }

  /// 拉起系统“忽略电池优化”授权弹窗（提升后台存活率的关键一步）。
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('[KeepAlive] 申请电池优化白名单失败: $e');
    }
  }

  /// 打开本应用的系统详情页。
  ///
  /// 用来让用户手动允许「后台数据」、开启自启动等 —— 这些开关没有公开 API，
  /// 只能把用户送到正确的位置（部分机型还有"后台流量限制"这类额外开关）。
  static Future<void> openAppSettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('openAppSettings');
    } catch (e) {
      debugPrint('[KeepAlive] 打开应用设置页失败: $e');
    }
  }

  /// 打开系统的电池优化列表页（部分 ROM 没有直接授权弹窗时的兜底入口）
  static Future<void> openBatteryOptimizationSettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('openBatteryOptimizationSettings');
    } catch (e) {
      debugPrint('[KeepAlive] 打开电池优化列表失败: $e');
    }
  }

  /// 登录成功后的统一入口：开启常驻 + 引导加入电池优化白名单。
  static Future<void> enableAfterLogin() async {
    if (!_isAndroid) return;
    debugPrint('[KeepAlive] 登录成功，正在开启后台常驻服务...');
    final granted = await start();
    // 未加入白名单时拉起系统授权弹窗（用户可拒绝，不影响后续使用）
    final ignoring = await isIgnoringBatteryOptimizations();
    debugPrint('[KeepAlive] 服务已拉起(通知权限=$granted)，电池优化白名单=$ignoring');
    if (!ignoring) {
      await requestIgnoreBatteryOptimizations();
    }
  }
}
