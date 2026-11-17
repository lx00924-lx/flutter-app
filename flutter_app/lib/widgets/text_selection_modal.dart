import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/tts_service.dart';

/// 局部文字选取模态浮层（点击「选取文字」后弹出，精准支持局部拖拽高亮选取，工具栏提供：引用、朗读、复制）
class TextSelectionModal extends StatefulWidget {
  final ChatMessage message;

  const TextSelectionModal({super.key, required this.message});

  static void show(BuildContext context, ChatMessage message) {
    FocusManager.instance.primaryFocus?.unfocus();
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (_) => TextSelectionModal(message: message),
    ).then((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  State<TextSelectionModal> createState() => _TextSelectionModalState();
}

class _TextSelectionModalState extends State<TextSelectionModal> {
  TextSelection? _currentSelection;

  @override
  void dispose() {
    FocusManager.instance.primaryFocus?.unfocus();
    super.dispose();
  }

  /// 只返回**真正选中的那段**；没选中时返回 null。
  ///
  /// ⚠️ 2026-11-18：和 `_getSelectedText` 分开是有意的 —— 那个方法在没选中时
  /// 兜底返回**全文**（给工具栏的「朗读/引用」用，选了才点得到，兜底合理）。
  /// 但底部那个按钮要区分「用户到底选没选」，用兜底值就分不出来了。
  String? get _selectionOnly {
    final sel = _currentSelection;
    if (sel != null && sel.isValid && !sel.isCollapsed) {
      final text = sel.textInside(widget.message.content);
      if (text.trim().isNotEmpty) return text;
    }
    return null;
  }

  String _getSelectedText([EditableTextState? editableTextState]) {
    // 优先从 EditableTextState 获取真实高亮选区
    if (editableTextState != null) {
      final sel = editableTextState.textEditingValue.selection;
      if (sel.isValid && !sel.isCollapsed) {
        return sel.textInside(widget.message.content);
      }
    }
    // 其次从 onSelectionChanged 缓存选区获取
    if (_currentSelection != null && _currentSelection!.isValid && !_currentSelection!.isCollapsed) {
      return _currentSelection!.textInside(widget.message.content);
    }
    // 兜底返回完整内容
    return widget.message.content;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final settings = context.watch<SettingsProvider>().settings;
    final chat = context.read<ChatProvider>();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
          maxWidth: 600,
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部操作提示与关闭按钮
              Row(
                children: [
                  Icon(Icons.format_shapes, color: const Color(0xFF0284C7), size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    '选择文本内容',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(height: 16),

              // 核心可选文本输入区（支持手柄拖拽选中，工具栏含：引用、朗读、复制）
              Flexible(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      widget.message.content,
                      style: TextStyle(
                        fontSize: settings.chatFontSize.toDouble(),
                        height: 1.6,
                        color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                      ),
                      onSelectionChanged: (selection, cause) {
                        // ⚠️ 2026-11-18：这里原来只赋值、**没有 setState**，
                        // 所以底部按钮的文案根本不会跟着选区变。
                        // 只在「有选区 ⇄ 没选区」切换时才重建，拖动过程中
                        // 光标每动一个字都 setState 会白白重建整个弹窗。
                        final hadSelection = _currentSelection != null &&
                            _currentSelection!.isValid &&
                            !_currentSelection!.isCollapsed;
                        final hasSelection = selection.isValid && !selection.isCollapsed;
                        _currentSelection = selection;
                        if (hadSelection != hasSelection) setState(() {});
                      },
                      contextMenuBuilder: (context, editableTextState) {
                        final buttonItems = [
                          ContextMenuButtonItem(
                            label: '引用',
                            onPressed: () {
                              final text = _getSelectedText(editableTextState);
                              final quoteMsg = ChatMessage(
                                id: widget.message.id,
                                sessionId: widget.message.sessionId,
                                role: widget.message.role,
                                content: text,
                                createdAt: widget.message.createdAt,
                              );
                              chat.setQuotedMessage(quoteMsg);
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
                                const SnackBar(
                                  content: Text('已引用所选文字'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                          ContextMenuButtonItem(
                            label: '朗读',
                            onPressed: () {
                              final text = _getSelectedText(editableTextState);
                              context.read<SettingsProvider>().setAutoSpeakResponse(true);
                              TtsService.instance.speak(text, settings);
                              ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
                                const SnackBar(
                                  content: Text('已开始朗读所选文字'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                          ContextMenuButtonItem(
                            label: '复制',
                            onPressed: () {
                              editableTextState.copySelection(SelectionChangedCause.toolbar);
                            },
                          ),
                          ContextMenuButtonItem(
                            label: '全选',
                            onPressed: () {
                              editableTextState.selectAll(SelectionChangedCause.toolbar);
                            },
                          ),
                        ];

                        return AdaptiveTextSelectionToolbar.buttonItems(
                          anchors: editableTextState.contextMenuAnchors,
                          buttonItems: buttonItems,
                        );
                      },
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 底部快捷工具条（全选一键操作）
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // ⚠️ 2026-11-18：**有选中就只读选中的**。
                  // 原来不管选没选都读全文、文案也写死「全部朗读」——
                  // 用户选了半句再点，读的还是整条，文案也没告诉他。
                  OutlinedButton.icon(
                    icon: const Icon(Icons.volume_up_outlined, size: 16),
                    label: Text(_selectionOnly != null ? '朗读所选' : '全部朗读'),
                    onPressed: () {
                      context.read<SettingsProvider>().setAutoSpeakResponse(true);
                      TtsService.instance.speak(
                        _selectionOnly ?? widget.message.content,
                        settings,
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制全部'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.message.content));
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
