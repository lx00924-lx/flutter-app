import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

class UrlLauncherHelper {
  static const MethodChannel _channel = MethodChannel('com.lx.app/app_launcher');

  /// Android 端：请求系统通知权限（Android 13+ 运行时通知权限申请）
  static Future<bool> requestNotificationPermission() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final bool? res = await _channel.invokeMethod<bool>('requestNotificationPermission');
        return res ?? false;
      } catch (e) {
        debugPrint('请求通知权限失败: $e');
        return false;
      }
    }
    return true;
  }

  /// Android 端：检查系统通知权限是否已授予
  static Future<bool> checkNotificationPermission() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final bool? res = await _channel.invokeMethod<bool>('checkNotificationPermission');
        return res ?? false;
      } catch (e) {
        debugPrint('检查通知权限失败: $e');
        return false;
      }
    }
    return true;
  }

  /// Android 端：更新系统通知栏下载进度条
  static Future<void> showDownloadNotification({
    required int progress,
    int max = 100,
    String title = '正在下载安装包',
    String content = '',
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('showDownloadNotification', {
          'progress': progress,
          'max': max,
          'title': title,
          'content': content.isNotEmpty ? content : '$progress%',
        });
      } catch (e) {
        debugPrint('更新下载通知栏失败: $e');
      }
    }
  }

  /// Android 端：下载完成，通知栏提示“下载完成，点击立即安装”并挂载点击安装 PendingIntent
  static Future<void> completeDownloadNotification({
    required String apkPath,
    String title = '下载完成',
    String content = '点击立即安装新版本',
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('completeDownloadNotification', {
          'title': title,
          'content': content,
          'apkPath': apkPath,
        });
      } catch (e) {
        debugPrint('完成通知栏更新失败: $e');
      }
    }
  }

  /// Android 端：取消/清除下载通知
  static Future<void> cancelNotification() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('cancelNotification');
      } catch (e) {
        debugPrint('取消通知失败: $e');
      }
    }
  }

  /// Android 端：直接弹出系统原生安装界面
  static Future<bool> installApk(String apkPath) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<bool>('installApk', {
          'apkPath': apkPath,
        });
        return result ?? false;
      } catch (e) {
        debugPrint('调起 Android 系统安装器失败: $e');
      }
    }
    return false;
  }

  /// Windows 端：脱钩拉起独立安装程序，并安全退出当前应用避免文件占用冲突
  static Future<bool> launchWindowsInstaller(String exePath) async {
    if (!kIsWeb && Platform.isWindows) {
      try {
        await Process.start(
          exePath,
          [],
          mode: ProcessStartMode.detached,
        );
        // 留出 500ms 缓冲确保安装进程成功独立接管
        await Future.delayed(const Duration(milliseconds: 500));
        // 优雅自杀退出，彻底释放 dll 和主 exe 句柄
        exit(0);
      } catch (e) {
        debugPrint('脱钩启动 Windows 安装包失败: $e');
        return false;
      }
    }
    return false;
  }

  /// 跨平台打开外部链接（支持 Android 唤起系统浏览器、Windows 执行默认浏览器打开等）
  static Future<bool> openUrl(String url) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return false;

    if (kIsWeb) {
      return false;
    }

    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<bool>('openUrl', {'url': cleanUrl});
        return result ?? false;
      } else if (Platform.isWindows) {
        // Windows 通过 start 打开默认浏览器直接下载
        await Process.run('cmd', ['/c', 'start', '', cleanUrl]);
        return true;
      } else if (Platform.isMacOS) {
        await Process.run('open', [cleanUrl]);
        return true;
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [cleanUrl]);
        return true;
      }
    } catch (e) {
      debugPrint('打开 URL 失败: $e');
    }
    return false;
  }
}
