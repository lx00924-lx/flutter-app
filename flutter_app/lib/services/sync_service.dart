import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../models/app_settings.dart';
import '../config/app_config.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../utils/http_client_helper.dart';
import 'storage_service.dart';

/// 桥接控制指令的下发结果。
///
/// [busy] 与 [failed] 必须区分开：前者是「另一台设备正在切换状态，服务端按
/// 账号级互斥拒绝了这次点击」（属于正常保护，提示"稍候"即可），后者才是真的
/// 发不出去（没网、电脑端没登录等）。
enum BridgeCommandResult { ok, busy, failed }

/// 账号级「桥接状态切换中」标记（服务端下发，手机与电脑共用同一份真相）。
///
/// 任一端发起启停/重置后，服务端登记一条标记并通过会话轮询下发给**所有**设备；
/// 两端据此统一置灰按钮，直到 agentOnline 达到期望终态或超时。
class BridgeTransition {
  final String command;
  final bool target;
  final String by;
  final int since;

  const BridgeTransition({
    required this.command,
    required this.target,
    required this.by,
    required this.since,
  });

  static BridgeTransition? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final command = raw['command']?.toString().trim() ?? '';
    if (command.isEmpty) return null;
    return BridgeTransition(
      command: command,
      target: raw['target'] == true,
      by: raw['by']?.toString() ?? 'unknown',
      since: int.tryParse(raw['since']?.toString() ?? '') ?? 0,
    );
  }

  /// 发起端是不是本机（'mobile' / 'desktop'）。
  bool initiatedBy(String deviceType) => by == deviceType;
}

