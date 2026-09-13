import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import 'storage_service.dart';

/// 后台静默实时同步服务：实现 Flutter 客户端与服务端的自动增量同步及多端互斥下线监控
class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
    ),
  );

  bool _isSyncing = false;
  Timer? _sessionWatcherTimer;
  void Function(String reason)? onForceLogout;

  /// 获取服务器基地址（Web 端自适应 origin，App 原生端连接生产服务端）
  String get serverBaseUrl {
    if (kIsWeb) {
      final uri = Uri.base;
      if (uri.host.isNotEmpty) {
        final portPart = uri.hasPort && uri.port != 80 && uri.port != 443 ? ':${uri.port}' : '';
        return '${uri.scheme}://${uri.host}$portPart';
      }
    }
    return 'https://www.lx00924ai.top';
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
  }) {
    stopSessionWatcher();
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty || cleanUserId == 'guest' || cleanUserId == 'default_user') {
      return;
    }

    onForceLogout = onKicked;

    // 立即执行一次健康核验
    _checkSessionOnce(cleanUserId, clientSessionId, deviceType);

    // 每 4 秒轮询一次当前设备会话状态
    _sessionWatcherTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _checkSessionOnce(cleanUserId, clientSessionId, deviceType);
    });
  }

  /// 停止多端登录监控
  void stopSessionWatcher() {
    _sessionWatcherTimer?.cancel();
    _sessionWatcherTimer = null;
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
              final msg = ChatMessage.fromMap(item);
              if (msg.id.isNotEmpty &&
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
  Future<bool> checkAgentStatus(String token) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return false;
    try {
      final url = '$serverBaseUrl/api/agent/status?token=${Uri.encodeComponent(cleanToken)}';
      final resp = await _dio.get(url);
      if (resp.statusCode == 200 && resp.data is Map) {
        return resp.data['online'] == true;
      }
    } catch (_) {}
    return false;
  }

  /// 获取本地 Agent 的工作区列表及活动会话列表
  Future<Map<String, dynamic>> getAgentSessions(String token) async {
    final cleanToken = token.trim();
    try {
      final url = '$serverBaseUrl/api/agent/sessions?token=${Uri.encodeComponent(cleanToken)}';
      final resp = await _dio.get(url);
      if (resp.statusCode == 200 && resp.data is Map) {
        return {
          'online': resp.data['online'] == true,
          'workspaces': List<String>.from(resp.data['workspaces'] ?? ['deepseek-agent']),
          'sessions': resp.data['sessions'] as List? ?? [],
          'clientName': resp.data['clientName']?.toString() ?? 'DeepSeek-Harness-Local',
        };
      }
    } catch (e) {
      debugPrint('[SyncService] getAgentSessions error: $e');
    }
    return {
      'online': false,
      'workspaces': ['deepseek-agent'],
      'sessions': [],
      'clientName': 'DeepSeek-Harness-Local',
    };
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
            } else if (eventName == 'done') {
              yield {
                'content': '',
                'reasoning': '',
                'fullContent': parsed['fullContent'],
                'fullReasoning': parsed['fullReasoning'],
                'agentExecution': parsed['agentExecution'],
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
