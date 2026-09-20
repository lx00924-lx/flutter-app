import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';

/// 聊天输入框上方的「Agent 快捷栏」。
///
/// 只在 Agent 模式打开时显示，把四个最常改的选项提到手边：
///   工作区 / 目标会话 / 思考深度 / 执行权限
/// 关闭 Agent 模式后整条自动隐藏（由调用方判断，见 chat_input_bar）。
///
/// 工作区与会话列表与「设置 → DeepSeek Harness」共用 `SettingsProvider` 里的
/// 同一份缓存：都是电脑端 DSH 的真实目录，取不到就显示"暂无"，不编假选项。
class AgentQuickBar extends StatefulWidget {
  const AgentQuickBar({super.key});

  @override
  State<AgentQuickBar> createState() => _AgentQuickBarState();
}

class _AgentQuickBarState extends State<AgentQuickBar> {
  bool _isCreatingSession = false;
  bool _requestedCatalog = false;

  static const String _newSessionOption = '__lx_new_session__';

  static const Map<String, String> _reasoningLabels = {
    'high': '高',
    'medium': '中',
    'low': '低',
  };

  static const Map<String, String> _permissionLabels = {
    'read-only': '只读',
    'workspace-write': '工作区可写',
    'full-access': '完全访问',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureCatalog());
  }

  /// 目录为空且还没取过时，自动拉一次（不打扰用户）。
  Future<void> _ensureCatalog() async {
    if (!mounted || _requestedCatalog) return;
    final sp = context.read<SettingsProvider>();
    if (sp.agentCatalogLoaded || sp.agentCatalogLoading) return;
    _requestedCatalog = true;
    await sp.refreshAgentCatalog();
    if (mounted) setState(() {});
  }

  Future<void> _pickWorkspace(String value) async {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    setState(() {
      s.targetWorkspace = value;
      // 换了工作区，原会话基本不属于它了，回到「新建会话」
      s.targetSessionId = '';
    });
    sp.updateSettings(s);
  }

  Future<void> _pickSession(String value) async {
    final sp = context.read<SettingsProvider>();
    if (value != _newSessionOption) {
      final s = sp.settings;
      s.targetSessionId = value;
      sp.updateSettings(s);
      setState(() {});
      return;
    }
    await _createSession();
  }

  /// 「新建会话」：立刻在电脑端建一个并选中，之后消息都发进它。
  Future<void> _createSession() async {
    final sp = context.read<SettingsProvider>();
    if (sp.settings.isHarnessOnline != true) {
      _toast('电脑端桥接未在线，无法新建会话', isError: true);
      return;
    }
    setState(() => _isCreatingSession = true);
    try {
      final newId = await sp.createAgentSessionOnPc(workspace: sp.settings.targetWorkspace);
      if (!mounted) return;
      if (newId == null) {
        _toast('新建会话失败：请确认电脑端 LxAI 在运行', isError: true);
        return;
      }
      sp.settings.targetSessionId = newId;
      sp.updateSettings(sp.settings);
      setState(() {});
      _toast('已新建并选中会话', isError: false);
    } finally {
      if (mounted) setState(() => _isCreatingSession = false);
    }
  }

  void _toast(String text, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final s = sp.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final workspaces = sp.agentWorkspaces;
    final sessions = sp.sessionsForWorkspace(s.targetWorkspace);

    final String workspaceLabel =
        s.targetWorkspace.trim().isEmpty ? '默认工作区' : _shortName(s.targetWorkspace);

    String sessionLabel;
    if (_isCreatingSession) {
      sessionLabel = '新建中…';
    } else if (s.targetSessionId.trim().isEmpty) {
      sessionLabel = '新建会话';
    } else {
      final hit = sessions.where((e) => e['id']?.toString() == s.targetSessionId).toList();
      sessionLabel = hit.isEmpty ? '已选会话' : SettingsProvider.agentSessionLabel(hit.first);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0B1220) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.smart_toy_outlined, size: 15, color: Color(0xFF0284C7)),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip(
                    icon: Icons.folder_outlined,
                    label: workspaceLabel,
                    tooltip: '选择工作区（电脑端真实目录）',
                    isDark: isDark,
                    onSelected: (v) => _pickWorkspace(v),
                    items: workspaces.isEmpty
                        ? const {'': '暂无目录（下拉刷新）'}
                        : {for (final w in workspaces) w: _shortName(w)},
                  ),
                  const SizedBox(width: 6),
                  _chip(
                    icon: Icons.forum_outlined,
                    label: sessionLabel,
                    tooltip: '选择会话；选「新建会话」会立刻建一个并选中',
                    isDark: isDark,
                    onSelected: (v) => _pickSession(v),
                    items: {
                      _newSessionOption: '新建会话',
                      for (final sess in sessions)
                        if ((sess['id']?.toString() ?? '').isNotEmpty)
                          sess['id'].toString(): SettingsProvider.agentSessionLabel(sess),
                    },
                  ),
                  const SizedBox(width: 6),
                  _chip(
                    icon: Icons.psychology_outlined,
                    label: '思考 ${_reasoningLabels[s.agentReasoningEffort] ?? s.agentReasoningEffort}',
                    tooltip: '思考链预算 / Reasoning Effort',
                    isDark: isDark,
                    onSelected: (v) {
                      s.agentReasoningEffort = v;
                      sp.updateSettings(s);
                    },
                    items: _reasoningLabels,
                  ),
                  const SizedBox(width: 6),
                  _chip(
                    icon: Icons.shield_outlined,
                    label: _permissionLabels[s.agentPermission] ?? s.agentPermission,
                    tooltip: '本地执行权限',
                    isDark: isDark,
                    onSelected: (v) {
                      s.agentPermission = v;
                      sp.updateSettings(s);
                    },
                    items: _permissionLabels,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            icon: sp.agentCatalogLoading
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 16),
            tooltip: '重新获取电脑端工作区/会话',
            onPressed: sp.agentCatalogLoading
                ? null
                : () async {
                    _requestedCatalog = true;
                    final ok = await sp.refreshAgentCatalog();
                    if (!mounted) return;
                    if (!ok) _toast('没取到目录：请确认电脑端桥接在线', isError: true);
                  },
          ),
        ],
      ),
    );
  }

  /// 目录可能是很长的路径，只显示最后一段，避免把整条快捷栏撑爆。
  static String _shortName(String value) {
    final v = value.trim().replaceAll('\\', '/');
    if (v.isEmpty) return value;
    final parts = v.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? value : parts.last;
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required String tooltip,
    required bool isDark,
    required Map<String, String> items,
    required void Function(String) onSelected,
  }) {
    return PopupMenuButton<String>(
      tooltip: tooltip,
      position: PopupMenuPosition.over,
      onSelected: onSelected,
      itemBuilder: (ctx) => items.entries
          .map(
            (e) => PopupMenuItem<String>(
              value: e.key,
              height: 38,
              child: Text(e.value, style: const TextStyle(fontSize: 13)),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: const Color(0xFF0284C7)),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 108),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }
}
