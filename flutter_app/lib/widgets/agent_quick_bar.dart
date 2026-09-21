import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/sync_service.dart';

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

  static const Map<String, String> _reasoningLabels = {
    'off': '关闭思考',
    'low': '思考·低',
    'medium': '思考·中',
    'high': '思考·高',
    'max': '思考·最高',
  };

  static const Map<String, String> _permissionLabels = {
    // 本机 DSH 真实存在的三个权限预设（由插件 /v1/permission-presets 确认）
    'read-only': '只读',
    'workspace-write': '工作区可写',
    'danger-full-access': '完全访问',
  };

  /// 工作区下拉里的哨兵项：点了打开「手输路径」对话框（不可能是真实目录名）
  static const String _customWorkspaceKey = '__custom_workspace__';

  /// 模型下拉项：id → 展示名（只列电脑端 DSH 真实目录里的模型）。
  Map<String, String> _modelChoices(SettingsProvider sp, String current) {
    final items = <String, String>{};
    for (final m in sp.agentModels) {
      final id = m['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      items[id] = SettingsProvider.agentModelLabel(m);
    }
    final cur = current.trim();
    // 当前值不在目录里（还没刷新过 / 电脑端换了模型）也要显示，否则下拉空白像丢了设置
    if (cur.isNotEmpty && !items.containsKey(cur)) {
      items[cur] = '$cur（不在电脑端目录中）';
    }
    if (items.isEmpty) items[''] = '暂无模型（点右侧刷新）';
    return items;
  }

  /// 快捷栏上显示的模型名（尽量短，取不到就原样显示 id）。
  String _modelLabel(SettingsProvider sp, String current) {
    final cur = current.trim();
    if (cur.isEmpty) return '默认模型';
    for (final m in sp.agentModels) {
      if (m['id']?.toString().trim() == cur) return SettingsProvider.agentModelLabel(m);
    }
    return cur;
  }

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
    // 「自定义路径…」：设置页那张卡删掉后，手输路径的入口挪到这里
    if (value == _customWorkspaceKey) {
      final typed = await _promptWorkspacePath();
      if (typed == null || !mounted) return;
      final s = sp.settings;
      setState(() {
        s.targetWorkspace = typed.trim();
        s.targetSessionId = '';
      });
      sp.updateSettings(s);
      return;
    }
    final s = sp.settings;
    setState(() {
      s.targetWorkspace = value;
      // 换了工作区，原会话基本不属于它了，回到「新建会话」
      s.targetSessionId = '';
    });
    sp.updateSettings(s);
  }

  /// 手输工作区路径（例如电脑上任意目录）。
  Future<String?> _promptWorkspacePath() async {
    final ctrl = TextEditingController(
      text: context.read<SettingsProvider>().settings.targetWorkspace,
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义工作区路径', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '工作区路径 / 名称',
            hintText: r'例如 C:\workspace（留空则用电脑端默认工作区）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (ok != true) return null;
    return text;
  }

  Future<void> _pickSession(String value) async {
    final sp = context.read<SettingsProvider>();
    if (value.isEmpty) return;
    final s = sp.settings;
    s.targetSessionId = value;
    sp.updateSettings(s);
    setState(() {});
  }

  /// 「新建会话」：先问名字，再在电脑端建一个并选中，之后消息都发进它。
  Future<void> _createSession() async {
    final sp = context.read<SettingsProvider>();
    if (sp.settings.isHarnessOnline != true) {
      _toast('电脑端桥接未在线，无法新建会话', isError: true);
      return;
    }
    final title = await _promptSessionName();
    if (title == null || !mounted) return; // 用户取消
    setState(() => _isCreatingSession = true);
    try {
      final newId = await sp.createAgentSessionOnPc(
        workspace: sp.settings.targetWorkspace,
        title: title,
      );
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

  /// 询问会话名称（留空则由电脑端自动命名）。
  Future<String?> _promptSessionName() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建会话', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: '会话名称',
            hintText: '留空则自动命名',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true) return null;
    return name;
  }

  /// 立即把当前会话的「模型 / 思考深度 / 权限预设」下发到电脑端。
  ///
  /// 拿不到会话 id 时不报错：下一轮对话会把这几个设置一并带过去。
  Future<void> _applyOption(String kind, {String? what}) async {
    final label = what ?? (kind == 'permission' ? '权限' : '思考深度');
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    final sessionId = s.targetSessionId.trim();
    if (sessionId.isEmpty) {
      _toast('$label已保存，下一条消息生效', isError: false);
      return;
    }
    final res = await SyncService.instance.applyAgentSessionOption(
      token: s.harnessToken,
      userId: sp.syncUserId,
      kind: kind,
      sessionId: sessionId,
      permission: s.agentPermission,
      reasoningEffort: s.agentReasoningEffort,
      model: s.agentModel,
      harnessUrl: s.harnessServiceUrl,
    );
    if (!mounted) return;
    if (res.ok) {
      _toast('✅ 已切换电脑端$label', isError: false);
    } else {
      _toast('切换失败：${res.message}', isError: true);
    }
  }

  void _toast(String text, {required bool isError}) {    if (!mounted) return;
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
                    tooltip: '选择工作区（电脑端真实目录，末项可手输路径）',
                    isDark: isDark,
                    onSelected: (v) => _pickWorkspace(v),
                    items: {
                      if (workspaces.isEmpty) '': '暂无目录（点右侧刷新）',
                      for (final w in workspaces) w: _shortName(w),
                      _customWorkspaceKey: '✏️ 自定义路径…',
                    },
                  ),
                  const SizedBox(width: 6),
                  _chip(
                    icon: Icons.forum_outlined,
                    label: sessionLabel,
                    tooltip: '选择会话（只列电脑端真实存在的会话）',
                    isDark: isDark,
                    onSelected: (v) => _pickSession(v),
                    items: {
                      for (final sess in sessions)
                        if ((sess['id']?.toString() ?? '').isNotEmpty)
                          sess['id'].toString(): SettingsProvider.agentSessionLabel(sess),
                    }.isEmpty
                        ? const {'': '暂无会话（点 + 新建）'}
                        : {
                            for (final sess in sessions)
                              if ((sess['id']?.toString() ?? '').isNotEmpty)
                                sess['id'].toString(): SettingsProvider.agentSessionLabel(sess),
                          },
                  ),
                  // 「新建会话」独立成按钮：可以顺手起名字，也不再混进下拉选项里
                  const SizedBox(width: 4),
                  _iconButton(
                    icon: Icons.add,
                    tooltip: '新建会话（可命名）',
                    isDark: isDark,
                    busy: _isCreatingSession,
                    onTap: _createSession,
                  ),
                  const SizedBox(width: 6),
                  // 智能体模型：设置页那张「DSH 智能体执行选项」卡已删除，
                  // 模型选择收敛到这里（换模型后档位集合可能变化，顺手对齐一次）
                  _chip(
                    icon: Icons.memory_outlined,
                    label: _modelLabel(sp, s.agentModel),
                    tooltip: '智能体模型（电脑端 DSH 真实模型目录）',
                    isDark: isDark,
                    onSelected: (v) {
                      if (v.isEmpty) return;
                      s.agentModel = v;
                      final efforts = sp.reasoningEffortsFor(v);
                      if (efforts.isNotEmpty && !efforts.contains(s.agentReasoningEffort)) {
                        s.agentReasoningEffort = efforts.contains('high') ? 'high' : efforts.first;
                      }
                      sp.updateSettings(s);
                      setState(() {});
                      unawaited(_applyOption('model', what: '模型'));
                    },
                    items: _modelChoices(sp, s.agentModel),
                  ),
                  const SizedBox(width: 6),
                  _chip(
                    icon: Icons.psychology_outlined,
                    label: _reasoningLabels[s.agentReasoningEffort] ?? s.agentReasoningEffort,
                    tooltip: '思考链预算 / Reasoning Effort（档位随模型而定）',
                    isDark: isDark,
                    onSelected: (v) {
                      s.agentReasoningEffort = v;
                      sp.updateSettings(s);
                      unawaited(_applyOption('model', what: '思考深度'));
                    },
                    items: {
                      for (final e in sp.reasoningEffortsFor(s.agentModel))
                        e: _reasoningLabels[e] ?? e,
                    },
                  ),
                  const SizedBox(width: 6),
                  _chip(
                    icon: Icons.shield_outlined,
                    label: _permissionLabels[s.agentPermission] ?? s.agentPermission,
                    tooltip: '本地执行权限（DSH 权限预设）',
                    isDark: isDark,
                    onSelected: (v) {
                      s.agentPermission = v;
                      sp.updateSettings(s);
                      unawaited(_applyOption('permission', what: '权限'));
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
  }) {    return PopupMenuButton<String>(
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

  /// 快捷栏里的独立小按钮（新建会话用）。
  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required bool isDark,
    required bool busy,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: busy ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
            ),
          ),
          child: busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, size: 15, color: const Color(0xFF0284C7)),
        ),
      ),
    );
  }
}
