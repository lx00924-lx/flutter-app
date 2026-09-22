import 'package:flutter/material.dart';

/// 命令名与输入串的匹配打分（越小越靠前；-1 表示不匹配）。
///
/// 不要求把命令打全：
/// · 前缀命中（`/per`）     → 最优；
/// · 子串命中（`/mission`） → 次之；
/// · 子序列命中（`/pm`、`/prm`）→ 再次；
/// · 中文说明里命中（`/权限`）→ 兜底；
/// 这样"跟输入框里有相同字母"的命令都能浮出来。
int slashMatchScore({required String name, required String description, required String query}) {
  if (query.isEmpty) return 0;
  final n = name.toLowerCase();
  final q = query.toLowerCase();

  if (n.startsWith(q)) return 0;
  if (n.contains(q)) return 1;

  // 子序列：按顺序出现即可，不必连续
  var i = 0;
  for (var c = 0; c < n.length && i < q.length; c++) {
    if (n[c] == q[i]) i++;
  }
  if (i == q.length) return 2;

  if (description.toLowerCase().contains(q)) return 3;
  return -1;
}

class SlashCommand {
  final String name;
  final String description;  /// 参数候选：非空时，点命令会展开二级选择（例如 /permission 的三种预设）
  final List<SlashCommandOption> options;

  const SlashCommand({
    required this.name,
    required this.description,
    this.options = const [],
  });

  /// 带参数时的完整命令文本（不含参数则为 `/name`）
  String textWith(String? arg) {
    if (arg == null || arg.isEmpty) return '/$name';
    return '/$name $arg';
  }
}

class SlashCommandOption {
  final String value;
  final String label;
  const SlashCommandOption(this.value, this.label);
}

/// App 侧支持的斜杠命令表（**静态部分**）。
///
/// 这些命令全部由 App 本地执行，不再"发一条文本让桥接/DSH 当命令处理"——
/// 那条路走过一次弯路：DSH 不会把排队进会话的 `/xxx` 文本当命令执行，
/// 结果是会话里堆了一串命令消息而权限从未真正改变（见 bridge/plugin 的修复）。
/// 带动态候选的命令（/model、/workspace、/session）由调用方用真实目录拼出来。
const List<SlashCommand> kSlashCommands = [
  SlashCommand(
    name: 'help',
    description: '显示全部命令与用法',
  ),
  SlashCommand(
    name: 'permission',
    description: '切换 DSH 权限预设（沙箱范围 / 越界是否弹审批）',
    options: [
      SlashCommandOption('read-only', '只读：仅允许读取，禁止写入'),
      SlashCommandOption('workspace-write', '工作区可写：越界操作会弹审批'),
      SlashCommandOption('danger-full-access', '完全访问：不限范围、不再弹审批'),
    ],
  ),
  SlashCommand(
    name: 'model',
    description: '切换智能体模型（电脑端真实模型目录）',
  ),
  SlashCommand(
    name: 'effort',
    description: '切换思考链预算（档位随所选模型而定）',
    options: [
      SlashCommandOption('off', '关闭思考：最快'),
      SlashCommandOption('low', '低：少量思考'),
      SlashCommandOption('high', '高：深度推演（默认）'),
      SlashCommandOption('max', '最高：最充分'),
    ],
  ),
  SlashCommand(
    name: 'workspace',
    description: '切换目标工作区（电脑端真实目录）',
  ),
  SlashCommand(
    name: 'session',
    description: '切换目标会话（当前工作区下的真实会话）',
  ),
  SlashCommand(
    name: 'new',
    description: '在电脑端新建会话并选中（可跟名字：/new 登录页重构）',
  ),
  SlashCommand(
    name: 'stop',
    description: '立刻停止当前这一轮生成',
  ),
];

/// 输入框上方的命令面板（Telegram 风格的「输入 / 就浮出来」）。
///
/// 交互：
/// · 输入以 `/` 开头时出现，按已输入内容过滤；
/// · 无参数命令 → 点一下直接执行；
/// · 带参数命令 → 点一下展开参数候选（如三种权限预设），选中后执行。
class SlashCommandMenu extends StatelessWidget {
  final String query; // `/` 之后已输入的命令名部分（用于过滤）
  /// 已输入的命令参数部分（如 `/permission work` 里的 `work`），用于过滤参数候选
  final String argQuery;
  final SlashCommand? expanded; // 已展开参数的命令
  /// 可列出的命令（调用方传入，含按真实目录拼出来的动态候选）
  final List<SlashCommand> commands;
  final ValueChanged<SlashCommand> onPickCommand;
  final void Function(SlashCommand command, SlashCommandOption option) onPickOption;
  final VoidCallback onClose;

  const SlashCommandMenu({
    super.key,
    required this.query,
    this.argQuery = '',
    required this.expanded,
    this.commands = kSlashCommands,
    required this.onPickCommand,
    required this.onPickOption,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0B1220) : Colors.white;
    final border = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    // 模糊匹配 + 打分排序（前缀 > 子串 > 子序列 > 中文说明命中）
    final scored = <MapEntry<SlashCommand, int>>[];
    for (final c in commands) {
      final score = slashMatchScore(name: c.name, description: c.description, query: query);
      if (score >= 0) scored.add(MapEntry(c, score));
    }
    scored.sort((a, b) => a.value.compareTo(b.value));
    final items = scored.map((e) => e.key).toList();

    // 展开参数时，只显示该命令的参数列表（同样支持按已输入的参数过滤）
    final children = <Widget>[];
    if (expanded != null) {
      final opts = expanded!.options
          .where((o) => slashMatchScore(name: o.value, description: o.label, query: argQuery) >= 0)
          .toList();
      children.add(_header(context, '/${expanded!.name}', opts.length == expanded!.options.length ? '选择参数' : '筛选参数'));
      if (opts.isEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Text(
            '没有匹配的参数（可用：${expanded!.options.map((o) => o.value).join(' / ')}）',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ));
      }
      for (final opt in opts) {
        children.add(_row(
          context,
          left: opt.value,
          desc: opt.label,
          mono: true,
          onTap: () => onPickOption(expanded!, opt),
        ));
      }
    } else if (items.isEmpty) {
      return const SizedBox.shrink();
    } else {
      children.add(_header(context, '命令', '点击即可发送'));
      for (final c in items) {
        children.add(_row(
          context,
          left: '/${c.name}',
          desc: c.description,
          mono: true,
          onTap: () => onPickCommand(c),
        ));
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, -2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String left, String right) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          Text(
            left,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0284C7)),
          ),
          const Spacer(),
          Text(right, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
          const SizedBox(width: 4),
          InkWell(
            onTap: onClose,
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close, size: 14, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required String left,
    required String desc,
    required bool mono,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                left,
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: mono ? 'monospace' : null,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                desc,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
