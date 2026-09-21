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
      connectTimeout: const Duration(seconds: 10),
      // 15 秒太短：Agent 任务要等本地 DSH 跑完（服务端上限 300 秒），
      // 请求发出后十几秒没有任何事件就会被 Dio 判成 receive timeout，
      // 手机上表现为"发消息必失败：The request took longer than 0:00:15"。
      // 这里放宽到 2 分钟，SSE 长连接另外单独设更长的超时。
      receiveTimeout: const Duration(minutes: 2),
      sendTimeout: const Duration(seconds: 15),
    ),
  );

  bool _isSyncing = false;
  Timer? _sessionWatcherTimer;
  void Function(String reason)? onForceLogout;
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
    try {
      _pushChannel = kIsWeb
          ? WebSocketChannel.connect(uri)
          : IOWebSocketChannel.connect(uri, pingInterval: const Duration(seconds: 30));
    } catch (e) {
      debugPrint('[SyncService] 推送通道连接失败: $e');
      _schedulePushReconnect();
      return;
    }

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
    if (error is DioException && error.response?.statusCode == 401) {
      final data = error.response?.data;
      if (data is Map && data['error'] == 'FORCE_LOGOUT') {
        final reason = data['reason']?.toString() ?? '您的账号已在另一台设备上登录，当前设备已被下线。';
        stopSessionWatcher();
        onForceLogout?.call(reason);
      }
    }
  }

  /// 启动多端单点登录心跳监听（1手机 + 1电脑互斥）
  void startSessionWatcher({
    required String userId,
    required String clientSessionId,
    required String deviceType,
    required void Function(String reason) onKicked,
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
          onForceLogout?.call(reason);
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

  /// 客户端向服务端发起注册
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
    bool sessionListChanged = false;

    try {
      // 0. 先将离线期间积压的会话删除指令补发给云端
      await flushPendingDeletions(userId: cleanUserId, clientSessionId: clientSessionId);

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
              if (msg.id.isNotEmpty &&
                  msg.sessionId.trim().isNotEmpty &&
                  !pendingDeleteIds.contains(msg.sessionId) &&
                  !storage.hasMessage(msg.id)) {
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

        if ((importedCount > 0 || sessionListChanged) && onNewMessagesImported != null) {
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

  /// 实时静默推送单条或多条消息至服务器
  Future<void> pushMessages({
    required String userId,
    required List<ChatMessage> messages,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || messages.isEmpty) return;

    final validMessages = messages
        .where((m) => !m.isStreaming && (m.content.isNotEmpty || (m.attachments != null && m.attachments!.isNotEmpty)))
        .map((m) => m.toMap())
        .toList();

    if (validMessages.isEmpty) return;

    try {
      final url = '$serverBaseUrl/api/sync-messages';
      await _dio.post(
        url,
        data: {
          'userId': cleanUserId,
          'messages': validMessages,
        },
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );

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
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Push messages silent error: $e');
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

  /// 实时静默删除云端单条消息
  Future<void> deleteMessage({
    required String userId,
    required String messageId,
    String? clientSessionId,
  }) async {
    final cleanUserId = userId.trim();
    final cleanMessageId = messageId.trim();
    if (cleanUserId.isEmpty || cleanMessageId.isEmpty) return;

    try {
      final url = '$serverBaseUrl/api/delete-message';
      await _dio.post(
        url,
        data: {
          'userId': cleanUserId,
          'messageId': cleanMessageId,
        },
        options: _createOptions(userId: cleanUserId, clientSessionId: clientSessionId),
      );
    } catch (e) {
      _checkAndTriggerForceLogout(e);
      debugPrint('[SyncService] Delete message silent error: $e');
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
        return (ok: true, message: resp.data['message']?.toString() ?? '');
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
  /// DSH 在本地执行敏感操作前会挂起等用户拍板；App 通过 SSE 收到请求，
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

  /// 补拉挂起中的选择框（DSH 的 ask_user_question）。
  ///
  /// 推送通道断线期间挂起的选择框不会丢：App 启动、重连、推送通道刚连上时
  /// 都调一次，把还没答的补出来（服务端按 questionId 存了一份，10 分钟过期）。
  Future<List<Map<String, dynamic>>> fetchPendingQuestions({
    String token = '',
    String userId = '',
  }) async {
    try {
      final resp = await _dio.get(
        '$serverBaseUrl/api/agent/pending-questions',
        queryParameters: {
          if (token.trim().isNotEmpty) 'token': token.trim(),
          if (userId.trim().isNotEmpty) 'userId': userId.trim(),
        },
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
  /// 照跑不误（本地 DSH 也继续执行），跑完的结果过一会儿又同步回来 ——
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
          'online': resp.data['online'] == true,
          // 不再用假值兜底：服务端返回空即代表未取到真实工作区
          'workspaces': List<String>.from(resp.data['workspaces'] ?? const []),
          'sessions': resp.data['sessions'] as List? ?? [],
          'models': resp.data['models'] as List? ?? [],
          'clientName': resp.data['clientName']?.toString() ?? 'DeepSeek-Harness-Local',
        };
      }
    } catch (e) {
      debugPrint('[SyncService] getAgentSessions error: $e');
    }
    return {
      'online': false,
      // 取不到就返回空：界面显示空白框，绝不编一个 'deepseek-agent' 出来
      'workspaces': <String>[],
      'sessions': <dynamic>[],
      'models': <dynamic>[],
      'clientName': 'DeepSeek-Harness-Local',
    };
  }

  /// 请求电脑端在本地 DSH 中新建一个会话，成功返回新会话 id。
  ///
  /// 服务端经中继把 create_session 转发给桥接脚本，桥接再调用本地 DSH 创建；
  /// 失败（电脑端离线、DSH 不可达）返回 null —— 调用方据此保留原选择并提示，
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
    CancelToken? cancelToken,
  }) async* {
    final cleanUserId = userId.trim().isEmpty ? 'guest' : userId.trim();
    final url = '$serverBaseUrl/api/chat/stream';

    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        url,
        data: {
          'userId': cleanUserId,
          'assistantMessageId': assistantMessageId,
          'messages': messages.map((m) => m.toMap()).toList(),
          'settings': settings,
        },
        options: Options(
          responseType: ResponseType.stream,
          // SSE 是长连接：Agent 任务可能要跑几分钟，期间只要服务端没发事件，
          // 就会按 receiveTimeout 掐断（这正是手机上报的 15 秒超时）。这里
          // 单独放宽到 10 分钟，与服务端 300 秒任务上限匹配并留出余量。
          receiveTimeout: const Duration(minutes: 10),
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

    await for (final chunk in response.data!.stream) {
      final text = utf8.decode(chunk);
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
                'done': false,
              };
            } else if (eventName == 'step') {
              yield {
                'step': parsed['step'] ?? '',
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
                'done': false,
              };
            } else if (eventName == 'approval') {
              // DSH 在本地执行时请求用户拍板（越权操作确认）。以前这条通知只走
              // socket.io，而 App 没有 socket.io 客户端 —— 所以只有 DSH 自己弹窗。
              yield {
                'approval': parsed['approval'],
                'taskId': parsed['taskId'],
                'done': false,
              };
            } else if (eventName == 'question') {
              // DSH 的 ask_user_question 挂起了：走插件 → 桥接 → 中继这条链路推上来。
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
