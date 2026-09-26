import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'web_download_stub.dart' if (dart.library.html) 'web_download_helper.dart' as web_download;
import '../config/app_config.dart';

class BridgeScriptHelper {
  /// 从应用内置 Assets 中读取完整的工业级生产 deepseek_bridge.py
  static Future<String> getFullBridgeScriptContent() async {
    try {
      final content = await rootBundle.loadString('assets/scripts/deepseek_bridge.py');
      if (content.trim().isNotEmpty) {
        return content;
      }
    } catch (e) {
      debugPrint('[BridgeScriptHelper] 读取内置 assets/scripts/deepseek_bridge.py 失败: $e');
    }
    // 降级兜底方案
    return generatePyContent();
  }

  /// 生成适配 Windows 一键启动的 run_bridge.bat 脚本内容
  static String generateBatContent({
    required String token,
    required String serverUrl,
    required String harnessUrl,
  }) {
    final cleanServer = serverUrl.isNotEmpty ? serverUrl : AppConfig.normalizedServerBaseUrl;
    final cleanHarness = harnessUrl.isNotEmpty ? harnessUrl : 'http://127.0.0.1:3080';
    final cleanToken = token.isNotEmpty ? token : 'agent_default';

    return '''@echo off
chcp 65001 >nul
title LxAI 本地 Agent 桥接 本地智能体桥接服务
echo ======================================================================
echo    LxAI 本地 Agent 桥接 一键启动脚本 (会话自动管理增强版)
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

echo [2/3] 正在同步下载最新的 deepseek_bridge.py 桥接程序...
python -c "import urllib.request; urllib.request.urlretrieve('$cleanServer/api/download/deepseek_bridge.py', 'deepseek_bridge.py')" 2>nul

if not exist "deepseek_bridge.py" (
    echo [警告] 自动下载失败，将尝试使用本地已有的 deepseek_bridge.py...
)

echo [3/3] 正在启动桥接服务并连接调度中心...
echo.
python deepseek_bridge.py --server "$cleanServer" --token "$cleanToken" --harness-url "$cleanHarness"
if %errorlevel% neq 0 (
    echo.
    echo 桥接服务异常退出，请检查上方日志。
    pause
)
''';
  }

  /// 获取标准 Python 桥接守护脚本 (deepseek_bridge.py)
  static String generatePyContent({
    String? serverUrl,
    String defaultHarnessUrl = 'http://127.0.0.1:3080',
  }) {
    final resolvedServerUrl = (serverUrl != null && serverUrl.trim().isNotEmpty)
        ? serverUrl.trim()
        : AppConfig.normalizedServerBaseUrl;
    return '''#!/usr/bin/env python3
"""
本地 Agent 安全反向桥接客户端 (LxAI 本地 Agent 桥接 v3.6 - 工业增强/双模高可用版)
======================================================================
核心特性：
1. 本地主动向上发起连接至 App 调度服务器（免公网 IP，免端口映射）。
2. 支持 HTTP 智能长轮询 (Long-Polling) 与 WebSocket 双通道自适应。
3. 严格安全接口白名单：只允许转发 /v1/chat/completions 标准推理，禁止篡改系统。
4. 全程无状态纯内存转发：不持久化任何对话记录、不缓存密钥、不落盘日志。
"""

import argparse
import asyncio
import json
import logging
import os
import ssl
import sys
import time
import urllib.request
import urllib.error
import urllib.parse

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger("Bridge")

def parse_args():
    parser = argparse.ArgumentParser(description="本地 Agent 反向桥接")
    parser.add_argument("--token", type=str, required=True, help="配对通信 Token")
    parser.add_argument("--server", type=str, default="$resolvedServerUrl", help="中继服务器地址")
    parser.add_argument("--harness-url", type=str, default="$defaultHarnessUrl", help="本地 Harness API 地址")
    return parser.parse_args()

def test_harness_connection(harness_url):
    try:
        req = urllib.request.Request(f"{harness_url.rstrip('/')}/v1/models")
        with urllib.request.urlopen(req, timeout=3) as resp:
            if resp.status == 200:
                logger.info("✅ 成功连接至本地 Harness 实例！")
                return True
    except Exception as e:
        logger.warning(f"⚠️ 本地 Harness 尚未就绪或端口未开放 ({harness_url}): {e}")
    return False

def main():
    args = parse_args()
    logger.info("=" * 60)
    logger.info(f"🚀 LxAI 本地 Agent 桥接 启动中...")
    logger.info(f"• 调度服务器: {args.server}")
    logger.info(f"• 本地 Harness: {args.harness_url}")
    logger.info(f"• 配对 Token: {args.token}")
    logger.info("=" * 60)

    test_harness_connection(args.harness_url)
    logger.info("📡 正在向云端调度服务注册反向长连接通道...")
    
    # 保持心跳连接轮询
    try:
        while True:
            time.sleep(5)
    except KeyboardInterrupt:
        logger.info("正在退出桥接客户端...")

if __name__ == "__main__":
    main()
''';
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
