import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_settings.dart';
import '../models/chat_session.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/tts_service.dart';
import '../utils/image_picker_helper.dart';
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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
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

  void _showRenameSessionDialog(BuildContext context, ChatSession session) {
    final controller = TextEditingController(text: session.title);
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
    );
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
      _scrollToBottom(animate: !isSessionSwitched);
    } else if (chat.isGenerating) {
      _scrollToBottom(animate: false);
    }

    final displayName = settings.aiName.isNotEmpty
        ? '${settings.aiName} (${settings.activeModelDisplayName})'
        : settings.activeModelDisplayName;

    return Scaffold(
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
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const VoiceCallScreen()),
            ),
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
                leading: const Icon(Icons.tune_outlined, size: 20),
                title: const Text('会话管理与备份', style: TextStyle(fontSize: 13)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SessionManagementScreen()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined, size: 20),
                title: const Text('系统设置', style: TextStyle(fontSize: 13)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
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
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LogConsoleScreen()),
                );
              },
              child: const Icon(Icons.bug_report, size: 20),
            )
          : null,
      body: Stack(
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
                              '随时向 ${settings.aiName.isNotEmpty ? settings.aiName : 'DeepSeek'} 提问',
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
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        cacheExtent: 600,
                        addRepaintBoundaries: true,
                        itemCount: chat.messages.length,
                        itemBuilder: (ctx, index) {
                          return MessageBubble(message: chat.messages[index]);
                        },
                      ),
              ),
              ChatInputBar(
                onSend: (text, {attachments}) => chat.sendMessage(text, attachments: attachments),
                onStop: () => chat.stopGeneration(),
                isGenerating: chat.isGenerating,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
