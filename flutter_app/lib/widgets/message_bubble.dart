import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/tts_service.dart';
import '../utils/image_picker_helper.dart';
import 'app_avatar.dart';
import '../screens/agent_execution_detail_screen.dart';
import 'reasoning_view.dart';
import 'text_selection_modal.dart';
import 'voice_message_bubble.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isLatestAssistant;

  /// 是否与上一条同属一个"发送者分组"（同角色连续消息）：
  /// 用来收紧行间距，做出微信/QQ 那种一段一段的观感。
  final bool groupedWithPrev;

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
    this.groupedWithPrev = false,
  });

  /// 类似 Windows 右键的就地气泡菜单（弹出：引用、删除、朗读、选取文字、复制）
  void _showContextMenuAt(BuildContext context, Offset tapPosition) {
    FocusManager.instance.primaryFocus?.unfocus();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chat = context.read<ChatProvider>();
    final settings = context.read<SettingsProvider>().settings;
    final isAgent = message.isAgentMode || settings.defaultAgentMode;

    // 有没有过程可看：落库的那份，或本轮正在实时收集的那份 —— 跑着的时候
    // agentExecution 还是空的，不能只判断它，否则菜单项会时有时无
    final hasTrace = (message.agentExecution?.timeline.isNotEmpty ?? false) ||
        (message.agentExecution?.steps.isNotEmpty ?? false) ||
        (message.isStreaming && (chat.liveTimeline.isNotEmpty || chat.liveSteps.isNotEmpty));

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
        if (hasTrace)
          PopupMenuItem<String>(
            value: 'trace',
            height: 40,
            child: Row(
              children: [
                Icon(Icons.account_tree_outlined, size: 18, color: isDark ? Colors.lightBlueAccent : const Color(0xFF0284C7)),
                const SizedBox(width: 10),
                const Text('执行详情', style: TextStyle(fontSize: 14)),
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
      FocusManager.instance.primaryFocus?.unfocus();
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
        case 'trace':
          showAgentExecutionDetail(context, message, chat: chat);
          break;
        case 'select':
          FocusManager.instance.primaryFocus?.unfocus();
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (ctx) => TextSelectionModal(message: message),
          ).then((_) {
            FocusManager.instance.primaryFocus?.unfocus();
          });
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

    // 执行步骤：已完成的消息用自己那份记录；正在流式的用本轮实时收集的那份
    // （宿主是边跑边推的，agentExecution 要等 done 才有，中间这段时间界面得看得到）。
    // 详情（完整工具参数）与步骤一一对应，供点击展开。
    final liveSteps = message.isStreaming ? chat.liveSteps : const <String>[];
    final liveDetails = message.isStreaming ? chat.liveStepDetails : const <String>[];
    final liveTimeline = message.isStreaming ? chat.liveTimeline : const <Map<String, dynamic>>[];
    final steps = (message.agentExecution?.steps.isNotEmpty ?? false)
        ? message.agentExecution!.steps
        : liveSteps;
    final stepDetails = (message.agentExecution?.stepDetails.isNotEmpty ?? false)
        ? message.agentExecution!.stepDetails
        : liveDetails;
    // 有序时间线（思考/行动/原话交错）：优先用它渲染，旧消息退回步骤列表
    final timeline = (message.agentExecution?.timeline.isNotEmpty ?? false)
        ? message.agentExecution!.timeline
        : liveTimeline;

    final userAvatarBytes = settingsProvider.userAvatarBytes;
    final aiAvatarBytes = settingsProvider.aiAvatarBytes;

    final hasImagesOnly = (message.attachments != null &&
        message.attachments!.isNotEmpty &&
        message.attachments!.every((att) => !isAudioAttachment(att) && !isFileAttachment(att)) &&
        message.content.isEmpty &&
        (message.reasoningContent == null || message.reasoningContent!.isEmpty));

    Offset? tapPosition;

    return Padding(
      // 分组间距：同一发送者的连续消息贴紧，换人时留出更明显的间隔
      padding: EdgeInsets.fromLTRB(16, groupedWithPrev ? 2 : 8, 16, 4),
      child: Column(
        // 头像移到气泡**上方**单独一行：气泡因此能吃满可用宽度（用户要求：
        // "会话框生成在头像下面，以获取更宽的会话框宽度"）。同一发送者的连续消息
        // 只在分组第一条显示头像，避免每行都多占一行高度。
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!groupedWithPrev)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: AppAvatar(
                imageBytes: isUser ? userAvatarBytes : aiAvatarBytes,
                radius: 18,
                fallbackIcon: isUser ? Icons.person : Icons.smart_toy_outlined,
                fallbackBgColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE0F2FE),
                fallbackIconColor: const Color(0xFF0284C7),
              ),
            ),
          Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isUser && message.status == 'error')
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
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment:
                      isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
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
                  // 头像已经移到气泡上方单独一行，气泡可以用满宽度（用户要求"更宽"）：
                  // 以前是屏幕宽度的 78%，且还要让出头像那 46px。
                  maxWidth: MediaQuery.of(context).size.width - 44,
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

                    // 思考链 + 执行步骤（DSH 式：思考/行动按时间交错）
                    if ((message.reasoningContent != null &&
                            message.reasoningContent!.isNotEmpty) ||
                        steps.isNotEmpty ||
                        timeline.isNotEmpty)
                      ReasoningView(
                        reasoningText: message.reasoningContent ?? '',
                        isStreaming: message.isStreaming && message.content.isEmpty,
                        elapsedSeconds: message.elapsedSeconds,
                        steps: steps,
                        stepDetails: stepDetails,
                        timeline: timeline,
                        // 重内容（工具参数/输出）都在「执行详情」页，气泡里只留索引
                        onOpenDetail: (timeline.isNotEmpty || steps.isNotEmpty)
                            ? () => showAgentExecutionDetail(context, message, chat: chat)
                            : null,
                      ),

                    // 正文渲染
                    if (isUser)
                      if (message.content.isNotEmpty)
                        Text(
                          message.content,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: settings.chatFontSize.toDouble(),
                            height: 1.5,
                          ),
                        )
                      else
                        const SizedBox.shrink()
                    else
                      _CollapsibleMarkdownBody(
                        data: message.content.isEmpty && message.isStreaming ? '正在思考中...' : message.content,
                        isDark: isDark,
                        // 流式期间不折叠：内容还在长，折起来反而看不清进度
                        collapsible: !message.isStreaming,
                        // 气泡底色：折起来时底部渐隐要盖在它上面
                        fadeColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                        builders: {'pre': _CodeBlockBuilder(isDark: isDark)},
                        styleSheet: MarkdownStyleSheet(
                          p: TextStyle(
                            fontSize: settings.chatFontSize.toDouble(),
                            height: 1.62,
                            color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                          ),
                          // 标题层级：以前没配，全靠默认值 —— 手机上行距与正文不一致、
                          // 上下也不留白，长回答读起来"糊成一团"。
                          h1: TextStyle(
                            fontSize: (settings.chatFontSize + 4).toDouble(),
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                            color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                          ),
                          h2: TextStyle(
                            fontSize: (settings.chatFontSize + 2).toDouble(),
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                            color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                          ),
                          h3: TextStyle(
                            fontSize: (settings.chatFontSize + 1).toDouble(),
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                            color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
                          ),
                          listBullet: TextStyle(
                            fontSize: settings.chatFontSize.toDouble(),
                            height: 1.6,
                            color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                          ),
                          // 段间距 / 列表缩进：让多段长回答有呼吸感（聊天阅读体验）
                          blockSpacing: 8,
                          listIndent: 20,
                          blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                          blockquoteDecoration: BoxDecoration(
                            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(6),
                            border: Border(
                              left: BorderSide(
                                color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                                width: 3,
                              ),
                            ),
                          ),
                          a: TextStyle(
                            color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                            decoration: TextDecoration.underline,
                          ),
                          code: TextStyle(
                            backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                            fontFamily: 'monospace',
                            fontSize: (settings.chatFontSize - 2).toDouble().clamp(11, 24),
                          ),
                          codeblockPadding: const EdgeInsets.all(10),
                          codeblockDecoration: BoxDecoration(
                            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                            ),
                          ),
                        ),
                      ),
                    // 流式输出时的打字光标：比干巴巴一句"正在思考中..."更像在说话
                    if (!isUser && message.isStreaming) const _TypingCursor(),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
                    ),
                    // 时间戳移出气泡：透明背景、跟在气泡下方（用户要求）
                    _buildTimeLabel(isDark, isUser),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 气泡外的时间戳（透明背景，不再是气泡里的一行）——用户要求：
  /// 时间应该在聊天框外面，且不要有任何底色。
  Widget _buildTimeLabel(bool isDark, bool isUser) {
    return Padding(
      padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
      child: Text(
        _formatMessageTime(message.createdAt),
        textAlign: isUser ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
          // 用户要求：时间戳由灰色改为黑色。亮色模式下用近黑（与正文同色系，
          // 比纯黑更耐看）；暗色模式下纯黑会直接看不见，所以用浅色。
          color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF111827),
        ),
      ),
    );
  }
}

