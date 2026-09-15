import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/tts_service.dart';
import '../utils/image_picker_helper.dart';
import 'app_avatar.dart';
import 'reasoning_view.dart';
import 'text_selection_modal.dart';
import 'voice_message_bubble.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isLatestAssistant;

  static final Map<String, Uint8List> _attachmentBytesCache = {};
  static final Map<String, ImageProvider> _imageProviderCache = {};

  static bool isAudioAttachment(String att) {
    return att.startsWith('data:audio/');
  }

  static bool isFileAttachment(String att) {
    return att.startsWith('data:application/octet-stream');
  }

  static String getFileNameFromAttachment(String att) {
    try {
      final match = RegExp(r'name=([^;]+)').firstMatch(att);
      if (match != null) {
        return Uri.decodeComponent(match.group(1) ?? '文件');
      }
    } catch (_) {}
    return '文件';
  }

  static Uint8List? _getAttachmentBytes(String base64Str) {
    if (isAudioAttachment(base64Str) || isFileAttachment(base64Str)) return null;
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

  static ImageProvider? _getImageProvider(String att) {
    final localPath = ImagePickerHelper.extractLocalPathFromAttachment(att);
    final isLocalFilePresent = localPath != null && localPath.isNotEmpty && File(localPath).existsSync();
    if (isLocalFilePresent) {
      return _imageProviderCache.putIfAbsent(localPath, () => FileImage(File(localPath)));
    }
    final bytes = _getAttachmentBytes(att);
    if (bytes != null) {
      return _imageProviderCache.putIfAbsent(att, () => MemoryImage(bytes));
    }
    return null;
  }

  const MessageBubble({
    super.key,
    required this.message,
    this.isLatestAssistant = false,
  });

  /// 类似 Windows 右键的就地气泡菜单（弹出：引用、删除、朗读、选取文字、复制）
  void _showContextMenuAt(BuildContext context, Offset tapPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chat = context.read<ChatProvider>();
    final settings = context.read<SettingsProvider>().settings;
    final isAgent = message.isAgentMode || settings.defaultAgentMode;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        tapPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      items: [
        PopupMenuItem<String>(
          value: 'quote',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.reply, size: 18, color: isDark ? Colors.lightBlueAccent : const Color(0xFF0284C7)),
              const SizedBox(width: 10),
              const Text('引用', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'read',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.volume_up_outlined, size: 18, color: isDark ? Colors.amberAccent : Colors.orange),
              const SizedBox(width: 10),
              const Text('朗读', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'select',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.format_shapes, size: 18, color: isDark ? Colors.tealAccent : Colors.teal),
              const SizedBox(width: 10),
              const Text('选取文字', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.copy, size: 18, color: isDark ? Colors.greenAccent : Colors.green.shade700),
              const SizedBox(width: 10),
              const Text('复制', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        if (isLatestAssistant && !isAgent)
          PopupMenuItem<String>(
            value: 'regenerate',
            height: 40,
            child: Row(
              children: [
                Icon(Icons.refresh_rounded, size: 18, color: isDark ? Colors.cyanAccent : const Color(0xFF0284C7)),
                const SizedBox(width: 10),
                const Text('重新生成', style: TextStyle(fontSize: 14)),
              ],
            ),
          ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem<String>(
          value: 'delete',
          height: 40,
          child: Row(
            children: const [
              Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
              SizedBox(width: 10),
              Text('删除', style: TextStyle(fontSize: 14, color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    ).then((selected) {
      if (selected == null) return;
      switch (selected) {
        case 'quote':
          chat.setQuotedMessage(message);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已引用该消息'),
              duration: Duration(seconds: 1),
            ),
          );
          break;
        case 'read':
          context.read<SettingsProvider>().setAutoSpeakResponse(true);
          TtsService.instance.speak(message.content, settings);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('正在朗读消息...'),
              duration: Duration(seconds: 1),
            ),
          );
          break;
        case 'select':
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (ctx) => TextSelectionModal(message: message),
          );
          break;
        case 'copy':
          Clipboard.setData(ClipboardData(text: message.content));
          break;
        case 'regenerate':
          chat.regenerateLatestAssistantMessage(message.id);
          break;
        case 'delete':
          _confirmDeleteMessage(context, chat);
          break;
      }
    });
  }

  void _confirmDeleteMessage(BuildContext context, ChatProvider chat) {
    // 隐藏软键盘，避免操作弹窗关闭后键盘自动弹起
    FocusManager.instance.primaryFocus?.unfocus();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: const Text('确定要删除这条消息吗？此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              Navigator.pop(ctx);
              chat.deleteMessage(message.id);
            },
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  /// 格式化时间（24小时制，根据日期与时段精确拟人化）
  String _formatMessageTime(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDate = DateTime(dt.year, dt.month, dt.day);
    final diffDays = today.difference(msgDate).inDays;

    final hourStr = dt.hour.toString().padLeft(2, '0');
    final minStr = dt.minute.toString().padLeft(2, '0');
    final timeStr = '$hourStr:$minStr';

    // 判断时段：0-5 凌晨，6-10 早晨，11-13 中午，14-18 下午，19-23 夜晚
    String period;
    final h = dt.hour;
    if (h >= 0 && h < 6) {
      period = '凌晨';
    } else if (h >= 6 && h < 11) {
      period = '早晨';
    } else if (h >= 11 && h < 14) {
      period = '中午';
    } else if (h >= 14 && h < 19) {
      period = '下午';
    } else {
      period = '夜晚';
    }

    if (diffDays == 0) {
      return '$period $timeStr';
    } else if (diffDays == 1) {
      return '昨天 $timeStr';
    } else if (diffDays == 2) {
      return '前天 $timeStr';
    } else if (dt.year == now.year) {
      return '${dt.month}月${dt.day}日 $timeStr';
    } else {
      return '${dt.year}年${dt.month}月${dt.day}日 $timeStr';
    }
  }

  /// 渲染单张图片附件（优先加载本地原图，原图被清理或不存在时优雅回显缩略图并标注状态）
  Widget _buildImageAttachmentWidget(BuildContext context, String att, bool hasImagesOnly, bool isUser) {
    final localPath = ImagePickerHelper.extractLocalPathFromAttachment(att);
    final isLocalFilePresent = localPath != null && localPath.isNotEmpty && File(localPath).existsSync();
    final imgProvider = _getImageProvider(att);

    if (imgProvider == null) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                  child: Image(
                    image: imgProvider,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isLocalFilePresent ? Icons.hd_outlined : Icons.photo_outlined,
                          color: Colors.white,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isLocalFilePresent ? '本地超清原图' : '缩略图 (原图已清理)',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
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
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: hasImagesOnly
                ? BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isUser ? 16 : 4),
                    bottomRight: Radius.circular(isUser ? 4 : 16),
                  )
                : BorderRadius.circular(10),
            child: Container(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
              child: Image(
                image: imgProvider,
                width: double.infinity,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (ctx, err, stack) => Container(
                  height: 120,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image_outlined, color: Colors.grey, size: 36),
                ),
              ),
            ),
          ),
          // 状态标签
          Positioned(
            bottom: 6,
            right: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isLocalFilePresent ? Icons.hd_outlined : Icons.broken_image_outlined,
                    color: Colors.white70,
                    size: 11,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    isLocalFilePresent ? '原图' : '缩略图',
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                ],
              ),
            ),
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

    final hasImagesOnly = (message.attachments != null &&
        message.attachments!.isNotEmpty &&
        message.attachments!.every((att) => !isAudioAttachment(att) && !isFileAttachment(att)) &&
        message.content.isEmpty &&
        (message.reasoningContent == null || message.reasoningContent!.isEmpty));

    Offset? tapPosition;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            AppAvatar(
              imageBytes: aiAvatarBytes,
              radius: 18,
              fallbackIcon: Icons.smart_toy_outlined,
              fallbackBgColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE0F2FE),
              fallbackIconColor: const Color(0xFF0284C7),
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
              onTapDown: (details) {
                tapPosition = details.globalPosition;
              },
              onLongPress: () {
                final pos = tapPosition ??
                    Offset(
                      MediaQuery.of(context).size.width / 2,
                      MediaQuery.of(context).size.height / 2,
                    );
                _showContextMenuAt(context, pos);
              },
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                padding: hasImagesOnly ? EdgeInsets.zero : const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isUser
                      ? const Color(0xFF0284C7)
                      : (isDark ? const Color(0xFF1E293B) : const Color(0xFFFFFFFF)),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isUser ? 16 : 4),
                    bottomRight: Radius.circular(isUser ? 4 : 16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 附件渲染 (语音、通用文件、图片)
                    if (message.attachments != null && message.attachments!.isNotEmpty)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 1. 语音附件
                          ...message.attachments!.where((att) => isAudioAttachment(att)).map((att) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: VoiceMessageBubble(
                                audioDataUri: att,
                                isUser: isUser,
                              ),
                            );
                          }),
                          // 2. 通用文件附件
                          ...message.attachments!.where((att) => isFileAttachment(att)).map((att) {
                            final fileName = getFileNameFromAttachment(att);
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? Colors.white.withOpacity(0.18)
                                    : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9)),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isUser
                                      ? Colors.white.withOpacity(0.3)
                                      : (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.insert_drive_file_outlined,
                                    size: 20,
                                    color: isUser ? Colors.white : const Color(0xFF0284C7),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      fileName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: isUser
                                            ? Colors.white
                                            : (isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1E293B)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                          // 3. 图片附件 (支持原图优先与清理后缩略图降级回显)
                          ...message.attachments!
                              .where((att) => !isAudioAttachment(att) && !isFileAttachment(att))
                              .map((att) => _buildImageAttachmentWidget(context, att, hasImagesOnly, isUser)),
                          if (!hasImagesOnly && message.content.isNotEmpty)
                            const SizedBox(height: 8),
                        ],
                      ),

                    // 思考链展示
                    if (message.reasoningContent != null &&
                        message.reasoningContent!.isNotEmpty)
                      ReasoningView(
                        reasoningText: message.reasoningContent!,
                        isStreaming: message.isStreaming && message.content.isEmpty,
                        elapsedSeconds: message.elapsedSeconds,
                      ),

                    // 正文渲染
                    if (isUser)
                      if (message.content.isNotEmpty)
                        Text(
                          message.content,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: settings.chatFontSize.toDouble(),
                            height: 1.4,
                          ),
                        )
                      else
                        const SizedBox.shrink()
                    else
                      MarkdownBody(
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
                    const SizedBox(height: 4),
                    Align(
                      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Text(
                        _formatMessageTime(message.createdAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: isUser
                              ? Colors.white.withOpacity(0.72)
                              : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 10),
            AppAvatar(
              imageBytes: userAvatarBytes,
              radius: 18,
              fallbackIcon: Icons.person,
              fallbackBgColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE0F2FE),
              fallbackIconColor: const Color(0xFF0284C7),
            ),
          ],
        ],
      ),
    );
  }
}
