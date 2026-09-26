import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_recorder_service.dart';
import '../services/sync_service.dart';
import '../utils/image_picker_helper.dart';
import '../screens/voice_call_screen.dart';
import '../screens/scanner_screen.dart';
import 'agent_quick_bar.dart';
import 'slash_command_menu.dart';

class ChatInputBar extends StatefulWidget {
  final Function(String text, {List<String>? attachments}) onSend;
  final VoidCallback onStop;
  final bool isGenerating;
  /// 生成中发送时，用户选择「插话发送」后的回调
  final Function(String text, {List<String>? attachments})? onInterject;
  /// 生成中发送时，用户选择「排队发送」后的回调
  final Function(String text, {List<String>? attachments})? onEnqueue;

  const ChatInputBar({
    super.key,
    required this.onSend,
    required this.onStop,
    required this.isGenerating,
    this.onInterject,
    this.onEnqueue,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode;
  bool _hasText = false;
  bool _isMenuOpen = false;

  // 附件列表 (支持图片、通用文件、音频)
  final List<String> _pendingAttachments = [];
  final List<String> _pendingFileDisplayNames = [];

  // 录音状态管理
  bool _isRecording = false;
  bool _isLongPress = false;
  bool _isSlideCancelling = false;
  double _longPressStartY = 0.0;
  int _recordDurationSeconds = 0;
  Timer? _recordTimer;

  // 点击录音停止后的暂存待发送音频
  String? _recordedPendingAudioUri;
  int _recordedPendingAudioSec = 0;

  // ==================== 选择框卡片：分页 + 收起 ====================
  //
  // 电脑端 Agent 可以一次问好几件事（宿主的 user-questions 是数组）。一屏全摊开
  // 会把输入框顶没，所以多题时**一次只显示一题**，用「上一题 / 下一题」翻页，
  // 全部答完再点「提交答案」；不想看时可以把整张卡片收成一行。

  /// 当前显示第几题（0 基）
  int _questionStep = 0;

  /// 是否收起整张提问卡（收起后只剩标题一行）
  bool _questionCollapsed = false;

  /// 当前挂起问题的 questionId：换了一道新问题就把题号与收起状态复位
  String _questionNavId = '';

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        // 仅电脑桌面端（Windows / macOS / Linux）支持键盘快捷回车发送，手机端保持原生软键盘换行
        final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
        if (!isDesktop) return KeyEventResult.ignored;

        final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter;
        if (!isEnter) return KeyEventResult.ignored;

        final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
        final sp = context.read<SettingsProvider>();
        final sendOnEnter = sp.settings.sendOnEnter;

        if (sendOnEnter) {
          // 开启状态：Enter 直接发送消息，Shift + Enter 另起一行
          if (!isShiftPressed) {
            _handleSend();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        } else {
          // 关闭状态：Enter 另起一行，Shift + Enter 发送消息
          if (isShiftPressed) {
            _handleSend();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
      },
    );

    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) {
        setState(() {
          _hasText = has;
          if (_hasText && _isMenuOpen) {
            _isMenuOpen = false;
          }
        });
      }
      // 输入以 `/` 开头时，浮出命令面板（Telegram 那种）
      _syncSlashMenu();
    });

    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _isMenuOpen) {
        setState(() => _isMenuOpen = false);
      }
    });
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ==================== 斜杠命令面板 ====================

  /// 面板是否可见
  bool _slashMenuVisible = false;
  /// `/` 之后已输入的内容（用于过滤命令）
  String _slashQuery = '';
  /// 命令名之后已输入的参数（用于过滤参数候选，如 `/permission work` → `work`）
  String _slashArgQuery = '';
  /// 已展开参数的命令（例如 /permission 展开三种预设）
  SlashCommand? _slashExpanded;

  /// 根据输入内容决定命令面板的显示与过滤。
  ///
  /// 触发条件（避免误伤正常输入）：整段文本以 `/` 开头、且是单行。
  void _syncSlashMenu() {
    final text = _controller.text;
    final shouldShow = text.startsWith('/') && !text.contains('\n');

    if (!shouldShow) {
      if (_slashMenuVisible || _slashExpanded != null) {
        setState(() {
          _slashMenuVisible = false;
          _slashExpanded = null;
        });
      }
      return;
    }

    // `/permission ` 后面已带空格 → 展开该命令的参数候选，并按已输入参数过滤
    final body = text.substring(1);
    final spaceIdx = body.indexOf(' ');
    if (spaceIdx >= 0) {
      final name = body.substring(0, spaceIdx);
      final argText = body.substring(spaceIdx + 1).trim();
      // 用动态命令表（/model、/workspace、/session 的候选来自电脑端真实目录）
      final cmd = _slashCommandsFor(context.read<SettingsProvider>())
          .where((c) => c.name == name)
          .firstOrNull;
      if (cmd != null && cmd.options.isNotEmpty) {
        if (!_slashMenuVisible || _slashExpanded?.name != cmd.name || _slashArgQuery != argText) {
          setState(() {
            _slashMenuVisible = true;
            _slashExpanded = cmd;
            _slashQuery = '';
            _slashArgQuery = argText;
          });
        }
        return;
      }
    }

    final query = spaceIdx >= 0 ? body.substring(0, spaceIdx) : body;
    if (!_slashMenuVisible || _slashQuery != query || _slashExpanded != null) {
      setState(() {
        _slashMenuVisible = true;
        _slashExpanded = null;
        _slashQuery = query;
        _slashArgQuery = '';
      });
    }
  }

  /// 点了命令：带参数的展开候选，不带参数的直接执行
  void _onPickSlashCommand(SlashCommand cmd) {
    if (cmd.options.isNotEmpty) {
      setState(() {
        _slashExpanded = cmd;
        _slashMenuVisible = true;
      });
      // 顺带把命令补全到输入框，用户也能直接手敲参数
      _controller.text = '/${cmd.name} ';
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
      return;
    }
    _dismissSlashMenu();
    unawaited(_runSlashCommand(cmd.name, ''));
  }

  /// 点了某个参数：直接执行整条命令
  void _onPickSlashOption(SlashCommand cmd, SlashCommandOption opt) {
    _dismissSlashMenu();
    unawaited(_runSlashCommand(cmd.name, opt.value));
  }

  void _dismissSlashMenu() {
    _controller.clear();
    if (mounted) {
      setState(() {
        _slashMenuVisible = false;
        _slashExpanded = null;
      });
    }
  }

  /// 构造当前可用的斜杠命令：静态命令 + 用电脑端真实目录拼出的动态候选。
  List<SlashCommand> _slashCommandsFor(SettingsProvider sp) {
    final models = <SlashCommandOption>[];
    for (final m in sp.agentModels) {
      final id = m['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      models.add(SlashCommandOption(id, SettingsProvider.agentModelLabel(m)));
    }
    final workspaces = sp.agentWorkspaces
        .map((w) => SlashCommandOption(w, w))
        .toList();
    final sessions = <SlashCommandOption>[];
    for (final item in sp.sessionsForWorkspace(sp.settings.targetWorkspace)) {
      final id = item['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      sessions.add(SlashCommandOption(id, SettingsProvider.agentSessionLabel(item)));
    }
    return [
      for (final cmd in kSlashCommands)
        switch (cmd.name) {
          'model' => SlashCommand(name: cmd.name, description: cmd.description, options: models),
          'workspace' => SlashCommand(name: cmd.name, description: cmd.description, options: workspaces),
          'session' => SlashCommand(name: cmd.name, description: cmd.description, options: sessions),
          _ => cmd,
        },
    ];
  }

  /// 本地执行一条斜杠命令（**不再把命令当消息发给模型**）。
  ///
  /// 为什么改成本地执行：宿主不会把"排队进会话的 /xxx 文本"当命令执行 ——
  /// /permission 那次踩过坑（排了 13 条全成了聊天消息、预设从未改变）。这些能力
  /// App 本来就有对应的真接口（会话选项 / 建会话 / 取消生成），本地执行最可靠，
  /// 也不会污染会话记录。
  Future<void> _runSlashCommand(String name, String arg) async {
    final sp = context.read<SettingsProvider>();
    final chat = context.read<ChatProvider>();
    final s = sp.settings;
    switch (name) {
      case 'help':
        await _showSlashHelp();
        return;
      case 'permission':
      case 'model':
      case 'effort':
        await _applyAgentOption(kind: name, value: arg);
        return;
      case 'workspace':
        if (arg.isEmpty) {
          _slashToast('用法：/workspace <路径>（可选值见命令面板）');
          return;
        }
        s.targetWorkspace = arg;
        // 换了工作区，原会话基本不属于它了
        s.targetSessionId = '';
        sp.updateSettings(s);
        unawaited(sp.refreshAgentCatalog(silent: true));
        _slashToast('✅ 目标工作区已切到：$arg');
        return;
      case 'session':
        if (arg.isEmpty) {
          _slashToast('用法：/session <会话 id>（可选值见命令面板）');
          return;
        }
        s.targetSessionId = arg;
        sp.updateSettings(s);
        _slashToast('✅ 目标会话已切换');
        return;
      case 'new':
        if (s.isHarnessOnline != true) {
          _slashToast('电脑端桥接未在线，无法新建会话');
          return;
        }
        final newId = await sp.createAgentSessionOnPc(workspace: s.targetWorkspace, title: arg);
        if (newId == null) {
          _slashToast('新建会话失败：请确认电脑端 LxAI 在运行');
          return;
        }
        s.targetSessionId = newId;
        sp.updateSettings(s);
        _slashToast('✅ 已新建并选中会话');
        return;
      case 'stop':
        chat.stopGeneration();
        _slashToast('已停止当前生成');
        return;
      default:
        _slashToast('未知命令：/$name（输入 /help 看全部）');
    }
  }

  /// /permission、/model、/effort 共用的"改设置并立即下发到电脑端会话"。
  Future<void> _applyAgentOption({required String kind, required String value}) async {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    if (value.isEmpty) {
      _slashToast('用法：/$kind <值>（可选值见命令面板）');
      return;
    }
    switch (kind) {
      case 'permission':
        s.agentPermission = value;
      case 'effort':
        s.agentReasoningEffort = value;
      case 'model':
        s.agentModel = value;
        // 换模型后档位集合可能不同，顺手对齐，避免下发非法档位
        final efforts = sp.reasoningEffortsFor(value);
        if (efforts.isNotEmpty && !efforts.contains(s.agentReasoningEffort)) {
          s.agentReasoningEffort = efforts.contains('high') ? 'high' : efforts.first;
        }
    }
    sp.updateSettings(s);

    final sessionId = s.targetSessionId.trim();
    if (sessionId.isEmpty) {
      _slashToast('已保存，下一条消息生效（当前没有选中会话）');
      return;
    }
    final res = await SyncService.instance.applyAgentSessionOption(
      token: s.harnessToken,
      userId: sp.syncUserId,
      kind: kind == 'effort' ? 'model' : kind,
      sessionId: sessionId,
      permission: s.agentPermission,
      reasoningEffort: s.agentReasoningEffort,
      model: s.agentModel,
      harnessUrl: s.harnessServiceUrl,
    );
    _slashToast(res.ok ? '✅ 已切换电脑端${kind == 'permission' ? '权限' : (kind == 'model' ? '模型' : '思考深度')}：$value' : '切换失败：${res.message}');
  }

  /// /help：列出全部命令与用法
  Future<void> _showSlashHelp() async {
    final sp = context.read<SettingsProvider>();
    final commands = _slashCommandsFor(sp);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('可用命令', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final cmd in commands)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '/${cmd.name}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(cmd.description, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                        if (cmd.options.isNotEmpty)
                          Text(
                            '可选值：${cmd.options.map((o) => o.value).join(' / ')}',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          ),
                      ],
                    ),
                  ),
                Text(
                  '提示：输入 / 会自动浮出命令面板，支持模糊匹配（如 /pm 也能找到 /permission）。',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 手敲命令直接发送时的拦截：认得出来就在本地执行，不当消息发出去。
  bool _tryRunSlashFromText(String text) {
    if (!text.startsWith('/')) return false;
    final body = text.substring(1).trim();
    if (body.isEmpty) return false;
    final spaceIdx = body.indexOf(RegExp(r'\s'));
    final name = (spaceIdx < 0 ? body : body.substring(0, spaceIdx)).toLowerCase();
    final arg = spaceIdx < 0 ? '' : body.substring(spaceIdx + 1).trim();
    final sp = context.read<SettingsProvider>();
    if (!_slashCommandsFor(sp).any((c) => c.name == name)) return false;
    _dismissSlashMenu();
    unawaited(_runSlashCommand(name, arg));
    return true;
  }

  void _slashToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _handleSend() {
    final text = _controller.text.trim();
    final hasAttachments = _pendingAttachments.isNotEmpty || _recordedPendingAudioUri != null;

    // 斜杠命令：认得出来就在本地执行，绝不当消息发给模型
    // （命令走的是真接口，见 _runSlashCommand；手敲 /help 也一样）
    if (text.startsWith('/') && !hasAttachments && _tryRunSlashFromText(text)) return;

    if (text.isNotEmpty || hasAttachments) {
      final chat = context.read<ChatProvider>();
      final quote = chat.quotedMessage;
      String finalText = text;
      if (quote != null) {
        final quoteSender = quote.role == MessageRole.user ? '我' : 'AI';
        final snippet = quote.content.length > 100 ? '${quote.content.substring(0, 100)}...' : quote.content;
        final cleanSnippet = snippet.replaceAll('\n', ' ');
        finalText = '> 💬 **引用 [$quoteSender]**：$cleanSnippet\n\n$text';
        // 刻意不在这里清引用：生成中会先弹选择框，用户可能取消或犹豫到这一轮结束，
        // 那种情况下引用卡片应该还在。真正发出去时再清（见 _submitSend）。
      }

      final List<String> attachments = List.from(_pendingAttachments);
      if (_recordedPendingAudioUri != null) {
        attachments.add(_recordedPendingAudioUri!);
      }

      // 生成中发送 → 先弹「插话 / 排队」让用户选，和官方宿主一致
      if (widget.isGenerating) {
        _showSendModeSheet(finalText, attachments.isNotEmpty ? attachments : null);
        return;
      }

      _submitSend(finalText, attachments.isNotEmpty ? attachments : null, widget.onSend);
    }
  }

  /// 真正把消息交出去并清空输入区
  void _submitSend(
    String text,
    List<String>? attachments,
    Function(String text, {List<String>? attachments}) action,
  ) {
    action(text, attachments: attachments);
    _controller.clear();
    // 消息确实发出去了，这时才消费掉引用卡片
    if (mounted) context.read<ChatProvider>().clearQuotedMessage();
    if (!mounted) return;
    setState(() {
      _pendingAttachments.clear();
      _pendingFileDisplayNames.clear();
      _recordedPendingAudioUri = null;
      _recordedPendingAudioSec = 0;
      _isMenuOpen = false;
    });
  }

  /// 生成中发送：让用户选「插话发送」还是「排队发送」。
  ///
  /// 两者差别很大 ——
  /// · 插话：打断当前这轮，立刻处理你这条（Agent 执行阶段会连本地任务一起中止）；
  /// · 排队：不打断，等这轮结束后自动发出。
  ///
  /// 用户犹豫期间这一轮可能已经结束了：此时"插话"已无意义，弹窗会自动关闭并按
  /// 普通发送处理（下面监听 ChatProvider 的生成状态）。
  Future<void> _showSendModeSheet(String text, List<String>? attachments) async {
    final chat = context.read<ChatProvider>();
    final executing = chat.isAgentExecuting;
    bool turnFinished = false;

    // 轮次结束 → 关掉弹窗（返回值 'finished' 表示"已经不需要打断/排队了"）
    void onChatChanged() {
      if (!chat.isGenerating && !turnFinished) {
        turnFinished = true;
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop('finished');
        }
      }
    }

    chat.addListener(onChatChanged);
    String? mode;
    try {
      mode = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Row(
                    children: [
                      const Icon(Icons.bolt_outlined, size: 18, color: Color(0xFF0284C7)),
                      const SizedBox(width: 8),
                      Text(
                        executing ? '本地 Agent 正在执行' : '正在生成回复',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Text(
                    executing
                        ? '这条消息要怎么发？执行阶段的插话会中止电脑上正在跑的本地任务。'
                        : '这条消息要怎么发？',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.bolt_rounded, color: Color(0xFFF59E0B)),
                  title: const Text('插话发送', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    executing
                        ? '打断当前这轮（含电脑上正在执行的本地任务），立刻处理这条'
                        : '打断当前生成，立刻处理这条',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(ctx, 'interject'),
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded, color: Color(0xFF0284C7)),
                  title: const Text('排队发送', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('不打断，等这一轮结束后自动发出', style: TextStyle(fontSize: 12)),
                  onTap: () => Navigator.pop(ctx, 'queue'),
                ),
                const SizedBox(height: 8),
                Divider(height: 1, color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                ListTile(
                  leading: const Icon(Icons.close, size: 20),
                  title: const Text('取消', style: TextStyle(fontSize: 14)),
                  onTap: () => Navigator.pop(ctx, null),
                ),
                const SizedBox(height: 6),
              ],
            ),
          );
        },
      );
    } finally {
      chat.removeListener(onChatChanged);
    }

    if (!mounted) return;

    // 犹豫期间这一轮已经跑完了：自动收起选择框，**但不代发** ——
    // 消息原样留在输入框里，由用户自己点发送（是否要跟这条已完成的回复一起看，
    // 应该由用户决定，不该替他决定）
    if (mode == null && turnFinished) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('上一轮已经结束，消息仍在输入框，点发送即可发出'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (mode == null) return; // 用户主动取消

    if (mode == 'interject') {
      final action = widget.onInterject ?? widget.onSend;
      _submitSend(text, attachments, action);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚡ 已插话：当前这轮已打断'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      final action = widget.onEnqueue;
      if (action == null) return;
      _submitSend(text, attachments, action);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⏳ 已加入排队（当前排队 ${chat.queuedCount} 条）'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleAgentMode() {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    final newMode = !s.defaultAgentMode;
    s.defaultAgentMode = newMode;
    sp.updateSettings(s);
  }

  /// 渲染选择框卡片里的一个问题：标题 + 正文 + 逐项带描述的选项。
  ///
  /// 交互按问题类型分两种：
  ///   · 单选且有选项 → 点整行即作答（最快，也是绝大多数情况）；
  ///   · 多选 / 没有选项 → 行内勾选 + 下方输入框，最后统一按「提交」。
  /// 刻意不再提供「在电脑上回答」：别的设备或电脑网页端先答了，服务端会广播
  /// agent_question_resolved，本卡片自动收起。
  List<Widget> _buildQuestionCardBlock(
    BuildContext context,
    ChatProvider chat,
    Map<String, dynamic> item,
    bool isDark,
  ) {
    final id = item['id']?.toString() ?? '';
    final header = item['header']?.toString() ?? '';
    final text = item['question']?.toString() ?? '';
    final multi = item['multi_select'] == true || item['multiSelect'] == true;
    final rawOptions = item['options'];
    final options = rawOptions is List ? rawOptions.whereType<Map>().toList() : const <Map>[];
    final instant = chat.isInstantAnswerQuestion(item);
    final picked = chat.questionPicksFor(id);
    final custom = chat.questionCustomFor(id);

    return [
      if (header.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(header, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        ),
      if (text.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ),
      for (final opt in options)
        Builder(
          builder: (_) {
            final label = opt['label']?.toString() ?? '';
            if (label.isEmpty) return const SizedBox.shrink();
            final desc = opt['description']?.toString() ?? '';
            final selected = picked.contains(label);
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: instant
                    ? () => chat.answerQuestion([
                          {
                            'id': id,
                            'selected': [label],
                          }
                        ])
                    : () => chat.toggleQuestionPick(id, label, multiSelect: multi),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFF3B82F6).withOpacity(0.14)
                        : (isDark ? const Color(0xFF13293F) : Colors.white),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF3B82F6)
                          : (isDark ? const Color(0xFF27405C) : const Color(0xFFCBD5E1)),
                      width: selected ? 1.4 : 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(
                          instant
                              ? Icons.touch_app_outlined
                              : (selected ? Icons.check_box : Icons.check_box_outline_blank),
                          size: 16,
                          color: selected ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            if (desc.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                desc,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.35,
                                  color: isDark ? Colors.white60 : Colors.black54,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (instant)
                        const Padding(
                          padding: EdgeInsets.only(left: 6, top: 1),
                          child: Text('点击即作答', style: TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      if (!instant) ...[
        const SizedBox(height: 2),
        TextFormField(
          // 按问题 id 给 key：多题翻页时 Flutter 会重用同一位置的输入框 State，
          // 没有 key 的话翻到下一题还显示上一题输入的内容（initialValue 只在首次生效）
          key: ValueKey('question_custom_$id'),
          initialValue: custom,
          style: const TextStyle(fontSize: 12.5),
          decoration: const InputDecoration(
            isDense: true,
            hintText: '也可以直接输入回答（可选）',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => chat.setQuestionCustom(id, value),
        ),
      ],
    ];
  }

  /// 已答题目数（勾了选项，或写了自定义回答，都算答过）。
  ///
  /// 多题时标题行显示「已答 n/y」：翻页答题最容易漏掉后面的题，
  /// 有一个明确的进度提示，用户提交前能一眼看出还差几题。
  int _answeredQuestionCount(ChatProvider chat, List<Map<String, dynamic>> items) {
    var answered = 0;
    for (final item in items) {
      final id = item['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      if (chat.questionPicksFor(id).isNotEmpty || chat.questionCustomFor(id).isNotEmpty) {
        answered++;
      }
    }
    return answered;
  }

  /// 提问卡的标题行：图标 + 标题（含「第 x/y 题 · 已答 n/y」）+ 收起/展开按钮。
  ///
  /// 收起后只剩这一行，输入框和聊天内容不再被提问卡挤占 —— 想边看聊天边答题时
  /// 点一下收起来，想答了点一下展开（题号与已勾选内容都保留）。
  Widget _buildQuestionHeaderRow(
    int total,
    int step,
    int answered,
    bool orphaned,
    bool waitingLong, {
    required bool expanded,
  }) {
    final progress = total > 1 ? ' · 第 ${step + 1}/$total 题 · 已答 $answered/$total' : '';
    final stateNote = orphaned ? ' · 本轮已中止' : (waitingLong ? ' · 等待中' : '');
    return Row(
      children: [
        const Icon(Icons.help_outline, size: 16, color: Color(0xFF3B82F6)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '电脑端 Agent 在等你选择$progress$stateNote',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
        if (expanded)
          const Text(
            '另一台设备回答后会自动收起',
            style: TextStyle(fontSize: 10, color: Color(0xFF64748B)),
          ),
        IconButton(
          tooltip: expanded ? '收起提问框' : '展开提问框',
          onPressed: () => setState(() => _questionCollapsed = !_questionCollapsed),
          icon: Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 20,
            color: const Color(0xFF64748B),
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  /// 提问卡的翻页/提交行：「上一题」「下一题」+ 最后一题才有的「提交答案」。
  ///
  /// 为什么提交按钮只在最后一题出现（用户要求）：每一题都挂一个提交按钮，
  /// 很容易在只答了一题时就手快交卷（多题场景下漏答就是这么来的）；
  /// 放到最后一题，等于"翻完了才能交"。
  Widget _buildQuestionNavRow(ChatProvider chat, int total, int step) {
    final multiple = total > 1;
    final hasPrev = step > 0;
    final hasNext = step < total - 1;
    final isLast = step >= total - 1;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          if (multiple)
            TextButton(
              onPressed: hasPrev ? () => setState(() => _questionStep = step - 1) : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chevron_left, size: 18),
                  Text('上一题', style: TextStyle(fontSize: 12.5)),
                ],
              ),
            ),
          if (multiple)
            TextButton(
              onPressed: hasNext ? () => setState(() => _questionStep = step + 1) : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('下一题', style: TextStyle(fontSize: 12.5)),
                  Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          if (multiple && !isLast)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '翻到最后一题再提交',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
          const Spacer(),
          // 单选一题时（点一下即作答）不需要提交按钮；多题时只在最后一题给
          if (isLast)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              ),
              onPressed: chat.pendingQuestion == null ? null : () => chat.submitPendingQuestion(),
              child: const Text('提交答案', style: TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }

  // 1. 发送图片：调用原生相册
  Future<void> _handlePickImage() async {
    setState(() => _isMenuOpen = false);
    try {
      final result = await ImagePickerHelper.pickImageFromGallery();
      if (result != null && mounted) {
        setState(() {
          _pendingAttachments.add(result.toAttachmentString());
          _pendingFileDisplayNames.add('图片');
        });
      }
    } catch (e) {
      debugPrint('选择图片异常: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败: $e')),
        );
      }
    }
  }

  // 2. 拍照：调用手机相机
  Future<void> _handleTakePhoto() async {
    setState(() => _isMenuOpen = false);
    try {
      final result = await ImagePickerHelper.takePhotoFromCamera();
      if (result != null && mounted) {
        setState(() {
          _pendingAttachments.add(result.toAttachmentString());
          _pendingFileDisplayNames.add('拍照');
        });
      }
    } catch (e) {
      debugPrint('拍照异常: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('拍照失败: $e')),
        );
      }
    }
  }

  // 3. 发送文件：打开系统文件管理器
  Future<void> _handlePickFile() async {
    setState(() => _isMenuOpen = false);
    try {
      final file = await ImagePickerHelper.pickGenericFile();
      if (file != null && mounted) {
        setState(() {
          _pendingAttachments.add(file.base64Data);
          _pendingFileDisplayNames.add(file.name);
        });
      }
    } catch (e) {
      debugPrint('选择文件异常: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败: $e')),
        );
      }
    }
  }

  // 4. 录音功能
  Future<void> _startRecording({required bool isLongPress}) async {
    if (_isRecording) return;

    final hasPerm = await AudioRecorderService.instance.hasPermission();
    if (!hasPerm) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('需要麦克风权限以录制语音消息'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    final success = await AudioRecorderService.instance.startRecording();
    if (!success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('麦克风启动失败，请检查设备设置'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    setState(() {
      _isRecording = true;
      _isLongPress = isLongPress;
      _isSlideCancelling = false;
      _recordDurationSeconds = 0;
      _isMenuOpen = false;
    });

    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (mounted) {
        setState(() {
          _recordDurationSeconds = t.tick;
        });
      }
    });
  }

  Future<void> _stopRecording({bool cancelled = false}) async {
    if (!_isRecording) return;
    _recordTimer?.cancel();

    final isLong = _isLongPress;
    final isSlide = _isSlideCancelling;
    final isCancelled = cancelled || isSlide;

    setState(() {
      _isRecording = false;
      _isLongPress = false;
      _isSlideCancelling = false;
    });

    final result = await AudioRecorderService.instance.stopRecording(cancelled: isCancelled);

    if (isCancelled || result == null) {
      return;
    }

    if (isLong) {
      // 长按模式：松手直接发送语音消息
      widget.onSend(
        _controller.text.trim(),
        attachments: [result.base64AudioData],
      );
      _controller.clear();
      setState(() {
        _pendingAttachments.clear();
        _pendingFileDisplayNames.clear();
        _recordedPendingAudioUri = null;
      });
    } else {
      // 点击模式：点击结束录音后，转为待发送预览状态
      setState(() {
        _recordedPendingAudioUri = result.base64AudioData;
        _recordedPendingAudioSec = result.durationSeconds;
      });
    }
  }

  void _toggleClickRecording() {
    if (_isRecording) {
      _stopRecording(cancelled: false);
    } else {
      _startRecording(isLongPress: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final settingsProvider = context.watch<SettingsProvider>();
    final isAgentMode = settingsProvider.settings.defaultAgentMode;
    final isHarnessOnline = settingsProvider.settings.isHarnessOnline;

    final canSend = _hasText ||
        _pendingAttachments.isNotEmpty ||
        _recordedPendingAudioUri != null;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: EdgeInsets.only(
            left: 12,
            right: 12,
            top: 8,
            bottom: MediaQuery.of(context).padding.bottom + 8,
          ),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : Colors.white,
            border: Border(
              top: BorderSide(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                width: 1,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 0. Agent 模式快捷栏：工作区 / 会话 / 思考深度 / 执行权限。
              //    只在 Agent 模式打开时出现，关掉（左下角切回普通模式）即隐藏。
              if (isAgentMode) const AgentQuickBar(),
              // 0.5 排队中的消息（生成中点「排队发送」后出现在这里，可逐条撤回）
              Consumer<ChatProvider>(
                builder: (context, chat, _) {
                  if (chat.queuedCount == 0) return const SizedBox.shrink();
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.playlist_add_rounded, size: 15, color: Color(0xFF0284C7)),
                            const SizedBox(width: 6),
                            Text(
                              '排队中 ${chat.queuedCount} 条 · 本轮结束后自动发送',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            InkWell(
                              onTap: chat.clearQueue,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                child: Text(
                                  '全部清空',
                                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ...chat.queuedMessages.map(
                          (q) => Row(
                            children: [
                              Expanded(
                                child: Text(
                                  q.text.isEmpty ? '（附件）' : q.text.replaceAll('\n', ' '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => chat.withdrawQueued(q.id),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  child: Icon(Icons.close, size: 14, color: Colors.grey),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              // 0.4 宿主审批卡片：本地执行敏感操作前挂起等用户拍板。
              //     以前这条通知只走 socket.io，而 App 没有 socket.io 客户端，
              //     所以只有宿主自己弹窗；现在经 SSE 同步到这里。
              Consumer<ChatProvider>(
                builder: (context, chat, _) {
                  final approval = chat.pendingApproval;
                  if (approval == null) return const SizedBox.shrink();
                  final tool = approval['tool']?.toString() ?? '敏感操作';
                  // 文件沙箱越权升级这类审批，reason 才是"为什么要放行"的关键信息
                  // （例如"写入工作区之外的路径"），只给工具名等于让用户盲签。
                  final reason = approval['reason']?.toString().trim() ?? '';
                  // 延后待批：那一轮早已结束，批准后会以「续跑」方式重试该操作。
                  // 明确写出来，用户才知道"点了会不会有反应、会不会重跑一遍"。
                  final deferred = chat.pendingApprovalDeferred;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF2A1F0B) : const Color(0xFFFFFBEB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF59E0B)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.gpp_maybe_outlined, size: 16, color: Color(0xFFF59E0B)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                deferred ? '电脑端等待你的授权（本轮已中止）' : '电脑端等待你的授权',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        if (deferred) ...[
                          const SizedBox(height: 3),
                          Text(
                            '当时那一轮已经结束，现在批准会以「继续」的方式重试这个操作',
                            style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          '本地 Agent 想执行：$tool',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                        ),
                        if (reason.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '原因：$reason',
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.35,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => chat.resolveApproval('deny'),
                                child: const Text('拒绝', style: TextStyle(fontSize: 12)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF59E0B)),
                                onPressed: () => chat.resolveApproval('allow'),
                                child: const Text('允许本次', style: TextStyle(fontSize: 12)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
              // 0.5 选择框卡片：宿主的 ask_user_question 挂起时，App 直接在这里答。
              //
              // 刻意不做成模态弹窗（用户要求）：弹窗会盖住聊天、还得先关掉；选择框
              // 本来就该"贴在输入框上方"。别的设备或电脑网页端先答了 → 服务端广播
              // agent_question_resolved → 这里自动收起，所以不需要"在电脑上回答"按钮。
              Consumer<ChatProvider>(
                builder: (context, chat, _) {
                  final items = chat.pendingQuestionItems;
                  if (items.isEmpty) return const SizedBox.shrink();

                  // 换了一道新问题（或第一次出现）：题号、收起状态复位。
                  // 这里只改字段不 setState —— 正在 build 中，下一帧自然用新值。
                  final navId = chat.pendingQuestion?['questionId']?.toString() ?? '';
                  if (navId != _questionNavId) {
                    _questionNavId = navId;
                    _questionStep = 0;
                    _questionCollapsed = false;
                  }
                  final step = _questionStep.clamp(0, items.length - 1);
                  final total = items.length;
                  // 已答几题：用于标题行提示，避免多题时漏答（答过的题换个页也要看得出来）
                  final answered = _answeredQuestionCount(chat, items);
                  // 多题必须显式提交（点选项只是勾选）；单题单选有选项时仍是点一下即作答
                  final needsSubmit = chat.pendingQuestionNeedsSubmit;
                  // pending（刚问）/ waiting（等久了但**仍在等**，本轮不会交给模型）/
                  // orphaned（本轮已中止，答复走续跑）
                  final qState = chat.pendingQuestionState;
                  final orphaned = qState == 'orphaned';
                  final waitingLong = qState == 'waiting';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: _questionCollapsed
                        ? const EdgeInsets.fromLTRB(10, 4, 6, 4)
                        : const EdgeInsets.fromLTRB(10, 10, 10, 8),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F2338) : const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF3B82F6)),
                    ),
                    child: _questionCollapsed
                        ? _buildQuestionHeaderRow(total, step, answered, orphaned, waitingLong, expanded: false)
                        : ConstrainedBox(
                            // 选项多、描述长时给一个较高的可视区，超出内部滚动，别把输入框顶没
                            constraints: const BoxConstraints(maxHeight: 380),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildQuestionHeaderRow(total, step, answered, orphaned, waitingLong, expanded: true),
                                  if (orphaned)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 3),
                                      child: Text(
                                        '本轮已中止（等了很久没人答）· 现在答复会以「继续」的方式发回给 Agent',
                                        style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                                      ),
                                    )
                                  else if (waitingLong)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 3),
                                      child: Text(
                                        '已等待较久 · Agent 仍在等你的答复，不会自己继续（请在最后一题提交）',
                                        style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  // 一次只渲染当前这一题
                                  ..._buildQuestionCardBlock(context, chat, items[step], isDark),
                                  if (needsSubmit)
                                    _buildQuestionNavRow(chat, total, step),
                                ],
                              ),
                            ),
                          ),
                  );
                },
              ),
              // 1. 引用消息卡片预览
              Consumer<ChatProvider>(
                builder: (context, chat, _) {
                  final quote = chat.quotedMessage;
                  if (quote == null) return const SizedBox.shrink();
                  final isUserMsg = quote.role == MessageRole.user;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(8),
                      border: const Border(
                        left: BorderSide(
                          color: Color(0xFF0284C7),
                          width: 3,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.format_quote, size: 16, color: Color(0xFF0284C7)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '引用 [${isUserMsg ? "我" : "AI"}]: ${quote.content.replaceAll('\n', ' ')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => chat.clearQuotedMessage(),
                          child: const Padding(
                            padding: EdgeInsets.all(2.0),
                            child: Icon(Icons.close, size: 16, color: Colors.grey),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

              // 2. 待发送附件列表 (图片、文件、录音条)
              if (_pendingAttachments.isNotEmpty || _recordedPendingAudioUri != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        // 待发送语音预览条
                        if (_recordedPendingAudioUri != null)
                          Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0284C7).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFF0284C7), width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.mic, color: Color(0xFF0284C7), size: 18),
                                const SizedBox(width: 4),
                                Text(
                                  '语音消息 (${_recordedPendingAudioSec > 0 ? _recordedPendingAudioSec : 1}")',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0284C7),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: () => setState(() {
                                    _recordedPendingAudioUri = null;
                                    _recordedPendingAudioSec = 0;
                                  }),
                                  child: const Icon(Icons.close, size: 16, color: Color(0xFF0284C7)),
                                ),
                              ],
                            ),
                          ),

                        // 待发送图片/文件条目
                        ...List.generate(_pendingAttachments.length, (idx) {
                          final att = _pendingAttachments[idx];
                          final isFile = att.startsWith('data:application/octet-stream');
                          final isImg = !isFile && !att.startsWith('data:audio/');

                          if (isImg) {
                            final localPath = ImagePickerHelper.extractLocalPathFromAttachment(att);
                            final hasLocalFile = localPath != null && localPath.isNotEmpty && File(localPath).existsSync();
                            final previewBytes = hasLocalFile ? null : ImagePickerHelper.decodeBase64Image(att);
                            if (!hasLocalFile && previewBytes == null) return const SizedBox.shrink();

                            final ImageProvider imgProvider = hasLocalFile
                                ? FileImage(File(localPath)) as ImageProvider
                                : MemoryImage(previewBytes!) as ImageProvider;

                            return Container(
                              margin: const EdgeInsets.only(right: 8),
                              child: Stack(
                                children: [
                                  Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: const Color(0xFF0284C7), width: 1.5),
                                      image: DecorationImage(
                                        image: imgProvider,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: -2,
                                    right: -2,
                                    child: GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _pendingAttachments.removeAt(idx);
                                          if (idx < _pendingFileDisplayNames.length) {
                                            _pendingFileDisplayNames.removeAt(idx);
                                          }
                                        });
                                      },
                                      child: Container(
                                        decoration: const BoxDecoration(
                                          color: Colors.black87,
                                          shape: BoxShape.circle,
                                        ),
                                        padding: const EdgeInsets.all(2),
                                        child: const Icon(Icons.close, color: Colors.white, size: 12),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          } else {
                            // 文件卡片预览
                            final fileName = idx < _pendingFileDisplayNames.length
                                ? _pendingFileDisplayNames[idx]
                                : '已选文件';
                            return Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.insert_drive_file, color: Color(0xFF0284C7), size: 18),
                                  const SizedBox(width: 6),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 120),
                                    child: Text(
                                      fileName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _pendingAttachments.removeAt(idx);
                                        if (idx < _pendingFileDisplayNames.length) {
                                          _pendingFileDisplayNames.removeAt(idx);
                                        }
                                      });
                                    },
                                    child: const Icon(Icons.close, size: 14, color: Colors.grey),
                                  ),
                                ],
                              ),
                            );
                          }
                        }),
                      ],
                    ),
                  ),
                ),

              // 3. 展开的 + 号工具栏面板
              if (_isMenuOpen)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildToolItem(
                        icon: Icons.photo_library_outlined,
                        label: '发图片',
                        color: const Color(0xFF0284C7),
                        isDark: isDark,
                        onTap: _handlePickImage,
                      ),
                      _buildToolItem(
                        icon: Icons.camera_alt_outlined,
                        label: '拍照',
                        color: const Color(0xFF10B981),
                        isDark: isDark,
                        onTap: _handleTakePhoto,
                      ),
                      _buildToolItem(
                        icon: Icons.folder_open_outlined,
                        label: '发文件',
                        color: const Color(0xFFF59E0B),
                        isDark: isDark,
                        onTap: _handlePickFile,
                      ),
                      _buildToolItem(
                        icon: Icons.qr_code_scanner_rounded,
                        label: '扫一扫',
                        color: const Color(0xFF8B5CF6),
                        isDark: isDark,
                        onTap: () {
                          setState(() => _isMenuOpen = false);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ScannerScreen(),
                              fullscreenDialog: true,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

              // 4. 点击录音模式下的动态提示栏（长按模式采用悬浮 HUD，保证输入框坐标绝对稳定）
              if (_isRecording && !_isLongPress)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFF0284C7),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.mic,
                        color: Color(0xFF0284C7),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '🔴 录音中 $_recordDurationSeconds" · 点击麦克风发送',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(width: 12),
                      InkWell(
                        onTap: () => _stopRecording(cancelled: true),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Text(
                            '取消',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFFEF4444),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // 5. 斜杠命令面板（输入 / 时浮出，Telegram 风格）
              if (_slashMenuVisible)
                SlashCommandMenu(
                  query: _slashQuery,
                  argQuery: _slashArgQuery,
                  expanded: _slashExpanded,
                  commands: _slashCommandsFor(settingsProvider),
                  onPickCommand: _onPickSlashCommand,
                  onPickOption: _onPickSlashOption,
                  onClose: () => setState(() {
                    _slashMenuVisible = false;
                    _slashExpanded = null;
                  }),
                ),

              // 6. 主输入条
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 1. Agent 模式切换胶囊按钮（保留在输入框左侧）
                  InkWell(
                    onTap: _toggleAgentMode,
                    borderRadius: BorderRadius.circular(20),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                      decoration: BoxDecoration(
                        color: isAgentMode
                          ? const Color(0xFF0284C7).withOpacity(0.18)
                          : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isAgentMode
                            ? const Color(0xFF0284C7).withOpacity(0.5)
                            : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isAgentMode ? Icons.smart_toy_outlined : Icons.auto_awesome,
                            size: 14,
                            color: isAgentMode
                              ? const Color(0xFF0284C7)
                              : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isAgentMode ? 'Agent' : '普通',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isAgentMode ? FontWeight.bold : FontWeight.normal,
                              color: isAgentMode
                                ? const Color(0xFF0284C7)
                                : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569)),
                            ),
                          ),
                          if (isAgentMode) ...[
                            const SizedBox(width: 4),
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isHarnessOnline ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // 2. 文本输入框与麦克风按钮
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              focusNode: _focusNode,
                              maxLines: 4,
                              minLines: 1,
                              textInputAction: TextInputAction.newline,
                              style: TextStyle(
                                fontSize: 14,
                                color: isDark ? Colors.white : const Color(0xFF0F172A),
                              ),
                              decoration: InputDecoration(
                                hintText: isAgentMode
                                    ? '向本地 Agent 发送需求...'
                                    : '输入消息向 AI 提问...',
                                hintStyle: TextStyle(
                                  color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                                  fontSize: 13,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              ),
                            ),
                          ),

                          // 麦克风录音控制 (状态驱动的手势隔离：点击录音中与静止/长按状态完全解耦)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            child: _isRecording && !_isLongPress
                                // 模式 A：点击录音进行中 -> 纯点击停止按钮，0 延迟响应，彻底脱离长按手势竞技场
                                ? Tooltip(
                                    message: '点击完成录音',
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        HapticFeedback.lightImpact();
                                        _stopRecording(cancelled: false);
                                      },
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 150),
                                        padding: const EdgeInsets.all(8),
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Color(0xFF0284C7),
                                        ),
                                        child: const Icon(
                                          Icons.stop_rounded,
                                          size: 20,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  )
                                // 模式 B：静止状态 / 长按录音中 -> 完整支持轻点触发点击录音，长按触发长按并支持上滑取消
                                : Tooltip(
                                    message: _isRecording ? '松开手指完成录音，上滑取消' : '点击/长按录音 (长按可上滑取消)',
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        if (!_isRecording) {
                                          _startRecording(isLongPress: false);
                                        }
                                      },
                                      onLongPressStart: (details) {
                                        if (!_isRecording) {
                                          HapticFeedback.lightImpact();
                                          _startRecording(isLongPress: true);
                                        }
                                      },
                                      onLongPressMoveUpdate: (details) {
                                        if (_isRecording && _isLongPress) {
                                          // offsetFromOrigin.dy 向上滑动为负值
                                          final dy = details.offsetFromOrigin.dy;
                                          final cancelling = dy < -30;
                                          if (cancelling != _isSlideCancelling) {
                                            HapticFeedback.mediumImpact();
                                            setState(() => _isSlideCancelling = cancelling);
                                          }
                                        }
                                      },
                                      onLongPressEnd: (_) {
                                        if (_isRecording && _isLongPress) {
                                          HapticFeedback.lightImpact();
                                          _stopRecording(cancelled: _isSlideCancelling);
                                        }
                                      },
                                      onLongPressCancel: () {
                                        if (_isRecording && _isLongPress) {
                                          _stopRecording(cancelled: true);
                                        }
                                      },
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 150),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: _isRecording
                                              ? (_isSlideCancelling ? const Color(0xFFEF4444) : const Color(0xFF0284C7))
                                              : Colors.transparent,
                                        ),
                                        child: Icon(
                                          _isRecording
                                              ? (_isSlideCancelling ? Icons.cancel_outlined : Icons.stop_rounded)
                                              : Icons.mic_none_outlined,
                                          size: 20,
                                          color: _isRecording
                                              ? Colors.white
                                              : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // 3. 右侧按钮：生成中同时给「发送」和「停止」——
                  //    点发送会弹出「插话 / 排队」选择（和官方宿主的交互一致）
                  if (widget.isGenerating && canSend)
                    IconButton.filled(
                      onPressed: _handleSend,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(10),
                      ),
                      tooltip: '发送（可选插话或排队）',
                    )
                  else if (widget.isGenerating)
                    IconButton.filled(
                      onPressed: widget.onStop,
                      icon: const Icon(Icons.stop_rounded, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(10),
                      ),
                      tooltip: '停止生成',
                    )
                  else if (canSend)
                    IconButton.filled(
                      onPressed: _handleSend,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(10),
                      ),
                      tooltip: '发送消息',
                    )
                  else
                    IconButton.filled(
                      onPressed: () {
                        setState(() => _isMenuOpen = !_isMenuOpen);
                      },
                      icon: AnimatedRotation(
                        turns: _isMenuOpen ? 0.125 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(Icons.add, size: 20),
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                        foregroundColor: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                        padding: const EdgeInsets.all(10),
                      ),
                      tooltip: '展开更多功能',
                    ),
                ],
              ),
            ],
          ),
        ),

        // 6. 长按录音浮动 HUD（悬浮在输入条正上方，绝对定位避免界面抖动或坐标漂移）
        if (_isRecording && _isLongPress)
          Positioned(
            top: -54,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: _isSlideCancelling
                      ? const Color(0xFFEF4444)
                      : (isDark ? const Color(0xFF1E293B).withOpacity(0.95) : const Color(0xFF0F172A).withOpacity(0.92)),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: (_isSlideCancelling ? const Color(0xFFEF4444) : Colors.black).withOpacity(0.25),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isSlideCancelling ? Icons.delete_outline_rounded : Icons.mic_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isSlideCancelling
                          ? '松开手指，取消发送'
                          : '🔴 正在录音 $_recordDurationSeconds" · 松开发送，上滑取消',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildToolItem({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
