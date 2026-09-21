import 'package:flutter/material.dart';

/// 一条可用命令（名称 + 中文说明 + 可选的参数候选）。
class SlashCommand {
  final String name;
  final String description;
  /// 参数候选：非空时，点命令会展开二级选择（例如 /permission 的三种预设）
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

/// App 侧支持的斜杠命令表。
///
/// 目前只有 /permission —— 桥接实现了命令路由，会在派发任务前把它当命令执行
/// （见 deepseek_bridge.try_handle_dsh_command）。这里只列**确实能用**的，
/// 不摆样子货。
const List<SlashCommand> kSlashCommands = [
  SlashCommand(
    name: 'permission',
    description: '切换本地 DSH 的权限预设（沙箱范围与是否弹审批）',
    options: [
      SlashCommandOption('read-only', '只读：仅允许读取，禁止写入'),
      SlashCommandOption('workspace-write', '工作区可写：越界操作会弹审批'),
      SlashCommandOption('danger-full-access', '完全访问：不限范围、不再弹审批'),
    ],
  ),
];

/// 输入框上方的命令面板（Telegram 风格的「输入 / 就浮出来」）。
///
/// 交互：
/// · 输入以 `/` 开头时出现，按已输入内容过滤；
/// · 无参数命令 → 点一下直接发送；
/// · 带参数命令 → 点一下展开参数候选（如三种权限预设），选中后发送完整命令。
class SlashCommandMenu extends StatelessWidget {
  final String query; // `/` 之后已输入的部分（用于过滤）
  final SlashCommand? expanded; // 已展开参数的命令
  final ValueChanged<SlashCommand> onPickCommand;
  final void Function(SlashCommand command, SlashCommandOption option) onPickOption;
  final VoidCallback onClose;

  const SlashCommandMenu({
    super.key,
    required this.query,
    required this.expanded,
    required this.onPickCommand,
    required this.onPickOption,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0B1220) : Colors.white;
    final border = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    final items = kSlashCommands
        .where((c) => query.isEmpty || c.name.toLowerCase().startsWith(query.toLowerCase()))
        .toList();

    // 展开参数时，只显示该命令的参数列表
    final children = <Widget>[];
    if (expanded != null) {
      children.add(_header(context, '/${expanded!.name}', '选择参数'));
      for (final opt in expanded!.options) {
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
