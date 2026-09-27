import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_message.dart';

/// 打开某一轮 Agent 执行的「执行详情」页。
///
/// 用途定位（用户原话）：**事后排查** —— 出问题时能回头看清它到底调了什么工具、
/// 参数是什么、输出是什么。
///
/// 为什么不放在聊天气泡里：工具参数与输出动辄几 KB（原始 JSON、日志回显），铺在对话
/// 里又长又吵，而 90% 的阅读场景根本不需要。所以气泡里只留一行摘要 + 紧凑行列表，
/// 重内容全部收进这一页 —— 要看的人点进来，不看的人永远不被打扰。
void showAgentExecutionDetail(BuildContext context, ChatMessage message) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => AgentExecutionDetailScreen(message: message)),
  );
}

class AgentExecutionDetailScreen extends StatelessWidget {
  const AgentExecutionDetailScreen({super.key, required this.message});

  final ChatMessage message;

  AgentExecutionRecord? get _record => message.agentExecution;

  bool get _hasTrace {
    final record = _record;
    if (record == null) return false;
    return record.timeline.isNotEmpty || record.steps.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final record = _record;
    final items = record == null || record.timeline.isEmpty
        ? <Map<String, dynamic>>[
            if (record != null)
              for (var i = 0; i < record.steps.length; i++)
                {
                  'kind': 'note',
                  'text': record.steps[i],
                  'tool': '',
                  'detail': i < record.stepDetails.length ? record.stepDetails[i] : '',
                },
          ]
        : record.timeline;

    return Scaffold(
      appBar: AppBar(
        title: const Text('执行详情', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          if (_hasTrace)
            IconButton(
              tooltip: '复制全部过程',
              icon: const Icon(Icons.copy_all_outlined, size: 20),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _buildPlainText(items)));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制整轮执行过程'), duration: Duration(seconds: 1)),
                );
              },
            ),
        ],
      ),
      body: !_hasTrace
          ? Center(
              child: Text(
                '这一轮没有可展示的执行过程',
                style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
              children: [
                _summaryCard(context, record),
                const SizedBox(height: 14),
                for (final item in items) _timelineBlock(context, item),
                if ((record?.rawOutput ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _rawOutputBlock(context, record!.rawOutput!.trim()),
                ],
              ],
            ),
    );
  }

  // ── 顶部摘要：状态 / 步数 / 用时 ───────────────────────────────────────────
  Widget _summaryCard(BuildContext context, AgentExecutionRecord? record) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = record?.status ?? 'completed';
    final (label, color) = switch (status) {
      'failed' => ('执行失败', const Color(0xFFDC2626)),
      'cancelled' => ('已中止', const Color(0xFFF59E0B)),
      _ => ('已完成', const Color(0xFF10B981)),
    };
    final stepCount = record?.timeline.where((e) => e['kind'] == 'action').length ??
        record?.steps.length ??
        0;
    final elapsed = message.elapsedSeconds;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF16213A) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 9, color: color),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
          _metaText('$stepCount 步'),
          if (elapsed != null) _metaText('用时 ${_formatDuration(elapsed)}'),
          _metaText(_formatTime(message.createdAt)),
        ],
      ),
    );
  }

  Widget _metaText(String text) {
    return Builder(builder: (context) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Text(
        text,
        style: TextStyle(fontSize: 12.5, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
      );
    });
  }

  // ── 单个时间线条目 ─────────────────────────────────────────────────────────
  Widget _timelineBlock(BuildContext context, Map<String, dynamic> item) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final kind = (item['kind'] ?? 'note').toString();
    final text = (item['text'] ?? '').toString();
    final tool = (item['tool'] ?? '').toString();
    final detail = (item['detail'] ?? '').toString();
    final result = (item['result'] ?? '').toString();
    final failed = (item['status'] ?? '') == 'error';

    if (kind == 'note') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SelectableText(
          text,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          ),
        ),
      );
    }

    final title = switch (kind) {
      'thinking' => '思考',
      'action' => tool.isEmpty ? '行动' : '${tool[0].toUpperCase()}${tool.substring(1)}',
      _ => kind,
    };
    final summary = kind == 'action' && text.contains('· ')
        ? text.substring(text.indexOf('· ') + 2).trim()
        : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: failed
              ? const Color(0xFFDC2626)
              : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 6, 7),
            child: Row(
              children: [
                Icon(
                  kind == 'thinking' ? Icons.psychology_outlined : Icons.terminal,
                  size: 15,
                  color: failed
                      ? const Color(0xFFDC2626)
                      : (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7)),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
                  ),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (failed)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Text('失败', style: TextStyle(fontSize: 11.5, color: Color(0xFFDC2626))),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 0.5),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (kind == 'thinking')
                  _codeText(text, isDark, mono: false)
                else ...[
                  if (detail.trim().isNotEmpty) ...[
                    _sectionLabel('参数', isDark),
                    _codeText(detail, isDark),
                  ],
                  if (result.trim().isNotEmpty) ...[
                    if (detail.trim().isNotEmpty) const SizedBox(height: 10),
                    _sectionLabel('输出', isDark),
                    _codeText(result, isDark),
                  ],
                  if (detail.trim().isEmpty && result.trim().isEmpty)
                    Text(
                      '（这个工具没有参数与输出记录）',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
        ),
      ),
    );
  }

  Widget _codeText(String text, bool isDark, {bool mono = true}) {
    return SelectableText(
      text,
      style: TextStyle(
        fontSize: 12.5,
        height: 1.5,
        fontFamily: mono ? 'monospace' : null,
        color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
      ),
    );
  }

  Widget _rawOutputBlock(BuildContext context, String raw) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('宿主原始输出', isDark),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF16213A) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
          ),
          child: _codeText(raw, isDark, mono: false),
        ),
      ],
    );
  }

  /// 整轮过程的纯文本导出（供"复制全部"）：排查时可以直接贴给别人看。
  String _buildPlainText(List<Map<String, dynamic>> items) {
    final buffer = StringBuffer();
    buffer.writeln('=== LxAI 执行详情 ===');
    buffer.writeln('时间：${_formatTime(message.createdAt)}');
    if (message.elapsedSeconds != null) buffer.writeln('用时：${_formatDuration(message.elapsedSeconds!)}');
    buffer.writeln('状态：${_record?.status ?? 'completed'}');
    buffer.writeln();
    for (final item in items) {
      final kind = (item['kind'] ?? 'note').toString();
      final text = (item['text'] ?? '').toString();
      final tool = (item['tool'] ?? '').toString();
      final detail = (item['detail'] ?? '').toString();
      final result = (item['result'] ?? '').toString();
      if (kind == 'thinking') {
        buffer.writeln('[思考] $text');
      } else if (kind == 'action') {
        buffer.writeln('[行动] ${tool.isEmpty ? '工具' : tool} · $text');
        if (detail.trim().isNotEmpty) buffer.writeln('  参数：$detail');
        if (result.trim().isNotEmpty) buffer.writeln('  输出：$result');
      } else {
        buffer.writeln('[过程] $text');
      }
      buffer.writeln();
    }
    if (message.content.trim().isNotEmpty) {
      buffer.writeln('=== 宿主对用户说的话 ===');
      buffer.writeln(message.content.trim());
    }
    if ((_record?.rawOutput ?? '').trim().isNotEmpty) {
      buffer.writeln();
      buffer.writeln('=== 宿主原始输出 ===');
      buffer.writeln(_record!.rawOutput!.trim());
    }
    return buffer.toString();
  }

  static String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '$minutes 分' : '$minutes 分 $rest 秒';
  }

  static String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}