/// 后台静默实时同步服务：实现 Flutter 客户端与服务端的自动增量同步及多端互斥下线监控
class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._() {
    HttpClientHelper.configureProxy(_dio);
  }

  final Dio _dio = Dio(
    BaseOptions(
      // 建连接的时间。10 秒太短：手机在弱网/切网时会报
      // 「无法连接到调度服务器: connection timeout … 0:00:10」，
      // 而此时服务端其实是好的（消息照样能送达）。放宽到 30 秒。
      connectTimeout: const Duration(seconds: 30),
      // 15 秒太短：Agent 任务要等本地宿主跑完（服务端上限 300 秒），
      // 请求发出后十几秒没有任何事件就会被 Dio 判成 receive timeout，
      // 手机上表现为"发消息必失败：The request took longer than 0:00:15"。
      // 这里放宽到 2 分钟，SSE 长连接另外单独设更长的超时（见 streamServerAgentChat）。
      receiveTimeout: const Duration(minutes: 2),
      // 发请求的时间。Agent 消息可能带图片（base64 后几百 KB），
      // 15 秒在慢速上行时会不够。
      sendTimeout: const Duration(seconds: 60),
    ),
  );

  bool _isSyncing = false;
  Timer? _sessionWatcherTimer;
  void Function(String reason, bool canTakeover)? onForceLogout;
  /// 服务端换发 Agent Token 时回调（用于刷新本地设置与界面显示）
  void Function(String token)? onAgentTokenSynced;
  /// 收到手机端下发的桥接控制指令时回调（电脑端据此启停本机脚本）
  void Function(String command)? onBridgeCommand;
  /// Agent 在线状态变化回调（服务端每次轮询下发，用于自动刷新界面）
  void Function(bool online)? onAgentOnlineChanged;
  /// 账号级「桥接状态切换中」标记变化回调（null 表示已切换完成）
  void Function(BridgeTransition? transition)? onBridgeTransition;
  /// 另一端改过设置时回调（本端应重新拉一次云端设置）
  void Function()? onSettingsChanged;

  /// 已应用过的设置版本号，避免重复拉取
  int _appliedSettingsRevision = 0;

  // ==================== App 推送通道（原生 WebSocket） ====================
  //
  // 服务端一直在广播 17 种事件（设置变更、上下线、审批、任务进度、消息……），
  // 但客户端从来没有 socket.io 客户端，等于没人听：只能靠 4 秒会话轮询 + 12 秒
  // 消息拉取去"猜"。这条通道把这些事件真正送到端上，轮询降级为兜底。
  WebSocketChannel? _pushChannel;
  StreamSubscription? _pushSub;
  Timer? _pushReconnectTimer;
  Timer? _pushPingTimer;
  bool _pushConnected = false;
  int _pushRetries = 0;
  String _pushUserId = '';
  String _pushClientSessionId = '';
  String _pushDeviceType = 'mobile';
  bool _pushClosedByUs = false;

  /// 推送通道是否已连通（界面与轮询频率据此自适应）
  bool get pushConnected => _pushConnected;

  /// 收到推送事件时的回调（event 名 + data），由 SettingsProvider 注册后再分发
  void Function(String event, Map<String, dynamic> data)? onPushEvent;

  /// 建立推送长连接（登录后调用；断开会自动重连）
  void startPushChannel({
    required String userId,
    required String clientSessionId,
    required String deviceType,
  }) {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest' || clientSessionId.trim().isEmpty) return;
    stopPushChannel();
    _pushUserId = cleanUserId;
    _pushClientSessionId = clientSessionId.trim();
    _pushDeviceType = deviceType;
    _pushClosedByUs = false;
    _pushRetries = 0;
    _connectPushChannel();
  }

  void stopPushChannel() {
    _pushClosedByUs = true;
    _pushReconnectTimer?.cancel();
    _pushPingTimer?.cancel();
    _pushSub?.cancel();
    _pushSub = null;
    _pushChannel?.sink.close();
    _pushChannel = null;
    _pushConnected = false;
  }

  Uri? _pushUri() {
    try {
      final base = Uri.parse(serverBaseUrl);
      final scheme = base.scheme == 'https' ? 'wss' : 'ws';
      return base.replace(
        scheme: scheme,
        path: '/ws/app',
        queryParameters: {
          'userId': _pushUserId,
          'clientSessionId': _pushClientSessionId,
          'deviceType': _pushDeviceType,
        },
      );
    } catch (e) {
      debugPrint('[SyncService] 构造推送地址失败: $e');
      return null;
    }
  }

  void _connectPushChannel() {
    final uri = _pushUri();
    if (uri == null) return;
    WebSocketChannel channel;
    try {
      channel = kIsWeb
          ? WebSocketChannel.connect(uri)
          : IOWebSocketChannel.connect(uri, pingInterval: const Duration(seconds: 30));
      _pushChannel = channel;
    } catch (e) {
      debugPrint('[SyncService] 推送通道连接失败: $e');
      _schedulePushReconnect();
      return;
    }

    // `ready` 必须有人接住：中继重启期间连接会失败，而这个 future 若无人 await，
    // 就会以"未处理异常"的形式糊到日志里（实测中继重启时刷
    // `Unhandled Exception: WebSocketChannelException … 502`）。真正的重连由下面
    // stream 的 onError / onDone 负责，这里只是把噪音收干净。
    unawaited(() async {
      try {
        await channel.ready;
      } catch (e) {
        debugPrint('[SyncService] 推送通道连接未建立（将按退避重连）: $e');
      }
    }());

    _pushSub = _pushChannel!.stream.listen(
      (raw) {
        _pushRetries = 0;
        if (!_pushConnected) {
          _pushConnected = true;
          debugPrint('[SyncService] 推送通道已连通');
          onPushEvent?.call('push_connected', const {});
        }
        try {
          final decoded = jsonDecode(raw.toString());
          if (decoded is! Map) return;
          final event = decoded['event']?.toString() ?? '';
          if (event.isEmpty) return;
          final data = decoded['data'] is Map
              ? Map<String, dynamic>.from(decoded['data'] as Map)
              : <String, dynamic>{};
          if (event == 'ping') {
            _pushChannel?.sink.add(jsonEncode({'type': 'ping'}));
            return;
          }
          if (event == 'pong' || event == 'ready') return;
          onPushEvent?.call(event, data);
        } catch (e) {
          debugPrint('[SyncService] 推送消息解析失败: $e');
        }
      },
      onError: (e) {
        debugPrint('[SyncService] 推送通道错误: $e');
        _handlePushDown();
      },
      onDone: () {
        debugPrint('[SyncService] 推送通道已关闭');
        _handlePushDown();
      },
      cancelOnError: true,
    );

    // 客户端心跳：服务端 20 秒发一次 ping，这里 25 秒回一次，双向都能发现死链
    _pushPingTimer?.cancel();
    _pushPingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_pushConnected) {
        try {
          _pushChannel?.sink.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
      }
    });
  }

  void _handlePushDown() {
    final wasConnected = _pushConnected;
    _pushConnected = false;
    _pushPingTimer?.cancel();
    if (wasConnected) onPushEvent?.call('push_disconnected', const {});
    if (!_pushClosedByUs) _schedulePushReconnect();
  }

  void _schedulePushReconnect() {
    _pushReconnectTimer?.cancel();
    // 退避重连：2s → 5s → 10s → 之后固定 20s
    final delays = [2, 5, 10, 20];
    final delay = delays[_pushRetries < delays.length ? _pushRetries : delays.length - 1];
    _pushRetries++;
    _pushReconnectTimer = Timer(Duration(seconds: delay), () {
      if (_pushClosedByUs || _pushUserId.isEmpty) return;
      _connectPushChannel();
    });
  }

  String get serverBaseUrl {
    if (kIsWeb) {
      final uri = Uri.base;
      if (uri.host.isNotEmpty) {
        final portPart = uri.hasPort && uri.port != 80 && uri.port != 443 ? ':${uri.port}' : '';
        return '${uri.scheme}://${uri.host}$portPart';
      }
    }
    return AppConfig.normalizedServerBaseUrl;
  }

  /// 统一注入设备与会话识别头
  Options _createOptions({
    String? userId,
    String? clientSessionId,
    String? deviceType,
  }) {
    return Options(
      headers: {
        if (userId != null && userId.isNotEmpty) 'x-user-id': userId,
        'x-device-type': deviceType ?? AppSettings.currentDeviceType,
        if (clientSessionId != null && clientSessionId.isNotEmpty) 'x-client-session-id': clientSessionId,
      },
    );
  }

  void _checkAndTriggerForceLogout(dynamic error) {
    if (error is! DioException) return;
    // ⚠️ 只认 `401 + error == 'FORCE_LOGOUT'`，**不要**顺手把 403 也当成"下线"。
    // 2026-10-06 曾在这里加过一条 403 分支（当时的判断是"服务端身份守卫回 403，
    // 客户端只认 401 会静默失效"）—— 但那个判断是错的：真正的静默失效来自
    // /api/check-session 的 `{valid:true}` 兜底，与服务端改用 FORCE_LOGOUT 表述之后，
    // 这条 403 分支在运行时根本走不到，属于要重打包才生效的死代码，已撤掉。
    //
    // 真正要守的规矩在**服务端**那边：凡是"这个凭证服务端不认了"，一律用
    // `401 + error:'FORCE_LOGOUT'`（形状与顶号一致、带 kickedSessionId 且
    // canTakeover:false），因为客户端的轮询与推送通道都只认这一种。
    // **别新造错误码** —— 旧版 App 遇到不认识的码会整条忽略、继续带着废弃凭证轮询，
    // 而它的每个请求都会被身份守卫拦下，表现就是"界面一切正常、云端同步静默失效"。
    if (error.response?.statusCode == 401) {
      final data = error.response?.data;
      if (data is Map && data['error'] == 'FORCE_LOGOUT') {
        final reason = data['reason']?.toString() ?? '您的账号已在另一台设备上登录，当前设备已被下线。';
        // canTakeover：服务端判定该设备槽位早已没人活跃（对方关掉了 / 本地与服务端
        // 的 clientSessionId 分叉），客户端可凭账号密码静默重登接管，无需弹假顶号。
        final canTakeover = data['canTakeover'] == true;
        stopSessionWatcher();
        onForceLogout?.call(reason, canTakeover);
      }
    }
  }

  /// 启动多端单点登录心跳监听（1手机 + 1电脑互斥）
  void startSessionWatcher({
    required String userId,
    required String clientSessionId,
    required String deviceType,
    required void Function(String reason, bool canTakeover) onKicked,
    void Function(String token)? onTokenSynced,
    void Function(String command)? onCommand,
    void Function(bool online)? onOnlineChanged,
    void Function(BridgeTransition? transition)? onTransition,
    void Function()? onSettingsUpdated,
  }) {
    stopSessionWatcher();
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest' || cleanUserId == 'default_user') {
      return;
    }

    onForceLogout = onKicked;
    onAgentTokenSynced = onTokenSynced;
    onBridgeCommand = onCommand;
    onAgentOnlineChanged = onOnlineChanged;
    onBridgeTransition = onTransition;
    onSettingsChanged = onSettingsUpdated;
    _appliedSettingsRevision = 0;

    // 立即执行一次健康核验
    _checkSessionOnce(cleanUserId, clientSessionId, deviceType);

    // 轮询周期自适应：推送通道连通时降到 30 秒（只当兜底），断了回到 4 秒。
    // 4 秒轮询每天每台设备要发 21600 次请求，长连接顶上之后没必要这么密。
    _restartSessionTimer(cleanUserId, clientSessionId, deviceType);
  }

  void _restartSessionTimer(String userId, String clientSessionId, String deviceType) {
    _sessionWatcherTimer?.cancel();
    final seconds = _pushConnected ? 30 : 4;
    _sessionWatcherTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      _checkSessionOnce(userId, clientSessionId, deviceType);
    });
    // 推送通道状态变化时，这里会由 onPushEvent('push_connected'/'push_disconnected') 重新调用
    _watcherArgs = (userId: userId, clientSessionId: clientSessionId, deviceType: deviceType);
  }

  ({String userId, String clientSessionId, String deviceType})? _watcherArgs;

  /// 推送通道上下线时调整轮询频率
  void refreshPollingInterval() {
    final args = _watcherArgs;
    if (args == null) return;
    final target = _pushConnected ? 30 : 4;
    if (_currentPollSeconds == target) return;
    _currentPollSeconds = target;
    _restartSessionTimer(args.userId, args.clientSessionId, args.deviceType);
    debugPrint('[SyncService] 会话轮询周期调整为 ${target}s（推送通道${_pushConnected ? "已连通" : "断开"}）');
  }

  int _currentPollSeconds = 4;

  /// 停止多端登录监控
  void stopSessionWatcher() {
    _sessionWatcherTimer?.cancel();
    _sessionWatcherTimer = null;
    _watcherArgs = null;
  }

  Future<void> _checkSessionOnce(String userId, String clientSessionId, String deviceType) async {
    try {
      final url = '$serverBaseUrl/api/check-session';
      final response = await _dio.get(
        url,
        queryParameters: {
          'userId': userId,
          'deviceType': deviceType,
          'clientSessionId': clientSessionId,
        },
      );

      if (response.statusCode == 200) {
        final data = response.data;
        if (data is Map && data['valid'] == false) {
          final reason = data['reason']?.toString() ?? '您的账号已在另一台设备上登录，当前设备已被下线。';
          stopSessionWatcher();
          onForceLogout?.call(reason, data['canTakeover'] == true);
        } else if (data is Map) {
          // 服务端在此接口顺带下发当前 Agent Token：换发后各端无需重登即可收敛，
          // 修复"点重置 token 后界面仍显示旧值、两端 token 不一致"的问题。
          final serverToken = data['harnessToken']?.toString().trim();
          if (serverToken != null && serverToken.isNotEmpty) {
            onAgentTokenSynced?.call(serverToken);
          }
          // 手机端下发的桥接控制指令（start / stop / restart），由电脑端在此执行
          final command = data['bridgeCommand']?.toString().trim();
          if (command != null && command.isNotEmpty) {
            onBridgeCommand?.call(command);
          }
          // Agent 在线状态：由服务端在每次轮询时下发，两端据此自动更新界面，
          // 无需用户手动点"刷新"（手机端尤其需要，它无法本地探测电脑进程）。
          if (data['agentOnline'] is bool) {
            onAgentOnlineChanged?.call(data['agentOnline'] as bool);
          }
          // 账号级「切换中」标记：任一端发起启停/重置后出现，两端据此统一置灰按钮，
          // 直到状态真的切换到位（服务端确认后不再下发该字段）。
          onBridgeTransition?.call(BridgeTransition.fromJson(data['bridgeTransition']));

          // 设置版本号：另一端改过设置（开屏启动页等）就重新拉一次。
          // 之前只在冷启动/登录时拉，App 开着的时候双端设置永远不同步。
          final rev = int.tryParse(data['settingsUpdatedAt']?.toString() ?? '');
          if (rev != null && rev > 0 && rev != _appliedSettingsRevision) {
            final bySession = data['settingsBySessionId']?.toString() ?? '';
            _appliedSettingsRevision = rev;
            // 自己写的不必再拉回来（避免无谓往返）
            if (bySession.isEmpty || bySession != clientSessionId) {
              debugPrint('[SyncService] 检测到另一端更新了设置，正在重新拉取云端配置');
              onSettingsChanged?.call();
            }
          }
        }
      }
    } catch (e) {
      _checkAndTriggerForceLogout(e);
    }
  }

  /// 客户端向服务端发起登录认证，并注册当前设备的唯一会话 ID
  Future<Map<String, dynamic>> loginWithServer({
    required String username,
    required String password,
    required String clientSessionId,
    required String deviceType,
  }) async {
    try {
      final url = '$serverBaseUrl/api/login';
      final response = await _dio.post(
        url,
        data: {
          'username': username.trim(),
          'password': password,
          'deviceType': deviceType,
          'clientSessionId': clientSessionId,
        },
      );

      if (response.statusCode == 200 && response.data is Map) {
        return {
          'success': true,
          'data': response.data,
        };
      }
      return {
        'success': false,
        'message': '登录失败，请检查网络后重试',
      };
    } catch (e) {
      if (e is DioException && e.response?.data is Map) {
        final err = e.response!.data['error']?.toString();
        return {
          'success': false,
          'message': err ?? '账号或密码错误',
        };
      }
      return {
        'success': false,
        'message': '无法连接到服务器，请检查网络连接',
      };
    }
  }

  /// 客户端向服务端发起注册。
  ///
  /// ⚠️ **已废弃，且调用它必定失败**（2026-10-02 起）。
  /// 服务端 `/api/register` 现在要求 `email` + `code`（邮箱验证码）两个必填字段，
  /// 还要过 Cloudflare Turnstile —— 本方法只发 `username` + `password`，
  /// 会被服务端以 400 打回。注册已统一移到**官网**（浏览器里做验证码与人机验证），
  /// App 端只保留「前往官网注册」的跳转，见 `screens/login_screen.dart`。
  /// 这里暂不删除，是为了不破坏可能存在的自建部署分支；新代码不要调用它。
  @Deprecated('注册已移到官网（需邮箱验证码 + Turnstile），App 内调用必定失败')
  Future<Map<String, dynamic>> registerWithServer({
    required String username,
    required String password,
  }) async {
    try {
      final url = '$serverBaseUrl/api/register';
      final response = await _dio.post(
        url,
        data: {
          'username': username.trim(),
          'password': password,
        },
      );

      if (response.statusCode == 200 && response.data is Map) {
        return {
          'success': true,
          'data': response.data,
        };
      }
      return {
        'success': false,
        'message': '注册失败，请稍后重试',
      };
    } catch (e) {
      if (e is DioException && e.response?.data is Map) {
        final err = e.response!.data['error']?.toString();
        return {
          'success': false,
          'message': err ?? '注册失败，该用户名可能已被占用',
        };
      }
      return {
        'success': false,
        'message': '无法连接到服务器，请检查网络连接',
      };
    }
  }

  /// 客户端主动登出通知服务端释放当前设备槽位
  Future<void> logoutServer({
    required String username,
    required String clientSessionId,
    required String deviceType,
  }) async {
    stopSessionWatcher();
    try {
      final url = '$serverBaseUrl/api/logout';
      await _dio.post(
        url,
        data: {
          'username': username.trim(),
          'clientSessionId': clientSessionId,
          'deviceType': deviceType,
        },
      );
    } catch (e) {
      debugPrint('[SyncService] Logout server error: $e');
    }
  }

  /// 后台静默从服务器拉取历史消息并合并到本地 Hive，同时基于服务器有效会话与本地 isSynced 状态进行双向权威对齐
  Future<int> pullAndMergeMessages({
    required String userId,
    String? clientSessionId,
    Function()? onNewMessagesImported,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || _isSyncing) return 0;
    _isSyncing = true;
    int importedCount = 0;
    // 用云端更完整的版本覆盖本地半截内容的条数（断流场景，见下方注释）
    int updatedCount = 0;
    bool sessionListChanged = false;

    try {
      // 0. 先将离线期间积压的会话删除指令补发给云端
      await flushPendingDeletions(userId: cleanUserId, clientSessionId: clientSessionId);

      // 0b. 再把离线期间没推上去的消息补传（服务器没开时发的那些）。
      //     放在拉取之前：先把本地的补上去，紧接着拉回来的列表里就有它们了，
      //     这一轮界面就是一致的，不用等下一次同步。
      await flushPendingPushes(userId: cleanUserId, clientSessionId: clientSessionId);

      final url = '$serverBaseUrl/api/messages/$cleanUserId';
      final response = await _dio.get(
        url,
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );

      if (response.statusCode == 200 && response.data is List) {
        final list = response.data as List;
        final storage = StorageService.instance;
        final pendingDeleteIds = Set<String>.from(storage.getPendingDeleteSessionIds());

        // 1. 提取服务器当前权威存活且未处于本地待删队列中的会话 ID 集合
        final serverSessionIds = <String>{};
        for (var item in list) {
          if (item is Map && item['sessionId'] != null) {
            final sId = item['sessionId'].toString().trim();
            if (sId.isNotEmpty && !pendingDeleteIds.contains(sId)) {
              serverSessionIds.add(sId);
            }
          }
        }

        // 2. 检查本地所有会话，执行权威对齐与离线新会话保护：
        final allLocalSessions = storage.getAllSessions();
        for (var localSession in allLocalSessions) {
          if (pendingDeleteIds.contains(localSession.id)) {
            // 处于待删除队列的本地会话必须清除
            await storage.deleteSession(localSession.id);
            sessionListChanged = true;
          } else if (localSession.isSynced && !serverSessionIds.contains(localSession.id)) {
            // 该会话曾经成功上过云端，但服务器现已不存在 -> 说明已被其他设备删除 -> 本地级联同步清除
            await storage.deleteSession(localSession.id);
            sessionListChanged = true;
          } else if (!localSession.isSynced) {
            // 该会话是在离线/未开启服务器时本地新建的 -> 坚决不误删，将其本地消息反向补传至云端
            final localMsgs = storage.getMessagesForSession(localSession.id);
            if (localMsgs.isNotEmpty) {
              await pushMessages(
                userId: cleanUserId,
                messages: localMsgs,
                clientSessionId: clientSessionId,
              );
            }
            localSession.isSynced = true;
            await storage.saveSession(localSession);
          }
        }

        // 3. 将云端新消息与会话导入本地
        final List<ChatMessage> newMessages = [];
        final List<ChatMessage> updatedMessages = [];
        final Map<String, ChatSession> neededSessions = {};

        for (var item in list) {
          if (item is Map) {
            try {
              final rawSessionId = (item['sessionId'] ?? '').toString().trim();
              if (rawSessionId.isEmpty) {
                // 坚决忽略无关联会话 ID 的孤儿错误消息，防止生成异常新对话
                continue;
              }
              final msg = ChatMessage.fromMap(item);
              if (msg.id.isEmpty ||
                  msg.sessionId.trim().isEmpty ||
                  pendingDeleteIds.contains(msg.sessionId)) {
                continue;
              }
              // 本地已有同 id：一般不覆盖（避免把本地更全的内容冲掉），
              // 但**云端明显更有内容**时要覆盖 —— 典型场景：手机 SSE 中途断流，
              // 本地只剩半截 + 「连接中断」提示，而服务端其实已经存了完整回复。
              // 这条规则是单向的：只允许"更长覆盖更短"，绝不会用空内容清掉本地。
              if (storage.hasMessage(msg.id)) {
                final local = storage.getMessageById(msg.id);
                final remoteLen = msg.content.trim().length;
                final localLen = (local?.content ?? '').trim().length;
                // 本地是"连接中断/取回中"的占位文案时无条件接受云端版本：
                // 那是**状态**不是回答，长度比较挡不住它（占位句比短回答还长）。
                final localIsPlaceholder = ChatMessage.isRetrievalPlaceholder(local?.content);
                if (remoteLen > 0 && (remoteLen > localLen || localIsPlaceholder)) {
                  updatedMessages.add(msg);
                }
                continue;
              }
              if (true) {
                newMessages.add(msg);

                // 检查对应 session 是否存在
                if (!storage.hasSession(msg.sessionId) && !neededSessions.containsKey(msg.sessionId)) {
                  final title = msg.content.length > 20
                      ? '${msg.content.substring(0, 20)}...'
                      : (msg.content.isNotEmpty ? msg.content : '云端同步会话');
                  neededSessions[msg.sessionId] = ChatSession(
                    id: msg.sessionId,
                    title: title,
                    createdAt: msg.createdAt,
                    updatedAt: msg.createdAt,
                    isSynced: true,
                  );
                }
              }
            } catch (_) {}
          }
        }

        // 补全缺失的会话
        for (var session in neededSessions.values) {
          session.isSynced = true;
          await storage.saveSession(session);
          sessionListChanged = true;
        }

        // 保存新消息
        for (var msg in newMessages) {
          await storage.saveMessage(msg);
          importedCount++;
        }

        // 用云端更完整的版本覆盖本地（断流后本地只剩半截 + 连接中断提示的场景）
        for (var msg in updatedMessages) {
          await storage.saveMessage(msg);
          updatedCount++;
        }

        if ((importedCount > 0 || updatedCount > 0 || sessionListChanged) && onNewMessagesImported != null) {
          onNewMessagesImported();
        }
      }
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Pull messages silent error: $e');
    } finally {
      _isSyncing = false;
    }

    return importedCount;
  }

  /// 实时静默推送单条或多条消息至服务器。
  ///
  /// @returns 是否**真的推上去了**（服务端确认 2xx）。失败时会把这几条消息的 id
  ///   记进本地"待推队列"，等同步时由 [flushPendingPushes] 补传 —— 以前失败只打
  ///   一行日志，服务器没开时发的消息就永远上不了云。
  Future<bool> pushMessages({
    required String userId,
    required List<ChatMessage> messages,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || messages.isEmpty) return false;

    final validMessages = messages
        .where((m) =>
            !m.isStreaming &&
            // 断流占位文案绝不推云端：它会把服务端其实已经跑完的完整回答覆盖掉
            // （占位句是"状态"，不是内容）。
            !ChatMessage.isRetrievalPlaceholder(m.content) &&
            (m.content.isNotEmpty || (m.attachments != null && m.attachments!.isNotEmpty)))
        .map((m) => m.toMap())
        .toList();

    if (validMessages.isEmpty) return false;

    // 待推队列里要记的是**原始消息 id**（不是过滤后的），否则被过滤掉的那条
    // 永远出不了队，会一直卡在队列里反复重试。
    final pushIds = messages.map((m) => m.id).where((id) => id.isNotEmpty).toList();

    try {
      final url = '$serverBaseUrl/api/sync-messages';
      final resp = await _dio.post(
        url,
        data: {
          'userId': cleanUserId,
          'messages': validMessages,
        },
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );
      final status = resp.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        debugPrint('[SyncService] Push messages failed: HTTP $status');
        await StorageService.instance.addPendingPushMessageIds(pushIds);
        return false;
      }

      // 推成功了：把这几条从待推队列里摘掉（它们可能正是上次失败时入队的）
      await StorageService.instance.removePendingPushMessageIds(pushIds);

      // 标记所涉及的本地会话已成功同步
      final storage = StorageService.instance;
      final sessionIds = Set<String>.from(messages.map((m) => m.sessionId).where((id) => id.isNotEmpty));
      for (final sId in sessionIds) {
        final allSessions = storage.getAllSessions();
        final match = allSessions.where((s) => s.id == sId).firstOrNull;
        if (match != null && !match.isSynced) {
          match.isSynced = true;
          await storage.saveSession(match);
        }
      }
      return true;
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Push messages failed（已入待推队列，等服务器回来补传）: $e');
      // 关键：以前这里只打一行日志，消息就永远上不了云。现在记下来，同步时补推。
      await StorageService.instance.addPendingPushMessageIds(pushIds);
      return false;
    }
  }

  /// 把消息登记进"待推送"队列（不立即发）。
  ///
  /// 给"发送时就连 DNS 都不通"那条早返回路径用 —— 那种情况 `sendMessage`
  /// 根本不会走到 [pushMessages]，不记一笔的话上线后也没人补传。
  Future<void> enqueuePendingPush(List<ChatMessage> messages) async {
    await StorageService.instance.addPendingPushMessageIds(
      messages.map((m) => m.id).where((id) => id.isNotEmpty),
    );
  }

  /// 补推离线期间没推上去的消息。
  ///
  /// 在 [pullAndMergeMessages] 开头与 `flushPendingDeletions` 并列调用：
  /// 每次同步（含每 12 秒的周期同步）都会试着补一次，服务器回来了自然就补齐了。
  ///
  /// 只处理**队列里记过的 id**，按 id 从本地取最新内容再推 —— 不是"服务端没有的
  /// 本地消息全都推一遍"，所以不会把另一台设备已删的消息推回去。
  Future<void> flushPendingPushes({
    required String userId,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty) return;
    final storage = StorageService.instance;
    final pendingIds = storage.getPendingPushMessageIds();
    if (pendingIds.isEmpty) return;

    final toPush = <ChatMessage>[];
    final vanished = <String>[];
    for (final id in pendingIds) {
      final msg = storage.getMessageById(id);
      if (msg == null) {
        // 本地已经没有了（比如用户在补推前把它删了）→ 出队，别一直挂着
        vanished.add(id);
        continue;
      }
      toPush.add(msg);
    }
    if (vanished.isNotEmpty) await storage.removePendingPushMessageIds(vanished);
    if (toPush.isEmpty) return;

    final ok = await pushMessages(
      userId: cleanUserId,
      messages: toPush,
      clientSessionId: clientSessionId,
    );
    if (ok) {
      debugPrint('[SyncService] 已补推 ${toPush.length} 条离线消息');
    }
  }

  /// 实时静默推送会话元数据到服务器（用于会话重命名或创建时同步）
  Future<void> pushSessions({
    required String userId,
    required List<ChatSession> sessions,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || sessions.isEmpty) return;

    try {
      final url = '$serverBaseUrl/api/agent/sync-sessions';
      await _dio.post(
        url,
        data: {
          'userId': cleanUserId,
          'sessions': sessions.map((s) => s.toMap()).toList(),
        },
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Push sessions silent error: $e');
    }
  }

  /// 从云端拉取用户设置配置
  Future<AppSettings?> pullSettings({
    required String userId,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest' || cleanUserId == 'default_user') {
      return null;
    }
    try {
      final url = '$serverBaseUrl/api/settings/$cleanUserId';
      final response = await _dio.get(
        url,
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );
      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map;
        if (data.isNotEmpty && data['apiEndpoints'] != null) {
          return AppSettings.fromMap(data);
        }
      }
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Pull settings error: $e');
    }
    return null;
  }

  /// 推送用户设置配置至云端持久化存储
  Future<bool> pushSettings({
    required String userId,
    required AppSettings settings,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest' || cleanUserId == 'default_user') {
      return false;
    }
    try {
      final url = '$serverBaseUrl/api/settings/$cleanUserId';
      final response = await _dio.post(
        url,
        data: settings.toCloudMap(),
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );
      return response.statusCode == 200;
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Push settings error: $e');
      return false;
    }
  }

  /// 请求服务器后台托管异步生成，确保 App 强杀/切后台后服务器继续完成回复落盘
  Future<void> requestServerBackgroundGeneration({
    required String userId,
    required String assistantMessageId,
    required List<ChatMessage> messages,
    required Map<String, dynamic> settings,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || assistantMessageId.isEmpty) return;

    try {
      final url = '$serverBaseUrl/api/chat/generate';
      await _dio.post(
        url,
        data: {
          'userId': cleanUserId,
          'assistantMessageId': assistantMessageId,
          'messages': messages.map((m) => m.toMap()).toList(),
          'settings': settings,
        },
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Server background gen request: $e');
    }
  }

  /// 实时静默删除云端单条消息。
  ///
  /// @returns 是否**真的删掉了**（服务端确认 2xx）。调用方必须据此决定本地要不要删 ——
  ///   以前这里吞掉异常、调用方照样删本地，于是"服务器没开时删的那条"在下次同步
  ///   又被当成新消息拉回来（复活）。宁可当场告诉用户"删除失败"，也不要假成功。
  Future<bool> deleteMessage({
    required String userId,
    required String messageId,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    final cleanMessageId = messageId.trim();
    if (cleanUserId.isEmpty || cleanMessageId.isEmpty) return false;

    try {
      final url = '$serverBaseUrl/api/delete-message';
      final resp = await _dio.post(
        url,
        data: {
          'userId': cleanUserId,
          'messageId': cleanMessageId,
        },
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );
      final ok = resp.statusCode != null && resp.statusCode! >= 200 && resp.statusCode! < 300;
      if (!ok) {
        debugPrint('[SyncService] Delete message failed: HTTP ${resp.statusCode}');
      }
      return ok;
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Delete message failed（服务器不可达，本地不删）: $e');
      return false;
    }
  }

  /// 实时静默删除云端会话（网络失败时自动存入离线待删除队列）
  Future<void> deleteSession({
    required String userId,
    required String sessionId,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    final cleanSessionId = sessionId.trim();
    if (cleanUserId.isEmpty || cleanSessionId.isEmpty) return;

    try {
      final url = '$serverBaseUrl/api/delete-session';
      await _dio.post(
        url,
        data: {
          'userId': cleanUserId,
          'sessionId': cleanSessionId,
        },
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );
      // 成功发送后从本地待重试删除队列中移除
      await StorageService.instance.removePendingDeleteSessionId(cleanSessionId);
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      // 网络故障或服务器未开启，安全记入本地待重试队列
      await StorageService.instance.addPendingDeleteSessionId(cleanSessionId);
      debugPrint('[SyncService] Delete session recorded in pending queue: $e');
    }
  }

  /// 补发离线期间积压的会话删除指令
  Future<void> flushPendingDeletions({
    required String userId,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty) return;
    final storage = StorageService.instance;
    final pendingIds = storage.getPendingDeleteSessionIds();
    if (pendingIds.isEmpty) return;

    for (final sessionId in List<String>.from(pendingIds)) {
      try {
        final url = '$serverBaseUrl/api/delete-session';
        final resp = await _dio.post(
          url,
          data: {
            'userId': cleanUserId,
            'sessionId': sessionId,
          },
          options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
        );
        if (resp.statusCode == 200) {
          await storage.removePendingDeleteSessionId(sessionId);
        }
      } catch (e) {
        debugPrint('[SyncService] Retry flush pending deletion failed for $sessionId: $e');
        break; // 仍无法连接服务器时暂停后续循环
      }
    }
  }

  /// 检查特定 Token 的本地 Agent 在线状态
  ///
  /// [userId] 为当前登录账号，服务端据此校验该 Token 是否属于本账号（防越权）。
  Future<bool> checkAgentStatus(String token, {String userId = ''}) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return false;
    try {
      final url = '$serverBaseUrl/api/agent/status'
          '?token=${Uri.encodeComponent(cleanToken)}'
          '&userId=${Uri.encodeComponent(userId.trim())}';
      final resp = await _dio.get(url);
      if (resp.statusCode == 200 && resp.data is Map) {
        return resp.data['online'] == true;
      }
    } catch (_) {}
    return false;
  }

  /// 下发桥接控制指令（start / stop / restart）给该账号的**电脑端** App 执行。
  ///
  /// 手机无法直接启动电脑上的脚本，因此指令先排到服务端，电脑端 App 在
  /// 会话轮询（≤4 秒）中取走并在本机执行。
  /// 服务端按账号级互斥：已有设备在切换状态时返回 409（[BridgeCommandResult.busy]）。
  Future<BridgeCommandResult> sendBridgeCommand({
    required String userId,
    required String command,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest') return BridgeCommandResult.failed;
    try {
      final resp = await _dio.post(
        '$serverBaseUrl/api/agent/bridge-command',
        data: {
          'userId': cleanUserId,
          'command': command,
          'device': AppSettings.currentDeviceType,
        },
      );
      final ok = resp.statusCode == 200 && (resp.data is Map) && resp.data['success'] == true;
      return ok ? BridgeCommandResult.ok : BridgeCommandResult.failed;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        debugPrint('[SyncService] 桥接状态切换中，服务端拒绝了本次指令');
        return BridgeCommandResult.busy;
      }
      debugPrint('[SyncService] sendBridgeCommand error: $e');
      return BridgeCommandResult.failed;
    } catch (e) {
      debugPrint('[SyncService] sendBridgeCommand error: $e');
      return BridgeCommandResult.failed;
    }
  }

  /// 电脑端**本地**启停前登记一次「切换中」，让手机端也同步置灰按钮。
  ///
  /// 本地启停不走指令队列，若不登记，手机在状态回传前仍能下发相反指令。
  /// 账号已有切换在进行时返回 [BridgeCommandResult.busy]，调用方应放弃本次操作。
  Future<BridgeCommandResult> beginBridgeTransition({
    required String userId,
    required String command,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest') return BridgeCommandResult.failed;
    try {
      final resp = await _dio.post(
        '$serverBaseUrl/api/agent/bridge-transition',
        data: {
          'userId': cleanUserId,
          'command': command,
          'device': AppSettings.currentDeviceType,
        },
      );
      final ok = resp.statusCode == 200 && (resp.data is Map) && resp.data['success'] == true;
      return ok ? BridgeCommandResult.ok : BridgeCommandResult.failed;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) return BridgeCommandResult.busy;
      debugPrint('[SyncService] beginBridgeTransition error: $e');
      return BridgeCommandResult.failed;
    } catch (e) {
      debugPrint('[SyncService] beginBridgeTransition error: $e');
      return BridgeCommandResult.failed;
    }
  }

  /// 撤销「状态切换中」标记（本地启停失败时用，避免两端按钮白等 20 秒兜底）。
  Future<void> cancelBridgeTransition({required String userId}) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest') return;
    try {
      await _dio.post(
        '$serverBaseUrl/api/agent/bridge-transition/cancel',
        data: {'userId': cleanUserId, 'device': AppSettings.currentDeviceType},
      );
    } catch (e) {
      debugPrint('[SyncService] cancelBridgeTransition error: $e');
    }
  }

  /// 立即把「权限预设 / 思考深度」下发到电脑端当前会话（不必等下一轮对话）。
  ///
  /// [kind] 为 'permission' 或 'model'。返回 (是否成功, 失败原因)。
  /// 电脑端插件版本过旧、桥接离线、预设名不合法等都会以失败原因返回，
  /// 不再"看着像生效其实没变"。
  Future<({bool ok, String message})> applyAgentSessionOption({
    required String token,
    required String userId,
    required String kind,
    required String sessionId,
    String permission = '',
    String reasoningEffort = '',
    String model = '',
    String harnessUrl = '',
  }) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return (ok: false, message: '缺少配对 Token');
    try {
      final resp = await _dio.post(
        '$serverBaseUrl/api/agent/session-option',
        data: {
          'token': cleanToken,
          'userId': userId.trim(),
          'kind': kind,
          'sessionId': sessionId.trim(),
          if (permission.isNotEmpty) 'permission': permission,
          if (reasoningEffort.isNotEmpty) 'reasoningEffort': reasoningEffort,
          if (model.isNotEmpty) 'model': model,
          if (harnessUrl.isNotEmpty) 'harnessUrl': harnessUrl,
        },
      );
      if (resp.statusCode == 200 && resp.data is Map && resp.data['success'] == true) {
        final raw = resp.data['message']?.toString() ?? '';
        // 关键：不能只看 HTTP 成功。插件历史上出现过"排了一条命令就回 applied:true"
        // 的假成功（宿主根本不把排队文本当命令），所以这里解析真实回执，
        // applied:false 一律按失败报给用户，并把"当前实际值"带出来。
        if (kind == 'permission' && raw.contains('"applied"')) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map && decoded['applied'] == false) {
              final current = decoded['current']?.toString() ?? '';
              return (
                ok: false,
                message: current.isEmpty
                    ? '电脑端没有应用这个权限预设（宿主回执 applied:false）'
                    : '电脑端没有应用：它当前实际是「$current」',
              );
            }
          } catch (_) {
            // 解析不了就当成功（老版本插件返回的是别的形状）
          }
        }
        return (ok: true, message: raw);
      }
      return (ok: false, message: resp.data is Map ? (resp.data['error']?.toString() ?? '切换失败') : '切换失败');
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = (data is Map ? data['error']?.toString() : null) ?? e.message ?? '网络异常';
      debugPrint('[SyncService] applyAgentSessionOption($kind) 失败: $msg');
      return (ok: false, message: msg);
    } catch (e) {
      debugPrint('[SyncService] applyAgentSessionOption($kind) 异常: $e');
      return (ok: false, message: '$e');
    }
  }

  /// 获取电脑端真实可用的权限预设列表（插件提供，取不到则返回空）。
  Future<List<Map<String, dynamic>>> fetchPermissionPresets({
    required String token,
    String userId = '',
  }) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return const [];
    try {
      final resp = await _dio.get(
        '$serverBaseUrl/api/agent/permission-presets'
        '?token=${Uri.encodeComponent(cleanToken)}'
        '&userId=${Uri.encodeComponent(userId.trim())}',
      );
      final presets = (resp.data is Map) ? resp.data['presets'] : null;
      if (presets is List) {
        return presets.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('[SyncService] fetchPermissionPresets error: $e');
    }
    return const [];
  }

  /// 回报一次本地操作的审批决定（allow / deny）。
  ///
  /// 宿主在本地执行敏感操作前会挂起等用户拍板；App 通过 SSE 收到请求，
  /// 用户点完按钮后走这里把决定送回去。
  Future<bool> approveAgentTask({
    required String token,
    required String approvalId,
    required String action,
    String taskId = '',
    String userId = '',
  }) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty || approvalId.isEmpty) return false;
    try {
      final resp = await _dio.post(
        '$serverBaseUrl/api/agent/approve',
        data: {
          'token': cleanToken,
          'approvalId': approvalId,
          'action': action,
          if (taskId.isNotEmpty) 'taskId': taskId,
          if (userId.isNotEmpty) 'userId': userId,
        },
      );
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('[SyncService] approveAgentTask error: $e');
      return false;
    }
  }

  /// 补拉挂起中的选择框（宿主的 ask_user_question）。
  ///
  /// 推送通道断线期间挂起的选择框不会丢：App 启动、重连、推送通道刚连上时
  /// 都调一次，把还没答的补出来（服务端按 questionId 存了一份，10 分钟过期）。
  Future<List<Map<String, dynamic>>> fetchPendingQuestions({
    String token = '',
    String userId = '',
    String clientSessionId = '',
  }) async {
    try {
      final resp = await _dio.get(
        '$serverBaseUrl/api/agent/pending-questions',
        queryParameters: {
          if (token.trim().isNotEmpty) 'token': token.trim(),
          if (userId.trim().isNotEmpty) 'userId': userId.trim(),
        },
        // 服务端已对这两个接口加身份校验（原先"参数为空就返回所有人的待办"）。
        // userId 既是查询条件也是身份声明，二者必须一致。
        options: _createOptions(userId: userId, clientSessionId: clientSessionId),
      );
      if (resp.statusCode == 200 && resp.data is Map) {
        final list = (resp.data as Map)['questions'];
        if (list is List) {
          return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        }
      }
    } catch (e) {
      debugPrint('[SyncService] fetchPendingQuestions error: $e');
    }
    return const [];
  }

  /// 补拉挂起中的审批（含文件沙箱越权升级这类不依赖任务的授权请求）。
  ///
  /// 与选择框同理：审批原先只在"手机发起那一轮的 SSE 流"里出现，断线、切后台、
  /// 或审批由电脑网页端/后台触发时就永远看不到。服务端按 approvalId 存了一份，
  /// App 启动、重连、回到前台都补拉一次。
  Future<List<Map<String, dynamic>>> fetchPendingApprovals({
    String token = '',
    String userId = '',
    String clientSessionId = '',
  }) async {
    try {
      final resp = await _dio.get(
        '$serverBaseUrl/api/agent/pending-approvals',
        queryParameters: {
          if (token.trim().isNotEmpty) 'token': token.trim(),
          if (userId.trim().isNotEmpty) 'userId': userId.trim(),
        },
        // 同 fetchPendingQuestions：服务端要身份校验，别漏了这两个头。
        options: _createOptions(userId: userId, clientSessionId: clientSessionId),
      );
      if (resp.statusCode == 200 && resp.data is Map) {
        final list = (resp.data as Map)['approvals'];
        if (list is List) {
          return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        }
      }
    } catch (e) {
      debugPrint('[SyncService] fetchPendingApprovals error: $e');
    }
    return const [];
  }

  /// 答复一个选择框；decline=true 表示「在电脑上回答」（交回电脑端网页弹窗）。
  Future<bool> answerAgentQuestion({
    required String token,
    required String questionId,
    List<Map<String, dynamic>> answers = const [],
    bool decline = false,
    String userId = '',
  }) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty || questionId.isEmpty) return false;
    try {
      final resp = await _dio.post(
        '$serverBaseUrl/api/agent/answer-question',
        data: {
          'token': cleanToken,
          'questionId': questionId,
          'answers': answers,
          'decline': decline,
          if (userId.isNotEmpty) 'userId': userId,
        },
      );
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('[SyncService] answerAgentQuestion error: $e');
      return false;
    }
  }

  /// 打断/停止服务端正在进行的这一轮生成。
  ///
  /// 插话发送与「停止生成」都调用它。以前 App 只断开自己的 SSE，服务端那一轮
  /// 照跑不误（本地宿主也继续执行），跑完的结果过一会儿又同步回来 ——
  /// 这就是"点了停止，答案还诈尸"的原因。
  Future<bool> cancelServerGeneration({
    required String userId,
    String assistantMessageId = '',
    String sessionId = '',
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest') return false;
    try {
      final resp = await _dio.post(
        '$serverBaseUrl/api/chat/cancel',
        data: {
          'userId': cleanUserId,
          if (assistantMessageId.isNotEmpty) 'assistantMessageId': assistantMessageId,
          if (sessionId.isNotEmpty) 'sessionId': sessionId,
        },
      );
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('[SyncService] cancelServerGeneration error: $e');
      return false;
    }
  }

  /// 换发 Agent 配对 Token（服务端为唯一真源）。
  ///
  /// "重新生成"必须调用它而不是本地随机：服务端会生成新 token、踢掉旧连接，
  /// 并广播给该用户所有设备，保证手机与电脑始终使用同一枚 token。
  /// 成功返回新 token，失败返回 null。
  Future<String?> rotateAgentToken({
    required String userId,
    String oldToken = '',
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest') return null;
    try {
      final resp = await _dio.post(
        '$serverBaseUrl/api/agent/rotate-token',
        data: {
          'userId': cleanUserId,
          'oldToken': oldToken.trim(),
          'device': AppSettings.currentDeviceType,
        },
      );
      if (resp.statusCode == 200 && resp.data is Map) {
        final token = resp.data['token']?.toString().trim();
        if (token != null && token.isNotEmpty) return token;
      }
    } catch (e) {
      debugPrint('[SyncService] rotateAgentToken error: $e');
    }
    return null;
  }

  /// 获取本地 Agent 的工作区列表及活动会话列表
  ///
  /// [userId] 为当前登录账号，服务端据此校验该 Token 是否属于本账号（防越权）。
  Future<Map<String, dynamic>> getAgentSessions(String token, {String userId = ''}) async {
    final cleanToken = token.trim();
    try {
      final url = '$serverBaseUrl/api/agent/sessions'
          '?token=${Uri.encodeComponent(cleanToken)}'
          '&userId=${Uri.encodeComponent(userId.trim())}';
      final resp = await _dio.get(url);
      if (resp.statusCode == 200 && resp.data is Map) {
        return {
          // ok=这次请求本身成功了（区别于"服务端明确说电脑端不在线"）。
          // 以前把任何异常都压成 online:false，于是一次网络抖动就会让界面
          // 显示"桥接不在线"，还弹出误导性的"请确认电脑端桥接在线"。
          'ok': true,
          'online': resp.data['online'] == true,
          'error': resp.data['error']?.toString() ?? '',
          // 不再用假值兜底：服务端返回空即代表未取到真实工作区
          'workspaces': List<String>.from(resp.data['workspaces'] ?? const []),
          'sessions': resp.data['sessions'] as List? ?? [],
          'models': resp.data['models'] as List? ?? [],
          'clientName': resp.data['clientName']?.toString() ?? 'LxAI-Bridge-Local',
        };
      }
      return {
        'ok': false,
        'online': false,
        'error': '中继返回 HTTP ${resp.statusCode}',
        'workspaces': <String>[],
        'sessions': <dynamic>[],
        'models': <dynamic>[],
        'clientName': 'LxAI-Bridge-Local',
      };
    } catch (e) {
      debugPrint('[SyncService] getAgentSessions error: $e');
    }
    return {
      'ok': false,
      'online': false,
      'error': '没连上中继（网络/服务器暂时不可达）',
      // 取不到就返回空：界面显示空白框，绝不编一个 'deepseek-agent' 出来
      'workspaces': <String>[],
      'sessions': <dynamic>[],
      'models': <dynamic>[],
      'clientName': 'LxAI-Bridge-Local',
    };
  }

  /// 请求电脑端在本地宿主中新建一个会话，成功返回新会话 id。
  ///
  /// 服务端经中继把 create_session 转发给桥接脚本，桥接再调用本地宿主创建；
  /// 失败（电脑端离线、宿主不可达）返回 null —— 调用方据此保留原选择并提示，
  /// 而不是伪造一个本地 id 发出去（那正是"发消息必然失败"的根源之一）。
  Future<String?> createAgentSession({
    required String token,
    String userId = '',
    String workspace = '',
    String title = '',
    String model = '',
  }) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return null;
    try {
      final resp = await _dio.post(
        '$serverBaseUrl/api/agent/create-session',
        data: {
          'token': cleanToken,
          'userId': userId.trim(),
          'workspace': workspace.trim(),
          'title': title.trim(),
          if (model.trim().isNotEmpty) 'model': model.trim(),
        },
      );
      if (resp.statusCode == 200 && resp.data is Map) {
        final data = Map<String, dynamic>.from(resp.data as Map);
        if (data['success'] == false) {
          debugPrint('[SyncService] createAgentSession 被服务端拒绝: ${data['error']}');
          return null;
        }
        if (data['online'] == false) {
          debugPrint('[SyncService] createAgentSession：电脑端桥接不在线');
          return null;
        }
        final sid = data['sessionId']?.toString().trim();
        if (sid != null && sid.isNotEmpty && !sid.startsWith('session_')) {
          return sid;
        }
        // 服务端在桥接离线时会回退造一个 session_xxx 假 id，这里拒绝它
        debugPrint('[SyncService] createAgentSession：服务端未返回真实会话 id（$sid）');
        return null;
      }
    } catch (e) {
      debugPrint('[SyncService] createAgentSession error: $e');
    }
    return null;
  }

  /// 手机 App 扫码后确认绑定/授权电脑端临时 SessionCode
  Future<Map<String, dynamic>> confirmBridgeAuthSession({
    required String sessionCode,
    required String token,
    String? account,
  }) async {
    final cleanCode = sessionCode.trim().toUpperCase();
    final cleanToken = token.trim();
    if (cleanCode.isEmpty || cleanToken.isEmpty) {
      return {'success': false, 'message': '临时配对码或 Token 为空'};
    }
    try {
      final url = '$serverBaseUrl/api/bridge/auth-confirm';
      final resp = await _dio.post(
        url,
        data: {
          'sessionCode': cleanCode,
          'token': cleanToken,
          'account': account ?? 'guest',
        },
      );
      if (resp.statusCode == 200 && resp.data is Map) {
        return {
          'success': resp.data['success'] == true,
          'message': resp.data['message']?.toString() ?? '授权成功',
        };
      }
      return {
        'success': false,
        'message': resp.data?['error']?.toString() ?? '授权失败',
      };
    } catch (e) {
      debugPrint('[SyncService] confirmBridgeAuthSession error: $e');
      return {
        'success': false,
        'message': '网络或服务器异常: $e',
      };
    }
  }

  /// 经由服务器中继管道直接流式监听 Agent 执行状态与最终模型回复 (SSE 管道)
  Stream<Map<String, dynamic>> streamServerAgentChat({
    required String userId,
    required String assistantMessageId,
    required List<ChatMessage> messages,
    required Map<String, dynamic> settings,
    List<Map<String, dynamic>>? images,
    CancelToken? cancelToken,
  }) async* {
    final cleanUserId = userId.trim().isEmpty ? 'guest' : userId.trim();
    final url = '$serverBaseUrl/api/chat/stream';

    Response<ResponseBody> response;
    try {
      // 【图片诊断】③出网：图片跨 App→中继→桥接→插件四段，任何一段丢了都表现为
      // "模型没看到图"。这一行确认 App 确实把 images 放进了 HTTP body ——
      // 它是 0 就说明问题在 App 侧（对照 ① ② 的日志能定位到具体哪一步）。
      debugPrint('[图片诊断] ③出网：images=${images?.length ?? 0} 张，'
          'base64 总长=${images == null ? 0 : images.fold<int>(0, (sum, e) => sum + ((e['data'] as String?)?.length ?? 0))}');
      response = await _dio.post<ResponseBody>(
        url,
        data: {
          'userId': cleanUserId,
          'assistantMessageId': assistantMessageId,
          'messages': messages.map((m) => m.toMap()).toList(),
          'settings': settings,
          // 图片（Agent 模式附件）：中继原样下发给桥接，再由 DSH 插件的 attachments
          // 服务换成宿主的持久引用（ImageBlock）。
          // ⚠️ data 必须是**规范 base64** —— 宿主逐字节校验（重新编码不一致就报
          // INVALID_IMAGE_BASE64），所以这一路只做搬运，不许中途重新编码。
          // 只有真带了图才加这个字段：中继与桥接都按"有 images 才处理"写的。
          if (images != null && images.isNotEmpty) 'images': images,
        },
        options: Options(
          responseType: ResponseType.stream,
          // SSE 是长连接：一轮 Agent 任务里，本地宿主可能要跑几分钟、中途还可能
          // 等用户拍板（审批卡片 / 选择框）；「动手前先问大脑」又会再加一次本地
          // 推理。期间只要服务端没发事件，就会被按 receiveTimeout 掐断
          // （历史上手机报过 15 秒、10 秒超时）。这里放宽到 20 分钟。
          // ⚠️ 服务端那一侧仍有 AGENT_TASK_TIMEOUT_MS（默认 30 分钟）兜底。
          receiveTimeout: const Duration(minutes: 20),
          headers: {
            'Accept': 'text/event-stream',
          },
        ),
        cancelToken: cancelToken,
      );
    } catch (e) {
      yield {
        'error': '无法连接到调度服务器: $e',
        'done': true,
      };
      return;
    }

    String buffer = '';

    // 必须让 Utf8Decoder 跨包累积解码，不能对每个 chunk 单独 utf8.decode：
    // SSE 是网络分包到达的，而中文一个字 3 字节 —— 包边界经常落在多字节字符中间，
    // 单独解码会抛 FormatException，异常从 await for 里冒出来直接打断整条流
    // （表现为 App 每次发消息都显示"连接中断，正在向电脑端取回结果"，然后靠兜底
    // 对账把内容补回来）。transform(utf8.decoder) 由解码器自己留住半个字符，
    // allowMalformed 再兜住真正的非法字节，两者缺一不可。
    await for (final text in response.data!.stream.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true))) {
      buffer += text;

      while (buffer.contains('\n\n')) {
        final eventEnd = buffer.indexOf('\n\n');
        final rawBlock = buffer.substring(0, eventEnd);
        buffer = buffer.substring(eventEnd + 2);

        final lines = rawBlock.split('\n');
        String eventName = 'message';
        String dataStr = '';

        for (final line in lines) {
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            dataStr = line.substring(5).trim();
          }
        }

        if (dataStr.isNotEmpty) {
          try {
            final parsed = jsonDecode(dataStr);
            if (eventName == 'chunk') {
              yield {
                'content': parsed['content'] ?? '',
                'reasoning': parsed['reasoning'] ?? '',
                'fullContent': parsed['fullContent'],
                'fullReasoning': parsed['fullReasoning'],
                // 润色阶段的内容属于「回答气泡」（另一个消息框），不是在写过程消息
                'answerMessageId': parsed['answerMessageId'],
                'done': false,
              };
            } else if (eventName == 'step') {
              yield {
                'step': parsed['step'] ?? '',
                // detail = 完整工具参数或工具输出原文（折叠展示）
                // kind = thinking/action/result/note；tool = 工具名；
                // status = success/error；callId = 调用与结果的精确配对
                'detail': parsed['detail'] ?? '',
                'kind': parsed['kind'] ?? '',
                'tool': parsed['tool'] ?? '',
                'status': parsed['status'] ?? '',
                'callId': parsed['callId'] ?? '',
                'done': false,
              };
            } else if (eventName == 'agent_started') {
              yield {
                'agent_started': true,
                'initialStep': parsed['initialStep'] ?? '',
                'done': false,
              };
            } else if (eventName == 'agent_finished') {
              yield {
                'agent_finished': true,
                'result': parsed['result'],
                'done': false,
              };
            } else if (eventName == 'phase') {
              yield {
                'phase': parsed['phase'] ?? '',
                // 进入润色阶段时服务端就告诉客户端"回答气泡"的消息 id
                'answerMessageId': parsed['answerMessageId'],
                'done': false,
              };
            } else if (eventName == 'approval') {
              // 宿主在本地执行时请求用户拍板（越权操作确认）。以前这条通知只走
              // socket.io，而 App 没有 socket.io 客户端 —— 所以只有宿主自己弹窗。
              yield {
                'approval': parsed['approval'],
                'taskId': parsed['taskId'],
                'done': false,
              };
            } else if (eventName == 'question') {
              // 宿主的 ask_user_question 挂起了：走插件 → 桥接 → 中继这条链路推上来。
              // 和审批一样，不能只依赖推送通道（SSE 在流就顺手带一份）。
              yield {
                'question': parsed['questions'],
                'questionId': parsed['questionId'],
                'done': false,
              };
            } else if (eventName == 'done') {
              yield {
                'content': '',
                'reasoning': '',
                'fullContent': parsed['fullContent'],
                'fullReasoning': parsed['fullReasoning'],
                'agentExecution': parsed['agentExecution'],
                'answerMessageId': parsed['answerMessageId'],
                'answerContent': parsed['answerContent'],
                'interrupted': parsed['interrupted'] == true,
                'done': true,
              };
            } else if (eventName == 'error') {
              yield {
                'error': parsed['error'] ?? '生成中断',
                'done': true,
              };
            }
          } catch (_) {}
        }
      }
    }
  }

  /// 从服务端拉取最新维护的模型上下文上限配置表
  Future<Map<String, int>> fetchModelLimits() async {
    try {
      final url = '$serverBaseUrl/api/model-limits';
      final response = await _dio.get(url);
      if (response.statusCode == 200 && response.data is Map) {
        final rawLimits = response.data['limits'];
        if (rawLimits is Map) {
          final Map<String, int> result = {};
          rawLimits.forEach((k, v) {
            if (v is num) {
              result[k.toString()] = v.toInt();
            }
          });
          return result;
        }
      }
    } catch (e) {
      debugPrint('[SyncService] fetchModelLimits failed (using offline fallback): $e');
    }
    return {};
  }
}
