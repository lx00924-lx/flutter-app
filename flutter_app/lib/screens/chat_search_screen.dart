import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../providers/chat_provider.dart';
import '../services/storage_service.dart';

class ChatSearchScreen extends StatefulWidget {
  const ChatSearchScreen({super.key});

  @override
  State<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends State<ChatSearchScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<ChatMessage> _allMessages = [];
  Map<String, ChatSession> _sessionsMap = {};

  List<ChatMessage> _filteredMessages = [];
  int _currentHighlightIndex = 0;

  DateTime? _selectedDate;
  bool _onlyImages = false;

  final Map<int, GlobalKey> _itemKeys = {};

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _loadData() {
    final storage = StorageService.instance;
    final sessions = storage.getAllSessions();
    final messages = storage.getAllMessages();

    setState(() {
      _allMessages = messages;
      _sessionsMap = {for (var s in sessions) s.id: s};
      _applyFilter();
    });
  }

  void _onSearchChanged() {
    _applyFilter();
  }

  void _applyFilter() {
    final query = _searchCtrl.text.trim().toLowerCase();
    final now = DateTime.now();

    List<ChatMessage> result = _allMessages.where((msg) {
      // 1. 只看图片过滤
      if (_onlyImages) {
        if (msg.attachments == null || msg.attachments!.isEmpty) {
          return false;
        }
      }

      // 2. 日期过滤
      if (_selectedDate != null) {
        final d = msg.createdAt;
        final isSameDate = d.year == _selectedDate!.year &&
            d.month == _selectedDate!.month &&
            d.day == _selectedDate!.day;
        if (!isSameDate) return false;
      }

      // 3. 关键词模糊搜索
      if (query.isNotEmpty) {
        // 支持对自然语言常用日期词（如"昨天"、"今天"）做相对日期匹配
        bool matchesRelativeDate = false;
        if (query == '昨天') {
          final yesterday = now.subtract(const Duration(days: 1));
          matchesRelativeDate = msg.createdAt.year == yesterday.year &&
              msg.createdAt.month == yesterday.month &&
              msg.createdAt.day == yesterday.day;
        } else if (query == '今天') {
          matchesRelativeDate = msg.createdAt.year == now.year &&
              msg.createdAt.month == now.month &&
              msg.createdAt.day == now.day;
        }

        final contentMatches = msg.content.toLowerCase().contains(query);
        final reasoningMatches = msg.reasoningContent?.toLowerCase().contains(query) ?? false;
        final sessionTitle = _sessionsMap[msg.sessionId]?.title.toLowerCase() ?? '';
        final sessionMatches = sessionTitle.contains(query);

        if (!contentMatches && !reasoningMatches && !sessionMatches && !matchesRelativeDate) {
          return false;
        }
      }

      return true;
    }).toList();

    setState(() {
      _filteredMessages = result;
      _currentHighlightIndex = 0;
      _itemKeys.clear();
      for (int i = 0; i < _filteredMessages.length; i++) {
        _itemKeys[i] = GlobalKey();
      }
    });

    if (_filteredMessages.isNotEmpty) {
      _scrollToCurrentItem();
    }
  }

  void _previousMatch() {
    if (_filteredMessages.isEmpty) return;
    setState(() {
      if (_currentHighlightIndex > 0) {
        _currentHighlightIndex--;
      } else {
        _currentHighlightIndex = _filteredMessages.length - 1; // 循环跳转到最后一条
      }
    });
    _scrollToCurrentItem();
  }

  void _nextMatch() {
    if (_filteredMessages.isEmpty) return;
    setState(() {
      if (_currentHighlightIndex < _filteredMessages.length - 1) {
        _currentHighlightIndex++;
      } else {
        _currentHighlightIndex = 0; // 循环跳转到第一条
      }
    });
    _scrollToCurrentItem();
  }

