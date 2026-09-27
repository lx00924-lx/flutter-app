import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/app_settings.dart';
import '../services/storage_service.dart';
import '../services/storage_path_service.dart';
import '../services/sync_service.dart';
import '../services/keep_alive_service.dart';
import '../services/bridge_process_manager.dart';
import '../utils/image_picker_helper.dart';
import '../main.dart' show rootNavigatorKey;

class SettingsProvider extends ChangeNotifier {
  late AppSettings _settings;
  bool _isShowingKickDialog = false;
  Timer? _cloudPushDebounceTimer;

  Uint8List? _userAvatarBytes;
  Uint8List? _aiAvatarBytes;
  Uint8List? _customBackgroundBytes;

  SettingsProvider() {
    _settings = StorageService.instance.loadSettings();
    _updateImageCache();
    StoragePathService.instance.setCustomPath(_settings.customDataPath);

    // 确保有唯一的 clientSessionId
    if (_settings.clientSessionId.isEmpty) {
      _settings.clientSessionId = const Uuid().v4();
      _save(pushToCloud: false);
    }

    // 确保有本机唯一的 Agent 配对 Token：
    // 历史版本所有设备共用同一个硬编码 Token（服务端还会回退到 default_agent_token），
    // 这构成越权通道。fromMap 已把旧值/空值替换为新的随机值，这里负责落盘与云端同步。
    if (_settings.harnessToken.isEmpty ||
        _settings.harnessToken == kLegacyDefaultAgentToken) {
      _settings.harnessToken = generateAgentPairingToken();
      _save();
      debugPrint('[Settings] 已为本机生成唯一的 Agent 配对 Token');
    }

    // 异步拉取服务端维护的模型上下文上限表
    fetchAndApplyModelLimits();

    // 若已登录，立即启动多端互斥监听与云端设置静默同步
    if (_settings.isLoggedIn && _settings.loginAccount.trim().isNotEmpty) {
      _startSessionMonitoring();
      pullCloudSettings();
    }
  }

  Map<String, int> _serverModelLimits = {};
  Map<String, int> get serverModelLimits => _serverModelLimits;

  AppSettings get settings => _settings;
  bool get isLoggedIn => _settings.isLoggedIn;
  bool get isDarkMode => _settings.isDarkMode;
  bool get enableSplash => _settings.enableSplash;
  String get activeModelDisplayName => _settings.activeModelDisplayName;
  String get activeEndpointId => _settings.activeEndpointId;
  ApiModelEndpoint? get activeEndpoint => _settings.activeEndpoint;
  String get syncUserId => _settings.loginAccount.trim().isNotEmpty ? _settings.loginAccount.trim() : 'default_user';
  String get clientSessionId => _settings.clientSessionId;

  Uint8List? get userAvatarBytes => _userAvatarBytes;
  Uint8List? get aiAvatarBytes => _aiAvatarBytes;
  Uint8List? get customBackgroundBytes => _customBackgroundBytes;

  void _updateImageCache() {
    _userAvatarBytes = ImagePickerHelper.decodeBase64Image(_settings.userAvatar);
    _aiAvatarBytes = ImagePickerHelper.decodeBase64Image(_settings.aiAvatar);
    _customBackgroundBytes = ImagePickerHelper.decodeBase64Image(_settings.customBackground);
  }

  void toggleTheme() {
    _settings.isDarkMode = !_settings.isDarkMode;
    _save();
  }

  /// 切换 AI 回复自动朗读开关
  void toggleAutoSpeakResponse() {
    _settings.autoSpeakResponse = !_settings.autoSpeakResponse;
    _save();
  }

  /// 显式设置自动朗读状态
  void setAutoSpeakResponse(bool enabled) {
    if (_settings.autoSpeakResponse != enabled) {
      _settings.autoSpeakResponse = enabled;
      _save();
    }
  }

  /// 在主界面下拉弹窗中切换选中的 API 卡片
  void selectEndpoint(ApiModelEndpoint endpoint) {
    _settings.activeEndpointId = endpoint.id;
    _settings.activeModelDisplayName = endpoint.cardName;
    _save();
  }

  /// 添加新的 API 模型卡片
  void addApiEndpoint(ApiModelEndpoint endpoint) {
    _settings.apiEndpoints.add(endpoint);
    if (_settings.apiEndpoints.length == 1) {
      _settings.activeEndpointId = endpoint.id;
      _settings.activeModelDisplayName = endpoint.cardName;
    }
    _save();
  }

  /// 更新现有 API 模型卡片
  void updateApiEndpoint(ApiModelEndpoint endpoint) {
    final idx = _settings.apiEndpoints.indexWhere((e) => e.id == endpoint.id);
    if (idx != -1) {
      _settings.apiEndpoints[idx] = endpoint;
      if (_settings.activeEndpointId == endpoint.id) {
        _settings.activeModelDisplayName = endpoint.cardName;
      }
      _save();
    }
  }

  /// 删除 API 模型卡片
  void removeApiEndpoint(String endpointId) {
    _settings.apiEndpoints.removeWhere((e) => e.id == endpointId);
    if (_settings.activeEndpointId == endpointId && _settings.apiEndpoints.isNotEmpty) {
      _settings.activeEndpointId = _settings.apiEndpoints.first.id;
      _settings.activeModelDisplayName = _settings.apiEndpoints.first.cardName;
    }
    _save();
  }

  void updateSettings(AppSettings newSettings) {
    _settings = newSettings;
    _save();
  }

  /// 更新自定义存储与缓存路径
  void updateCustomDataPath(String newPath) {
    _settings.customDataPath = newPath;
    _save();
  }

