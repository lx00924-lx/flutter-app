import 'dart:async';
import 'dart:io' show InternetAddress, SocketException;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/sync_service.dart';
import 'settings_provider.dart';

class ChatProvider extends ChangeNotifier {
  final SettingsProvider settingsProvider;
  final ApiService _apiService = ApiService();
  final StorageService _storage = StorageService.instance;

  List<ChatSession> _sessions = [];
  ChatSession? _currentSession;
  List<ChatMessage> _messages = [];
  ChatMessage? _quotedMessage;
  bool _isGenerating = false;
  StreamSubscription? _streamSub;
  CancelToken? _cancelToken;

  ChatProvider(this.settingsProvider) {
    loadSessions();
  }

  Future<bool> isNetworkOnline() async {
    if (kIsWeb) return true;
    try {
      final ep = settingsProvider.activeEndpoint?.endpoint;
      if (ep != null && ep.isNotEmpty) {
        final uri = Uri.tryParse(ep);
        if (uri != null && uri.host.isNotEmpty) {
          if (uri.host == 'localhost' || uri.host == '127.0.0.1') return true;
          try {
            final res = await InternetAddress.lookup(uri.host).timeout(const Duration(milliseconds: 1200));
            if (res.isNotEmpty) return true;
          } catch (_) {}
        }
      }
      final res = await InternetAddress.lookup('dns.alidns.com').timeout(const Duration(milliseconds: 1200));
      return res.isNotEmpty;
    } catch (_) {
      try {
        final res2 = await InternetAddress.lookup('223.5.5.5').timeout(const Duration(milliseconds: 1000));
        return res2.isNotEmpty;
      } catch (_) {
        return false;
      }
    }
  }

  List<ChatSession> get sessions => _sessions;
  ChatSession? get currentSession => _currentSession;
  List<ChatMessage> get messages => _messages;
  ChatMessage? get quotedMessage => _quotedMessage;
  bool get isGenerating => _isGenerating;

  void setQuotedMessage(ChatMessage? msg) {
    _quotedMessage = msg;
    notifyListeners();
  }

  void clearQuotedMessage() {
    _quotedMessage = null;
    notifyListeners();
  }

  void deleteMessage(String messageId) {
    _storage.deleteMessage(messageId);
    _messages.removeWhere((m) => m.id == messageId);
    if (_quotedMessage?.id == messageId) {
      _quotedMessage = null;
    }
    notifyListeners();
    SyncService.instance.deleteMessage(
      userId: settingsProvider.syncUserId,
      messageId: messageId,
      clientSessionId: settingsProvider.clientSessionId,
    );
  }

  void reloadFromStorage() {
    loadSessions();
  }

  void loadSessions() {
    _sessions = _storage.getAllSessions();
    if (_sessions.isNotEmpty) {
      selectSession(_sessions.first);
    } else {
      createNewSession();
    }
  }

  void _silentSyncFromServer() {
    final currentSessionId = _currentSession?.id;
    SyncService.instance.pullAndMergeMessages(
      userId: settingsProvider.syncUserId,
      clientSessionId: settingsProvider.clientSessionId,
      onNewMessagesImported: () {
        _sessions = _storage.getAllSessions();
        if (currentSessionId != null && _storage.hasSession(currentSessionId)) {
          _messages = _storage.getMessagesForSession(currentSessionId);
        } else if (_sessions.isNotEmpty) {
          _currentSession = _sessions.first;
          _messages = _storage.getMessagesForSession(_sessions.first.id);
        }
        notifyListeners();
      },
    );
  }

  void createNewSession({String? title}) {
    final newSession = ChatSession(
      id: const Uuid().v4(),
      title: title ?? '新对话 ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
      model: settingsProvider.activeModelDisplayName,
    );
    _storage.saveSession(newSession);
    _sessions.insert(0, newSession);
    _currentSession = newSession;
    _messages = [];
    notifyListeners();
    _silentSyncFromServer();
  }

  void selectSession(ChatSession session) {
    _currentSession = session;
    _messages = _storage.getMessagesForSession(session.id);
    notifyListeners();
    _silentSyncFromServer();
  }

