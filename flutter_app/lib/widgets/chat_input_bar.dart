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
import '../utils/image_picker_helper.dart';
import '../screens/voice_call_screen.dart';
import '../screens/scanner_screen.dart';
import 'agent_quick_bar.dart';

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

  void _handleSend() {
    final text = _controller.text.trim();
    final hasAttachments = _pendingAttachments.isNotEmpty || _recordedPendingAudioUri != null;

    if (text.isNotEmpty || hasAttachments) {
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

      final List<String> attachments = List.from(_pendingAttachments);
      if (_recordedPendingAudioUri != null) {
        attachments.add(_recordedPendingAudioUri!);
      }

      widget.onSend(
        finalText,
        attachments: attachments.isNotEmpty ? attachments : null,
      );

      _controller.clear();
      setState(() {
        _pendingAttachments.clear();
        _pendingFileDisplayNames.clear();
        _recordedPendingAudioUri = null;
        _recordedPendingAudioSec = 0;
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

              // 5. 主输入条
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

                  // 3. 右侧按钮：生成中为停止，有内容或有附件为发送，否则展开工具栏
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
