import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/image_picker_helper.dart';
import 'reasoning_view.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  static final Map<String, Uint8List> _attachmentBytesCache = {};

  static Uint8List? _getAttachmentBytes(String base64Str) {
    if (_attachmentBytesCache.containsKey(base64Str)) {
      return _attachmentBytesCache[base64Str];
    }
    final bytes = ImagePickerHelper.decodeBase64Image(base64Str);
    if (bytes != null) {
      if (_attachmentBytesCache.length > 50) {
        _attachmentBytesCache.remove(_attachmentBytesCache.keys.first);
      }
      _attachmentBytesCache[base64Str] = bytes;
    }
    return bytes;
  }

  static Widget _buildSelectionContextMenu(
      BuildContext context, SelectableRegionState selectableRegionState) {
    final List<ContextMenuButtonItem> buttonItems =
        selectableRegionState.contextMenuButtonItems;
    final List<ContextMenuButtonItem> customItems = [];
    for (final item in buttonItems) {
      if (item.type == ContextMenuButtonType.copy) {
        customItems.add(
          ContextMenuButtonItem(
            label: '复制',
            onPressed: item.onPressed,
          ),
        );
      } else if (item.type == ContextMenuButtonType.selectAll) {
        customItems.add(
          ContextMenuButtonItem(
            label: '全选',
            onPressed: item.onPressed,
          ),
        );
      }
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: customItems,
    );
  }

  const MessageBubble({super.key, required this.message});

  void _showMessageActionSheet(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chat = context.read<ChatProvider>();

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.copy, color: Color(0xFF0284C7)),
                title: const Text('复制文本'),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: message.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制到剪贴板'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.format_quote, color: Color(0xFF0284C7)),
                title: const Text('引用此消息'),
                onTap: () {
                  Navigator.pop(ctx);
                  chat.setQuotedMessage(message);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已引用该消息，输入回复后发送'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('删除此条消息', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteMessage(context, chat);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDeleteMessage(BuildContext context, ChatProvider chat) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除单条消息'),
        content: const Text('确定要从当前会话中删除这条消息记录吗？此操作不可逆。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              chat.deleteMessage(message.id);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已删除该条消息'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final settingsProvider = context.watch<SettingsProvider>();
    final settings = settingsProvider.settings;
    final chat = context.read<ChatProvider>();

    final userAvatarBytes = settingsProvider.userAvatarBytes;
    final aiAvatarBytes = settingsProvider.aiAvatarBytes;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF0284C7).withOpacity(0.15),
              backgroundImage: aiAvatarBytes != null ? MemoryImage(aiAvatarBytes) : null,
              child: aiAvatarBytes == null
                  ? Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF0284C7), Color(0xFF2563EB)],
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(Icons.smart_toy_outlined, color: Colors.white, size: 20),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
          ],
          if (isUser && message.status == 'error') ...[
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 10),
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.error, color: Colors.redAccent, size: 22),
                tooltip: '发送失败，点击重新发送',
                onPressed: () async {
                  final success = await chat.resendMessage(message.id);
                  if (!success && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('网络仍未连接，请检查网络通畅度后重试'),
                        backgroundColor: Colors.redAccent,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
            ),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: () => _showMessageActionSheet(context),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.8,
                ),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isUser
                      ? (isDark ? const Color(0xFF0284C7) : const Color(0xFF0284C7))
                      : (isDark ? const Color(0xFF1E293B) : Colors.white),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isUser ? 16 : 4),
                    bottomRight: Radius.circular(isUser ? 4 : 16),
                  ),
                  border: isUser
                      ? null
                      : Border.all(
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                          width: 1,
                        ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.03),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 图片附件展示 (完全脱离 SelectionArea，避免灰度蒙层与拦截手势)
                    if (message.attachments != null && message.attachments!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: message.attachments!.map((att) {
                            final imgBytes = _getAttachmentBytes(att);
                            if (imgBytes == null) return const SizedBox.shrink();
                            return GestureDetector(
                              onTap: () {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => Dialog(
                                    backgroundColor: Colors.transparent,
                                    insetPadding: const EdgeInsets.all(12),
                                    child: Stack(
                                      alignment: Alignment.topRight,
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(16),
                                          child: Image.memory(imgBytes, fit: BoxFit.contain),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.close, color: Colors.white, size: 28),
                                          onPressed: () => Navigator.pop(ctx),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.memory(
                                  imgBytes,
                                  width: 140,
                                  height: 140,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                    // 思考链展示
                    if (message.reasoningContent != null &&
                        message.reasoningContent!.isNotEmpty)
                      ReasoningView(
                        reasoningText: message.reasoningContent!,
                        isStreaming: message.isStreaming && message.content.isEmpty,
                        elapsedSeconds: message.elapsedSeconds,
                      ),

                    // 正文渲染 (精确定位 SelectionArea 仅包裹纯文本，彻底解决灰度蒙层遮挡及滑动冲突)
                    if (isUser)
                      if (message.content.isNotEmpty)
                        SelectionArea(
                          contextMenuBuilder: _buildSelectionContextMenu,
                          child: Text(
                            message.content,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: settings.chatFontSize.toDouble(),
                              height: 1.4,
                            ),
                          ),
                        )
                      else
                        const SizedBox.shrink()
                    else
                      SelectionArea(
                        contextMenuBuilder: _buildSelectionContextMenu,
                        child: MarkdownBody(
                          data: message.content.isEmpty && message.isStreaming ? '正在思考中...' : message.content,
                          selectable: false,
                          styleSheet: MarkdownStyleSheet(
                            p: TextStyle(
                              fontSize: settings.chatFontSize.toDouble(),
                              height: 1.6,
                              color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                            ),
                            listBullet: TextStyle(
                              fontSize: settings.chatFontSize.toDouble(),
                              color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                            ),
                            code: TextStyle(
                              backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                              fontFamily: 'monospace',
                              fontSize: (settings.chatFontSize - 2).toDouble().clamp(11, 24),
                            ),
                            codeblockDecoration: BoxDecoration(
                              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // 底部操作栏（复制、引用、删除）
                    if (!isUser && !message.isStreaming && message.content.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.copy, size: 16),
                            tooltip: '复制',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: message.content));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制到剪贴板'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 14),
                          IconButton(
                            icon: const Icon(Icons.format_quote, size: 17),
                            tooltip: '引用',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                            onPressed: () {
                              chat.setQuotedMessage(message);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已引用该消息'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 14),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 17),
                            tooltip: '删除',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                            onPressed: () {
                              _confirmDeleteMessage(context, chat);
                            },
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 10),
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF0284C7).withOpacity(0.15),
              backgroundImage: userAvatarBytes != null ? MemoryImage(userAvatarBytes) : null,
              child: userAvatarBytes == null
                  ? Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xFF0284C7), Color(0xFF0EA5E9)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person, color: Colors.white, size: 20),
                    )
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}
