import 'package:flutter/material.dart';

/// Agent 的「思考 / 执行步骤」卡片。
///
/// 排版对齐 DSH（用户拿来对照的就是它）：
/// - **思考**显示宿主那份真实思考，纯文本原样展示：不加 `>` 引用前缀、**不用斜体**
///   （中文斜体发飘，而且"模型原话"用斜体也不符合语义 —— 用户点名要去掉）；
/// - **执行步骤**（派发 / 工具调用 / 完成）单独列一块，不再和思考拼进同一个字符串。
///   以前两者混在一起，看上去就像"思维链 = 一串工具调用"。
class ReasoningView extends StatefulWidget {
  final String reasoningText;
  final bool isStreaming;
  final int? elapsedSeconds;

  /// 这一轮的执行步骤（电脑端派发 / 工具调用 / 完成）。为空则不显示该区块。
  final List<String> steps;

  const ReasoningView({
    super.key,
    required this.reasoningText,
    this.isStreaming = false,
    this.elapsedSeconds,
    this.steps = const [],
  });

  @override
  State<ReasoningView> createState() => _ReasoningViewState();
}

class _ReasoningViewState extends State<ReasoningView> {
  bool _isExpanded = false;

  /// 展开区的最大高度：思考可以很长，不能把正文顶出屏幕外。
  static const double _maxExpandedHeight = 360;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasThinking = widget.reasoningText.trim().isNotEmpty;
    final steps = widget.steps.where((s) => s.trim().isNotEmpty).toList();

    final String title;
    if (!hasThinking && steps.isNotEmpty) {
      title = widget.isStreaming ? '正在电脑端执行…' : '电脑端执行记录';
    } else if (widget.isStreaming) {
      title = '正在深度思考中...';
    } else {
      title = '已深度思考 ${widget.elapsedSeconds != null ? "(${widget.elapsedSeconds}秒)" : ""}'.trim();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF16213A) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_alt_outlined,
                    size: 18,
                    color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                      ),
                    ),
                  ),
                  if (steps.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        '${steps.length} 步',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                  Icon(
                    _isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 18,
                    color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded) ...[
            const Divider(height: 1, thickness: 0.5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _maxExpandedHeight),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 思考正文：纯文本、无斜体。中文斜体在手机上可读性差，且这里是
                    // "模型原话"，应当和正文一样的正体排版。
                    SelectableText(
                      hasThinking ? widget.reasoningText : '（本轮没有思考内容）',
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.65,
                        color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                      ),
                    ),
                    if (steps.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            Icons.checklist_rtl_outlined,
                            size: 14,
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '执行步骤',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      for (final step in steps)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: SelectableText(
                            step,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.5,
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