  /// 启动多端单点互斥监听（1台手机 + 1台电脑）
  void _startSessionMonitoring() {
    SyncService.instance.startSessionWatcher(
      userId: _settings.loginAccount,
      clientSessionId: _settings.clientSessionId,
      deviceType: AppSettings.currentDeviceType,
      onKicked: (reason, canTakeover) {
        // 服务端说这个设备槽位早已没人活跃 → 是本地与服务端 id 分叉造成的假顶号，
        // 用本地账号密码静默重登一次即可自愈；接管失败再按真实顶号弹窗。
        if (canTakeover) {
          unawaited(_trySilentTakeover().then((ok) {
            if (!ok) handleForceLogout(reason);
          }));
          return;
        }
        handleForceLogout(reason);
      },
      onTokenSynced: _applyServerAgentToken,
      onCommand: _handleBridgeCommand,
      onOnlineChanged: _applyAgentOnline,
      onTransition: _applyBridgeTransition,
      onSettingsUpdated: () => pullCloudSettings(),
    );

    // 让 BridgeProcessManager 在自动重启时能拿到「当前有效 Token / Harness 地址」
    BridgeProcessManager.instance.tokenProvider = () async => _settings.harnessToken;
    BridgeProcessManager.instance.harnessUrlProvider = () async => _harnessUrlForBridge();

    // 推送长连接：把服务端广播的事件（设置/上下线/审批/消息）真正送到端上，
    // 轮询退化为兜底（连通时 4 秒 → 30 秒）
    SyncService.instance.onPushEvent = _handlePushEvent;
    SyncService.instance.startPushChannel(
      userId: _settings.loginAccount,
      clientSessionId: _settings.clientSessionId,
      deviceType: AppSettings.currentDeviceType,
    );

    // 已登录：开启 Android 常驻保活前台服务，确保划掉任务栏后
    // Dart isolate 仍存活，上面的会话轮询与中继长连接得以继续运行
    KeepAliveService.enableAfterLogin();

    // 启动即拉一次电脑端目录：进聊天页时快捷栏也会拉，但那是"用到了才拉"，
    // 用户先看设置页时会一直显示自己的旧档位。这里主动对齐一次。
    // （电脑端此刻若还没起来，_applyAgentOnline 会在它上线时再补一次。）
    unawaited(refreshAgentCatalog(silent: true));

    // 用户开了「启动应用时自动启动桥接」就把电脑端桥接拉起来
    // （实测桌面端启动后桥接不会自己起，用户会以为电脑端掉线了）
    unawaited(_autoStartBridgeIfEnabled());
  }

  /// 按设置项「启动应用时自动启动桥接」在启动/登录后拉起电脑端桥接。
  ///
  /// 仅电脑端执行 —— 手机端没有本机 python 脚本，它的"启动桥接"是下发指令给电脑端。
  /// 桥接已在运行时直接返回（幂等），避免起出第二个进程抢同一个 Token。
  Future<void> _autoStartBridgeIfEnabled() async {
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    if (!isDesktop || !_settings.autoStartBridgeOnLaunch) return;
    final manager = BridgeProcessManager.instance;
    if (manager.isRunning) {
      debugPrint('[Bridge] 自动启动：桥接已在运行，跳过');
      return;
    }
    final token = _settings.harnessToken.trim();
    if (token.isEmpty) {
      debugPrint('[Bridge] 自动启动：还没有配对 Token，跳过（登录后可手动启动一次）');
      return;
    }
    // 等启动期的会话轮询/云端同步先跑完，避免和它们抢网络与磁盘
    await Future.delayed(const Duration(seconds: 4));
    if (!_settings.autoStartBridgeOnLaunch || manager.isRunning) return;
    debugPrint('[Bridge] 按设置自动启动桥接（电脑端）');
    await manager.start(token: token, harnessUrl: _harnessUrlForBridge());
  }

  /// 供 ChatProvider 订阅的"消息 / 审批"类推送事件
  void Function(String event, Map<String, dynamic> data)? chatPushHandler;

  /// 分发推送通道收到的事件：设置 / 在线状态 / 强制下线在这里处理，
  /// 消息与审批转给 ChatProvider（它管着消息列表和审批卡片）。
  void _handlePushEvent(String event, Map<String, dynamic> data) {
    switch (event) {
      case 'push_connected':
        SyncService.instance.refreshPollingInterval();
        // 顺带让 ChatProvider 补拉"断线期间挂起的选择框"
        chatPushHandler?.call(event, data);
        return;
      case 'push_disconnected':
        SyncService.instance.refreshPollingInterval();
        return;
      case 'settings_updated':
        // 另一端改过设置：立刻拉一次，不必再等 4 秒轮询发现版本号变化
        unawaited(pullCloudSettings());
        return;
      case 'agent_status_change':
        // 只认自己这枚 Token。中继历史上是 `io.emit` 全服广播（推送通道又镜像了
        // 所有 io.emit），客户端此前不校验 token —— 于是**别人电脑上的桥接上下线
        // 会把本机打成在线/离线**，进而触发一次"电脑端刚上线 → 拉一次目录"。
        // 中继侧已收窄到归属账号，这里是第二道闸（旧中继 + 归属未解析时的兜底广播）。
        final eventToken = data['token']?.toString().trim() ?? '';
        final myToken = _settings.harnessToken.trim();
        if (eventToken.isNotEmpty && myToken.isNotEmpty && eventToken != myToken) {
          return;
        }
        final online = data['online'];
        if (online is bool) _applyAgentOnline(online);
        return;
      case 'force_logout':
        final targetDevice = data['deviceType']?.toString() ?? '';
        final kickedSession = data['kickedSessionId']?.toString() ?? '';
        final canTakeover = data['canTakeover'] == true;
        // kickedSessionId 缺失时只能退化成按设备类型判断（服务端早期版本就没带这个字段，
        // 那会让同类型的每个实例都把自己当成被顶的那个）。现在服务端已带上，
        // 且推送目标也按设备类型过滤，不再误伤。
        final isMine = kickedSession.isNotEmpty
            ? kickedSession == _settings.clientSessionId
            : targetDevice == AppSettings.currentDeviceType;
        if (isMine) {
          final reason = data['reason']?.toString() ?? '您的账号已在另一台设备上登录，当前设备已被下线。';
          if (canTakeover) {
            // 对方槽位早已过期 → 静默重登接管，不打扰用户
            unawaited(_trySilentTakeover().then((ok) {
              if (!ok) handleForceLogout(reason);
            }));
          } else {
            handleForceLogout(reason);
          }
        }
        return;
      default:
        chatPushHandler?.call(event, data);
    }
  }

