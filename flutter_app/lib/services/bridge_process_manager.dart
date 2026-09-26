import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../utils/bridge_script_helper.dart';

/// 本地 bridge（`lxai_bridge.py`）进程的**全局**管理器。
///
/// 为什么需要它：此前进程由「本地 Agent 设置页」的 State 持有，带来两个问题：
/// 1. 页面一旦销毁，进程退出监控就被取消 —— 用户在别的页面时，桥接崩了/被重置
///    导致退出，App 完全感知不到，也不会自动恢复；
/// 2. 无法接收来自手机的启停指令（页面不在前台就没人执行）。
///
/// 现在把进程生命周期收敛到这个单例服务，页面只做展示与调用，因此：
/// * 退出监控全局有效，意外退出（如手机重置 Token）可自动用新 Token 重启；
/// * 手机下发的启停指令可在任意时刻被执行。
class BridgeProcessManager extends ChangeNotifier {
  BridgeProcessManager._();

  static final BridgeProcessManager instance = BridgeProcessManager._();

  Process? _process;
  int? _pid;
  Timer? _watchTimer;
  bool _stoppedByUser = false;
  int _autoRestartCount = 0;
  String _lastHarnessUrl = '127.0.0.1:3080';
  String _lastToken = '';

  /// 最近一次操作的结果提示（供界面弹 SnackBar）
  String? lastMessage;
  bool lastMessageIsError = false;

  /// 自动重启时用于获取「当前有效 Token」的回调，由 SettingsProvider 注册。
  Future<String> Function()? tokenProvider;
  /// 获取最近一次设置里的 harness 地址
  Future<String> Function()? harnessUrlProvider;

  bool get isRunning => _process != null;
  int? get pid => _pid;

  /// 启动（已在运行则忽略）。[token] 为空时脚本会进入扫码配对流程。
  ///
  /// [resetRetryCount]：用户/远端主动启动时重置自动重连次数，让每次手动或
  /// 手机下发的启动都重新拥有完整的重试预算。自动重连路径必须传 false，
  /// 否则计数被清零会导致"无限重启"。
  Future<bool> start({
    required String token,
    required String harnessUrl,
    bool resetRetryCount = true,
  }) async {
    if (_process != null) return true;
    if (resetRetryCount) _autoRestartCount = 0;

    _lastToken = token.trim();
    _lastHarnessUrl = harnessUrl.trim().isEmpty ? '127.0.0.1:3080' : harnessUrl.trim();

    try {
      final scriptPath = 'lxai_bridge.py';
      await ensureScriptUpToDate(scriptPath);

      // 启动前先清掉游离的旧桥接进程。
      //
      // 桥接是用 detached 方式拉起来的，App 被强杀、或被覆盖安装/更新时它不会跟着
      // 退出；用户下次再点「启动」就会变成两个进程抢同一枚 Token —— 服务端按 Token
      // 只认最后一个连接，表现就是"时好时坏、偶尔收不到任务"。这里统一清理，
      // 保证任何时刻只有一个桥接在跑。
      if (Platform.isWindows) {
        await _killStaleBridges(scriptPath);
      }

      final executable = Platform.isWindows ? 'python' : 'python3';
      // 让桥接把输出同时落盘：App 这边只能滚动显示最近几行，进程一崩（异常/硬崩溃）
      // 现场就随管道散了 —— 之前"桥接凭空掉线"查不下去就是这个原因。
      // 日志落在脚本同一目录（= App 工作目录），桥接侧会自动轮转并打码 token。
      final bridgeDir = File(scriptPath).absolute.parent.path;
      final bridgeLogPath = '$bridgeDir${Platform.pathSeparator}bridge-run.log';
      final args = <String>[
        scriptPath,
        if (_lastToken.isNotEmpty) ...['--token', _lastToken],
        '--harness-url', 'http://$_lastHarnessUrl',
        '--server', AppConfig.normalizedServerBaseUrl,
        '--log-file', bridgeLogPath,
        '--log-max-mb', '5',
      ];

      final process = await Process.start(
        executable,
        args,
        mode: ProcessStartMode.detachedWithStdio,
      );

      _process = process;
      _pid = process.pid;
      _stoppedByUser = false;
      _setMessage('桥接服务已在后台运行', isError: false);
      _watch(process.pid);
      notifyListeners();
      return true;
    } catch (e) {
      _setMessage('启动失败: $e（请确认电脑已安装 Python 并加入 PATH）', isError: true);
      notifyListeners();
      return false;
    }
  }

