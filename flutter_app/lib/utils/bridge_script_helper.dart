import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'web_download_stub.dart' if (dart.library.html) 'web_download_helper.dart' as web_download;
import '../config/app_config.dart';

class BridgeScriptHelper {
  /// 从应用内置 Assets 中读取完整的工业级生产 lxai_bridge.py。
  ///
  /// 读取失败或内容明显残缺时返回 **null**（调用方必须处理），绝不返回替代品。
  ///
  /// 历史教训：这里曾经在读取失败时降级返回一个 `generatePyContent()` 的"空壳脚本"
  /// —— 148 行、自称 v3.6，实际只探活一次宿主然后 `while True: sleep(5)`，永远不连中继。
  /// 而 `BridgeProcessManager.ensureScriptUpToDate()` 会拿这个返回值**覆盖磁盘上能用的
  /// 脚本**，于是"资产读取失败"会静默演变成"桥接进程活着但电脑端永远离线"，
  /// 用户拿不到任何指向真因的报错。宁可明确失败，也不要这种假成功。
  static Future<String?> getFullBridgeScriptContent() async {
    try {
      final content = await rootBundle.loadString('assets/scripts/lxai_bridge.py');
      if (isPlausibleBridgeScript(content)) {
        return content;
      }
      debugPrint('[BridgeScriptHelper] 内置 lxai_bridge.py 内容不完整（${content.length} 字符），拒绝使用');
    } catch (e) {
      debugPrint('[BridgeScriptHelper] 读取内置 assets/scripts/lxai_bridge.py 失败: $e');
    }
    return null;
  }

  /// 内容合理性检查：只认"看起来确实是那份桥接脚本"的文本。
  ///
  /// 双重保险 —— 读取侧（本文件）用它挡掉残缺资产，写入侧
  /// （`BridgeProcessManager.ensureScriptUpToDate`）用它挡掉"用残缺内容覆盖好脚本"。
  /// 判据取真脚本里稳定的三处特征 + 体积下限（真脚本约 3300 行 / 134KB）。
  static bool isPlausibleBridgeScript(String content) {
    if (content.trim().length < 20000) return false;
    const markers = <String>['def poll_', 'def dsh_headers', 'merge_session_row'];
    for (final marker in markers) {
      if (!content.contains(marker)) return false;
    }
    return true;
  }

  /// 生成适配 Windows 一键启动的 run_bridge.bat 脚本内容
  static String generateBatContent({
    required String token,
    required String serverUrl,
    required String harnessUrl,
  }) {
    final cleanServer = serverUrl.isNotEmpty ? serverUrl : AppConfig.normalizedServerBaseUrl;
    final cleanHarness = harnessUrl.isNotEmpty ? harnessUrl : 'http://127.0.0.1:19387';
    final cleanToken = token.isNotEmpty ? token : 'agent_default';

    // 行尾必须显式写成 CRLF 后再落盘：Windows 的 cmd.exe 按 CRLF 定位批处理行边界，
    // LF-only 的 .bat 会被逐字符吃掉（echo → cho、title → t），双击直接报
    // "xxx 不是内部或外部命令"。这里的模板字符串换行天生是 LF，故统一转换一次。
    return '''@echo off
chcp 65001 >nul
title LxAI Bridge 本地智能体桥接服务
echo ======================================================================
echo    LxAI 本地 Agent 桥接一键启动脚本 (会话自动管理增强版)
echo    服务器地址: $cleanServer
echo    本地 Harness: $cleanHarness
echo ======================================================================
echo.

where python >nul 2>nul
if %errorlevel% neq 0 (
    echo [错误] 未检测到 Python 环境，请先安装 Python 3.8+ 并勾选 Add to PATH！
    pause
    exit /b 1
)

echo [1/3] 正在检查依赖库 (websockets, aiohttp, urllib3)...
python -m pip install websockets aiohttp urllib3 -q --disable-pip-version-check 2>nul

echo [2/3] 正在同步下载最新的 lxai_bridge.py 桥接程序...
python -c "import urllib.request; urllib.request.urlretrieve('$cleanServer/api/download/lxai_bridge.py', 'lxai_bridge.py')" 2>nul

if not exist "lxai_bridge.py" (
    echo [警告] 自动下载失败，将尝试使用本地已有的 lxai_bridge.py...
)

echo [3/3] 正在启动桥接服务并连接调度中心...
echo.
python lxai_bridge.py --server "$cleanServer" --token "$cleanToken" --harness-url "$cleanHarness"
if %errorlevel% neq 0 (
    echo.
    echo 桥接服务异常退出，请检查上方日志。
    pause
)
'''.replaceAll('\n', '\r\n');
  }

  /// 真实触发文件下载与保存：
  /// - Web 端：通过浏览器 Blob 下载；
  /// - 电脑桌面端（Windows / macOS / Linux）：正常弹出系统文件选择器由用户挑选保存位置；
  /// - 手机端（Android / iOS）：直接复制/保存至系统公共 Download 目录，方便文件管理器或社交软件即刻查看与分享。
  static Future<String?> downloadFile({
    required String fileName,
    required String content,
  }) async {
    try {
      final bytes = utf8.encode(content);
      if (kIsWeb) {
        web_download.downloadFileWeb(fileName, bytes);
        return '浏览器下载已启动';
      }

      // 电脑桌面端（Windows / macOS / Linux）：正常弹出系统文件保存窗口
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: '保存脚本文件',
          fileName: fileName,
        );
        if (savePath == null) {
          // 用户主动在弹窗中点击取消
          return null;
        }
        final file = File(savePath);
        await file.writeAsBytes(bytes);
        return savePath;
      }

      // 手机移动端（Android / iOS）：优先直接存入系统公共 Download 目录
      String targetPath = '';
      if (Platform.isAndroid) {
        // 安卓公共系统下载目录
        const publicDownloadDir = '/storage/emulated/0/Download';
        final pDir = Directory(publicDownloadDir);
        if (await pDir.exists()) {
          targetPath = '$publicDownloadDir/$fileName';
        } else {
          // 降级使用外部私有存储
          final extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            targetPath = '${extDir.path}/$fileName';
          }
        }
      }

      // iOS 或其它平台的兜底路径
      if (targetPath.isEmpty) {
        final docsDir = await getApplicationDocumentsDirectory();
        targetPath = '${docsDir.path}/$fileName';
      }

      final file = File(targetPath);
      await file.writeAsBytes(bytes);
      return targetPath;
    } catch (e) {
      debugPrint('[BridgeScriptHelper] 下载文件出错: $e');
      return null;
    }
  }
}