  /// 服务端在每次轮询（4 秒）下发 Agent 在线状态，据此自动更新界面。
  ///
  /// 修复：手机端点「停止」后桥接确实停了，但界面仍显示"在线/停止按钮"——
  /// 因为手机无法本地探测电脑进程，此前只能手动点刷新才会更新。
  void _applyAgentOnline(bool online) {
    if (_settings.isHarnessOnline == online) return;
    final wasOffline = !_settings.isHarnessOnline;
    _settings.isHarnessOnline = online;
    if (online) _agentOnlineSince = DateTime.now();
    _save(pushToCloud: false);
    debugPrint('[Settings] Agent 在线状态更新: $online');
    // 电脑端刚上线（典型场景：先开 App，再开宿主 / 桥接）：立刻补拉一次目录，
    // 把这期间电脑端真实生效的模型 / 思考深度 / 权限对齐过来 ——
    // 否则界面会一直停在 App 自己存的旧值，用户以为"设置没同步"。
    if (online && wasOffline && _settings.isLoggedIn) {
      // 节流：刚成功拿到过目录就别再拉一次。中继的在线状态会因桥接重连/心跳
      // 抖动而反复变成 true，每次都拉一遍的结果就是快捷栏那个刷新图标一直在转，
      // 看上去就是"App 时不时闪一下、自动刷新桥接"。
      final last = _lastCatalogSuccessAt;
      if (last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
        debugPrint('[Settings] 刚拿到过电脑端目录，本次上线不重复拉取');
      } else {
        unawaited(refreshAgentCatalog(silent: true));
      }
    }
  }

  /// 电脑端"上线"的时刻。用于区分两种"在线但目录为空"：
  /// 刚上线（多半是目录还在路上，提示"正在同步"即可）vs 已在线很久（那才需要怀疑宿主）。
  DateTime? _agentOnlineSince;
  bool get agentRecentlyCameOnline =>
      _agentOnlineSince != null &&
      DateTime.now().difference(_agentOnlineSince!) < const Duration(seconds: 20);

  /// 服务端下发的「桥接状态切换中」标记（null = 已切换完成/无切换）。
  BridgeTransition? _bridgeTransition;
  BridgeTransition? get bridgeTransition => _bridgeTransition;

  /// 当前是否有设备正在切换桥接状态（含本机或其他端发起的）。
  ///
  /// 这是**账号级**互斥：手机点了启动、电脑还没执行完的这几秒里，
  /// 电脑端界面同样必须置灰按钮，否则又点一次就会下发相反指令。
  bool get isBridgeSwitching => _bridgeTransition != null;

  /// 本机之外的另一台设备正在切换（用于提示文案）。
  bool get isBridgeSwitchingByOtherDevice =>
      _bridgeTransition != null &&
      _bridgeTransition!.by != AppSettings.currentDeviceType;

  void _applyBridgeTransition(BridgeTransition? transition) {
    final changed = (_bridgeTransition?.command != transition?.command) ||
        (_bridgeTransition?.by != transition?.by) ||
        ((_bridgeTransition == null) != (transition == null));
    _bridgeTransition = transition;
    if (changed) {
      debugPrint(
        transition == null
            ? '[Settings] 桥接状态切换完成，按钮恢复可点'
            : '[Settings] 桥接状态切换中（${transition.command} by ${transition.by}），两端按钮置灰',
      );
      notifyListeners();
    }
  }

  /// 把设置里的 Harness 地址整理成 bridge 需要的 `host:port` 形式。
  String _harnessUrlForBridge() {
    var url = _settings.harnessServiceUrl.trim();
    if (url.startsWith('http://')) {
      url = url.substring(7);
    } else if (url.startsWith('https://')) {
      url = url.substring(8);
    }
    url = url.replaceAll(RegExp(r'/+$'), '');
    return url.isEmpty ? '127.0.0.1:3080' : url;
  }

  /// 执行手机端下发的桥接控制指令（电脑端 App 收到后在本机操作脚本）。
  ///
  /// 手机点「重置 Token」时服务端会换发新 Token 并踢掉旧连接，脚本按设计退出；
  /// 随后手机排队一条 restart 指令，电脑端这里用【刚同步到的新 Token】把它拉起来。
  ///
  /// 注意：仅电脑端执行。手机端收到同样的指令必须忽略 —— 它没有本机脚本可启停。
  Future<void> _handleBridgeCommand(String command) async {
    // 仅电脑端（Android/iOS 没有本机 python 脚本可启停）
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    if (!isDesktop) {
      debugPrint('[Bridge] 本端非电脑端，忽略远端指令: $command');
      return;
    }
    final manager = BridgeProcessManager.instance;
    final token = _settings.harnessToken.trim();
    final harness = _harnessUrlForBridge();
    debugPrint('[Bridge] 收到远端指令: $command');
    switch (command) {
      case 'start':
        await manager.start(token: token, harnessUrl: harness);
        break;
      case 'stop':
        await manager.stop();
        break;
      case 'restart':
        await manager.restart(token: token, harnessUrl: harness);
        break;
      default:
        debugPrint('[Bridge] 未知指令，已忽略: $command');
    }
  }

  /// 服务端下发新的 Agent Token 时同步到本地并刷新界面。
  ///
  /// 该回调由会话轮询（每 4 秒）驱动，因此任一端"重新生成"后，
  /// 另一端无需重新登录即可收敛到同一枚 token，界面显示也会同步更新。
  void _applyServerAgentToken(String token) {
    final clean = token.trim();
    if (clean.isEmpty || clean == _settings.harnessToken) return;
    _settings.harnessToken = clean;
    // 服务端已是唯一真源，无需再推回去
    _save(pushToCloud: false);
    debugPrint('[Settings] 已同步服务端下发的 Agent Token');
  }

