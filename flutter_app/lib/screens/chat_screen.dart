import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/tts_service.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/message_bubble.dart';
import 'log_console_screen.dart';
import 'session_management_screen.dart';
import 'settings_screen.dart';
import 'voice_call_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = 0;
  String? _lastSessionId;
  bool _userScrolledUp = false;
  bool _isUserInteracting = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    final distFromBottom = maxScroll - currentScroll;
    // 若距离底部超过 30 像素，视为用户主动向上翻阅，暂停流式自动吸底
    if (distFromBottom > 30) {
      if (!_userScrolledUp) {
        setState(() {
          _userScrolledUp = true;
        });
      }
    } else if (distFromBottom <= 10) {
      if (_userScrolledUp) {
        setState(() {
          _userScrolledUp = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = true, bool force = false}) {
    // 🛡️ 核心防手势打断：
    // 1. 若用户手指正在触摸/拖拽屏幕(_isUserInteracting)，严禁调用 jumpTo/animateTo，否则会瞬间强行杀死手势！
    // 2. 若用户已向上滑动翻看历史(_userScrolledUp)，且非强制（如发新消息/换会话），保持视口静止自由翻阅！
    if (!force) {
      if (_isUserInteracting || _userScrolledUp) return;
      if (_scrollController.hasClients) {
        final distFromBottom = _scrollController.position.maxScrollExtent - _scrollController.offset;
        if (distFromBottom > 30) return;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      // 帧回调内部二次校验，避免在回调延迟微秒内用户手指触碰而被强行打断
      if (!force && (_isUserInteracting || _userScrolledUp)) return;

      final maxScroll = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          maxScroll,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(maxScroll);
      }
    });
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _showRenameSessionDialog(BuildContext context, ChatSession session) {    final controller = TextEditingController(text: session.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.edit_outlined, color: Color(0xFF0284C7), size: 22),
            SizedBox(width: 8),
            Text('重命名会话', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '请输入会话名称',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          onSubmitted: (val) {
            final newTitle = val.trim();
            if (newTitle.isNotEmpty) {
              context.read<ChatProvider>().renameSession(session.id, newTitle);
            }
            Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final newTitle = controller.text.trim();
              if (newTitle.isNotEmpty) {
                context.read<ChatProvider>().renameSession(session.id, newTitle);
              }
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showModelSelector(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    final settingsProvider = context.read<SettingsProvider>();
    final endpoints = settingsProvider.settings.apiEndpoints;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Text(
                    '选择对话模型',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                if (endpoints.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('暂无可用模型，请在设置中添加 API 端点'),
                  )
                else
                  ...endpoints.map((ep) {
                    final isSelected = settingsProvider.activeEndpointId == ep.id;
                    return ListTile(
                      leading: Icon(
                        Icons.bolt,
                        color: isSelected ? const Color(0xFF0284C7) : null,
                      ),
                      title: Text(
                        ep.cardName,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? const Color(0xFF0284C7) : null,
                        ),
                      ),
                      subtitle: Text(
                        '${ep.modelName} · ${ep.endpoint}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Color(0xFF0284C7))
                          : null,
                      onTap: () {
                        settingsProvider.selectEndpoint(ep);
                        Navigator.pop(ctx);
                      },
                    );
                  }),
              ],
            ),
          ),
        );
      },
    ).then((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final settingsProvider = context.watch<SettingsProvider>();
    final settings = settingsProvider.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 自动滚动监测：新消息到来、会话切换或流式输出时自动滑动到底部
    if (chat.messages.length != _lastMessageCount || chat.currentSession?.id != _lastSessionId) {
      final isSessionSwitched = chat.currentSession?.id != _lastSessionId;
      _lastMessageCount = chat.messages.length;
      _lastSessionId = chat.currentSession?.id;
      // 会话切换或收到新消息时，重置用户上滑与手势交互状态并强制吸底。
      //
      // 但"消息条数变了"并不都是用户自己发的：云端迟到的回答、另一端同步过来的
      // 消息也会让条数变化 —— 以前一律 force:true，等于把正在往上翻历史的用户
      // 硬拽回底部（用户实测反馈："消息框位置不对"）。现在只有**本机正在生成**
      // （= 用户刚发了消息）或切换会话时才强制吸底，其余情况尊重用户当前位置。
      final shouldForce = isSessionSwitched || chat.isGenerating;
      _userScrolledUp = false;
      _isUserInteracting = false;
      _scrollToBottom(animate: !isSessionSwitched, force: shouldForce);
    } else if (chat.isGenerating) {
      _scrollToBottom(animate: false);
    }

    final displayName = settings.aiName.isNotEmpty
        ? '${settings.aiName} (${settings.activeModelDisplayName})'
        : settings.activeModelDisplayName;

    return Scaffold(
      onDrawerChanged: (isOpen) {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      appBar: AppBar(
        title: InkWell(
          onTap: () => _showModelSelector(context),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down, size: 20),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              settings.autoSpeakResponse ? Icons.volume_up : Icons.volume_off_outlined,
              color: settings.autoSpeakResponse ? const Color(0xFF0284C7) : null,
            ),
            tooltip: settings.autoSpeakResponse ? '自动朗读：已开启 (点击关闭/打断)' : '自动朗读：已关闭 (点击开启)',
            onPressed: () {
              if (settings.autoSpeakResponse) {
                // 处于开启状态或朗读中，点击关闭并立即中断当前朗读
                TtsService.instance.stop();
                settingsProvider.setAutoSpeakResponse(false);
              } else {
                // 处于关闭状态，点击开启
                settingsProvider.setAutoSpeakResponse(true);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.phone_in_talk_outlined),
            tooltip: '实时语音通话',
            onPressed: () async {
              FocusManager.instance.primaryFocus?.unfocus();
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const VoiceCallScreen()),
              );
              FocusManager.instance.primaryFocus?.unfocus();
            },
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.chat_bubble_outline, color: Color(0xFF0284C7)),
                    const SizedBox(width: 12),
                    const Text(
                      '历史对话',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        chat.createNewSession();
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: chat.sessions.length,
                  itemBuilder: (ctx, index) {
                    final session = chat.sessions[index];
                    final isSelected = chat.currentSession?.id == session.id;

                    return ListTile(
                      selected: isSelected,
                      selectedTileColor: isDark
                          ? const Color(0xFF1E293B)
                          : const Color(0xFFE0F2FE),
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        session.model ?? 'deepseek-v4-flash',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () {
                        FocusManager.instance.primaryFocus?.unfocus();
                        chat.selectSession(session);
                        Navigator.pop(context);
                      },
                      // 侧边栏消息仅支持长按重命名，严禁删除
                      onLongPress: () {
                        _showRenameSessionDialog(context, session);
                      },
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              ListTile(
                // 气泡类图标（会话）。刻意不用 `chat_bubble_outline` —— 那正是本抽屉
                // 顶部「历史对话」用的图标，同一个抽屉里出现两个一样的不合适；
                // 也不用原来的 `tune_outlined`（滑块），它和下面的「系统设置」齿轮观感太像，
                // 用户反馈过"都用设置图标，有点误导"。
                leading: const Icon(Icons.forum_outlined, size: 20),
                title: const Text('会话管理与备份', style: TextStyle(fontSize: 13)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  Navigator.pop(context);
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SessionManagementScreen()),
                  );
                  FocusManager.instance.primaryFocus?.unfocus();
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined, size: 20),
                title: const Text('系统设置', style: TextStyle(fontSize: 13)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  Navigator.pop(context);
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                  FocusManager.instance.primaryFocus?.unfocus();
                },
              ),
            ],
          ),
        ),
      ),
      // 实装悬浮调试球 (根据设置项 showDebugFab 动态控制)
      floatingActionButton: settings.showDebugFab
          ? FloatingActionButton.small(
              heroTag: 'debug_console_fab',
              backgroundColor: const Color(0xFF0284C7).withOpacity(0.9),
              foregroundColor: Colors.white,
              tooltip: '打开检修控制台',
              onPressed: () async {
                FocusManager.instance.primaryFocus?.unfocus();
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LogConsoleScreen()),
                );
                FocusManager.instance.primaryFocus?.unfocus();
              },
              child: const Icon(Icons.bug_report, size: 20),
            )
          : null,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          FocusManager.instance.primaryFocus?.unfocus();
        },
        child: Stack(
          children: [
            // 自定义背景图片渲染（支持暗夜模式开关与透明度，使用缓存内存图节约解码开销）
            if (settings.customBackground.isNotEmpty &&
                (!isDark || settings.showBackgroundInDarkMode) &&
                settingsProvider.customBackgroundBytes != null) ...[
              Positioned.fill(
                child: Opacity(
                  opacity: (settings.backgroundOpacity / 100).clamp(0.0, 1.0),
                  child: Image.memory(
                    settingsProvider.customBackgroundBytes!,
                    fit: BoxFit.cover,
                    // 解码期间保持上一帧（与 AppAvatar 对齐）：背景铺满全屏，
                    // 默认行为会在重新解码时把整屏露成底色。
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ],
            Column(
              children: [
                Expanded(
                  child: chat.messages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFF0284C7), Color(0xFF2563EB)],
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Icon(Icons.auto_awesome, color: Colors.white, size: 36),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                '随时向 ${settings.aiName.isNotEmpty ? settings.aiName : 'AI'} 提问',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '原生 Flutter 驱动 · 支持超长思考链 · 毫秒级流式响应',
                                style: TextStyle(
                                  color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        )
                      : NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification is ScrollStartNotification) {
                              if (notification.dragDetails != null) {
                                _isUserInteracting = true;
                              }
                            } else if (notification is UserScrollNotification) {
                              if (notification.direction != ScrollDirection.idle) {
                                _isUserInteracting = true;
                              }
                            } else if (notification is ScrollUpdateNotification) {
                              final metrics = notification.metrics;
                              final distFromBottom = metrics.maxScrollExtent - metrics.pixels;
                              if (distFromBottom > 30) {
                                if (!_userScrolledUp) {
                                  setState(() {
                                    _userScrolledUp = true;
                                  });
                                }
                              } else if (distFromBottom <= 10) {
                                if (_userScrolledUp) {
                                  setState(() {
                                    _userScrolledUp = false;
                                  });
                                }
                              }
                            } else if (notification is ScrollEndNotification) {
                              _isUserInteracting = false;
                              final metrics = notification.metrics;
                              final distFromBottom = metrics.maxScrollExtent - metrics.pixels;
                              if (distFromBottom <= 15 && _userScrolledUp) {
                                setState(() {
                                  _userScrolledUp = false;
                                });
                              }
                            }
                            return false;
                          },
                          child: Stack(
                            children: [
                              ListView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                cacheExtent: 600,
                                addRepaintBoundaries: true,
                                itemCount: chat.messages.length,
                                itemBuilder: (ctx, index) {
                                  final msg = chat.messages[index];
                                  // 检查是否为整个会话中最后一条 Assistant 消息
                                  final isLatestAssistant = msg.role == MessageRole.assistant &&
                                      index == chat.messages.lastIndexWhere((m) => m.role == MessageRole.assistant);
                                  final prev = index > 0 ? chat.messages[index - 1] : null;
                                  final bubble = MessageBubble(
                                    message: msg,
                                    isLatestAssistant: isLatestAssistant,
                                    // 同一发送者的连续消息收紧间距（微信/QQ 那种分组观感），
                                    // 换人时留出更明显的间隔
                                    groupedWithPrev: prev != null && prev.role == msg.role,
                                  );
                                  // 跨天时插一条居中日期分隔（微信/QQ 都有），长会话里定位快很多
                                  if (prev != null && _isSameDay(prev.createdAt, msg.createdAt)) {
                                    return bubble;
                                  }
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      _DateDivider(dateTime: msg.createdAt, isDark: isDark),
                                      bubble,
                                    ],
                                  );
                                },
                              ),
                              // 向上翻历史时给一个"回到最新"的入口：以前只能自己一路划回去
                              if (_userScrolledUp)
                                Positioned(
                                  right: 12,
                                  bottom: 10,
                                  child: Material(
                                    color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                    elevation: 3,
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: () {
                                        _isUserInteracting = false;
                                        if (_userScrolledUp) {
                                          setState(() => _userScrolledUp = false);
                                        }
                                        _scrollToBottom(animate: true, force: true);
                                      },
                                      child: const Padding(
                                        padding: EdgeInsets.all(8),
                                        child: Icon(
                                          Icons.keyboard_double_arrow_down,
                                          size: 20,
                                          color: Color(0xFF0284C7),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
                ChatInputBar(
                  onSend: (text, {attachments, dshImages}) => chat.sendMessage(
                    text,
                    attachments: attachments,
                    dshImages: dshImages,
                  ),
                  onStop: () => chat.stopGeneration(),
                  isGenerating: chat.isGenerating,
                  // 生成中发送：输入栏弹出「插话 / 排队」选择后回调到这里
                  onInterject: (text, {attachments, dshImages}) => chat.interjectMessage(
                    text,
                    attachments: attachments,
                    dshImages: dshImages,
                  ),
                  onEnqueue: (text, {attachments, dshImages}) => chat.enqueueMessage(
                    text,
                    attachments: attachments,
                    dshImages: dshImages,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 跨天时的居中日期分隔条（今天 / 昨天 / 6月12日 / 2025年6月12日）。
///
/// 微信、QQ 以及各家大模型 App 都有这条：长会话里一眼能看出"这是哪天的对话"，
/// 比以前只靠每条消息下方的时刻去推算要直观得多。
class _DateDivider extends StatelessWidget {
  const _DateDivider({required this.dateTime, required this.isDark});

  final DateTime dateTime;
  final bool isDark;

  String get _label {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dateTime.year, dateTime.month, dateTime.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff == 2) return '前天';
    if (dateTime.year == now.year) return '${dateTime.month}月${dateTime.day}日';
    return '${dateTime.year}年${dateTime.month}月${dateTime.day}日';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ),
        ),
      ),
    );
  }
}
