import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../config/app_config.dart';
import '../utils/bridge_script_helper.dart';
import '../services/sync_service.dart';

class HarnessSettingsScreen extends StatefulWidget {
  const HarnessSettingsScreen({super.key});

  @override
  State<HarnessSettingsScreen> createState() => _HarnessSettingsScreenState();
}

class _HarnessSettingsScreenState extends State<HarnessSettingsScreen> {
  late TextEditingController _tokenCtrl;
  late TextEditingController _harnessUrlCtrl;
  late TextEditingController _workspaceCtrl;
  late TextEditingController _localWsUrlCtrl;
  late TextEditingController _localAgentTokenCtrl;

  final FocusNode _tokenFocus = FocusNode();
  final FocusNode _harnessUrlFocus = FocusNode();
  final FocusNode _workspaceFocus = FocusNode();
  final FocusNode _localWsUrlFocus = FocusNode();
  final FocusNode _localAgentTokenFocus = FocusNode();

  bool _isRefreshing = false;
  bool _isStartingBridge = false;
  /// 正在向服务端换发配对 Token（防止重复点击）
  bool _isRotatingToken = false;
  /// 桥接进程存活监控：进程意外退出时（例如 Token 被重置导致 bridge 自行退出）
  /// 需要把界面状态同步回"未启动"，否则会出现"界面显示守护中、实际进程已死"的假状态。
  Timer? _bridgeWatchTimer;
  /// 用户主动停止时为 true，避免监控把"主动停止"误判为"意外退出"
  bool _bridgeStoppedByUser = false;
  /// 自动重启次数上限（防止桥接反复失败时无限重启）
  int _bridgeAutoRestartCount = 0;
  static Process? _headlessBridgeProcess; // 桌面端保持全局单例后台守护进程
  List<String> _workspaces = ['deepseek-agent', 'workspace-main', 'dev-sandbox'];
  List<Map<String, dynamic>> _rawSessions = [];
  List<String> _filteredSessions = ['智能选择 / 自动新建会话 (推荐)'];
  String _selectedSession = '智能选择 / 自动新建会话 (推荐)';