/// 超长回答先折起来：默认只露前 [collapsedHeight] 像素，底部渐隐 + 一个「展开全文」。
///
/// 各家客户端的常见做法：一屏读不完的长回答不让用户一路滑，想看全文点一下即可。
/// 折叠用"限高 + 裁剪"而不是截断文本，避免把 Markdown 语法从中间切断。
class _CollapsibleMarkdownBody extends StatefulWidget {
  const _CollapsibleMarkdownBody({
    required this.data,
    required this.styleSheet,
    required this.isDark,
    required this.fadeColor,
    this.builders = const {},
    this.collapsible = true,
  });

  final String data;
  final MarkdownStyleSheet styleSheet;
  final bool isDark;

  /// 气泡底色：折起来时底部渐隐要盖在它上面
  final Color fadeColor;
  final Map<String, MarkdownElementBuilder> builders;
  final bool collapsible;

  /// 超过这么多字符才折（短回答折起来反而多一次点击）
  static const int threshold = 1200;
  static const double collapsedHeight = 340;

  @override
  State<_CollapsibleMarkdownBody> createState() => _CollapsibleMarkdownBodyState();
}

class _CollapsibleMarkdownBodyState extends State<_CollapsibleMarkdownBody> {
  bool _expanded = false;

  bool get _foldable =>
      widget.collapsible && widget.data.length > _CollapsibleMarkdownBody.threshold;

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: widget.data,
      selectable: false,
      styleSheet: widget.styleSheet,
      builders: widget.builders,
    );
    if (!_foldable || _expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          body,
          if (_foldable) _toggleButton(expand: false),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _CollapsibleMarkdownBody.collapsedHeight),
              child: ClipRect(child: body),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 44,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [widget.fadeColor.withAlpha(0), widget.fadeColor],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        _toggleButton(expand: true),
      ],
    );
  }

  Widget _toggleButton({required bool expand}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => setState(() => _expanded = expand),
        icon: Icon(expand ? Icons.expand_more : Icons.expand_less, size: 16),
        label: Text(expand ? '展开全文' : '收起', style: const TextStyle(fontSize: 12.5)),
      ),
    );
  }
}

