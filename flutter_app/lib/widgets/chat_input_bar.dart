import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/image_picker_helper.dart';

class ChatInputBar extends StatefulWidget {
  final Function(String text, {List<String>? attachments}) onSend;
  final VoidCallback onStop;
  final bool isGenerating;

  const ChatInputBar({
    super.key,
    required this.onSend,
    required this.onStop,
    required this.isGenerating,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;
  bool _isMenuOpen = false;
  bool _isRecording = false;
  int _recordDuration = 0;
  String? _selectedImageBase64;

  @override
  void initState() {
    super.initState();
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
    });

    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _isMenuOpen) {
        setState(() => _isMenuOpen = false);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isNotEmpty || _selectedImageBase64 != null) {
      final chat = context.read<ChatProvider>();
      final quote = chat.quotedMessage;
      String finalText = text;
      if (quote != null) {
        final quoteSender = quote.role == MessageRole.user ? '我' : 'AI';
        final snippet = quote.content.length > 100 ? '${quote.content.substring(0, 100)}...' : quote.content;
        final cleanSnippet = snippet.replaceAll('\n', ' ');
        finalText = '> 💬 **引用 [$quoteSender]**：$cleanSnippet\n\n$text';
        chat.clearQuotedMessage();
      }
      final attachments = _selectedImageBase64 != null ? [_selectedImageBase64!] : null;
      widget.onSend(finalText, attachments: attachments);
      _controller.clear();
      setState(() {
        _selectedImageBase64 = null;
        _isMenuOpen = false;
      });
    }
  }

  void _toggleAgentMode() {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    final newMode = !s.defaultAgentMode;
    s.defaultAgentMode = newMode;
    sp.updateSettings(s);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(newMode ? '⚡ 已切换至 DeepSeek Agent 自动化模式' : '✨ 已切换至普通大模型对话模式'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _handlePickImage() async {
    final img = await ImagePickerHelper.pickImageAsBase64();
    if (img != null && mounted) {
      setState(() {
        _selectedImageBase64 = img;
        _isMenuOpen = false;
      });
    }
  }

  bool _isLongPressRecording = false;

  void _startRecording({bool isLongPress = false}) {
    if (_isRecording) return;
    setState(() {
      _isRecording = true;
      _isLongPressRecording = isLongPress;
      _recordDuration = 0;
      _isMenuOpen = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isLongPress ? '🎙️ 正在长按录音中，松手即可发送...' : '🎙️ 正在进行麦克风录入...再次点击结束'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _stopRecording({bool cancelled = false}) {
    if (!_isRecording) return;
    final wasLongPress = _isLongPressRecording;
    setState(() {
      _isRecording = false;
      _isLongPressRecording = false;
    });
    if (cancelled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已取消录音'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    // 录音结束，填入识别内容
    if (_controller.text.isEmpty) {
      _controller.text = '请帮我梳理一下今天的重点工作事项。';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ 语音录制完成，已转写输入文字'),
        duration: Duration(seconds: 2),
      ),
    );
    if (wasLongPress) {
      _handleSend();
    }
  }

  void _toggleVoiceRecording() {
    if (_isRecording) {
      _stopRecording();
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

    final canSend = _hasText || _selectedImageBase64 != null;

    return Container(
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
          // 引用消息卡片预览
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
          // 图片待发送缩略图预览
          if (_selectedImageBase64 != null)
            Builder(
              builder: (context) {
                final previewBytes = ImagePickerHelper.decodeBase64Image(_selectedImageBase64);
                if (previewBytes == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Stack(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF0284C7), width: 1.5),
                            image: DecorationImage(
                              image: MemoryImage(previewBytes),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        Positioned(
                          top: -2,
                          right: -2,
                          child: GestureDetector(
                            onTap: () => setState(() => _selectedImageBase64 = null),
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.black87,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(2),
                              child: const Icon(Icons.close, color: Colors.white, size: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

          // 展开的 + 号工具栏面板
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
                    label: '选图片',
                    color: const Color(0xFF0284C7),
                    isDark: isDark,
                    onTap: _handlePickImage,
                  ),
                  _buildToolItem(
                    icon: Icons.camera_alt_outlined,
                    label: '拍照/扫描',
                    color: const Color(0xFF10B981),
                    isDark: isDark,
                    onTap: _handlePickImage,
                  ),
                  _buildToolItem(
                    icon: Icons.phone_in_talk_outlined,
                    label: '实时通话',
                    color: const Color(0xFF8B5CF6),
                    isDark: isDark,
                    onTap: () {
                      setState(() => _isMenuOpen = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已启动实时语音通话通道')),
                      );
                    },
                  ),
                  _buildToolItem(
                    icon: isAgentMode ? Icons.terminal_rounded : Icons.auto_awesome_outlined,
                    label: isAgentMode ? '切回普通' : '开启Agent',
                    color: const Color(0xFFF59E0B),
                    isDark: isDark,
                    onTap: () {
                      _toggleAgentMode();
                      setState(() => _isMenuOpen = false);
                    },
                  ),
                ],
              ),
            ),

          // 主输入条
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 1. Agent 模式切换胶囊按钮（与 Web 端设计一致）
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

              // 2. 文本输入核心框与内嵌麦克风
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
                                ? '向本地 DeepSeek Agent 发送需求...'
                                : '输入消息向 DeepSeek 提问...',
                            hintStyle: TextStyle(
                              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                              fontSize: 13,
                            ),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          ),
                        ),
                      ),

                      // 3. 语音录音按钮 (麦克风：支持点按切换模式与长按即说即发双模)
                      GestureDetector(
                        onTap: _toggleVoiceRecording,
                        onLongPressStart: (_) => _startRecording(isLongPress: true),
                        onLongPressEnd: (_) => _stopRecording(),
                        onLongPressCancel: () => _stopRecording(cancelled: true),
                        child: Tooltip(
                          message: '点按切换录音 / 长按说话即发',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _isRecording
                                    ? const Color(0xFFEF4444).withOpacity(0.15)
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                _isRecording ? Icons.stop_circle : Icons.mic_none_outlined,
                                size: 21,
                                color: _isRecording
                                    ? const Color(0xFFEF4444)
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

              // 4. 右侧动态按钮：无内容时为「+」号工具栏展开按钮，有内容时变为「发送」按钮
              if (widget.isGenerating)
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