  /// 对 Token 进行脱敏展示（例如: sk-1234******************）
  static String _maskToken(String token) {
    final t = token.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('sk-')) {
      final prefix = t.substring(0, t.length >= 7 ? 7 : t.length); // 保留 sk- 及前4位
      return '$prefix${'*' * 18}';
    } else if (t.startsWith('agent_')) {
      final prefix = t.substring(0, t.length >= 10 ? 10 : t.length);
      return '$prefix${'*' * 18}';
    } else {
      final prefix = t.substring(0, t.length >= 4 ? 4 : t.length);
      return '$prefix${'*' * 18}';
    }
  }

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsProvider>().settings;
    _tokenCtrl = TextEditingController(text: s.harnessToken);
    var urlText = s.harnessServiceUrl.trim();
    if (urlText.startsWith('http://')) {
      urlText = urlText.substring(7);
    } else if (urlText.startsWith('https://')) {
      urlText = urlText.substring(8);
    }
    if (urlText.isEmpty) {
      urlText = '127.0.0.1:3080';
    }
    _harnessUrlCtrl = TextEditingController(text: urlText);
    _workspaceCtrl = TextEditingController(text: s.targetWorkspace);
    _localWsUrlCtrl = TextEditingController(
      text: s.localBridgeWsUrl.isNotEmpty ? s.localBridgeWsUrl : 'http://127.0.0.1:3080',
    );
    _localAgentTokenCtrl = TextEditingController(text: s.localAgentToken);

    if (!_workspaces.contains(s.targetWorkspace)) {
      _workspaces.insert(0, s.targetWorkspace);
    }

    // 绑定失焦自动保存监听，解决每次击键卡顿问题
    _tokenFocus.addListener(_handleFocusChange);
    _harnessUrlFocus.addListener(_handleFocusChange);
    _workspaceFocus.addListener(() {
      _handleFocusChange();
      if (!_workspaceFocus.hasFocus) {
        _updateFilteredSessions();
      }
    });
    _localWsUrlFocus.addListener(_handleFocusChange);
    _localAgentTokenFocus.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (!_tokenFocus.hasFocus &&
        !_harnessUrlFocus.hasFocus &&
        !_workspaceFocus.hasFocus &&
        !_localWsUrlFocus.hasFocus &&
        !_localAgentTokenFocus.hasFocus) {
      _saveSilently();
    }
  }

  void _updateFilteredSessions() {
    final currentWs = _workspaceCtrl.text.trim();
    final list = <String>['智能选择 / 自动新建会话 (推荐)'];
    for (final sess in _rawSessions) {
      final sessWs = sess['workspace']?.toString() ?? '';
      if (sessWs.isEmpty || sessWs == currentWs) {
        final title = sess['title']?.toString() ?? sess['id']?.toString() ?? '未命名会话';
        list.add(title);
      }
    }
    setState(() {
      _filteredSessions = list;
      if (!_filteredSessions.contains(_selectedSession)) {
        _selectedSession = _filteredSessions.first;
      }
    });
  }

  void _saveSilently() {
    if (!mounted) return;
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    s.harnessToken = _tokenCtrl.text.trim();
    var rawUrl = _harnessUrlCtrl.text.trim();
    if (rawUrl.isEmpty) rawUrl = '127.0.0.1:3080';
    if (!rawUrl.startsWith('http://') && !rawUrl.startsWith('https://')) {
      s.harnessServiceUrl = 'http://$rawUrl';
    } else {
      s.harnessServiceUrl = rawUrl;
    }
    s.targetWorkspace = _workspaceCtrl.text.trim();
    s.localBridgeWsUrl = _localWsUrlCtrl.text.trim().isNotEmpty
        ? _localWsUrlCtrl.text.trim()
        : 'http://127.0.0.1:3080';
    s.localAgentToken = _localAgentTokenCtrl.text.trim();
    sp.updateSettings(s);
  }

  @override
  void dispose() {
    _saveSilently();
    _bridgeWatchTimer?.cancel();
    _tokenFocus.dispose();
    _harnessUrlFocus.dispose();
    _workspaceFocus.dispose();
    _localWsUrlFocus.dispose();
    _localAgentTokenFocus.dispose();
    _tokenCtrl.dispose();
    _harnessUrlCtrl.dispose();
    _workspaceCtrl.dispose();
    _localWsUrlCtrl.dispose();
    _localAgentTokenCtrl.dispose();
    super.dispose();
  }

  void _save() {
    FocusScope.of(context).unfocus();
    _saveSilently();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Harness 桥接设置已保存')),
    );
  }

  Future<void> _refreshWorkspacesAndSessions() async {
    setState(() => _isRefreshing = true);
    final sp = context.read<SettingsProvider>();
    try {
      final res = await sp.fetchAgentWorkspacesAndSessions();
      final isOnline = res['online'] == true;
      final wsList = (res['workspaces'] as List<dynamic>?)?.map((e) => e.toString()).toList();
      final sessList = (res['sessions'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList();

      if (mounted) {
        setState(() {
          _isRefreshing = false;
          if (wsList != null && wsList.isNotEmpty) {
            _workspaces = wsList;
            if (!_workspaces.contains(_workspaceCtrl.text.trim())) {
              _workspaceCtrl.text = _workspaces.first;
            }
          }
          if (sessList != null) {
            _rawSessions = sessList;
            _updateFilteredSessions();
          }
        });

        if (isOnline) {
          // 关键：不能只看 online 就报成功——bridge 在线但没取到真实工作区时，
          // _workspaces 仍是本地预设占位值，必须明确告知用户，避免“假成功”。
          final gotReal = wsList != null && wsList.isNotEmpty;
          ScaffoldMessenger.of(context).showSnackBar(
            gotReal
                ? SnackBar(content: Text('✅ 成功同步本地 Agent 工作区（共 ${_workspaces.length} 个工作区）'))
                : const SnackBar(
                    content: Text('⚠️ 桥接已在线，但未取到本地目录列表（请检查电脑端 DSH 是否正常）'),
                    backgroundColor: Colors.orange,
                  ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ 电脑端桥接脚本当前未在线，已载入本地预设工作区'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRefreshing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('刷新异常: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  /// 启动/停止本地后台无头桥接程序 (仅限桌面端 Windows/macOS/Linux)
  /// 重新生成配对 Token（服务端换发）+ 必要时重启已运行的桥接进程。
  ///
  /// 关键点：token 唯一真源在服务端，所以这里不能本地随机生成；
  /// 换发后若桥接进程仍在运行，它会继续用旧 token 连接（表现为"界面显示新 token
  /// 但电脑端仍是旧 token、手机连不上"），因此必须同步重启桥接。
  Future<void> _rotateToken(SettingsProvider sp) async {
    final s = sp.settings;
    final oldToken = s.harnessToken.trim();
    setState(() => _isRotatingToken = true);
    try {
      final newToken = await SyncService.instance.rotateAgentToken(
        userId: s.loginAccount,
        oldToken: oldToken,
      );
      if (!mounted) return;

      if (newToken == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('换发失败：请确认已登录且网络正常'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      final bridgeWasRunning = _headlessBridgeProcess != null;
      setState(() {
        _tokenCtrl.text = newToken;
        s.harnessToken = newToken;
      });
      sp.updateSettings(s);

      if (bridgeWasRunning) {
        // 电脑端重置：直接用服务端换发的新 token 重启桥接（App 托管场景下
        // 该 token 即配对凭据，无需再扫码）。
        // 手机端重置导致的"桥接已停止"由 _watchBridgeProcess 自动重启处理。
        await _restartHeadlessBridge(newToken, _harnessUrlCtrl.text.trim());
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🔑 配对 Token 已更新，电脑端桥接已自动重启并重连'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🔑 配对 Token 已更新（桥接未运行，下次启动将使用新 Token）')),
        );
      }
    } finally {
      if (mounted) setState(() => _isRotatingToken = false);
    }
  }

  /// 确保本地 bridge 脚本与 App 内置版本一致。
  ///
  /// 此前只在"文件不存在"时写入，导致**旧脚本永远不会被更新**：用户升级 App 后
  /// 仍跑着几轮之前的老脚本（例如缺少 DSH 会话鉴权、缺少凭证自愈），
  /// 表现为"桥接已启动但取不到工作区/会话"。
  /// 现改为按内容比对，不一致即覆盖。
  Future<void> _ensureBridgeScriptUpToDate(String scriptPath) async {
    final pyContent = await BridgeScriptHelper.getFullBridgeScriptContent();
    try {
      final file = File(scriptPath);
      if (await file.exists()) {
        final existing = await file.readAsString();
        if (existing.trim() == pyContent.trim()) {
          return; // 已是最新，无需重写
        }
        debugPrint('[Bridge] 检测到本地脚本与内置版本不一致，正在更新...');
      }
      await file.writeAsString(pyContent);
    } catch (e) {
      // 写失败不阻断启动：继续用磁盘上已有的脚本
      debugPrint('[Bridge] 更新本地脚本失败（将沿用现有文件）: $e');
    }
  }

  /// 启动后监控桥接进程：退出即清理界面状态，并如实提示原因。
  ///
  /// bridge 在收到服务的 token_revoked 时会自行退出（这是"重置即切断连接"的一部分），
  /// 此前 App 不会察觉，于是界面一直显示"电脑端后台守护中"，而实际进程早已结束 ——
  /// 表现为"手机端显示未连接、电脑端点重启才能恢复"。这里把状态如实反映出来。
  void _watchBridgeProcess(int pid) {
    _bridgeWatchTimer?.cancel();
    _bridgeWatchTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final proc = _headlessBridgeProcess;
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
      final stoppedByUser = _bridgeStoppedByUser;
      _bridgeStoppedByUser = false;
      _headlessBridgeProcess = null;
      if (!mounted) return;
      setState(() {});

      if (stoppedByUser) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已停止电脑后台桥接守护进程')),
        );
        return;
      }

      // 非用户主动停止 —— 最典型的原因是「手机端点了重置 Token」：
      // 服务端换发新 token 并通知本机，脚本按设计自行退出。
      // 这里自动用服务端刚下发的新 token 把它拉起来，用户无需任何手动操作。
      if (_bridgeAutoRestartCount < 3) {
        _bridgeAutoRestartCount++;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('检测到 Token 已变更，正在自动重连桥接...'),
            duration: Duration(seconds: 3),
          ),
        );
        // 等待一次会话轮询（4 秒周期）把服务端的新 token 同步到本地，
        // 否则会用旧 token 重启、立刻再次被拒。
        await Future.delayed(const Duration(seconds: 5));
        if (!mounted) return;
        final sp = context.read<SettingsProvider>();
        final token = sp.settings.harnessToken.trim();
        await _restartHeadlessBridge(token, _harnessUrlCtrl.text.trim());
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 桥接已自动重连'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('电脑端桥接反复退出（退出码 $code），已停止自动重试，请手动点击「启动」。'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    });
  }

  /// 重启后台桥接进程：先停旧进程，再用新 Token 以相同参数启动。
  Future<void> _restartHeadlessBridge(String token, String harnessUrl) async {
    final running = _headlessBridgeProcess;
    if (running != null) {
      try {
        running.kill(ProcessSignal.sigterm);
      } catch (_) {
        try {
          running.kill();
        } catch (_) {}
      }
      _headlessBridgeProcess = null;
      // 给进程一点退出时间，避免端口/连接残留
      await Future.delayed(const Duration(milliseconds: 600));
    }

    setState(() => _isStartingBridge = true);
    try {
      final scriptPath = 'deepseek_bridge.py';
      await _ensureBridgeScriptUpToDate(scriptPath);

      final executable = Platform.isWindows ? 'python' : 'python3';
      // 只有拿到有效 token 时才传 --token；留空则让脚本进入扫码配对流程。
      // 重置 token 后必须走扫码（见 _rotateToken 的说明），因此这里允许传空。
      final args = <String>[
        scriptPath,
        if (token.trim().isNotEmpty) ...['--token', token.trim()],
        '--harness-url', 'http://$harnessUrl',
        '--server', AppConfig.normalizedServerBaseUrl,
      ];
      final process = await Process.start(
        executable,
        args,
        mode: ProcessStartMode.detachedWithStdio,
      );
      _headlessBridgeProcess = process;
      _bridgeStoppedByUser = false;
      _watchBridgeProcess(process.pid);

      // 启动后静默自检连接状态
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) context.read<SettingsProvider>().refreshAgentStatus();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('桥接重启失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isStartingBridge = false);
    }
  }

  Future<void> _toggleHeadlessBridge(String token, String harnessUrl) async {
    if (_headlessBridgeProcess != null) {
      // 停止后台进程
      try {
        _headlessBridgeProcess!.kill(ProcessSignal.sigterm);
      } catch (_) {
        _headlessBridgeProcess!.kill();
      }
      _bridgeStoppedByUser = true; // 告知监控：这是主动停止，不要误报异常退出
      _headlessBridgeProcess = null;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已停止电脑后台桥接守护进程')),
      );
      return;
    }

    setState(() => _isStartingBridge = true);
    try {
      final scriptPath = 'deepseek_bridge.py';
      await _ensureBridgeScriptUpToDate(scriptPath);

      final executable = Platform.isWindows ? 'python' : 'python3';
      final args = <String>[
        scriptPath,
        if (token.trim().isNotEmpty) ...['--token', token.trim()],
        '--harness-url', 'http://$harnessUrl',
        '--server', AppConfig.normalizedServerBaseUrl,
      ];
      final process = await Process.start(
        executable,
        args,
        mode: ProcessStartMode.detachedWithStdio,
      );

      _headlessBridgeProcess = process;
      _bridgeStoppedByUser = false;
      _watchBridgeProcess(process.pid);
      setState(() => _isStartingBridge = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🚀 本地桥接服务已在后台静默运行，无需保持黑窗口！'),
          backgroundColor: Colors.green,
        ),
      );

      // 启动后 2 秒静默自检连接状态
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          context.read<SettingsProvider>().refreshAgentStatus();
        }
      });
    } catch (e) {
      setState(() => _isStartingBridge = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('启动失败: $e (请确保电脑已安装 Python 并加入环境变量)'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _showQrScanPairingDialog() {
    final token = _tokenCtrl.text.trim();
    final url = _harnessUrlCtrl.text.trim();
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final codeController = TextEditingController();
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.qr_code_scanner, color: Color(0xFF0284C7)),
              SizedBox(width: 8),
              Text('Agent 扫码授权与配对'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '支持手机扫码秒连、临时授权码快速绑定或一键复制口令：',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).brightness == Brightness.dark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('当前配对 Token: ${_maskToken(token)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text('Harness 地址: http://$url', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 4),
                      const Text('协议: 端到端双向安全长连接 (免公网 IP)', style: TextStyle(fontSize: 12, color: Colors.green)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                // 扫码授权码快速绑定输入框 (方便手机端输入电脑终端上生成的 AUTH_XXXX 临时码)
                const Text(
                  '扫码配对 / 动态授权码绑定：',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: '输入电脑终端显示的临时码 (如 AUTH_ABC123)',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: isSubmitting
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.send, color: Color(0xFF0284C7)),
                            tooltip: '确认绑定并授权',
                            onPressed: isSubmitting ? null : () async {
                              final inputCode = codeController.text.trim().toUpperCase();
                              if (inputCode.isEmpty) return;
                              setDlgState(() => isSubmitting = true);
                              final res = await SyncService.instance.confirmBridgeAuthSession(
                                sessionCode: inputCode,
                                token: token,
                                account: context.read<SettingsProvider>().settings.loginAccount,
                              );
                              setDlgState(() => isSubmitting = false);
                              if (res['success'] == true) {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(res['message'] ?? '绑定授权成功！电脑端已自动上线'), backgroundColor: Colors.green),
                                );
                                context.read<SettingsProvider>().refreshAgentStatus();
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(res['message'] ?? '授权失败，请检查临时码'), backgroundColor: Colors.redAccent),
                                );
                              }
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '💡 手机端通过相机扫描电脑终端打印的二维码，即可自动识别临时授权链接并握手完成配对。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7), foregroundColor: Colors.white),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: 'TOKEN=$token;URL=http://$url'));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制配对参数至剪贴板')),
                );
              },
              child: const Text('复制配对参数'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final s = sp.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('DeepSeek Harness 设置'),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 桥接状态与模式
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.computer, color: Color(0xFF0284C7)),
                        const SizedBox(width: 8),
                        const Text(
                          '本地 Agent 桥接设置 (DeepSeek Harness)',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: s.isHarnessOnline
                                ? Colors.green.withOpacity(0.2)
                                : Colors.grey.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                size: 10,
                                color: s.isHarnessOnline ? Colors.green : Colors.grey,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                s.isHarnessOnline ? '桥接在线' : '桥接离线',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: s.isHarnessOnline ? Colors.green : Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    // 仅在电脑桌面端 (Windows / macOS / Linux) 显示：一键静默无头运行 / 停止后台桥接
                    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF0284C7).withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _headlessBridgeProcess != null ? Icons.bolt : Icons.play_circle_outline,
                              color: _headlessBridgeProcess != null ? Colors.green : const Color(0xFF0284C7),
                              size: 28,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _headlessBridgeProcess != null ? '电脑端后台守护中 (无头模式)' : '一键无头后台启动',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _headlessBridgeProcess != null
                                        ? 'PID: ${_headlessBridgeProcess!.pid}，长连接已建立，无黑色控制台窗口'
                                        : '点击即可在后台静默运行 py 桥接，无需手动打开 CMD 或保留黑窗口',
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            _isStartingBridge
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _headlessBridgeProcess != null ? Colors.redAccent : const Color(0xFF0284C7),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    icon: Icon(
                                      _headlessBridgeProcess != null ? Icons.stop : Icons.play_arrow,
                                      size: 16,
                                    ),
                                    label: Text(
                                      _headlessBridgeProcess != null ? '停止' : '启动',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                    onPressed: () => _toggleHeadlessBridge(
                                      _tokenCtrl.text.trim(),
                                      _harnessUrlCtrl.text.trim(),
                                    ),
                                  ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('默认 Agent 模式', style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                        s.defaultAgentMode ? '已开启（优先执行电脑本地 Agent 操作）' : '已关闭（直接与 App 模型对话）',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: s.defaultAgentMode,
                      onChanged: (val) {
                        s.defaultAgentMode = val;
                        sp.updateSettings(s);
                      },
                    ),
                    const SizedBox(height: 8),
                    // 配对 Token（非文本选取，仅支持纯随机生成，支持长按复制完整真实 Token）
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onLongPress: () {
                              Clipboard.setData(ClipboardData(text: _tokenCtrl.text.trim()));
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '配对 Token (长按复制)',
                                border: OutlineInputBorder(),
                                isDense: true,
                                helperText: '系统高强度随机生成，长按可直接复制真实凭证',
                              ),
                              child: Text(
                                _maskToken(_tokenCtrl.text.trim()),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: '重新生成配对 Token',
                          onPressed: _isRotatingToken ? null : () => _rotateToken(sp),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: '复制',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _tokenCtrl.text.trim()));
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.withOpacity(0.3)),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('🛡️ 安全防护与白名单：', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber)),
                          SizedBox(height: 2),
                          Text(
                            '桥接脚本内置严格接口白名单（仅允许标准对话转发），禁止篡改系统与插件；纯内存运行，不持久化任何对话与日志。',
                            style: TextStyle(fontSize: 11, color: Colors.amber),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _harnessUrlCtrl,
                      focusNode: _harnessUrlFocus,
                      decoration: const InputDecoration(
                        labelText: 'Harness 服务地址',
                        prefixText: 'http://',
                        hintText: '127.0.0.1:3080',
                        border: OutlineInputBorder(),
                        helperText: '固定协议头 http://，默认预填 127.0.0.1:3080',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // DSH 智能体执行选项配置（用户需求定制）
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.tune, size: 20, color: Color(0xFF0284C7)),
                        SizedBox(width: 8),
                        Text(
                          'DSH 智能体执行选项',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // 1. 底层模型
                    DropdownButtonFormField<String>(
                      value: s.agentModel,
                      decoration: const InputDecoration(
                        labelText: '智能体调度模型',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '驱动 Agent 推演拆解与调度的语言模型',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'deepseek-reasoner',
                          child: Text('DeepSeek-R1 (深度思考推演模式)'),
                        ),
                        DropdownMenuItem(
                          value: 'deepseek-chat',
                          child: Text('DeepSeek-V3 (高速通用模型)'),
                        ),
                        DropdownMenuItem(
                          value: 'local-harness-default',
                          child: Text('本地工作区默认模型 (Harness Default)'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          s.agentModel = val;
                          sp.updateSettings(s);
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    // 2. 思考链强度
                    DropdownButtonFormField<String>(
                      value: s.agentReasoningEffort,
                      decoration: const InputDecoration(
                        labelText: '思考链预算 / 强度 (Reasoning Effort)',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '控制 Agent 在执行工具前的拆解深度',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'low', child: Text('Low - 快速分析 (少量思考)')),
                        DropdownMenuItem(value: 'medium', child: Text('Medium - 标准平衡 (推荐)')),
                        DropdownMenuItem(value: 'high', child: Text('High - 深度推演 (全量多步分析)')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          s.agentReasoningEffort = val;
                          sp.updateSettings(s);
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    // 3. 执行权限管控
                    DropdownButtonFormField<String>(
                      value: s.agentPermission,
                      decoration: const InputDecoration(
                        labelText: '工具执行安全权限',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '本地执行高危命令或文件修改时的防护策略',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'ask', child: Text('安全拦截 - 敏感操作每次弹窗确认 (推荐)')),
                        DropdownMenuItem(value: 'auto_allow', child: Text('自治执行 - 自动放行白名单内操作')),
                        DropdownMenuItem(value: 'read_only', child: Text('只读审查 - 仅允许读取，禁止修改/写入')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          s.agentPermission = val;
                          sp.updateSettings(s);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 本地工作区与会话列表（下拉选择 + 联动筛选）
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '本地工作区与会话选择',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          icon: _isRefreshing
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.refresh, size: 14),
                          label: const Text('刷新列表', style: TextStyle(fontSize: 12)),
                          onPressed: _isRefreshing ? null : _refreshWorkspacesAndSessions,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // 目标工作区下拉选择与自定义输入
                    DropdownButtonFormField<String>(
                      value: _workspaces.contains(_workspaceCtrl.text.trim()) ? _workspaceCtrl.text.trim() : null,
                      decoration: const InputDecoration(
                        labelText: '目标工作区 (下拉选择)',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '选择电脑上已配置的代码仓或专属目录',
                      ),
                      items: _workspaces.map((ws) {
                        return DropdownMenuItem(value: ws, child: Text(ws, style: const TextStyle(fontSize: 13)));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          _workspaceCtrl.text = val;
                          s.targetWorkspace = val;
                          sp.updateSettings(s);
                          _updateFilteredSessions();
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _workspaceCtrl,
                      focusNode: _workspaceFocus,
                      decoration: const InputDecoration(
                        labelText: '自定义工作区路径/名称',
                        hintText: 'deepseek-agent 或 C:\\workspace',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    // 目标会话下拉（联动当前工作区）
                    DropdownButtonFormField<String>(
                      value: _filteredSessions.contains(_selectedSession) ? _selectedSession : _filteredSessions.first,
                      decoration: const InputDecoration(
                        labelText: '目标会话 (已联动当前工作区)',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '选择已存在的上下文会话或自动开启新会话',
                      ),
                      items: _filteredSessions.map((sess) {
                        return DropdownMenuItem(value: sess, child: Text(sess, style: const TextStyle(fontSize: 13)));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedSession = val);
                          s.targetSessionId = val == '智能选择 / 自动新建会话 (推荐)' ? '' : val;
                          sp.updateSettings(s);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 局域网 / 本地直连设置 (Local Agent)
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.lan_outlined, size: 20, color: Colors.blueAccent),
                        SizedBox(width: 8),
                        Text(
                          '局域网 / 本地直连设置 (可选)',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '同 WiFi 局域网或桌面版直接连接本地电脑 Agent，无需公网中继。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _localWsUrlCtrl,
                      focusNode: _localWsUrlFocus,
                      decoration: const InputDecoration(
                        labelText: '本地直连地址 (WS / HTTP)',
                        hintText: 'http://127.0.0.1:3080',
                        border: OutlineInputBorder(),
                        helperText: '局域网或本机直连地址，默认 http://127.0.0.1:3080',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _localAgentTokenCtrl,
                      focusNode: _localAgentTokenFocus,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '直连安全 Token (可选)',
                        hintText: '留空或输入本地安全口令',
                        border: OutlineInputBorder(),
                        helperText: '局域网握手鉴权 Token，未配置可留空 (已启用安全隐藏)',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 本地启动程序与脚本导出
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('电脑端启动命令 (免公网 IP，扫码即连)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onLongPress: () {
                        Clipboard.setData(ClipboardData(
                          text: 'python deepseek_bridge.py --harness-url "http://${_harnessUrlCtrl.text.trim()}"',
                        ));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制电脑端启动命令')),
                        );
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.withOpacity(0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'python deepseek_bridge.py --harness-url "http://${_harnessUrlCtrl.text.trim()}"',
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '💡 免输入 Token：运行后终端自动生成配对二维码，手机扫码即可极速完成授权！',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? Colors.lightBlueAccent.shade100 : const Color(0xFF0284C7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    // 一键工具组：手机端与电脑端完美响应式三等分对齐，不突兀折行
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final isNarrow = constraints.maxWidth < 460;
                        if (isNarrow) {
                          return Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: () async {
                                    final pyContent = await BridgeScriptHelper.getFullBridgeScriptContent();
                                    final savedPath = await BridgeScriptHelper.downloadFile(
                                      fileName: 'deepseek_bridge.py',
                                      content: pyContent,
                                    );
                                    if (context.mounted) {
                                      if (savedPath != null) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('已保存至: $savedPath'),
                                            backgroundColor: Colors.green,
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  child: const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.download, size: 15, color: Color(0xFF0284C7)),
                                      SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          '下载 py',
                                          style: TextStyle(fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: () async {
                                    final batContent = BridgeScriptHelper.generateBatContent(
                                      token: _tokenCtrl.text.trim(),
                                      serverUrl: AppConfig.normalizedServerBaseUrl,
                                      harnessUrl: 'http://${_harnessUrlCtrl.text.trim()}',
                                    );
                                    final savedPath = await BridgeScriptHelper.downloadFile(
                                      fileName: 'run_bridge.bat',
                                      content: batContent,
                                    );
                                    if (context.mounted && savedPath != null) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('已保存至: $savedPath'),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                    }
                                  },
                                  child: const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.download, size: 15, color: Color(0xFF0284C7)),
                                      SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          '下载 bat',
                                          style: TextStyle(fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0284C7),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(
                                      text: 'python deepseek_bridge.py --harness-url "http://${_harnessUrlCtrl.text.trim()}"',
                                    ));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('已复制免 Token 启动命令')),
                                    );
                                  },
                                  child: const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.copy, size: 15),
                                      SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          '复制命令',
                                          style: TextStyle(fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          );
                        }

                        // 宽屏 / 电脑端布局
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.download, size: 16, color: Color(0xFF0284C7)),
                              label: const Text('下载 py 脚本', style: TextStyle(fontSize: 13)),
                              onPressed: () async {
                                final pyContent = await BridgeScriptHelper.getFullBridgeScriptContent();
                                final savedPath = await BridgeScriptHelper.downloadFile(
                                  fileName: 'deepseek_bridge.py',
                                  content: pyContent,
                                );
                                if (context.mounted && savedPath != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('已保存至: $savedPath'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.download, size: 16, color: Color(0xFF0284C7)),
                              label: const Text('下载 bat 脚本', style: TextStyle(fontSize: 13)),
                              onPressed: () async {
                                final batContent = BridgeScriptHelper.generateBatContent(
                                  token: _tokenCtrl.text.trim(),
                                  serverUrl: AppConfig.normalizedServerBaseUrl,
                                  harnessUrl: 'http://${_harnessUrlCtrl.text.trim()}',
                                );
                                final savedPath = await BridgeScriptHelper.downloadFile(
                                  fileName: 'run_bridge.bat',
                                  content: batContent,
                                );
                                if (context.mounted && savedPath != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('已保存至: $savedPath'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0284C7),
                                foregroundColor: Colors.white,
                              ),
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('复制命令', style: TextStyle(fontSize: 13)),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(
                                  text: 'python deepseek_bridge.py --harness-url "http://${_harnessUrlCtrl.text.trim()}"',
                                ));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已复制免 Token 启动命令')),
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