  /// 停止：用户主动停止时不再自动重启。
  Future<void> stop({bool byUser = true}) async {
    final proc = _process;
    if (proc == null) return;
    _stoppedByUser = byUser;
    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {
      try {
        proc.kill();
      } catch (_) {}
    }
    _watchTimer?.cancel();
    _process = null;
    _pid = null;
    if (byUser) {
      _setMessage('已停止电脑后台桥接守护进程', isError: false);
    }
    notifyListeners();
  }

  /// 重启：先停旧进程，再用给定 Token 启动。
  Future<bool> restart({
    required String token,
    required String harnessUrl,
  }) async {
    await stop(byUser: true);
    // 给进程一点退出时间，避免连接/端口残留
    await Future.delayed(const Duration(milliseconds: 600));
    return start(token: token, harnessUrl: harnessUrl);
  }

  /// 清掉本机游离的旧桥接进程（只认命令行里带 lxai_bridge.py 的 python）。
  ///
  /// 只清理同名脚本的进程，不动其它 python：用户可能有别的脚本在跑。
  Future<void> _killStaleBridges(String scriptPath) async {
    try {
      final cmd = "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | "
          "Where-Object { \$_.CommandLine -like '*$scriptPath*' } | "
          "ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }";
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', cmd],
      ).timeout(const Duration(seconds: 10));
      debugPrint('[Bridge] 已清理游离的旧桥接进程（exit=${result.exitCode}）');
    } catch (e) {
      debugPrint('[Bridge] 清理旧桥接进程失败（忽略，继续启动）: $e');
    }
  }

  /// 保证磁盘上的脚本与 App 内置版本一致（旧版本会导致功能缺失）。
  Future<void> ensureScriptUpToDate(String scriptPath) async {    try {
      final pyContent = await BridgeScriptHelper.getFullBridgeScriptContent();
      final file = File(scriptPath);
      if (await file.exists()) {
        final existing = await file.readAsString();
        if (existing.trim() == pyContent.trim()) return;
        debugPrint('[Bridge] 本地脚本与内置版本不一致，正在更新...');
      }
      await file.writeAsString(pyContent);
    } catch (e) {
      debugPrint('[Bridge] 更新脚本失败（沿用现有文件）: $e');
    }
  }

  void _watch(int pid) {
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final proc = _process;
      if (proc == null || proc.pid != pid) {
        timer.cancel();
        return;
      }
      int? code;
      try {
        code = await proc.exitCode.timeout(const Duration(milliseconds: 300));
      } catch (_) {
        code = null; // 仍在运行
      }
      if (code == null) return;

      // 进程已退出
      timer.cancel();
      final stoppedByUser = _stoppedByUser;
      _stoppedByUser = false;
      _process = null;
      _pid = null;

      if (stoppedByUser) {
        notifyListeners();
        return;
      }

      // 非主动停止：最典型原因是「另一端点了重置 Token」——服务端换发新 Token
      // 并通知本机，脚本按设计自行退出。这里自动用刚下发的新 Token 拉起来。
      if (_autoRestartCount < 3) {
        _autoRestartCount++;
        _setMessage('检测到 Token 已变更，正在自动重连桥接...', isError: false);
        notifyListeners();
        // 等服务端的新 Token 通过会话轮询同步到本地
        await Future.delayed(const Duration(seconds: 5));
        String token = _lastToken;
        String harness = _lastHarnessUrl;
        try {
          if (tokenProvider != null) token = (await tokenProvider!()).trim();
        } catch (_) {}
        try {
          if (harnessUrlProvider != null) {
            final h = (await harnessUrlProvider!()).trim();
            if (h.isNotEmpty) harness = h;
          }
        } catch (_) {}
        await start(token: token, harnessUrl: harness, resetRetryCount: false);
      } else {
        _setMessage('桥接反复退出（退出码 $code），已停止自动重试，请手动启动', isError: true);
        notifyListeners();
      }
    });
  }

  void _setMessage(String text, {required bool isError}) {
    lastMessage = text;
    lastMessageIsError = isError;
  }

  /// 取出并清空待展示的提示
  String? takeMessage() {
    final m = lastMessage;
    lastMessage = null;
    return m;
  }
}
