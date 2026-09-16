import 'dart:async';
import 'dart:io' show InternetAddress, SocketException;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../services/api_service.dart';
import '../services/asr_service.dart';
import '../services/storage_service.dart';
import '../services/sync_service.dart';
import '../services/tts_service.dart';
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

  Timer? _periodicSyncTimer;

  ChatProvider(this.settingsProvider) {
    _storage.cleanOrphanData().then((_) => loadSessions());
    _startPeriodicSync();
  }

  void _startPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_isGenerating) {
        _silentSyncFromServer();
      }
    });
  }

  @override
  void dispose() {
    _periodicSyncTimer?.cancel();
    super.dispose();
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
    // 启动或从存储重新载入时：检查当前选中会话是否依然有效且存在于列表中
    final currentId = _currentSession?.id;
    if (currentId != null && _sessions.any((s) => s.id == currentId)) {
      // 仍然存在，更新引用并拉取最新消息
      _currentSession = _sessions.firstWhere((s) => s.id == currentId);
      _messages = _storage.getMessagesForSession(currentId);
      notifyListeners();
    } else if (_sessions.isNotEmpty) {
      // 当前选中的会话已不在列表中或尚未初始化，自动选中第一个有效会话
      selectSession(_sessions.first);
    } else {
      // 列表为空，自动创建全新干净会话
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
        // 如果当前选中的会话依然存在于会话列表中且在本地数据库中有效
        if (currentSessionId != null && _sessions.any((s) => s.id == currentSessionId) && _storage.hasSession(currentSessionId)) {
          _currentSession = _sessions.firstWhere((s) => s.id == currentSessionId);
          _messages = _storage.getMessagesForSession(currentSessionId);
        } else if (_sessions.isNotEmpty) {
          // 当前选中的会话已不在列表中（可能在其他端被删除或被离线队列清除），自动切至第一个会话
          _currentSession = _sessions.first;
          _messages = _storage.getMessagesForSession(_sessions.first.id);
        } else {
          // 若全部被清空，自动新建一个干净对话
          final newSession = ChatSession(
            id: const Uuid().v4(),
            title: '新对话 ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
            model: settingsProvider.activeModelDisplayName,
            isSynced: false,
          );
          _storage.saveSession(newSession);
          _sessions = [newSession];
          _currentSession = newSession;
          _messages = [];
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
    final target = _sessions.where((s) => s.id == sessionId).firstOrNull;
    final wasSynced = target?.isSynced ?? true;

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

    // 只有曾经成功同步过云端的会话才需要向云端发起删除通知或存入重发队列
    if (wasSynced) {
      SyncService.instance.deleteSession(
        userId: settingsProvider.syncUserId,
        sessionId: sessionId,
        clientSessionId: settingsProvider.clientSessionId,
      );
    }
  }

  void deleteSessions(List<String> sessionIds) {
    if (sessionIds.isEmpty) return;
    for (final id in sessionIds) {
      final target = _sessions.where((s) => s.id == id).firstOrNull;
      final wasSynced = target?.isSynced ?? true;

      _storage.deleteSession(id);
      if (wasSynced) {
        SyncService.instance.deleteSession(
          userId: settingsProvider.syncUserId,
          sessionId: id,
          clientSessionId: settingsProvider.clientSessionId,
        );
      }
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

    // 语音消息智能识别：若无文字输入且包含语音条附件，静默调用 ASR 服务转写为文字喂给大模型
    String resolvedText = cleanText;
    final audioAtt = attachments?.firstWhere(
      (att) => att.startsWith('data:audio/'),
      orElse: () => '',
    );
    if (resolvedText.isEmpty && audioAtt != null && audioAtt.isNotEmpty) {
      try {
        final transcribed = await AsrService.instance.transcribeAudio(
          base64AudioData: audioAtt,
          settings: settingsProvider.settings,
        );
        if (transcribed != null && transcribed.trim().isNotEmpty) {
          resolvedText = transcribed.trim();
        }
      } catch (e) {
        debugPrint('ASR 自动转写异常: $e');
      }
    }

    // 分离图片附件与其他类型，支持图片+文字消息分两个消息框发送（先发图片，再发文字）
    final hasAttachments = attachments != null && attachments.isNotEmpty;
    final hasText = resolvedText.isNotEmpty;
    final List<ChatMessage> userMsgsToSend = [];

    if (hasAttachments && hasText && !attachments.any((att) => att.startsWith('data:audio/'))) {
      // 纯图片/通用文件拆分：第1个气泡发送附件，第2个气泡发送纯文字
      final mediaMsg = ChatMessage(
        id: const Uuid().v4(),
        sessionId: _currentSession!.id,
        role: MessageRole.user,
        content: '',
        attachments: List<String>.from(attachments),
        status: online ? 'completed' : 'error',
      );
      final textMsg = ChatMessage(
        id: const Uuid().v4(),
        sessionId: _currentSession!.id,
        role: MessageRole.user,
        content: resolvedText,
        attachments: null,
        status: online ? 'completed' : 'error',
      );
      userMsgsToSend.add(mediaMsg);
      userMsgsToSend.add(textMsg);
    } else {
      // 语音消息（保留语音气泡条并挂载识别文本供大模型理解）或单条纯文本消息
      final userMsg = ChatMessage(
        id: const Uuid().v4(),
        sessionId: _currentSession!.id,
        role: MessageRole.user,
        content: resolvedText,
        attachments: attachments,
        status: online ? 'completed' : 'error',
      );
      userMsgsToSend.add(userMsg);
    }

    if (!online) {
      // 无网络：将消息标记为 error 状态，落盘并上屏，不推送到后端，不触发大模型请求
      for (final msg in userMsgsToSend) {
        _messages.add(msg);
        await _storage.saveMessage(msg);
      }

      if (_messages.isNotEmpty && _currentSession!.title == '新对话') {
        final titleText = cleanText.isNotEmpty
            ? cleanText
            : (resolvedText.isNotEmpty ? resolvedText : ((audioAtt != null && audioAtt.isNotEmpty) ? '语音消息' : '图片/文件消息'));
        _currentSession!.title = titleText.length > 20 ? '${titleText.substring(0, 20)}...' : titleText;
        await _storage.saveSession(_currentSession!);
      }
      notifyListeners();
      return;
    }

    for (final msg in userMsgsToSend) {
      _messages.add(msg);
      await _storage.saveMessage(msg);
    }

    // 静默实时推送到服务器
    SyncService.instance.pushMessages(
      userId: settingsProvider.syncUserId,
      messages: userMsgsToSend,
      clientSessionId: settingsProvider.clientSessionId,
    );

    // 自动更新会话标题（若为第一轮消息）
    if (_currentSession!.title == '新对话') {
      final titleText = cleanText.isNotEmpty
          ? cleanText
          : (resolvedText.isNotEmpty ? resolvedText : ((audioAtt != null && audioAtt.isNotEmpty) ? '语音消息' : '图片/文件消息'));
      _currentSession!.title = titleText.length > 20 ? '${titleText.substring(0, 20)}...' : titleText;
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
      'sessionSummary': _currentSession?.summary,
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

              // 若开启了自动朗读，自动朗读本次回复内容
              if (settingsProvider.settings.autoSpeakResponse && assistantMsg.content.trim().isNotEmpty) {
                TtsService.instance.speak(assistantMsg.content.trim(), settingsProvider.settings);
              }
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
        // --- 非 Agent 模式：直连模型接口流式输出（结合固定前缀与历史增量摘要） ---
        final stream = _apiService.streamChatCompletion(
          history: _messages.where((m) => !m.isStreaming).toList(),
          settings: settingsProvider.settings,
          sessionSummary: _currentSession?.summary,
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

              // 若开启了自动朗读，自动朗读本次回复内容
              if (settingsProvider.settings.autoSpeakResponse && assistantMsg.content.trim().isNotEmpty) {
                TtsService.instance.speak(assistantMsg.content.trim(), settingsProvider.settings);
              }

              // 异步后台检测是否触发上下文滑动截断与自动摘要生成
              _checkAndTriggerBackgroundSummary();
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
              final lastUserMsg = userMsgsToSend.isNotEmpty ? userMsgsToSend.last : null;
              if (lastUserMsg != null) {
                lastUserMsg.status = 'error';
                _storage.saveMessage(lastUserMsg);
              }
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
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        return;
      }
      final lastUserMsg = userMsgsToSend.isNotEmpty ? userMsgsToSend.last : null;
      if (lastUserMsg != null) {
        lastUserMsg.status = 'error';
        await _storage.saveMessage(lastUserMsg);
      }
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

  /// 重新生成指定的最新助理回复消息
  Future<bool> regenerateLatestAssistantMessage(String assistantMsgId) async {
    if (_isGenerating) {
      stopGeneration();
    }

    final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
    if (idx == -1) return false;
    final targetMsg = _messages[idx];
    if (targetMsg.role != MessageRole.assistant) return false;

    // 🛡️ Agent 模式双重防护：避免重复调用本地 Agent 执行具有副作用的真实任务
    if (targetMsg.isAgentMode || settingsProvider.settings.defaultAgentMode) {
      return false;
    }

    // 1. 从列表、本地存储与云端彻底清除该条 AI 消息
    deleteMessage(assistantMsgId);

    if (_messages.isEmpty || _currentSession == null) return false;

    // 2. 检查网络
    final online = await isNetworkOnline();
    if (!online) {
      return false;
    }

    // 3. 构建新的流式助理消息
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
      'sessionSummary': _currentSession?.summary,
    };

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

              if (settingsProvider.settings.autoSpeakResponse && assistantMsg.content.trim().isNotEmpty) {
                TtsService.instance.speak(assistantMsg.content.trim(), settingsProvider.settings);
              }
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
        final stream = _apiService.streamChatCompletion(
          history: _messages.where((m) => !m.isStreaming).toList(),
          settings: settingsProvider.settings,
          sessionSummary: _currentSession?.summary,
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

              if (settingsProvider.settings.autoSpeakResponse && assistantMsg.content.trim().isNotEmpty) {
                TtsService.instance.speak(assistantMsg.content.trim(), settingsProvider.settings);
              }

              _checkAndTriggerBackgroundSummary();
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
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        return false;
      }
      assistantMsg.isStreaming = false;
      assistantMsg.content += '\n\n*(重新生成异常: $e)*';
      await _storage.saveMessage(assistantMsg);
      _isGenerating = false;
      _cancelToken = null;
      notifyListeners();
      return false;
    }
    return true;
  }

  /// 异步后台检测是否触发上下文滑动截断与自动摘要生成（稳固 KV 缓存前缀）
  Future<void> _checkAndTriggerBackgroundSummary() async {
    final session = _currentSession;
    if (session == null || _messages.isEmpty) return;

    final activeEp = settingsProvider.activeEndpoint;
    final maxContext = activeEp?.contextLength ?? 30000;

    // 计算当前所有消息的大致字符长度
    int totalLen = settingsProvider.settings.systemPrompt.length;
    for (final m in _messages) {
      totalLen += m.content.length + 10;
    }

    // 当会话历史总长度超过上下文容量的 80% 或已产生滑动溢出时，触发增量摘要
    if (totalLen > (maxContext * 0.8) && _messages.length > 8) {
      // 提取前半部分消息进行增量浓缩（保留最近 6 条完整上下文）
      final cutoffIndex = _messages.length - 6;
      if (cutoffIndex > session.lastSummarizedIndex) {
        final messagesToSummarize = _messages.sublist(session.lastSummarizedIndex, cutoffIndex);
        if (messagesToSummarize.isNotEmpty) {
          final newSummary = await _apiService.generateConversationSummary(
            oldMessages: messagesToSummarize,
            settings: settingsProvider.settings,
            previousSummary: session.summary,
          );

          if (newSummary != null && newSummary.isNotEmpty) {
            session.summary = newSummary;
            session.lastSummarizedIndex = cutoffIndex;
            session.updatedAt = DateTime.now();
            await _storage.saveSession(session);
            SyncService.instance.pushSessions(
              userId: settingsProvider.syncUserId,
              sessions: [session],
              clientSessionId: settingsProvider.clientSessionId,
            );
          }
        }
      }
    }
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
