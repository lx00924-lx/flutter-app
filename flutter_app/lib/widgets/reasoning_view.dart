import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Agent 的「过程」卡片：思考 / 行动按时间顺序交错排列（对齐 DSH 网页端）。
///
/// 用户要求的样子（原话）：
/// ```
/// 总思维链 {
///    {dsh思考}
///    {dsh行动 … 可展开}
///    {dsh行动}
/// }
/// 提供给用户的消息（宿主自己说的话）
/// ```
/// 所以这里：**思考一行、行动一行**按发生顺序往下排；行动行只显示一行摘要
/// （优先用工具自己的 description），点一下弹出完整参数；宿主对我们说的原话
/// 作为正文样式的段落穿插其中。
///
/// 思考文本保持纯文本正体 —— 中文斜体发飘，而且那是"模型原话"，不该用斜体。
class ReasoningView extends StatefulWidget {
  final String reasoningText;
  final bool isStreaming;
  final int? elapsedSeconds;

  /// 旧消息的兜底：只有步骤列表、没有时间线时用它渲染。
  final List<String> steps;
  final List<String> stepDetails;

  /// **有序**过程时间线（优先使用）。每项：
  /// `{'kind': 'thinking'|'action'|'note'|'text', 'text': 展示文本, 'tool': 工具名, 'detail': 完整参数}`
  final List<Map<String, dynamic>> timeline;

  const ReasoningView({
    super.key,
    required this.reasoningText,
    this.isStreaming = false,
    this.elapsedSeconds,
    this.steps = const [],
    this.stepDetails = const [],
    this.timeline = const [],
  });

  @override
  State<ReasoningView> createState() => _ReasoningViewState();
}

class _ReasoningViewState extends State<ReasoningView> {
  bool _isExpanded = false;

  /// 展开区的最大高度：思考可以很长，不能把正文顶出屏幕外。
  static const double _maxExpandedHeight = 380;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 有时间线用时间线；旧消息退回"步骤列表"（当作 note 项）
    final items = widget.timeline.isNotEmpty
        ? widget.timeline
        : <Map<String, dynamic>>[
            for (var i = 0; i < widget.steps.length; i++)
              {
                'kind': 'note',
                'text': widget.steps[i],
                'tool': '',
                'detail': i < widget.stepDetails.length ? widget.stepDetails[i] : '',
              },
          ];

    final thinkingCount = items.where((e) => e['kind'] == 'thinking').length;
    final actionCount = items.where((e) => e['kind'] == 'action').length;
    final hasThinking = widget.reasoningText.trim().isNotEmpty || thinkingCount > 0;

    final String title;
    if (!hasThinking && actionCount > 0) {
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
                  if (actionCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        '$actionCount 步',
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
                    if (items.isEmpty && hasThinking)
                      SelectableText(
                        widget.reasoningText,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.65,
                          color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                        ),
                      )
                    else
                      for (final item in items) _TimelineRow(item: item, isDark: isDark),
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

/// 时间线里的一项：思考 / 行动 / 提示 / 宿主原话。
class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.item, required this.isDark});

  final Map<String, dynamic> item;
  final bool isDark;

  String get _kind => (item['kind'] ?? 'note').toString();
  String get _rawText => (item['text'] ?? '').toString();
  String get _detail => (item['detail'] ?? '').toString();
  String get _tool => (item['tool'] ?? '').toString();

  /// `🔧 [执行工具] pwsh · 摘要` → `摘要`
  String get _actionSummary {
    final idx = _rawText.indexOf('· ');
    return idx >= 0 ? _rawText.substring(idx + 2).trim() : '';
  }

  /// 行动行左侧的工具名（首字母大写），取不到就写"行动"
  String get _actionLabel {
    final tool = _tool.trim();
    if (tool.isEmpty) return '行动';
    return tool[0].toUpperCase() + tool.substring(1);
  }

  String get _displayText {
    if (_kind == 'action') {
      final summary = _actionSummary;
      return summary.isNotEmpty ? summary : _rawText;
    }
    return _rawText;
  }

  /// 点开能看到的东西：行动看完整参数，思考看全文
  String get _expandableContent {
    if (_detail.trim().isNotEmpty) return _detail;
    if (_kind == 'thinking') return _rawText;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final strong = isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569);

    // 宿主对我们说的话：按正文排版，不当作步骤行
    if (_kind == 'text') {
      return Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 10),
        child: SelectableText(
          _rawText,
          style: TextStyle(fontSize: 13.5, height: 1.6, color: strong),
        ),
      );
    }

    final expandable = _expandableContent.trim().isNotEmpty;
    final isAction = _kind == 'action';
    final isThinking = _kind == 'thinking';

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            isAction
                ? Icons.terminal
                : isThinking
                    ? Icons.psychology_outlined
                    : Icons.chevron_right,
            size: 14,
            color: isAction
                ? (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7))
                : muted,
          ),
        ),
        const SizedBox(width: 6),
        if (isAction || isThinking)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              isAction ? _actionLabel : '思考',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: isAction
                    ? (isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0369A1))
                    : muted,
              ),
            ),
          ),
        Expanded(
          child: Text(
            _displayText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: muted),
          ),
        ),
        if (expandable)
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 1),
            child: Icon(
              Icons.unfold_more,
              size: 14,
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
            ),
          ),
      ],
    );

    final content = Padding(
      padding: EdgeInsets.only(bottom: isThinking ? 8 : 4, top: 1),
      child: row,
    );

    if (!expandable) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _showDetail(context),
      child: content,
    );
  }

  void _showDetail(BuildContext context) {
    final body = _expandableContent;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          _kind == 'action' ? '${_actionLabel} · 完整参数' : '思考全文',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
          child: SingleChildScrollView(
            child: SelectableText(
              body,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                fontFamily: _kind == 'action' ? 'monospace' : null,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: body));
              Navigator.pop(ctx);
            },
            child: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
