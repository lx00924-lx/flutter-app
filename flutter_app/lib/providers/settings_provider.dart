import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/app_settings.dart';
import '../services/storage_service.dart';
import '../services/storage_path_service.dart';
import '../services/sync_service.dart';
import '../services/keep_alive_service.dart';
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
      onKicked: (reason) {
        handleForceLogout(reason);
      },
    );

    // 已登录：开启 Android 常驻保活前台服务，确保划掉任务栏后
    // Dart isolate 仍存活，上面的会话轮询与中继长连接得以继续运行
    KeepAliveService.enableAfterLogin();
  }

  /// 处理顶号强制下线
  void handleForceLogout(String reason) {
    if (!_settings.isLoggedIn) return;

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

    // 登录时生成全新唯一的 clientSessionId
    final newSessionId = const Uuid().v4();
    _settings.clientSessionId = newSessionId;

    final res = await SyncService.instance.loginWithServer(
      username: cleanAccount,
      password: password,
      clientSessionId: newSessionId,
      deviceType: AppSettings.currentDeviceType,
    );

    if (res['success'] == true) {
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
      // 若服务器不可达，且本地已保存过同账号密码，允许本地离线登录
      if (_settings.loginAccount == cleanAccount && _settings.accountPassword == password) {
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
    final isOnline = data['online'] == true;
    if (_settings.isHarnessOnline != isOnline) {
      _settings.isHarnessOnline = isOnline;
      _save();
    }
    return data;
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

        _settings = cloud;
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

  void _save({bool pushToCloud = true}) {
    _updateImageCache();
    StoragePathService.instance.setCustomPath(_settings.customDataPath);
    StorageService.instance.saveSettings(_settings);
    notifyListeners();
    if (pushToCloud) {
      _debouncePushSettings();
    }
  }
}
