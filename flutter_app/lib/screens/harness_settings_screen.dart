import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../config/app_config.dart';
import '../utils/bridge_script_helper.dart';
import '../services/sync_service.dart';
import '../services/bridge_process_manager.dart';
import 'scanner_screen.dart';

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
  /// 正在电脑端新建会话（避免连点建出好几个空会话）
  bool _isCreatingSession = false;
  /// 正在向服务端换发配对 Token（防止重复点击）
  bool _isRotatingToken = false;

  /// 「启停 / 重置」这类会改变桥接状态的操作用它统一互斥。
  ///
  /// 为什么要跨到"状态真正切换完"才解锁：手机端点一下只是把指令丢给服务端，
  /// 要等电脑端 App 下一次轮询（≤4 秒）执行、服务端再把 agentOnline 回传，
  /// 界面才知道结果。此前的写法在 HTTP 请求返回后就立刻解锁，用户看着没反应
  /// 就会连点 —— 于是 start/stop 指令一条接一条下发，桥接被反复启停。
  ///
  /// 这里除了本机发起的操作，还包括**服务端下发的账号级切换标记**：
  /// 手机点了启动，电脑端界面在这几秒内同样必须置灰，反之亦然。
  bool get _isBridgeBusy =>
      _isStartingBridge ||
      _isRotatingToken ||
      (_settingsProvider?.isBridgeSwitching ?? false);

  /// 切换中的提示文案（优先用服务端标记，它代表账号当前的切换）。
  String get _bridgeSwitchLabel {
    final provider = _settingsProvider;
    final remote = provider?.bridgeTransition;
    final target = remote?.target ?? _bridgeSwitchTarget ?? true;
    final action = target ? '上线' : '停止';
    if (remote != null && (provider?.isBridgeSwitchingByOtherDevice ?? false)) {
      final who = remote.by == 'mobile' ? '手机端' : '电脑端';
      return '$who正在$action…';
    }
    return '正在$action…';
  }

  /// 本次操作期望的最终在线状态；非 null 表示"正在切换中"。
  bool? _bridgeSwitchTarget;
  Timer? _bridgeSwitchWatchdog;
  /// 切换看门狗的兜底时限：超过就解锁并提示，避免按钮永久卡住。
  static const Duration _bridgeSwitchTimeout = Duration(seconds: 20);

  /// 桥接进程与退出监控已统一交给全局 BridgeProcessManager 管理，
  // 本页面不再持有进程句柄（否则会与远端指令的执行路径产生两个进程）。
  /// 页面初始化时抓住的 Provider 引用：dispose 阶段不能再走 context 查找。
  SettingsProvider? _settingsProvider;

  /// 「新建会话」选项的值（下拉里与真实会话 id 区分开）。
  ///
  /// 含义：**现在就去电脑端建一个新会话并选中它**，之后的每条消息都发进这个
  /// 会话；旧版的「智能选择 / 自动新建会话」是每条消息都让服务端另建一个，
  /// 于是每问一句就多出一个新会话。
  static const String _kNewSessionOption = '__lx_new_session__';
  String _selectedSessionId = '';

  /// 桥接是否在运行。
  ///
  /// 电脑端：看本地进程（由 BridgeProcessManager 管理）；
  /// 手机端：本机没有进程，改看服务端上报的 Agent 在线状态。
  bool get _bridgeRunning {
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    if (isDesktop) {
      return BridgeProcessManager.instance.isRunning;
    }
    return context.read<SettingsProvider>().settings.isHarnessOnline;
  }

  /// 对 Token 进行脱敏展示（例如: lx-oSdk******************）。
  ///
  /// 规则：保留「前缀 + 随机部分前 4 位」，其余全部用 `*` 盖掉。
  /// 这样每次重新生成后，`lx-` 后面露出的 4 位随机字符必然变化 —— 用户一眼
  /// 就能确认 Token 真的换了（旧版前缀恒为 sk-agent，脱敏后千篇一律）。
  static String _maskToken(String token) {
    final t = token.trim();
    if (t.isEmpty) return '';
    int prefixLen;
    if (t.startsWith('lx-')) {
      prefixLen = 3;
    } else if (t.startsWith('sk-agent')) {
      prefixLen = 8; // 历史 Token 格式，兼容展示
    } else if (t.startsWith('sk-')) {
      prefixLen = 3;
    } else {
      prefixLen = 0;
    }
    final visibleEnd = (prefixLen + 4).clamp(0, t.length);
    return '${t.substring(0, visibleEnd)}${'*' * 18}';
  }

  /// 等桥接状态真正切换到 [target] 后再解锁按钮；超时兜底解锁并提示。
  void _armBridgeSwitchWatchdog(bool target) {
    _bridgeSwitchWatchdog?.cancel();
    _bridgeSwitchTarget = target;
    final deadline = DateTime.now().add(_bridgeSwitchTimeout);
    _bridgeSwitchWatchdog = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final converged = _bridgeRunning == target;
      if (!converged && DateTime.now().isBefore(deadline)) return;
      timer.cancel();
      if (!mounted) return;
      setState(() {
        _isStartingBridge = false;
        _isRotatingToken = false;
        _bridgeSwitchTarget = null;
      });
      if (!converged) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('状态切换超时未确认：请检查电脑端 LxAI 是否在运行、是否已登录同一账号'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 5),
          ),
        );
      }
    });
  }

  /// 操作失败/无需等待时立刻解锁按钮。
  void _releaseBridgeSwitch() {
    _bridgeSwitchWatchdog?.cancel();
    _bridgeSwitchWatchdog = null;
    _bridgeSwitchTarget = null;
    if (!mounted) return;
    setState(() {
      _isStartingBridge = false;
      _isRotatingToken = false;
    });
  }

  /// 打开扫一扫（与聊天界面工具栏里的「扫一扫」是同一个页面）。
  Future<void> _openScanner() async {
    final paired = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const ScannerScreen(),
        fullscreenDialog: true,
      ),
    );
    if (!mounted) return;
    if (paired == true) {
      // 配对成功后服务端会下发/换发 Token，主动拉一次状态并让显示跟着收敛
      await context.read<SettingsProvider>().refreshAgentStatus();
      if (!mounted) return;
      _syncTokenFromProvider();
    }
  }

  /// 让输入框里的 Token 始终等于设置里的当前值。
  ///
  /// 服务端换发 Token 后（本机重置、或另一端点重置）会经 4 秒轮询写入设置，
  /// 此前本页的显示只在 initState 与手动重置时赋值，因此会一直停在旧值上，
  /// 这也加重了"Token 好像从来没更新过"的错觉。
  void _syncTokenFromProvider() {
    if (!mounted) return;
    final latest = (_settingsProvider?.settings.harnessToken ?? '').trim();
    if (latest.isEmpty || latest == _tokenCtrl.text.trim()) return;
    setState(() => _tokenCtrl.text = latest);
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
    _selectedSessionId = s.targetSessionId.trim();

    // 绑定失焦自动保存监听，解决每次击键卡顿问题
    _tokenFocus.addListener(_handleFocusChange);
    _harnessUrlFocus.addListener(_handleFocusChange);
    _workspaceFocus.addListener(() {
      _handleFocusChange();
    });
    _localWsUrlFocus.addListener(_handleFocusChange);
    _localAgentTokenFocus.addListener(_handleFocusChange);

    // 服务端换发/下发 Token 时同步刷新本页显示（详见 _syncTokenFromProvider）
    _settingsProvider = context.read<SettingsProvider>();
    _settingsProvider!.addListener(_syncTokenFromProvider);

    // 会话/工作区目录由电脑端提供，且缓存在 Provider 里（返回再进不会丢）。
    // 首次进入若还没取过、而桥接又在线，就自动拉一次，不必让用户手动点刷新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sp = _settingsProvider;
      if (sp == null) return;
      if (!sp.agentCatalogLoaded && sp.settings.isHarnessOnline) {
        unawaited(_refreshWorkspacesAndSessions());
      }
    });
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

  /// 当前工作区下的会话（Provider 里缓存的那份）。
  List<Map<String, dynamic>> _sessionsForCurrentWorkspace() {
    final sp = _settingsProvider;
    if (sp == null) return const [];
    return sp.sessionsForWorkspace(_workspaceCtrl.text.trim());
  }

  /// 下拉里展示的会话选项：第一项固定是「新建会话」，其余是真实会话。
  List<DropdownMenuItem<String>> _sessionItems() {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: _kNewSessionOption,
        child: Text('新建会话', style: TextStyle(fontSize: 13)),
      ),
    ];
    for (final sess in _sessionsForCurrentWorkspace()) {
      final id = sess['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      items.add(
        DropdownMenuItem(
          value: id,
          child: Text(
            SettingsProvider.agentSessionLabel(sess),
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    return items;
  }

  /// 会话下拉的当前值：必须落在选项里，否则 Flutter 会断言失败。
  String? _sessionDropdownValue() {
    final items = _sessionItems();
    if (_selectedSessionId.isEmpty) return _kNewSessionOption;
    for (final it in items) {
      if (it.value == _selectedSessionId) return _selectedSessionId;
    }
    // 已选会话不在当前工作区的列表里（例如换了工作区）：退回「新建会话」，
    // 但不偷偷改写用户的选择，等他自己确认。
    return _kNewSessionOption;
  }

  /// 选中「新建会话」→ 立刻在电脑端建一个并选中它。
  ///
  /// 这样后续每条消息都发进同一个会话；旧逻辑是每条消息都让服务端另建一个，
  /// 于是每问一句就多出一个空会话。
  Future<void> _createAndSelectSession(SettingsProvider sp) async {
    if (sp.settings.isHarnessOnline != true) {
      _snack('电脑端桥接未在线，无法新建会话：请先启动桥接', isError: true);
      return;
    }
    final workspace = _workspaceCtrl.text.trim();
    setState(() => _isCreatingSession = true);
    try {
      final newId = await sp.createAgentSessionOnPc(workspace: workspace);
      if (!mounted) return;
      if (newId == null) {
        // 保留原选择，不写任何伪造的 id —— 否则发消息必然失败
        _snack('新建会话失败：请确认电脑端 LxAI 在运行且本地 DSH 正常', isError: true);
        return;
      }
      setState(() => _selectedSessionId = newId);
      sp.settings.targetSessionId = newId;
      sp.updateSettings(sp.settings);
      _snack('已新建并选中会话', isError: false);
    } finally {
      if (mounted) setState(() => _isCreatingSession = false);
    }
  }

  void _snack(String text, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
      ),
    );
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
    s.targetSessionId = _selectedSessionId.trim();
    s.localBridgeWsUrl = _localWsUrlCtrl.text.trim().isNotEmpty
        ? _localWsUrlCtrl.text.trim()
        : 'http://127.0.0.1:3080';
    s.localAgentToken = _localAgentTokenCtrl.text.trim();
    sp.updateSettings(s);
  }

  @override
  void dispose() {
    _bridgeSwitchWatchdog?.cancel();
    _settingsProvider?.removeListener(_syncTokenFromProvider);
    _saveSilently();
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
      final gotReal = await sp.refreshAgentCatalog(silent: false);
      if (!mounted) return;
      setState(() => _isRefreshing = false);

      final wsList = sp.agentWorkspaces;
      if (wsList.isNotEmpty && !wsList.contains(_workspaceCtrl.text.trim())) {
        // 之前选的工作区在电脑上已经不存在了：清掉它，不要拿假值顶替，
        // 也不要随便替用户选一个 —— 界面显示空白，让用户自己挑。
        _workspaceCtrl.text = '';
        sp.settings.targetWorkspace = '';
        sp.updateSettings(sp.settings);
      }

      if (gotReal) {
        _snack('✅ 已同步电脑端目录（${wsList.length} 个工作区 / ${sp.agentSessions.length} 个会话）',
            isError: false);
      } else if (sp.settings.isHarnessOnline) {
        _snack('⚠️ 桥接已在线，但没取到目录：请确认电脑端 DSH 正常工作', isError: true);
      } else {
        _snack('⚠️ 电脑端桥接未在线，暂无可用目录（启动桥接后会自动获取）', isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRefreshing = false);
        _snack('刷新异常: $e', isError: true);
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
    // 状态切换期间禁止重复点击：连点会连续换发 Token 并连发重启指令，
    // 桥接被反复踢下线又拉起，最终谁也没连上。
    if (_isBridgeBusy) return;

    final s = sp.settings;
    final oldToken = s.harnessToken.trim();

    // 【必须在重置之前读取】重置会立刻踢掉旧连接，服务端随即把 agentOnline 置为 false。
    // 若在这之后再读，4 秒一次的状态轮询可能刚好把它刷成 false，
    // 于是两个分支都不成立、重启指令根本不会下发（表现为"手机点重置后仍需手动恢复"）。
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final manager = BridgeProcessManager.instance;
    final bridgeWasRunning = isDesktop ? manager.isRunning : s.isHarnessOnline;

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
        _releaseBridgeSwitch();
        return;
      }

      setState(() {
        _tokenCtrl.text = newToken;
        s.harnessToken = newToken;
      });
      sp.updateSettings(s);

      if (bridgeWasRunning) {
        // 桥接要带着新 Token 重新上线，等它真的回到在线状态再解锁按钮。
        _armBridgeSwitchWatchdog(true);
      } else {
        _armBridgeSwitchWatchdog(false);
      }

      if (bridgeWasRunning && isDesktop) {
        // 电脑端重置：直接用服务端换发的新 token 重启桥接（App 托管场景下
        // 该 token 即配对凭据，无需再扫码）。
        await manager.restart(
          token: newToken,
          harnessUrl: _harnessUrlCtrl.text.trim().isEmpty
              ? '127.0.0.1:3080'
              : _harnessUrlCtrl.text.trim(),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🔑 配对 Token 已更新，电脑端桥接已自动重启并重连'),
            backgroundColor: Colors.green,
          ),
        );
      } else if (bridgeWasRunning) {
        // 手机端重置：本机无法操作电脑脚本，改为下发重启指令，
        // 由电脑端 App 在会话轮询中取走并用新 Token 重启桥接。
        final result = await SyncService.instance.sendBridgeCommand(
          userId: sp.syncUserId,
          command: 'restart',
        );
        if (!mounted) return;
        if (result != BridgeCommandResult.ok) _releaseBridgeSwitch();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              switch (result) {
                BridgeCommandResult.ok => '🔑 Token 已重置，已通知电脑端用新 Token 重启桥接（数秒内生效）',
                BridgeCommandResult.busy => '🔑 Token 已重置；另一台设备正在切换状态，无需重复操作',
                BridgeCommandResult.failed =>
                  '🔑 Token 已重置，但通知电脑端失败：请确认电脑端已打开 LxAI 应用',
              },
            ),
            backgroundColor: result == BridgeCommandResult.ok ? Colors.green : Colors.orange,
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🔑 配对 Token 已更新（桥接未运行，下次启动将使用新 Token）')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('换发异常: $e'), backgroundColor: Colors.redAccent),
        );
      }
      _releaseBridgeSwitch();
    }
  }
  /// 启停桥接。
  ///
  /// 进程由全局 `BridgeProcessManager` 统一管理（不再由本页面持有），这样：
  /// · 切到别的页面时，进程退出监控依然有效，可自动恢复；
  /// · 手机端下发的启停指令也能在任意时刻被执行。
  ///
  /// 手机端点到这个按钮时无法直接操作电脑上的脚本，因此改为把指令交给服务端，
  /// 由电脑端 App 在会话轮询（≤4 秒）中取走并在本机执行。
  Future<void> _toggleHeadlessBridge(String token, String harnessUrl) async {
    // 状态切换（含重置 Token）未完成前一律不接受新的点击：
    // 连点会连发 start/stop，桥接被反复启停，最后停在哪个状态全凭运气。
    if (_isBridgeBusy) return;

    final manager = BridgeProcessManager.instance;
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final normalizedHarness = harnessUrl.trim().isEmpty ? '127.0.0.1:3080' : harnessUrl.trim();

    setState(() => _isStartingBridge = true);
    try {
      // 期望终态：点了「停止」就是要离线，点了「启动」就是要在线。
      final target = !_bridgeRunning;
      final sp = context.read<SettingsProvider>();

      if (!isDesktop) {
        // 手机端：按电脑端 Agent 的在线状态决定下发 start 还是 stop
        final online = sp.settings.isHarnessOnline;
        final command = online ? 'stop' : 'start';
        final result = await SyncService.instance.sendBridgeCommand(
          userId: sp.syncUserId,
          command: command,
        );
        if (!mounted) return;
        // 指令只是"排上队"，要等电脑端执行 + 轮询回传，状态才算真的变。
        if (result == BridgeCommandResult.ok) {
          _armBridgeSwitchWatchdog(target);
        } else {
          _releaseBridgeSwitch();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              switch (result) {
                BridgeCommandResult.ok =>
                  '指令已发送（${command == 'start' ? '启动' : '停止'}），电脑端将在数秒内执行',
                BridgeCommandResult.busy =>
                  '另一台设备正在切换桥接状态，请等它完成后再操作',
                BridgeCommandResult.failed =>
                  '指令发送失败：请确认电脑端已安装并打开 LxAI 应用，且已登录同一账号',
              },
            ),
            backgroundColor: result == BridgeCommandResult.ok
                ? Colors.green
                : (result == BridgeCommandResult.busy ? Colors.orange : Colors.redAccent),
          ),
        );
        return;
      }

      // 电脑端：先在服务端登记"切换中"，这样手机端界面也会同步置灰，
      // 不会在电脑执行期间又下发一条相反指令。
      final reg = await SyncService.instance.beginBridgeTransition(
        userId: sp.syncUserId,
        command: target ? 'start' : 'stop',
      );
      if (!mounted) return;
      if (reg == BridgeCommandResult.busy) {
        _releaseBridgeSwitch();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('另一台设备正在切换桥接状态，请等它完成后再操作'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      // 电脑端：本地直接启停
      bool ok;
      if (manager.isRunning) {
        await manager.stop();
        ok = true;
      } else {
        ok = await manager.start(token: token, harnessUrl: normalizedHarness);
      }
      if (!mounted) return;
      if (ok) {
        _armBridgeSwitchWatchdog(target);
      } else {
        // 本地都起不来（例如没装 Python），状态永远不会变成期望值，
        // 必须立刻撤销服务端标记，否则两端按钮要白等 20 秒兜底才恢复。
        _releaseBridgeSwitch();
        unawaited(SyncService.instance.cancelBridgeTransition(userId: sp.syncUserId));
      }
      final msg = manager.takeMessage();
      if (msg != null) {
        final launched = manager.isRunning && !manager.lastMessageIsError;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(launched ? '🚀 $msg' : msg),
            backgroundColor: manager.lastMessageIsError
                ? Colors.redAccent
                : (launched ? Colors.green : null),
          ),
        );
      }
      // 启动后 2 秒静默自检连接状态（也会让看门狗更快确认到位）
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) context.read<SettingsProvider>().refreshAgentStatus();
      });
      // 桥接刚起来：顺手把电脑端的工作区/会话目录拉一次，
      // 省得用户还要自己点「刷新列表」（目录由此才有真实内容）。
      if (ok && target) {
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) unawaited(_refreshWorkspacesAndSessions());
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('启停异常: $e'), backgroundColor: Colors.redAccent),
        );
      }
      _releaseBridgeSwitch();
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
        actions: [
          // 与聊天界面工具栏里的「扫一扫」是同一个页面（ScannerScreen），
          // 这里只是多一个入口：扫码配对后不用再退回聊天页去扫。
          IconButton(
            icon: const Icon(Icons.qr_code_scanner_rounded),
            tooltip: '扫一扫',
            onPressed: _isBridgeBusy ? null : _openScanner,
          ),
          const SizedBox(width: 4),
        ],
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
                    // 桥接控制卡片：电脑端本地启停；手机端下发指令给电脑端 App 执行
                    // （此前这里用 Platform 判断只让电脑端显示，现按需求在手机端也显示）
                    ...[
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
                              _bridgeRunning ? Icons.bolt : Icons.play_circle_outline,
                              color: _bridgeRunning ? Colors.green : const Color(0xFF0284C7),
                              size: 28,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _bridgeRunning
                                        ? '桥接运行中'
                                        : (Platform.isWindows || Platform.isMacOS || Platform.isLinux
                                            ? '一键无头后台启动'
                                            : '启动电脑端桥接'),
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _bridgeRunning
                                        ? (BridgeProcessManager.instance.isRunning
                                            ? 'PID: ${BridgeProcessManager.instance.pid}，长连接已建立，无黑色控制台窗口'
                                            : '长连接已建立（由电脑端 LxAI 应用托管运行）')
                                        : (Platform.isWindows || Platform.isMacOS || Platform.isLinux
                                            ? '点击即可在后台静默运行 py 桥接，无需手动打开 CMD 或保留黑窗口'
                                            : '点击后下发指令，由电脑端 LxAI 应用启动本机桥接（需保持该应用运行）'),
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            _isBridgeBusy
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        // 明确告诉用户"在等什么"，否则按钮变灰会被当成卡死
                                        _bridgeSwitchLabel,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  )
                                : ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _bridgeRunning ? Colors.redAccent : const Color(0xFF0284C7),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    icon: Icon(
                                      _bridgeRunning ? Icons.stop : Icons.play_arrow,
                                      size: 16,
                                    ),
                                    label: Text(
                                      _bridgeRunning ? '停止' : '启动',
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
                          onPressed: _isBridgeBusy ? null : () => _rotateToken(sp),
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
                    // 目标工作区下拉：只列电脑端真实存在的目录。
                    // 还没取到过就一个选项都没有（空白框），绝不显示假的工作区名。
                    DropdownButtonFormField<String>(
                      value: sp.agentWorkspaces.contains(_workspaceCtrl.text.trim())
                          ? _workspaceCtrl.text.trim()
                          : null,
                      decoration: InputDecoration(
                        labelText: '目标工作区 (下拉选择)',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        hintText: sp.agentWorkspaces.isEmpty ? '暂无目录（点右上角刷新列表）' : null,
                        helperText: sp.agentWorkspaces.isEmpty
                            ? '尚未从电脑端取到目录：启动桥接后会自动获取，也可点「刷新列表」'
                            : '选择电脑上已配置的代码仓或专属目录（共 ${sp.agentWorkspaces.length} 个）',
                      ),
                      items: sp.agentWorkspaces.map((ws) {
                        return DropdownMenuItem(value: ws, child: Text(ws, style: const TextStyle(fontSize: 13)));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _workspaceCtrl.text = val;
                            // 换工作区后，原会话多半不属于新工作区，回到「新建会话」
                            _selectedSessionId = '';
                          });
                          s.targetWorkspace = val;
                          s.targetSessionId = '';
                          sp.updateSettings(s);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _workspaceCtrl,
                      focusNode: _workspaceFocus,
                      decoration: const InputDecoration(
                        labelText: '自定义工作区路径/名称',
                        hintText: '例如 C:\\workspace（留空则用电脑端默认工作区）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (val) {
                        // 手动改路径后同样要重算会话列表
                        if (mounted) setState(() {});
                        s.targetWorkspace = val.trim();
                        sp.updateSettings(s);
                      },
                    ),
                    const SizedBox(height: 14),
                    // 目标会话下拉（联动当前工作区）
                    DropdownButtonFormField<String>(
                      value: _sessionDropdownValue(),
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: '目标会话 (已联动当前工作区)',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        helperText: _isCreatingSession
                            ? '正在电脑端新建会话…'
                            : '选「新建会话」会立刻建一个并选中它，之后的消息都发进这个会话',
                      ),
                      items: _sessionItems(),
                      onChanged: (_isCreatingSession || _isBridgeBusy)
                          ? null
                          : (val) {
                              if (val == null) return;
                              if (val == _kNewSessionOption) {
                                unawaited(_createAndSelectSession(sp));
                                return;
                              }
                              setState(() => _selectedSessionId = val);
                              s.targetSessionId = val;
                              sp.updateSettings(s);
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