  void _scrollToCurrentItem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _itemKeys[_currentHighlightIndex];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.3,
        );
      }
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(2020),
      lastDate: now,
      helpText: '选择检索日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
      _applyFilter();
    }
  }

  void _jumpToSession(ChatMessage msg) {
    final session = _sessionsMap[msg.sessionId];
    if (session != null) {
      final chat = context.read<ChatProvider>();
      chat.selectSession(session);
      // 返回并提示已进入所属会话
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已定位至会话: ${session.title}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = const Color(0xFF0284C7);

    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天记录检索与定位'),
        elevation: 0,
      ),
      body: Column(
        children: [
          // 顶部检索工具栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : Colors.white,
              border: Border(
                bottom: BorderSide(
                  color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                ),
              ),
            ),
            child: Column(
              children: [
                // 模糊输入框 + 上下翻滚控制按钮
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: InputDecoration(
                          hintText: '搜索聊天内容或关键词 (如: 昨天、代码、报错)',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _searchCtrl.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                  },
                                )
                              : null,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          filled: true,
                          fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // 检索结果序号指示器
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _filteredMessages.isEmpty
                            ? '0条'
                            : '${_currentHighlightIndex + 1}/${_filteredMessages.length}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: _filteredMessages.isNotEmpty ? primaryColor : Colors.grey,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),

                    // 上一条按钮
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_up),
                      tooltip: '上一条',
                      onPressed: _filteredMessages.isNotEmpty ? _previousMatch : null,
                    ),

                    // 下一条按钮
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down),
                      tooltip: '下一条',
                      onPressed: _filteredMessages.isNotEmpty ? _nextMatch : null,
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // 过滤标签栏 (日期选择、只看图片)
                Row(
                  children: [
                    // 按日期筛选
                    ActionChip(
                      avatar: Icon(
                        Icons.calendar_today_outlined,
                        size: 15,
                        color: _selectedDate != null ? Colors.white : primaryColor,
                      ),
                      label: Text(
                        _selectedDate == null
                            ? '选择日期'
                            : '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: 12,
                          color: _selectedDate != null ? Colors.white : null,
                        ),
                      ),
                      backgroundColor: _selectedDate != null ? primaryColor : null,
                      onPressed: _pickDate,
                    ),
                    if (_selectedDate != null) ...[
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () {
                          setState(() => _selectedDate = null);
                          _applyFilter();
                        },
                        child: const Icon(Icons.cancel, size: 16, color: Colors.grey),
                      ),
                    ],
                    const SizedBox(width: 10),

                    // 只显示图片
                    FilterChip(
                      avatar: Icon(
                        Icons.photo_outlined,
                        size: 16,
                        color: _onlyImages ? Colors.white : primaryColor,
                      ),
                      label: Text(
                        '只显示图片',
                        style: TextStyle(
                          fontSize: 12,
                          color: _onlyImages ? Colors.white : null,
                        ),
                      ),
                      selected: _onlyImages,
                      selectedColor: primaryColor,
                      onSelected: (val) {
                        setState(() => _onlyImages = val);
                        _applyFilter();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 结果列表
          Expanded(
            child: _filteredMessages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.find_in_page_outlined,
                          size: 56,
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _searchCtrl.text.isNotEmpty || _selectedDate != null || _onlyImages
                              ? '未检索到符合条件的聊天记录'
                              : '输入关键词或选择日期开始检索',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    itemCount: _filteredMessages.length,
                    itemBuilder: (context, index) {
                      final msg = _filteredMessages[index];
                      final isCurrent = index == _currentHighlightIndex;
                      final isUser = msg.role == MessageRole.user;
                      final session = _sessionsMap[msg.sessionId];
                      final sessionTitle = session?.title ?? '未知会话';

                      return Container(
                        key: _itemKeys[index],
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: isDark
                              ? (isCurrent ? const Color(0xFF1E293B) : const Color(0xFF0F172A))
                              : (isCurrent ? const Color(0xFFEFF6FF) : Colors.white),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isCurrent
                                ? primaryColor
                                : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                            width: isCurrent ? 2 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.02),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            setState(() => _currentHighlightIndex = index);
                            _jumpToSession(msg);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 头部：会话名称 + 角色 + 时间
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isUser
                                            ? primaryColor.withOpacity(0.15)
                                            : Colors.purple.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isUser ? '我' : 'AI',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isUser ? primaryColor : Colors.purple,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        sessionTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _formatDate(msg.createdAt),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                // 正文
                                Text(
                                  msg.content.isEmpty && msg.reasoningContent != null
                                      ? '[思考中] ${msg.reasoningContent!}'
                                      : msg.content,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                    color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                                  ),
                                ),

                                // 图片缩略图
                                if (msg.attachments != null && msg.attachments!.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    children: msg.attachments!.map((base64Str) {
                                      try {
                                        return ClipRRect(
                                          borderRadius: BorderRadius.circular(6),
                                          child: Image.memory(
                                            base64Decode(base64Str),
                                            width: 48,
                                            height: 48,
                                            fit: BoxFit.cover,
                                          ),
                                        );
                                      } catch (_) {
                                        return const SizedBox.shrink();
                                      }
                                    }).toList(),
                                  ),
                                ],

                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    '点击跳转至该会话 ➔',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: primaryColor,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
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
    );
  }
}