  /// 处理顶号强制下线
  void handleForceLogout(String reason) {
    if (!_settings.isLoggedIn) return;

    // 被顶下线后不应再保留"切换中"的置灰状态，否则重新登录后按钮是灰的
    _bridgeTransition = null;
    // 同时断开推送长连接，避免被踢的设备还挂在那里收事件
    SyncService.instance.stopPushChannel();
    _settings.isLoggedIn = false;
    _save();

    if (_isShowingKickDialog) return;
    _isShowingKickDialog = true;

    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null) {
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (dialogCtx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 26),
                SizedBox(width: 8),
                Text('账号已下线', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              ],
            ),
            content: Text(
              reason.isNotEmpty
                  ? reason
                  : '您的账号已在另一台${AppSettings.currentDeviceType == 'mobile' ? '手机' : '电脑'}上登录，当前设备已被下线。如非本人操作，请及时修改密码。',
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  _isShowingKickDialog = false;
                  Navigator.of(dialogCtx).pop();
                },
                child: const Text('重新登录'),
              ),
            ],
          ),
        ),
      ).then((_) {
        _isShowingKickDialog = false;
      });
    } else {
      _isShowingKickDialog = false;
    }
  }

  /// 远程服务端登录（支持 1 手机 + 1 电脑互斥限制）
  Future<Map<String, dynamic>> loginWithServer(String account, String password) async {
    final cleanAccount = account.trim();
    if (cleanAccount.isEmpty || password.isEmpty) {
      return {'success': false, 'message': '请输入账号与密码'};
    }

    // 登录时生成全新唯一的 clientSessionId。
    //
    // 注意：这里只生成，**不落盘**，要等服务端真的登记成功（见下方 success 分支）才写。
    // 曾经的写法是"先生成本地 id，再发登录请求"，于是请求失败（中继重启/断网）时
    // 会走下面的"离线登录"兜底并把新 id 持久化 —— 这个 id 服务端从没见过，
    // 之后每次 check-session / 推送握手都被判成"已在另一台设备登录"，用户看到的是
    // 每次启动都弹「账号已下线」的假顶号（本地 ef7da695… vs 中继 33da7e49… 即此例）。
    final newSessionId = const Uuid().v4();

    final res = await SyncService.instance.loginWithServer(
      username: cleanAccount,
      password: password,
      clientSessionId: newSessionId,
      deviceType: AppSettings.currentDeviceType,
    );

    if (res['success'] == true) {
      // 服务端已把本次会话写进 active_sessions，本地才跟着换 id，两边始终一致
      _settings.clientSessionId = newSessionId;
      _settings.loginAccount = cleanAccount;
      _settings.accountPassword = password;
      _settings.isLoggedIn = true;
      _save(pushToCloud: false);

      // 启动心跳多端互斥监听
      _startSessionMonitoring();

      // 异步拉取云端设置；若云端已有配置则合并，否则同步推送当前配置至云端
      pullCloudSettings().then((_) {
        _debouncePushSettings();
      });

      return {'success': true};
    } else {
      // 若服务器不可达，且本地已保存过同账号密码，允许本地离线登录。
      // 离线登录**沿用本地已有的 clientSessionId**（不换成服务端没见过的新 id），
      // 否则一旦分叉，用户会反复看到假顶号。
      if (_settings.loginAccount == cleanAccount && _settings.accountPassword == password) {
        debugPrint('[Settings] 服务端不可达，走本地离线登录（沿用原 clientSessionId，避免与服务端记录分叉）');
        _settings.isLoggedIn = true;
        _save(pushToCloud: false);
        _startSessionMonitoring();
        return {'success': true};
      }
      return {
        'success': false,
        'message': res['message'] ?? '登录失败，请检查账号与密码',
      };
    }
  }

  /// 记录上一次静默接管的时间，避免与"真在用的另一台设备"来回抢号
  DateTime? _lastTakeoverAt;

  /// 被判定"已在另一台设备登录"时的自愈：服务端若带了 canTakeover（该设备槽位
  /// 早已没人刷活跃），就用本地保存的账号密码静默重登一次，把服务端记录重新对齐到
  /// 本机 id，然后照常继续，不弹「账号已下线」。
  ///
  /// 这是**认证过的接管**：真在用的另一台设备每 4~30 秒就会刷新槽位活跃时间，
  /// 服务端不会给出 canTakeover，所以不会出现两台机器互相把对方顶下线。
  /// 60 秒内最多尝试一次，防止异常情况下打转。
  Future<bool> _trySilentTakeover() async {
    final last = _lastTakeoverAt;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
      return false;
    }
    final account = _settings.loginAccount.trim();
    final password = _settings.accountPassword;
    if (account.isEmpty || password.isEmpty) return false;
    _lastTakeoverAt = DateTime.now();
    debugPrint('[Settings] 检测到本机会话与服务端记录分叉，尝试静默重登接管');
    final res = await loginWithServer(account, password);
    final ok = res['success'] == true;
    debugPrint('[Settings] 静默接管${ok ? "成功，已恢复连接" : "失败，按真实顶号处理"}');
    return ok;
  }

  /// 远程服务端注册
  Future<Map<String, dynamic>> registerWithServer({
    required String account,
    required String userName,
    required String password,
  }) async {
    final cleanAccount = account.trim();
    if (cleanAccount.isEmpty || password.isEmpty) {
      return {'success': false, 'message': '账号与密码不能为空'};
    }

    final res = await SyncService.instance.registerWithServer(
      username: cleanAccount,
      password: password,
    );

    if (res['success'] == true) {
      _settings.userName = userName.trim().isNotEmpty ? userName.trim() : '用户_$cleanAccount';
      // 注册成功后自动执行登录
      return await loginWithServer(cleanAccount, password);
    } else {
      return {
        'success': false,
        'message': res['message'] ?? '注册失败，该用户名可能已被占用',
      };
    }
  }

  /// 本地兼容单机快速登录
  bool login(String account, String password) {
    if (_settings.loginAccount.isEmpty) {
      return false;
    }
    if (_settings.loginAccount == account &&
        (_settings.accountPassword.isEmpty || _settings.accountPassword == password)) {
      _settings.isLoggedIn = true;
      _save();
      _startSessionMonitoring();
      return true;
    }
    return false;
  }

  /// 用户注册 (兼容本地模式)
  void register({
    required String account,
    required String userName,
    required String password,
  }) {
    _settings.loginAccount = account.trim();
    _settings.userName = userName.trim().isNotEmpty ? userName.trim() : '用户_${account.trim()}';
    _settings.accountPassword = password;
    _settings.isLoggedIn = true;
    _save();
    _startSessionMonitoring();
  }

  /// 退出登录
  void logout() {
    SyncService.instance.logoutServer(
      username: _settings.loginAccount,
      clientSessionId: _settings.clientSessionId,
      deviceType: AppSettings.currentDeviceType,
    );
    SyncService.instance.stopSessionWatcher();

    // 已退出登录：关闭常驻保活，避免未登录状态仍占着前台服务与常驻通知
    KeepAliveService.stop();

    _settings.isLoggedIn = false;
    _save();
  }

  /// 更新 Agent 执行配置
  void updateAgentExecutionOptions({
    String? reasoningEffort,
    String? permission,
    String? model,
    String? workspace,
    String? sessionId,
  }) {
    if (reasoningEffort != null) _settings.agentReasoningEffort = reasoningEffort;
    if (permission != null) _settings.agentPermission = permission;
    if (model != null) _settings.agentModel = model;
    if (workspace != null) _settings.targetWorkspace = workspace;
    if (sessionId != null) _settings.targetSessionId = sessionId;
    _save();
  }

  /// 刷新本地 Agent 连接状态
  Future<bool> refreshAgentStatus() async {
    final isOnline = await SyncService.instance.checkAgentStatus(_settings.harnessToken);
    if (_settings.isHarnessOnline != isOnline) {
      _settings.isHarnessOnline = isOnline;
      _save();
    }
    return isOnline;
  }

  /// 获取本地 Agent 工作区与会话列表
  Future<Map<String, dynamic>> fetchAgentWorkspacesAndSessions() async {
    // 带上当前登录账号：服务端据此校验该 Token 是否属于本账号（防止越权访问他人电脑）
    final data = await SyncService.instance.getAgentSessions(
      _settings.harnessToken,
      userId: _settings.loginAccount,
    );
    final requestOk = data['ok'] == true;
    // 只有服务端**明确**说"电脑端不在线"才改本地在线标记。
    // 请求本身失败（断网/中继抖动/超时）不改 —— 否则一次抖动就把界面打成
    // "离线"，还弹"请确认电脑端桥接在线"，把用户指向错误的方向。
    if (requestOk) {
      final isOnline = data['online'] == true;
      if (_settings.isHarnessOnline != isOnline) {
        _settings.isHarnessOnline = isOnline;
        _save();
      }
    }
    _lastCatalogError = requestOk ? (data['error']?.toString() ?? '') : (data['error']?.toString() ?? '请求失败');
    _lastCatalogOnline = data['online'] == true;
    return data;
  }

  /// 最近一次目录刷新的失败原因（空 = 没失败）；供界面给出准确提示。
  String _lastCatalogError = '';
  String get lastCatalogError => _lastCatalogError;

  /// 服务端最近一次是否报告"电脑端在线"（用于区分"离线"和"在线但没取到"）。
  bool _lastCatalogOnline = false;
  bool get lastCatalogOnline => _lastCatalogOnline;

  // ==================== 电脑端工作区 / 会话目录缓存 ====================
  //
  // 放在 Provider 里而不是设置页的 State：设置页每次重建都会用假的预设值
  // （'deepseek-agent' 等）初始化，用户返回再进来就看到一堆并不存在的选项，
  // 选中后又把假目录发给 Agent，任务自然失败。目录只应由电脑端宿主提供，
  // 取不到就保持为空 —— 界面上就是个空白框，而不是编一个出来。

  List<String> _agentWorkspaces = [];
  List<Map<String, dynamic>> _agentSessions = [];
  List<Map<String, dynamic>> _agentModels = [];
  bool _agentCatalogLoaded = false;
  bool _agentCatalogLoading = false;

  /// 电脑端真实存在的工作区列表（未取到过则为空）。
  List<String> get agentWorkspaces => List.unmodifiable(_agentWorkspaces);

  /// 电脑端真实存在的会话列表（每条含 id / title / workspace）。
  List<Map<String, dynamic>> get agentSessions => List.unmodifiable(_agentSessions);

  /// 电脑端真实可用的模型（每条含 id / name / provider / reasoningEfforts）。
  List<Map<String, dynamic>> get agentModels => List.unmodifiable(_agentModels);

  /// 某个模型支持的思考档位（取不到时给出宿主通用的四档）。
  List<String> reasoningEffortsFor(String modelId) {
    final id = modelId.trim();
    for (final m in _agentModels) {
      if (m['id']?.toString() == id) {
        final efforts = m['reasoningEfforts'];
        if (efforts is List && efforts.isNotEmpty) {
          return efforts.map((e) => e.toString()).toList();
        }
      }
    }
    // 宿主当前部署的模型都是这四档（见 /v1/models 的 reasoningEfforts）
    return const ['off', 'low', 'high', 'max'];
  }

  /// 模型显示名。
  static String agentModelLabel(Map<String, dynamic> model) {
    final name = model['name']?.toString().trim() ?? '';
    final id = model['id']?.toString().trim() ?? '';
    if (name.isEmpty) return id;
    return name == id ? id : '$name ($id)';
  }

  /// 是否成功取到过一次目录（用于区分"还没取"与"取到空"）。
  bool get agentCatalogLoaded => _agentCatalogLoaded;
  bool get agentCatalogLoading => _agentCatalogLoading;

  /// 会话显示名：优先标题，其次 id。
  static String agentSessionLabel(Map<String, dynamic> session) {
    final title = session['title']?.toString().trim() ?? '';
    if (title.isNotEmpty) return title;
    final id = session['id']?.toString().trim() ?? '';
    return id.isEmpty ? '未命名会话' : id;
  }

  /// 按当前工作区过滤会话（工作区为空则返回全部）。
  List<Map<String, dynamic>> sessionsForWorkspace(String workspace) {
    final ws = workspace.trim();
    if (ws.isEmpty) return agentSessions;
    return _agentSessions.where((s) {
      final sw = s['workspace']?.toString().trim() ?? '';
      return sw.isEmpty || sw == ws;
    }).toList();
  }

  /// 宿主真实存在的权限预设（由插件 `/v1/permission-presets` 确认）。
  ///
  /// 采纳会话真值时要过滤：宿主在"当前沙箱/审批策略不匹配任何预设"时会报 `custom`，
  /// 它并不是可以下发的预设名，照抄过来只会让之后每一轮下发都失败一次。
  static const Set<String> agentPermissionPresets = {
    'read-only',
    'workspace-write',
    'danger-full-access',
  };

  /// 采纳电脑端会话**真实生效**的模型 / 思考深度 / 权限预设。
  ///
  /// 为什么需要：这三项此前在 App 里**只写不读** —— 启动时界面显示的是 App 自己存的
  /// 旧值（默认 high / workspace-write / deepseek-v4-flash），与宿主会话里实际生效的
  /// 档位对不上（用户看到"深度=高"，电脑端其实是最高）；更糟的是下一条消息还会把这个
  /// 旧值**推回** 宿主，把用户在电脑端调好的设置覆盖掉。
  ///
  /// 只对**当前目标会话**采纳：消息实际发进哪个会话，就以那个会话的真值为准。
  /// 没选会话时（"新建会话"模式）App 的值就是准的——新会话本来就按 App 下发的值创建，
  /// 此时若拿别的会话去覆盖，反而会把用户刚改的档位打回去。
  ///
  /// 只读回、**不回推**：避免读→写→再读的来回覆盖。
  /// 字段缺失（老插件 / 老桥接）时保持原值，绝不拿空值覆盖用户设置。
  void _adoptAgentStateFromSession() {
    if (_agentSessions.isEmpty) return;

    // 刚保存过设置（用户在下拉里改档位、跑 /effort、云端漫游合并…）就先不采纳：
    // 那条改动可能正在下发给电脑端，此刻读到的投影还是旧值，会把界面打回去。
    if (DateTime.now().difference(_lastSettingsSaveAt) < const Duration(seconds: 8)) {
      debugPrint('[Settings] 刚保存过设置，本轮跳过电脑端状态对齐');
      return;
    }

    final target = _settings.targetSessionId.trim();
    Map<String, dynamic>? row;
    if (target.isNotEmpty) {
      for (final s in _agentSessions) {
        final id = (s['id'] ?? s['sessionId'])?.toString().trim() ?? '';
        if (id == target) {
          row = s;
          break;
        }
      }
    }

    final realModel = row?['model']?.toString().trim() ?? '';
    final realEffort = row?['reasoningEffort']?.toString().trim() ?? '';
    final realPermission = row?['permission']?.toString().trim() ?? '';

    var changed = false;

    // 1) 模型：以电脑端会话为准。另外，若 App 存的模型在电脑端目录里根本不存在
    //    （典型：宿主重启后旧模型下线，如 deepseek-v41-flash），**无论有没有选中会话**
    //    都必须换掉 —— 否则下一条消息会带着这个不存在的模型名去请求，电脑端直接 404，
    //    手机上只看到一句含糊的"本地服务连接失败"。
    final catalogIds = _agentModels
        .map((m) => m['id']?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    var nextModel = realModel.isNotEmpty ? realModel : _settings.agentModel.trim();
    if (catalogIds.isNotEmpty && !catalogIds.contains(nextModel)) {
      debugPrint('[Settings] 当前模型 "$nextModel" 不在电脑端目录中，改用目录首个模型');
      nextModel = catalogIds.first;
    }
    if (nextModel.isNotEmpty && nextModel != _settings.agentModel) {
      _settings.agentModel = nextModel;
      changed = true;
    }

    if (row != null) {
      // 2) 思考深度：会话真值优先；缺失或该模型不支持时收敛到模型声明的档位
      final allowed = reasoningEffortsFor(_settings.agentModel);
      var nextEffort = realEffort.isNotEmpty ? realEffort : _settings.agentReasoningEffort;
      if (allowed.isNotEmpty && !allowed.contains(nextEffort)) {
        nextEffort = allowed.contains('high') ? 'high' : allowed.first;
      }
      if (nextEffort.isNotEmpty && nextEffort != _settings.agentReasoningEffort) {
        _settings.agentReasoningEffort = nextEffort;
        changed = true;
      }

      // 3) 权限预设：同样以会话真值为准，但只认真实存在的预设名（过滤 custom 这类派生值）
      if (realPermission.isNotEmpty &&
          agentPermissionPresets.contains(realPermission) &&
          realPermission != _settings.agentPermission) {
        _settings.agentPermission = realPermission;
        changed = true;
      }
    }

    if (changed) {
      debugPrint('[Settings] 已按电脑端会话对齐：模型=${_settings.agentModel} '
          '深度=${_settings.agentReasoningEffort} 权限=${_settings.agentPermission}');
      // 派生值不推云端：否则两端会为了"谁是准的"反复写一遍
      _save(pushToCloud: false);
    }
  }

  /// 正在进行的刷新（并发调用复用同一次，不要把"正在刷"当成"失败"）。
  ///
  /// 曾经的写法是开头 `if (_agentCatalogLoading) return false;`：
  /// 用户在自动刷新（尤其是带重试的那次，窗口最长约 10 秒）期间点刷新，
  /// 会立刻拿到 false，界面据此弹出"没取到目录"——纯属误报。
  Future<bool>? _agentCatalogPending;

  /// 「用户主动点刷新」才为 true —— 界面**只在这个窗口转圈**。
  ///
  /// 自动刷新（电脑端刚上线、启动时对齐）以前也复用 `_agentCatalogLoading`，
  /// 于是那个刷新图标会无缘无故地转一下 —— 用户看到的就是"App 时不时闪一下"。
  /// 后台刷新本来就该是无声的。
  bool _agentCatalogUserLoading = false;

  /// 最近一次**成功**取到目录的时刻（用于给"刚上线就补拉"节流）。
  DateTime? _lastCatalogSuccessAt;

  /// 拉取一次电脑端工作区与会话，并缓存下来供设置页与聊天快捷栏共用。
  ///
  /// 两个针对"电脑端刚上线"的处理（实测：桥接从注册成功到推出第一份目录约 4 秒）：
  /// - **在线但目录为空时自动重试**，最多 2 次（等 2 秒、3 秒），用户不必手点第二次；
  /// - **取不到时保留上一次的目录**，不要把一个暂时取不到的目录清空成空白，
  ///   否则用户看到的是"目录凭空消失"，而不是"暂时没拿到"。
  Future<bool> refreshAgentCatalog({bool silent = true}) {
    if (!silent && !_agentCatalogUserLoading) {
      _agentCatalogUserLoading = true;
      notifyListeners();
    }
    final pending = _agentCatalogPending;
    if (pending != null) {
      debugPrint('[Settings] 已有一次目录刷新在进行，复用其结果');
      return silent ? pending : pending.whenComplete(_endUserCatalogLoading);
    }
    final future = _refreshAgentCatalogInner(silent: silent);
    _agentCatalogPending = future;
    final wrapped = future.whenComplete(() {
      if (identical(_agentCatalogPending, future)) _agentCatalogPending = null;
    });
    return silent ? wrapped : wrapped.whenComplete(_endUserCatalogLoading);
  }

  void _endUserCatalogLoading() {
    if (!_agentCatalogUserLoading) return;
    _agentCatalogUserLoading = false;
    notifyListeners();
  }

  /// 界面的刷新按钮据此转圈：只反映"用户点的那一次"。
  bool get agentCatalogUserLoading => _agentCatalogUserLoading;

  Future<bool> _refreshAgentCatalogInner({required bool silent}) async {
    _agentCatalogLoading = true;
    try {
      var res = await fetchAgentWorkspacesAndSessions();
      var wsList = _parseWorkspaces(res);
      var sessList = _parseSessions(res);
      var modelList = _parseModels(res);

      // 电脑端在线却什么都没拿到 → 极可能是"刚注册、首份目录还在路上"，
      // 这不是失败，等两拍再问一次。
      for (var retry = 0; retry < 2; retry++) {
        final onlineButEmpty = _lastCatalogOnline && wsList.isEmpty && sessList.isEmpty;
        if (!onlineButEmpty) break;
        await Future.delayed(Duration(seconds: retry == 0 ? 2 : 3));
        res = await fetchAgentWorkspacesAndSessions();
        wsList = _parseWorkspaces(res);
        sessList = _parseSessions(res);
        modelList = _parseModels(res);
      }

      final gotContent = wsList.isNotEmpty || sessList.isNotEmpty;
      if (gotContent) {
        _agentWorkspaces = wsList;
        _agentSessions = sessList;
        _lastCatalogSuccessAt = DateTime.now();
      } else if (!_agentCatalogLoaded) {
        // 从来没取到过：保持空白（不要给假目录），界面据此显示"未取到"
        _agentWorkspaces = const [];
        _agentSessions = const [];
      } else {
        debugPrint('[Settings] 本次没取到目录，保留上一次缓存（${_agentWorkspaces.length} 个工作区）');
      }
      if (modelList.isNotEmpty) _agentModels = modelList;
      // 取到电脑端目录后，顺手把电脑端**真实生效**的模型 / 思考深度 / 权限对齐过来
      _adoptAgentStateFromSession();
      // 只有真的取到内容才算"已加载"，避免把一次失败当成"电脑上确实没有"
      _agentCatalogLoaded = _agentCatalogLoaded || gotContent;
      debugPrint('[Settings] 目录刷新: ${wsList.length} 个工作区 / ${sessList.length} 个会话 / '
          '${modelList.length} 个模型${_agentCatalogLoaded ? "" : "（未取到，界面保持空白）"}');
      notifyListeners();
      return gotContent;
    } catch (e) {
      debugPrint('[Settings] refreshAgentCatalog 失败: $e');
      _lastCatalogError = '$e';
      if (!silent) rethrow;
      return false;
    } finally {
      _agentCatalogLoading = false;
    }
  }

  List<String> _parseWorkspaces(Map<String, dynamic> res) =>
      (res['workspaces'] as List<dynamic>?)
          ?.map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList() ??
      <String>[];

  List<Map<String, dynamic>> _parseSessions(Map<String, dynamic> res) =>
      (res['sessions'] as List<dynamic>?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      <Map<String, dynamic>>[];

  List<Map<String, dynamic>> _parseModels(Map<String, dynamic> res) =>
      (res['models'] as List<dynamic>?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      <Map<String, dynamic>>[];

  /// 在电脑端新建一个会话，成功后刷新目录并返回新会话 id（失败返回 null）。
  Future<String?> createAgentSessionOnPc({
    String workspace = '',
    String title = '',
    String model = '',
  }) async {
    final sessionId = await SyncService.instance.createAgentSession(
      token: _settings.harnessToken,
      userId: _settings.loginAccount,
      workspace: workspace.trim(),
      title: title.trim(),
      model: model.trim(),
    );
    if (sessionId == null || sessionId.isEmpty) return null;
    await refreshAgentCatalog();
    return sessionId;
  }

  /// 从云端拉取配置并合并
  Future<void> pullCloudSettings() async {
    if (!_settings.isLoggedIn || _settings.loginAccount.trim().isEmpty || _settings.loginAccount.trim() == 'guest') {
      return;
    }
    try {
      final cloud = await SyncService.instance.pullSettings(
        userId: _settings.loginAccount,
        clientSessionId: _settings.clientSessionId,
      );
      if (cloud != null) {
        cloud.isLoggedIn = true;
        cloud.loginAccount = _settings.loginAccount;
        cloud.accountPassword = _settings.accountPassword;
        cloud.clientSessionId = _settings.clientSessionId;

        // 保留本地私密 API Key 与语音 Key，避免云端脱敏空值覆盖本地凭证
        for (final cloudEp in cloud.apiEndpoints) {
          final localMatches = _settings.apiEndpoints.where(
            (e) => e.id == cloudEp.id || e.modelName == cloudEp.modelName,
          );
          if (localMatches.isNotEmpty) {
            final localEp = localMatches.first;
            if (cloudEp.apiKey.trim().isEmpty && localEp.apiKey.trim().isNotEmpty) {
              cloudEp.apiKey = localEp.apiKey;
            }
          }
        }
        if (cloud.asrApiKey.trim().isEmpty && _settings.asrApiKey.trim().isNotEmpty) {
          cloud.asrApiKey = _settings.asrApiKey;
        }

        // 配对 Token 以【服务端】为准：服务端是唯一真源，它会在首次同步时采纳
        // 客户端带来的 token、之后保持稳定。此前"以本地为准"会导致多端各持一份、
        // 永远无法收敛（桌面端点启动用桌面 token、手机用自己的 token → 互相看不到）。
        final serverToken = cloud.harnessToken.trim();
        final localToken = _settings.harnessToken.trim();
        if (serverToken.length >= 16 && serverToken != kLegacyDefaultAgentToken) {
          cloud.harnessToken = serverToken;
        } else if (localToken.length >= 16 && localToken != kLegacyDefaultAgentToken) {
          // 服务端还没有（首次同步）：保留本地值，并立即推给服务端固化为真源
          cloud.harnessToken = localToken;
          Future.microtask(() {
            SyncService.instance.pushSettings(
              userId: cloud.loginAccount,
              settings: _settings,
              clientSessionId: _settings.clientSessionId,
            );
          });
        } else {
          cloud.harnessToken = generateAgentPairingToken();
        }

        // 在线状态是本机运行时事实：云端那份是**上一次推送时的旧值**（中继启动期
        // 尤其容易是 false，实测生产库里就恒为 false）。以前这里整份覆盖，于是
        // 每次云端漫游/推送回拉都把本地"在线"打成"离线"，下一轮轮询再打回"在线" ——
        // 客户端据此判定"电脑端刚上线"，又去拉一次目录（App 时不时闪一下的根因）。
        // 注意：中继与 pushSettings 两侧也已不再上传/存储这个字段，这里是第三道闸。
        final keepHarnessOnline = _settings.isHarnessOnline;
        _settings = cloud;
        _settings.isHarnessOnline = keepHarnessOnline;
        _save(pushToCloud: false);
      }
    } catch (e) {
      debugPrint('[SettingsProvider] pullCloudSettings error: $e');
    }
  }

  /// 防抖推送配置至云端
  void _debouncePushSettings() {
    _cloudPushDebounceTimer?.cancel();
    _cloudPushDebounceTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_settings.isLoggedIn && _settings.loginAccount.trim().isNotEmpty && _settings.loginAccount.trim() != 'guest') {
        SyncService.instance.pushSettings(
          userId: _settings.loginAccount,
          settings: _settings,
          clientSessionId: _settings.clientSessionId,
        );
      }
    });
  }

  /// 从服务端获取模型限制表并自动校验修正当前已配置的端点
  Future<void> fetchAndApplyModelLimits() async {
    try {
      final limits = await SyncService.instance.fetchModelLimits();
      if (limits.isNotEmpty) {
        _serverModelLimits = limits;
        bool changed = false;
        for (final ep in _settings.apiEndpoints) {
          final maxAllowed = findEffectiveLimit(ep.modelName);
          if (maxAllowed != null && maxAllowed > 0 && ep.contextLength > maxAllowed) {
            ep.contextLength = maxAllowed;
            changed = true;
          }
        }
        if (changed) {
          _save();
        } else {
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[SettingsProvider] fetchAndApplyModelLimits error: $e');
    }
  }

  /// 查找指定模型在服务端限制表中的有效上限（支持全字、小写与模糊匹配）
  int? findEffectiveLimit(String? modelName) {
    if (modelName == null || modelName.trim().isEmpty || _serverModelLimits.isEmpty) return null;
    final clean = modelName.trim().toLowerCase();

    // 1. 精确匹配
    if (_serverModelLimits.containsKey(clean)) {
      return _serverModelLimits[clean];
    }
    for (final entry in _serverModelLimits.entries) {
      if (entry.key.toLowerCase() == clean) {
        return entry.value;
      }
    }

    // 2. 模糊匹配
    for (final entry in _serverModelLimits.entries) {
      final k = entry.key.toLowerCase();
      if (clean.contains(k) || k.contains(clean)) {
        return entry.value;
      }
    }
    return null;
  }

  /// 最近一次保存设置的时间。用于让"按电脑端会话对齐"避开刚刚发生的本地修改：
  /// 用户刚把档位改成 max 并下发给电脑端，此刻投影可能还是旧值，立刻读回会把界面打回去。
  DateTime _lastSettingsSaveAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _save({bool pushToCloud = true}) {
    _lastSettingsSaveAt = DateTime.now();
    _updateImageCache();
    StoragePathService.instance.setCustomPath(_settings.customDataPath);
    StorageService.instance.saveSettings(_settings);
    notifyListeners();
    if (pushToCloud) {
      _debouncePushSettings();
    }
  }
}
