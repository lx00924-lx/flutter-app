import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppLogItem {
  final DateTime time;
  final String level; // INFO, WARN, ERROR, DEBUG
  final String tag;
  final String message;

  AppLogItem({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });
}

class AppLogger {
  static final AppLogger instance = AppLogger._();
  AppLogger._() {
    // 预置系统初始化日志
    log('INFO', 'System', 'App logger initialized.');
    log('INFO', 'Database', 'Hive local database connected (sessions, messages, settings).');
    log('INFO', 'Network', 'HTTP & SSE streaming channels ready.');
  }

  final List<AppLogItem> _logs = [];
  final List<VoidCallback> _listeners = [];

  List<AppLogItem> get logs => List.unmodifiable(_logs);

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void log(String level, String tag, String message) {
    final item = AppLogItem(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );
    _logs.add(item);
    if (_logs.length > 500) {
      _logs.removeAt(0); // 最多保留 500 条
    }
    for (var l in _listeners) {
      l();
    }
  }

  void clear() {
    _logs.clear();
    log('INFO', 'System', 'Logs cleared by user.');
    for (var l in _listeners) {
      l();
    }
  }

  String exportAsString() {
    return _logs
        .map((e) =>
            '[${e.time.toIso8601String().substring(11, 19)}] [${e.level}] [${e.tag}] ${e.message}')
        .join('\n');
  }
}

class LogConsoleScreen extends StatefulWidget {
  const LogConsoleScreen({super.key});

  @override
  State<LogConsoleScreen> createState() => _LogConsoleScreenState();
}

class _LogConsoleScreenState extends State<LogConsoleScreen> {
  final AppLogger _logger = AppLogger.instance;
  String _filterLevel = 'ALL';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _logger.addListener(_onLogsUpdated);
  }

  @override
  void dispose() {
    _logger.removeListener(_onLogsUpdated);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onLogsUpdated() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final filtered = _logger.logs.where((l) {
      if (_filterLevel != 'ALL' && l.level != _filterLevel) return false;
      final q = _searchCtrl.text.trim().toLowerCase();
      if (q.isNotEmpty) {
        return l.message.toLowerCase().contains(q) || l.tag.toLowerCase().contains(q);
      }
      return true;
    }).toList().reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.terminal, color: Color(0xFF0284C7)),
            SizedBox(width: 8),
            Text('APP 检修与调试控制台', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: '复制全部日志',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _logger.exportAsString()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制完整日志到剪贴板')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空日志',
            onPressed: () {
              _logger.clear();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('日志已清空')),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索与过滤筛选栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
              border: Border(
                bottom: BorderSide(
                  color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(fontSize: 13),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: '搜索日志关键词或模块...',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                      ),
                      prefixIcon: const Icon(Icons.search, size: 16),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _filterLevel,
                  underline: const SizedBox.shrink(),
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.bold,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'ALL', child: Text('全部级别')),
                    DropdownMenuItem(value: 'INFO', child: Text('INFO')),
                    DropdownMenuItem(value: 'WARN', child: Text('WARN')),
                    DropdownMenuItem(value: 'ERROR', child: Text('ERROR')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _filterLevel = val);
                  },
                ),
              ],
            ),
          ),

          // 核心控制台终端展示流
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 48,
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '暂无符合条件的日志记录',
                          style: TextStyle(
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, idx) {
                      final item = filtered[idx];
                      Color levelColor = const Color(0xFF10B981);
                      if (item.level == 'WARN') levelColor = const Color(0xFFF59E0B);
                      if (item.level == 'ERROR') levelColor = const Color(0xFFEF4444);

                      final timeStr = item.time.toIso8601String().substring(11, 19);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF1E293B) : Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: levelColor.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    item.level,
                                    style: TextStyle(
                                      color: levelColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '[${item.tag}]',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  timeStr,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            SelectableText(
                              item.message,
                              style: TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                                color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
