import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/chat_session.dart';
import '../providers/chat_provider.dart';
import '../services/storage_service.dart';
import 'chat_search_screen.dart';

class SessionManagementScreen extends StatefulWidget {
  const SessionManagementScreen({super.key});

  @override
  State<SessionManagementScreen> createState() => _SessionManagementScreenState();
}

class _SessionManagementScreenState extends State<SessionManagementScreen> {
  bool _isBatchMode = false;
  final Set<String> _selectedIds = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchKeyword = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() {
        _searchKeyword = _searchCtrl.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // 单选删除二次确认
  void _confirmDeleteSingle(ChatSession session) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text('删除会话'),
          ],
        ),
        content: Text(
          '确定要彻底删除会话「${session.title}」及其全部聊天记录吗？\n\n此操作不可逆，请谨慎操作。',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
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
              context.read<ChatProvider>().deleteSession(session.id);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已删除会话「${session.title}」')),
              );
            },
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  // 批量删除二次确认
  void _confirmBatchDelete(List<String> ids) {
    if (ids.isEmpty) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text('批量删除会话'),
          ],
        ),
        content: Text(
          '确定要彻底删除选中的 ${ids.length} 个会话及其全部聊天记录吗？\n\n这些会话的数据将被永久清除，无法恢复。',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
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
              final count = ids.length;
              context.read<ChatProvider>().deleteSessions(ids);
              setState(() {
                _selectedIds.clear();
                _isBatchMode = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('成功批量删除 $count 个会话')),
              );
            },
            child: const Text('确认彻底删除'),
          ),
        ],
      ),
    );
  }

  // 导出全量数据
  void _exportAll() {
    final data = StorageService.instance.exportAllData();
    _showExportResultDialog(data, '全部聊天记录备份');
  }

  // 导出选中的数据
  void _exportSelected(List<String> ids) {
    if (ids.isEmpty) return;
    final data = StorageService.instance.exportSelectedSessions(ids);
    _showExportResultDialog(data, '所选 ${ids.length} 个会话备份');
  }

  void _showExportResultDialog(Map<String, dynamic> data, String title) {
    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    final sessionList = (data['sessions'] as List?) ?? [];
    final messageList = (data['messages'] as List?) ?? [];
    final byteCount = utf8.encode(jsonStr).length;
    final kbSize = (byteCount / 1024).toStringAsFixed(1);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导出成功 - $title'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('包含会话: ${sessionList.length} 个', style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Text('包含消息: ${messageList.length} 条', style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Text('数据大小: $kbSize KB', style: const TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 12),
            Container(
              height: 120,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF1E293B)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: Text(
                  jsonStr,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制 JSON 内容'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: jsonStr));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已将备份 JSON 复制到剪贴板！')),
              );
            },
          ),
        ],
      ),
    );
  }

  // 导入数据
  void _importData() {
    final textCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入合并聊天记录'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '请粘贴导出的 JSON 备份数据：',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: textCtrl,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: '{\n  "sessions": [...],\n  "messages": [...]\n}',
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final raw = textCtrl.text.trim();
              if (raw.isEmpty) return;
              try {
                final parsed = json.decode(raw);
                if (parsed is! Map<String, dynamic>) {
                  throw Exception('JSON 格式必须包含对象根节点');
                }
                final count = await StorageService.instance.importData(parsed);
                if (mounted) {
                  context.read<ChatProvider>().reloadFromStorage();
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('成功导入 $count 条记录！')),
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('解析导入失败: $e')),
                );
              }
            },
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final allSessions = chat.sessions;
    final currentSession = chat.currentSession;

    // 过滤会话
    final filteredSessions = allSessions.where((s) {
      if (_searchKeyword.isEmpty) return true;
      final modelStr = s.model ?? '';
      return s.title.toLowerCase().contains(_searchKeyword) ||
          modelStr.toLowerCase().contains(_searchKeyword);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_isBatchMode ? '已选 ${_selectedIds.length} 项' : '会话管理'),
        actions: [
          if (!_isBatchMode) ...[
            if (allSessions.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.checklist_rtl, size: 18),
                label: const Text('批量管理'),
                onPressed: () {
                  setState(() {
                    _isBatchMode = true;
                    _selectedIds.clear();
                  });
                },
              ),
          ] else ...[
            TextButton(
              onPressed: () {
                setState(() {
                  if (_selectedIds.length == filteredSessions.length) {
                    _selectedIds.clear();
                  } else {
                    _selectedIds.addAll(filteredSessions.map((s) => s.id));
                  }
                });
              },
              child: Text(_selectedIds.length == filteredSessions.length ? '全不选' : '全选'),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '退出批量模式',
              onPressed: () {
                setState(() {
                  _isBatchMode = false;
                  _selectedIds.clear();
                });
              },
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // 顶部检索与数据备份操作工具条
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              children: [
                // 搜索框
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: '搜索会话标题或模型...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchKeyword.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => _searchCtrl.clear(),
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (!_isBatchMode) ...[
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.manage_search, size: 16),
                          label: const Text('聊天记录检索', style: TextStyle(fontSize: 12)),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const ChatSearchScreen()),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.file_upload_outlined, size: 16),
                          label: const Text('导出全部记录', style: TextStyle(fontSize: 12)),
                          onPressed: _exportAll,
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.file_download_outlined, size: 16),
                          label: const Text('导入备份数据', style: TextStyle(fontSize: 12)),
                          onPressed: _importData,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),

          // 会话卡片列表
          Expanded(
            child: filteredSessions.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 56,
                          color: isDark ? Colors.white24 : Colors.black26,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _searchKeyword.isNotEmpty ? '未检索到匹配的会话' : '暂无会话记录',
                          style: const TextStyle(fontSize: 15, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filteredSessions.length,
                    itemBuilder: (ctx, index) {
                      final s = filteredSessions[index];
                      final isActive = s.id == currentSession?.id;
                      final isSelected = _selectedIds.contains(s.id);
                      final msgCount = chat.getMessageCount(s.id);

                      return Card(
                        elevation: isActive ? 2 : 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: isSelected
                                ? const Color(0xFF0284C7)
                                : isActive
                                    ? const Color(0xFF0284C7).withOpacity(0.8)
                                    : (isDark
                                        ? const Color(0xFF334155)
                                        : const Color(0xFFE2E8F0)),
                            width: isSelected || isActive ? 2 : 1,
                          ),
                        ),
                        margin: const EdgeInsets.only(bottom: 12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            if (_isBatchMode) {
                              setState(() {
                                if (isSelected) {
                                  _selectedIds.remove(s.id);
                                } else {
                                  _selectedIds.add(s.id);
                                }
                              });
                            } else {
                              if (!isActive) {
                                chat.selectSession(s);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('已切换至会话「${s.title}」')),
                                );
                              }
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                if (_isBatchMode) ...[
                                  Checkbox(
                                    value: isSelected,
                                    activeColor: const Color(0xFF0284C7),
                                    onChanged: (val) {
                                      setState(() {
                                        if (val == true) {
                                          _selectedIds.add(s.id);
                                        } else {
                                          _selectedIds.remove(s.id);
                                        }
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? const Color(0xFF0284C7).withOpacity(0.15)
                                        : (isDark
                                            ? const Color(0xFF1E293B)
                                            : const Color(0xFFF1F5F9)),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    Icons.chat_bubble_outline,
                                    color: isActive ? const Color(0xFF0284C7) : Colors.grey,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              s.title,
                                              style: TextStyle(
                                                fontSize: 15,
                                                fontWeight: isActive
                                                    ? FontWeight.bold
                                                    : FontWeight.w600,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (isActive) ...[
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF0284C7),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: const Text(
                                                '当前使用',
                                                style: TextStyle(
                                                    color: Colors.white, fontSize: 10),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Text(
                                            '模型: ${s.model}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: isDark
                                                  ? const Color(0xFF94A3B8)
                                                  : const Color(0xFF64748B),
                                            ),
                                          ),
                                          const Text(' • ',
                                              style: TextStyle(color: Colors.grey)),
                                          Text(
                                            '$msgCount 条记录',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: isDark
                                                  ? const Color(0xFF94A3B8)
                                                  : const Color(0xFF64748B),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '更新时间: ${s.updatedAt.month}月${s.updatedAt.day}日 ${s.updatedAt.hour.toString().padLeft(2, '0')}:${s.updatedAt.minute.toString().padLeft(2, '0')}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (!_isBatchMode) ...[
                                  if (!isActive)
                                    TextButton(
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        foregroundColor: const Color(0xFF0284C7),
                                      ),
                                      onPressed: () {
                                        chat.selectSession(s);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('已切换至「${s.title}」')),
                                        );
                                      },
                                      child: const Text('切换'),
                                    ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 20, color: Colors.redAccent),
                                    tooltip: '删除会话',
                                    onPressed: () => _confirmDeleteSingle(s),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _isBatchMode
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A) : Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        label: Text('导出所选 (${_selectedIds.length})'),
                        onPressed: _selectedIds.isEmpty
                            ? null
                            : () => _exportSelected(_selectedIds.toList()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: Text('批量删除 (${_selectedIds.length})'),
                        onPressed: _selectedIds.isEmpty
                            ? null
                            : () => _confirmBatchDelete(_selectedIds.toList()),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}