  void renameSession(String sessionId, String newTitle) {
    final cleanTitle = newTitle.trim();
    if (cleanTitle.isEmpty) return;

    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      _sessions[idx].title = cleanTitle;
      _sessions[idx].updatedAt = DateTime.now();
      _storage.saveSession(_sessions[idx]);
      if (_currentSession?.id == sessionId) {
        _currentSession!.title = cleanTitle;
        _currentSession!.updatedAt = _sessions[idx].updatedAt;
      }
      notifyListeners();
      SyncService.instance.pushSessions(
        userId: settingsProvider.syncUserId,
        sessions: [_sessions[idx]],
        clientSessionId: settingsProvider.clientSessionId,
      );
    }
  }

  void deleteSession(String sessionId) {
    _storage.deleteSession(sessionId);
    _sessions.removeWhere((s) => s.id == sessionId);
    if (_currentSession?.id == sessionId) {
      if (_sessions.isNotEmpty) {
        selectSession(_sessions.first);
      } else {
        createNewSession();
      }
    } else {
      notifyListeners();
    }
    SyncService.instance.deleteSession(
      userId: settingsProvider.syncUserId,
      sessionId: sessionId,
      clientSessionId: settingsProvider.clientSessionId,
    );
  }

  void deleteSessions(List<String> sessionIds) {
    if (sessionIds.isEmpty) return;
    for (final id in sessionIds) {
      _storage.deleteSession(id);
      SyncService.instance.deleteSession(
        userId: settingsProvider.syncUserId,
        sessionId: id,
        clientSessionId: settingsProvider.clientSessionId,
      );
    }
    _sessions.removeWhere((s) => sessionIds.contains(s.id));
    if (_currentSession != null && sessionIds.contains(_currentSession!.id)) {
      if (_sessions.isNotEmpty) {
        selectSession(_sessions.first);
      } else {
        createNewSession();
      }
    } else {
      notifyListeners();
    }
  }

  int getMessageCount(String sessionId) {
    return _storage.getMessageCountForSession(sessionId);
  }

  Future<void> sendMessage(String text, {List<String>? attachments}) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty && (attachments == null || attachments.isEmpty)) return;
    if (_currentSession == null) createNewSession();

    // 如果大模型正在思考/回复，立即取消上一轮未完成的生成
    if (_isGenerating) {
      stopGeneration();
    }

    final online = await isNetworkOnline();
    if (!online) {
      // 无网络：将消息标记为 error 状态，落盘并上屏，不推送到后端，不触发大模型请求
      final userMsg = ChatMessage(
        id: const Uuid().v4(),
        sessionId: _currentSession!.id,
        role: MessageRole.user,
        content: cleanText,
        attachments: attachments,
        status: 'error',
      );

      _messages.add(userMsg);
      await _storage.saveMessage(userMsg);

      if (_messages.length == 1) {
        _currentSession!.title = cleanText.length > 20 ? '${cleanText.substring(0, 20)}...' : cleanText;
        await _storage.saveSession(_currentSession!);
      }
      notifyListeners();
      return;
    }

    final userMsg = ChatMessage(
      id: const Uuid().v4(),
      sessionId: _currentSession!.id,
      role: MessageRole.user,
      content: cleanText,
      attachments: attachments,
      status: 'completed',
    );

    _messages.add(userMsg);
    await _storage.saveMessage(userMsg);
    // 静默实时推送到服务器
    SyncService.instance.pushMessages(
      userId: settingsProvider.syncUserId,
      messages: [userMsg],
      clientSessionId: settingsProvider.clientSessionId,
    );

    // 自动更新会话标题（若为第一条消息）
    if (_messages.length == 1) {
      _currentSession!.title = cleanText.length > 20 ? '${cleanText.substring(0, 20)}...' : cleanText;
      await _storage.saveSession(_currentSession!);
    }

    final isAgentMode = settingsProvider.settings.defaultAgentMode;
    final assistantMsg = ChatMessage(
      id: const Uuid().v4(),
      sessionId: _currentSession!.id,
      role: MessageRole.assistant,
      content: '',
      reasoningContent: isAgentMode ? '> 🤖 正在连接本地 DeepSeek Harness 智能体调度管道...\n' : '',
      isStreaming: true,
      isAgentMode: isAgentMode,
    );

    _messages.add(assistantMsg);
    _isGenerating = true;
    notifyListeners();

    final activeEp = settingsProvider.activeEndpoint;
    final agentSettings = {
      'apiEndpoint': activeEp?.endpoint ?? '',
      'apiKey': activeEp?.apiKey ?? '',
      'modelName': activeEp?.modelName ?? '',
      'systemInstruction': settingsProvider.settings.systemPrompt,
      'contextLength': activeEp?.contextLength ?? 30000,
      'agentMode': isAgentMode,
      'agentToken': settingsProvider.settings.harnessToken,
      'agentHarnessUrl': settingsProvider.settings.harnessServiceUrl,
      'agentWorkspace': settingsProvider.settings.targetWorkspace,
      'agentSessionId': settingsProvider.settings.targetSessionId,
      'agentReasoningEffort': settingsProvider.settings.agentReasoningEffort,
      'agentPermission': settingsProvider.settings.agentPermission,
      'agentModel': settingsProvider.settings.agentModel,
    };

    // 无论用户在生成过程中是否强杀 App，服务器均已收到托管生成任务，持续生成并落盘，下次启动自动同步
    if (!isAgentMode) {
      SyncService.instance.requestServerBackgroundGeneration(
        userId: settingsProvider.syncUserId,
        assistantMessageId: assistantMsg.id,
        messages: _messages.where((m) => !m.isStreaming).toList(),
        clientSessionId: settingsProvider.clientSessionId,
        settings: agentSettings,
      );
    }

    final startTime = DateTime.now();
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    try {
      if (isAgentMode) {
        // --- 走服务端中继调度 Agent 管道，确保本地 Harness 执行结果无缝回传并与 LLM 整合 ---
        final stream = SyncService.instance.streamServerAgentChat(
          userId: settingsProvider.syncUserId,
          assistantMessageId: assistantMsg.id,
          messages: _messages.where((m) => !m.isStreaming).toList(),
          settings: agentSettings,
          cancelToken: cancelToken,
        );

        _streamSub = stream.listen(
          (chunk) {
            if (chunk['error'] != null) {
              assistantMsg.isStreaming = false;
              assistantMsg.content += '\n\n*(智能体执行异常: ${chunk['error']})*';
              _storage.saveMessage(assistantMsg);
              _isGenerating = false;
              _cancelToken = null;
              notifyListeners();
              return;
            }

            if (chunk['agent_started'] == true) {
              final step = chunk['initialStep']?.toString() ?? '任务已派发至本地 Harness';
              assistantMsg.reasoningContent = '> 🤖 $step\n';
              notifyListeners();
              return;
            }

            if (chunk['step'] != null) {
              final stepText = chunk['step'].toString();
              assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + '> ⚙️ $stepText\n';
              notifyListeners();
              return;
            }

            if (chunk['agent_finished'] == true) {
              assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + '\n> ✅ 本地智能体执行完毕，正在整理分析结果...\n\n';
              notifyListeners();
              return;
            }

            if (chunk['done'] == true) {
              assistantMsg.isStreaming = false;
              assistantMsg.elapsedSeconds = DateTime.now().difference(startTime).inSeconds;
              if (chunk['fullContent'] != null && chunk['fullContent'].toString().isNotEmpty) {
                assistantMsg.content = chunk['fullContent'].toString();
              }
              if (chunk['fullReasoning'] != null && chunk['fullReasoning'].toString().isNotEmpty) {
                assistantMsg.reasoningContent = chunk['fullReasoning'].toString();
              }
              if (chunk['agentExecution'] is Map) {
                assistantMsg.agentExecution = AgentExecutionRecord.fromMap(chunk['agentExecution'] as Map<dynamic, dynamic>);
              }
              _storage.saveMessage(assistantMsg);
              SyncService.instance.pushMessages(
                userId: settingsProvider.syncUserId,
                messages: [assistantMsg],
                clientSessionId: settingsProvider.clientSessionId,
              );
              _isGenerating = false;
              _cancelToken = null;
              notifyListeners();
              return;
            }

            final contentDelta = chunk['content'] as String? ?? '';
            final reasoningDelta = chunk['reasoning'] as String? ?? '';

            if (reasoningDelta.isNotEmpty) {
              assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + reasoningDelta;
            }
            if (contentDelta.isNotEmpty) {
              assistantMsg.content += contentDelta;
            }
            notifyListeners();
          },
          onError: (err) {
            if (err is DioException && CancelToken.isCancel(err)) {
              return;
            }
            assistantMsg.isStreaming = false;
            assistantMsg.content += '\n\n*(连接中断或 Agent 离线，请检查电脑端桥接脚本)*';
            _storage.saveMessage(assistantMsg);
            _isGenerating = false;
            _cancelToken = null;
            notifyListeners();
          },
          onDone: () {
            if (assistantMsg.isStreaming) {
              assistantMsg.isStreaming = false;
              assistantMsg.elapsedSeconds = DateTime.now().difference(startTime).inSeconds;
              _storage.saveMessage(assistantMsg);
              _isGenerating = false;
              _cancelToken = null;
              notifyListeners();
            }
          },
        );
      } else {
        // --- 非 Agent 模式：直连模型接口流式输出 ---
        final stream = _apiService.streamChatCompletion(
          history: _messages.where((m) => !m.isStreaming).toList(),
          settings: settingsProvider.settings,
          cancelToken: cancelToken,
        );

        _streamSub = stream.listen(
          (chunk) {
            if (chunk['done'] == true) {
              assistantMsg.isStreaming = false;
              assistantMsg.elapsedSeconds = DateTime.now().difference(startTime).inSeconds;
              _storage.saveMessage(assistantMsg);
              SyncService.instance.pushMessages(
                userId: settingsProvider.syncUserId,
                messages: [assistantMsg],
                clientSessionId: settingsProvider.clientSessionId,
              );
              _isGenerating = false;
              _cancelToken = null;
              notifyListeners();
              return;
            }

            final contentDelta = chunk['content'] as String? ?? '';
            final reasoningDelta = chunk['reasoning'] as String? ?? '';

            if (reasoningDelta.isNotEmpty) {
              assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + reasoningDelta;
            }
            if (contentDelta.isNotEmpty) {
              assistantMsg.content += contentDelta;
            }
            notifyListeners();
          },
          onError: (err) {
            if (err is DioException && CancelToken.isCancel(err)) {
              return;
            }
            final isConnErr = err is SocketException ||
                (err is DioException && (err.type == DioExceptionType.connectionError || err.type == DioExceptionType.connectionTimeout));
            if (isConnErr && assistantMsg.content.isEmpty && (assistantMsg.reasoningContent?.isEmpty ?? true)) {
              userMsg.status = 'error';
              _storage.saveMessage(userMsg);
              _messages.remove(assistantMsg);
              _storage.deleteMessage(assistantMsg.id);
              _isGenerating = false;
              _cancelToken = null;
              notifyListeners();
              return;
            }
            assistantMsg.isStreaming = false;
            assistantMsg.content += '\n\n*(请求异常，请检查 API Key 或网络设置)*';
            _storage.saveMessage(assistantMsg);
            _isGenerating = false;
            _cancelToken = null;
            notifyListeners();
          },
          onDone: () {
            if (assistantMsg.isStreaming) {
              assistantMsg.isStreaming = false;
              assistantMsg.elapsedSeconds = DateTime.now().difference(startTime).inSeconds;
              _storage.saveMessage(assistantMsg);
              SyncService.instance.pushMessages(
                userId: settingsProvider.syncUserId,
                messages: [assistantMsg],
                clientSessionId: settingsProvider.clientSessionId,
              );
            }
            _isGenerating = false;
            _cancelToken = null;
            notifyListeners();
          },
        );
      }
          _isGenerating = false;
          _cancelToken = null;
          notifyListeners();
        },
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        return;
      }
      userMsg.status = 'error';
      await _storage.saveMessage(userMsg);
      _messages.remove(assistantMsg);
      await _storage.deleteMessage(assistantMsg.id);
      _isGenerating = false;
      _cancelToken = null;
      notifyListeners();
    }
  }

  Future<bool> resendMessage(String messageId) async {
    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return false;
    final userMsg = _messages[idx];
    if (userMsg.role != MessageRole.user) return false;

    final online = await isNetworkOnline();
    if (!online) {
      // 依然无网络，保持 error 状态
      return false;
    }

    if (_isGenerating) {
      stopGeneration();
    }

    // 网络已连通，更新状态并重新推送给后端
    userMsg.status = 'completed';
    await _storage.saveMessage(userMsg);

    // 1. 推送到后端
    SyncService.instance.pushMessages(
      userId: settingsProvider.syncUserId,
      messages: [userMsg],
      clientSessionId: settingsProvider.clientSessionId,
    );

    // 2. 创建助理消息
    final assistantMsg = ChatMessage(
      id: const Uuid().v4(),
      sessionId: _currentSession!.id,
      role: MessageRole.assistant,
      content: '',
      reasoningContent: '',
      isStreaming: true,
    );
    _messages.add(assistantMsg);
    _isGenerating = true;
    notifyListeners();

    final activeEp = settingsProvider.activeEndpoint;
    SyncService.instance.requestServerBackgroundGeneration(
      userId: settingsProvider.syncUserId,
      assistantMessageId: assistantMsg.id,
      messages: _messages.where((m) => !m.isStreaming).toList(),
      clientSessionId: settingsProvider.clientSessionId,
      settings: {
        'apiEndpoint': activeEp?.endpoint ?? '',
        'apiKey': activeEp?.apiKey ?? '',
        'modelName': activeEp?.modelName ?? '',
        'systemInstruction': settingsProvider.settings.systemPrompt,
        'contextLength': activeEp?.contextLength ?? 30000,
        'agentMode': settingsProvider.settings.defaultAgentMode,
        'agentToken': settingsProvider.settings.harnessToken,
        'agentHarnessUrl': settingsProvider.settings.harnessServiceUrl,
        'agentWorkspace': settingsProvider.settings.targetWorkspace,
        'agentSessionId': settingsProvider.settings.targetSessionId,
      },
    );

    final startTime = DateTime.now();
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    try {
      final stream = _apiService.streamChatCompletion(
        history: _messages.where((m) => !m.isStreaming).toList(),
        settings: settingsProvider.settings,
        cancelToken: cancelToken,
      );

      _streamSub = stream.listen(
        (chunk) {
          if (chunk['done'] == true) {
            assistantMsg.isStreaming = false;
            assistantMsg.elapsedSeconds = DateTime.now().difference(startTime).inSeconds;
            _storage.saveMessage(assistantMsg);
            SyncService.instance.pushMessages(
              userId: settingsProvider.syncUserId,
              messages: [assistantMsg],
              clientSessionId: settingsProvider.clientSessionId,
            );
            _isGenerating = false;
            _cancelToken = null;
            notifyListeners();
            return;
          }

          final contentDelta = chunk['content'] as String? ?? '';
          final reasoningDelta = chunk['reasoning'] as String? ?? '';

          if (reasoningDelta.isNotEmpty) {
            assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + reasoningDelta;
          }
          if (contentDelta.isNotEmpty) {
            assistantMsg.content += contentDelta;
          }
          notifyListeners();
        },
        onError: (err) {
          if (err is DioException && CancelToken.isCancel(err)) {
            return;
          }
          final isConnErr = err is SocketException ||
              (err is DioException && (err.type == DioExceptionType.connectionError || err.type == DioExceptionType.connectionTimeout));
          if (isConnErr && assistantMsg.content.isEmpty && (assistantMsg.reasoningContent?.isEmpty ?? true)) {
            userMsg.status = 'error';
            _storage.saveMessage(userMsg);
            _messages.remove(assistantMsg);
            _storage.deleteMessage(assistantMsg.id);
            _isGenerating = false;
            _cancelToken = null;
            notifyListeners();
            return;
          }
          assistantMsg.isStreaming = false;
          assistantMsg.content += '\n\n*(请求异常，请检查 API Key 或网络设置)*';
          _storage.saveMessage(assistantMsg);
          _isGenerating = false;
          _cancelToken = null;
          notifyListeners();
        },
        onDone: () {
          if (assistantMsg.isStreaming) {
            assistantMsg.isStreaming = false;
            assistantMsg.elapsedSeconds = DateTime.now().difference(startTime).inSeconds;
            _storage.saveMessage(assistantMsg);
            SyncService.instance.pushMessages(
              userId: settingsProvider.syncUserId,
              messages: [assistantMsg],
              clientSessionId: settingsProvider.clientSessionId,
            );
          }
          _isGenerating = false;
          _cancelToken = null;
          notifyListeners();
        },
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        return false;
      }
      userMsg.status = 'error';
      await _storage.saveMessage(userMsg);
      _messages.remove(assistantMsg);
      await _storage.deleteMessage(assistantMsg.id);
      _isGenerating = false;
      _cancelToken = null;
      notifyListeners();
      return false;
    }
    return true;
  }

  void stopGeneration() {
    _cancelToken?.cancel('Generation stopped by user');
    _cancelToken = null;
    _streamSub?.cancel();
    _streamSub = null;
    _isGenerating = false;
    if (_messages.isNotEmpty && _messages.last.isStreaming) {
      _messages.last.isStreaming = false;
      // 若刚生成气泡尚未吐出任何字且无推理内容，清理空占位
      if (_messages.last.content.isEmpty && (_messages.last.reasoningContent?.isEmpty ?? true)) {
        final emptyId = _messages.last.id;
        _messages.removeLast();
        _storage.deleteMessage(emptyId);
      } else {
        _storage.saveMessage(_messages.last);
        SyncService.instance.pushMessages(
          userId: settingsProvider.syncUserId,
          messages: [_messages.last],
        );
      }
    }
    notifyListeners();
  }
}