/// 代码块：等宽、灰底、**横向滚动不换行**，右上角一键复制。
///
/// 以前走默认渲染：长命令会被硬换行折断，也没法直接复制。
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.isDark});

  final bool isDark;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return _CodeBlockView(code: element.textContent.trimRight(), isDark: isDark);
  }
}

class _CodeBlockView extends StatelessWidget {
  const _CodeBlockView({required this.code, required this.isDark});

  final String code;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 10),
              Text('代码', style: TextStyle(fontSize: 11, color: muted)),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('代码已复制'), duration: Duration(seconds: 1)),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy_all_outlined, size: 13, color: muted),
                      const SizedBox(width: 4),
                      Text('复制', style: TextStyle(fontSize: 11.5, color: muted)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Divider(height: 1, thickness: 0.5, color: borderColor),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: SelectableText(
              code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.45,
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 流式输出中的打字光标（各家大模型客户端的通用提示）。
///
/// 以前正文区只写一句静态的"正在思考中..."，看不出"还在继续输出"还是"卡住了"。
class _TypingCursor extends StatefulWidget {
  const _TypingCursor();

  @override
  State<_TypingCursor> createState() => _TypingCursorState();
}

class _TypingCursorState extends State<_TypingCursor> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.2, end: 1.0).animate(_controller),
        child: Container(
          width: 7,
          height: 14,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
      ),
    );
  }
}
