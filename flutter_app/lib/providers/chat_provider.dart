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

/// 一轮对话当前处在哪个阶段。
///
/// Agent 模式下这一轮分两段：先在电脑上执行（DSH），再把结果交给思考 API 润色。
/// 两段的"插话代价"完全不同 —— 执行阶段插话会丢掉正在跑的任务，润色阶段插话
/// 只是掐断一段便宜的文本生成，所以界面要按阶段决定"插话"能不能点。
enum TurnPhase { idle, executing, polishing }

/// 排队待发的消息。
class QueuedMessage {
  final String id;
  final String text;
  final List<String> attachments;
  final DateTime createdAt;

  const QueuedMessage({
    required this.id,
    required this.text,
    this.attachments = const [],
    required this.createdAt,
  });
}

class ChatProvider extends ChangeNotifier {
  final SettingsProvider settingsProvider;
  final ApiService _apiService = ApiService();
  final StorageService _storage = StorageService.instance;

  List<ChatSession> _sessions = [];
  ChatSession? _currentSession;
  List<ChatMessage> _messages = [];
  ChatMessage? _quotedMessage;
  bool _generating = false;
  /// 生成状态。
  ///
  /// 刻意用 setter 包一层：全文件有二十多处 `_isGenerating = false;`（各种
  /// 成功/失败/取消分支），每一处都手动重置阶段并推进排队队列太容易漏。
  /// 收口到这里，任何一条结束路径都会自动「阶段归 idle + 发下一条排队消息」。
  bool get _isGenerating => _generating;
  set _isGenerating(bool value) {
    final was = _generating;
    _generating = value;
    if (was && !value) {
      _turnPhase = TurnPhase.idle;
      scheduleMicrotask(_dispatchNextQueued);
    } else if (!was && value) {
      _turnPhase = TurnPhase.polishing;
    }
  }
  StreamSubscription? _streamSub;
  CancelToken? _cancelToken;

  /// 当前轮次所处阶段（用于插话判定与界面提示）
  TurnPhase _turnPhase = TurnPhase.idle;

  /// 轮次编号：每开一轮 +1；SSE 事件按编号认领，过期事件一律丢弃
  int _turnSeq = 0;

  /// 正在等待用户拍板的审批请求（DSH 执行敏感操作前）
  Map<String, dynamic>? _pendingApproval;
  Map<String, dynamic>? get pendingApproval => _pendingApproval;

  /// 排队中等待自动发送的消息
  final List<QueuedMessage> _queue = [];

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

  /// 当前轮次阶段
  TurnPhase get turnPhase => _turnPhase;

  /// 是否正在电脑上执行（DSH）。此时插话会打断正在跑的本地任务。
  bool get isAgentExecuting => _turnPhase == TurnPhase.executing;

  /// 现在插话是否安全：非执行阶段都可以（纯 API 对话、或已经在润色）。
  bool get canInterject => !_isGenerating || _turnPhase != TurnPhase.executing;

  /// 排队中的消息
  List<QueuedMessage> get queuedMessages => List.unmodifiable(_queue);
  int get queuedCount => _queue.length;

  /// 加入排队：当前这轮结束后自动发出
  void enqueueMessage(String text, {List<String>? attachments}) {
    final t = text.trim();
    final atts = attachments ?? const <String>[];
    if (t.isEmpty && atts.isEmpty) return;
    _queue.add(QueuedMessage(
      id: const Uuid().v4(),
      text: t,
      attachments: atts,
      createdAt: DateTime.now(),
    ));
    notifyListeners();
  }

  /// 撤回一条排队消息
  void withdrawQueued(String id) {
    _queue.removeWhere((q) => q.id == id);
    notifyListeners();
  }

  /// 清空排队
  void clearQueue() {
    _queue.clear();
    notifyListeners();
  }

  /// 一轮结束后自动发出下一条排队消息
  void _dispatchNextQueued() {
    if (_queue.isEmpty || _isGenerating) return;
    final next = _queue.removeAt(0);
    notifyListeners();
    // 稍等一下，让上一轮的气泡状态先落定，避免两条消息挤在一起
    Future.delayed(const Duration(milliseconds: 400), () {
      if (_isGenerating) {
        // 期间又开始了新一轮：放回队首，等下次
        _queue.insert(0, next);
        notifyListeners();
        return;
      }
      sendMessage(next.text, attachments: next.attachments.isEmpty ? null : next.attachments);
    });
  }

  /// 插话发送：打断当前轮次并立刻把这条发出去。
  ///
  /// 设计取舍（按实测调整）：
  /// · 只断开本地 SSE 是不够的 —— 服务端那次生成、电脑上正在跑的 DSH 任务都还在
  ///   继续，结果过一会儿又同步回来，所以先调 `/api/chat/cancel` 真打断；
  /// · 打断后的半截气泡**只留在本地、不推云端**：另一端拉到一半的内容再被服务端
  ///   的收尾版本覆盖，就会出现"这端有内容、那端是空气泡"。**完整消息才同步**；
  /// · 立刻开新一轮，旧轮的迟到事件由轮次编号拦掉，不会把新轮状态改坏。
  Future<void> interjectMessage(String text, {List<String>? attachments}) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty && (attachments == null || attachments.isEmpty)) return;

    if (!_isGenerating) {
      await sendMessage(text, attachments: attachments);
      return;
    }

    final streaming = (_messages.isNotEmpty && _messages.last.isStreaming) ? _messages.last : null;

    try {
      // 1) 通知服务端真正中止（含本地 DSH 任务）
      await SyncService.instance.cancelServerGeneration(
        userId: settingsProvider.syncUserId,
        assistantMessageId: streaming?.id ?? '',
        sessionId: _currentSession?.id ?? '',
      );
    } catch (e) {
      debugPrint('[ChatProvider] 插话时取消上一轮失败（继续发送）: $e');
    }

    // 2) 本地收尾：保留已生成的部分、就地标注被打断；不推云端
    _streamSub?.cancel();
    _streamSub = null;
    _cancelToken?.cancel('interrupted by user');
    _cancelToken = null;
    _isGenerating = false;

    if (streaming != null) {
      final hasContent = streaming.content.trim().isNotEmpty ||
          (streaming.reasoningContent?.trim().isNotEmpty ?? false);
      if (!hasContent) {
        _messages.remove(streaming);
        _storage.deleteMessage(streaming.id);
      } else {
        streaming.isStreaming = false;
        streaming.content = '${streaming.content.trimRight()}\n\n*（已被新消息打断）*';
        _storage.saveMessage(streaming);
        // 刻意不 pushMessages：半截内容同步到另一端只会造成状态打架
      }
    }
    notifyListeners();

    // 3) 立刻开新一轮（新气泡）
    await sendMessage(text, attachments: attachments);
  }

  /// 回报一次本地操作的审批决定（allow / deny）。
  Future<bool> resolveApproval(String action) async {
    final pending = _pendingApproval;
    if (pending == null) return false;
    final approvalId = pending['approvalId']?.toString() ?? '';
    if (approvalId.isEmpty) {
      _pendingApproval = null;
      notifyListeners();
      return false;
    }
    final ok = await SyncService.instance.approveAgentTask(
      token: settingsProvider.settings.harnessToken,
      approvalId: approvalId,
      action: action,
      taskId: pending['taskId']?.toString() ?? '',
      userId: settingsProvider.syncUserId,
    );
    if (ok) {
      _pendingApproval = null;
      notifyListeners();
    }
    return ok;
  }

  /// 本地直接清掉审批卡片（例如任务已结束）
  void dismissApproval() {
    if (_pendingApproval == null) return;
    _pendingApproval = null;
    notifyListeners();
  }

  // 说明：一轮结束时「阶段归 idle + 推进排队队列」统一收口在 _isGenerating 的
  // setter 里（见上方），全文件二十多处结束分支都不用各自处理。

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
    // Agent 模式先跑本地执行阶段；普通模式直接就是生成/润色阶段
    _turnPhase = isAgentMode ? TurnPhase.executing : TurnPhase.polishing;
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
    // 本轮编号：插话会立刻开新一轮，而旧一轮的 SSE 事件可能姗姗来迟
    // （done/error/chunk 都可能），必须让它们认领自己那一轮，否则会把新一轮的
    // 生成状态、气泡内容改坏 —— 表现为"插话后没有新消息、按钮卡在停止态"。
    final myTurn = ++_turnSeq;

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
            // 过期轮次的事件直接丢弃（插话后旧流可能还会吐 done/error）
            if (myTurn != _turnSeq) return;
            if (chunk['error'] != null) {
              assistantMsg.isStreaming = false;
              assistantMsg.content += '\n\n*(智能体执行异常: ${chunk['error']})*';
              _storage.saveMessage(assistantMsg);
              _isGenerating = false;
              _cancelToken = null;
              notifyListeners();
              return;
            }

            // DSH 请求用户拍板：在输入框上方弹出审批卡片
            if (chunk['approval'] is Map) {
              _pendingApproval = {
                ...Map<String, dynamic>.from(chunk['approval'] as Map),
                if (chunk['taskId'] != null) 'taskId': chunk['taskId'],
                'messageId': assistantMsg.id,
              };
              notifyListeners();
              return;
            }

            if (chunk['agent_started'] == true) {
              final step = chunk['initialStep']?.toString() ?? '任务已派发至本地 Harness';
              assistantMsg.reasoningContent = '> 🤖 $step\n';
              _turnPhase = TurnPhase.executing;
              notifyListeners();
              return;
            }

            if (chunk['step'] != null) {
              final stepText = chunk['step'].toString();
              assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + '> ⚙️ $stepText\n';
              if (_turnPhase != TurnPhase.executing) _turnPhase = TurnPhase.executing;
              notifyListeners();
              return;
            }

            // 服务端在本地执行结束、转入思考 API 润色时下发；此后插话只是掐断一段
            // 便宜的文本生成，不会丢本地已经跑完的活
            if (chunk['phase'] != null) {
              _turnPhase = chunk['phase'].toString() == 'polishing'
                  ? TurnPhase.polishing
                  : TurnPhase.executing;
              notifyListeners();
              return;
            }

            if (chunk['agent_finished'] == true) {
              assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + '\n> ✅ 本地智能体执行完毕，正在整理分析结果...\n\n';
              _turnPhase = TurnPhase.polishing;
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
    // 本轮编号：插话会立刻开新一轮，而旧一轮的 SSE 事件可能姗姗来迟
    // （done/error/chunk 都可能），必须让它们认领自己那一轮，否则会把新一轮的
    // 生成状态、气泡内容改坏 —— 表现为"插话后没有新消息、按钮卡在停止态"。
    final myTurn = ++_turnSeq;

    try {
      final stream = _apiService.streamChatCompletion(
        history: _messages.where((m) => !m.isStreaming).toList(),
        settings: settingsProvider.settings,
        cancelToken: cancelToken,
      );

      _streamSub = stream.listen(
        (chunk) {
          // 过期轮次的事件直接丢弃（插话后旧流可能还会吐 done/error）
          if (myTurn != _turnSeq) return;
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
    // Agent 模式先跑本地执行阶段；普通模式直接就是生成/润色阶段
    _turnPhase = isAgentMode ? TurnPhase.executing : TurnPhase.polishing;
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
    // 本轮编号：插话会立刻开新一轮，而旧一轮的 SSE 事件可能姗姗来迟
    // （done/error/chunk 都可能），必须让它们认领自己那一轮，否则会把新一轮的
    // 生成状态、气泡内容改坏 —— 表现为"插话后没有新消息、按钮卡在停止态"。
    final myTurn = ++_turnSeq;

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
            // 过期轮次的事件直接丢弃（插话后旧流可能还会吐 done/error）
            if (myTurn != _turnSeq) return;
            if (chunk['error'] != null) {
              assistantMsg.isStreaming = false;
              assistantMsg.content += '\n\n*(智能体执行异常: ${chunk['error']})*';
              _storage.saveMessage(assistantMsg);
              _isGenerating = false;
              _cancelToken = null;
              notifyListeners();
              return;
            }

            // DSH 请求用户拍板：在输入框上方弹出审批卡片
            if (chunk['approval'] is Map) {
              _pendingApproval = {
                ...Map<String, dynamic>.from(chunk['approval'] as Map),
                if (chunk['taskId'] != null) 'taskId': chunk['taskId'],
                'messageId': assistantMsg.id,
              };
              notifyListeners();
              return;
            }

            if (chunk['agent_started'] == true) {
              final step = chunk['initialStep']?.toString() ?? '任务已派发至本地 Harness';
              assistantMsg.reasoningContent = '> 🤖 $step\n';
              _turnPhase = TurnPhase.executing;
              notifyListeners();
              return;
            }

            if (chunk['step'] != null) {
              final stepText = chunk['step'].toString();
              assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + '> ⚙️ $stepText\n';
              if (_turnPhase != TurnPhase.executing) _turnPhase = TurnPhase.executing;
              notifyListeners();
              return;
            }

            // 服务端在本地执行结束、转入思考 API 润色时下发；此后插话只是掐断一段
            // 便宜的文本生成，不会丢本地已经跑完的活
            if (chunk['phase'] != null) {
              _turnPhase = chunk['phase'].toString() == 'polishing'
                  ? TurnPhase.polishing
                  : TurnPhase.executing;
              notifyListeners();
              return;
            }

            if (chunk['agent_finished'] == true) {
              assistantMsg.reasoningContent = (assistantMsg.reasoningContent ?? '') + '\n> ✅ 本地智能体执行完毕，正在整理分析结果...\n\n';
              _turnPhase = TurnPhase.polishing;
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
    // 通知服务端真正中止这一轮（含正在电脑上跑的 DSH 任务）。
    // 以前只断开本地 SSE：服务端那次生成照跑，本地 DSH 也继续执行，
    // 结果过一会儿又同步回来 —— 表现为"点了停止，答案还诈尸"。
    final streamingId = (_messages.isNotEmpty && _messages.last.isStreaming) ? _messages.last.id : '';
    if (streamingId.isNotEmpty || (_currentSession?.id.isNotEmpty ?? false)) {
      unawaited(SyncService.instance.cancelServerGeneration(
        userId: settingsProvider.syncUserId,
        assistantMessageId: streamingId,
        sessionId: _currentSession?.id ?? '',
      ));
    }
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
