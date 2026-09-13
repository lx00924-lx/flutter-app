import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import 'account_settings_screen.dart';
import 'personalization_settings_screen.dart';
import 'api_settings_screen.dart';
import 'asr_settings_screen.dart';
import 'harness_settings_screen.dart';
import 'storage_settings_screen.dart';
import 'log_console_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final s = settingsProvider.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('系统设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // 头部版本与状态
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Text(
                  '应用配置中心',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text('v1.0.1', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // --- 五大分类设置入口 ---
          _buildCategoryCard(
            context,
            icon: Icons.manage_accounts_outlined,
            iconColor: const Color(0xFF0284C7),
            title: '账户设置',
            subtitle: '账号、用户名、用户头像、AI名称、AI头像、修改密码',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AccountSettingsScreen()),
            ),
          ),
          _buildCategoryCard(
            context,
            icon: Icons.palette_outlined,
            iconColor: Colors.deepPurple,
            title: '个性化设置',
            subtitle: '自定义背景、字体大小(13-18px)、透明度、启动页设置、回复逻辑',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PersonalizationSettingsScreen()),
            ),
          ),
          _buildCategoryCard(
            context,
            icon: Icons.hub_outlined,
            iconColor: Colors.teal,
            title: '大模型 API 设置',
            subtitle: '点击「+」添加 API 地址、Key、模型名、专属上下文滑动截断、卡片管理',
            trailingBadge: '${s.apiEndpoints.length} 个端点',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ApiSettingsScreen()),
            ),
          ),
          _buildCategoryCard(
            context,
            icon: Icons.record_voice_over_outlined,
            iconColor: Colors.amber.shade800,
            title: '语音转写与合成设置 (ASR/TTS)',
            subtitle: '语音识别(SenseVoice/Groq)与语音朗读(手机自带/CosyVoice/OpenAI/微软)',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AsrSettingsScreen()),
            ),
          ),
          _buildCategoryCard(
            context,
            icon: Icons.terminal_outlined,
            iconColor: Colors.indigo,
            title: 'DeepSeek Harness 设置',
            subtitle: '电脑本地 Agent 桥接、免公网 IP 反向长连接、工作区会话刷新',
            trailingBadge: s.isHarnessOnline ? '在线' : '离线',
            badgeColor: s.isHarnessOnline ? Colors.green : Colors.grey,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HarnessSettingsScreen()),
            ),
          ),
          _buildCategoryCard(
            context,
            icon: Icons.folder_open_outlined,
            iconColor: const Color(0xFF0284C7),
            title: '数据与缓存存储路径',
            subtitle: s.customDataPath.isNotEmpty ? s.customDataPath : '打开系统资源管理器选择本地录音与临时缓存目录',
            trailingBadge: s.customDataPath.isNotEmpty ? '自定义' : '默认沙盒',
            badgeColor: s.customDataPath.isNotEmpty ? Colors.blue : Colors.grey,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StorageSettingsScreen()),
            ),
          ),
          const SizedBox(height: 16),

          // --- 剩余直接展示的系统功能 ---
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '系统与常规维护',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey),
            ),
          ),

          // 1. 日夜模式
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: SwitchListTile(
              secondary: Icon(
                settingsProvider.isDarkMode ? Icons.dark_mode : Icons.light_mode,
                color: const Color(0xFF0284C7),
              ),
              title: const Text('深色模式 (Dark Theme)'),
              subtitle: const Text('切换日间明亮与纯黑科技暗调'),
              value: settingsProvider.isDarkMode,
              onChanged: (val) => settingsProvider.toggleTheme(),
            ),
          ),
          const SizedBox(height: 10),

          // 2. GitHub 官方更新源 (随应用打包发布锁定)
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.cloud_sync_outlined, color: Color(0xFF0284C7)),
                      const SizedBox(width: 8),
                      const Text('GitHub 官方发布源', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const Spacer(),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已是最新版本 (v1.0.1+101)')),
                          );
                        },
                        child: const Text('检测新版本', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '官方仓库：${AppSettings.officialGithubOwner} / ${AppSettings.officialGithubRepo}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '随编译打包固件锁定，自动检测 Releases 发版通道',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // 4. APP 检修与调试设置
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.build_circle_outlined, color: Color(0xFF0284C7)),
                      SizedBox(width: 8),
                      Text('APP 检修与调试日志', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示悬浮调试球', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('在右下角提供轻量 🪲 调试按钮，方便随时排查', style: TextStyle(fontSize: 12)),
                    value: s.showDebugFab,
                    onChanged: (val) {
                      s.showDebugFab = val;
                      settingsProvider.updateSettings(s);
                    },
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.bug_report_outlined, size: 16),
                          label: const Text('打开控制台'),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const LogConsoleScreen()),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制日志'),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                              text: AppLogger.instance.exportAsString(),
                            ));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('运行日志已复制到剪贴板')),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildCategoryCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? trailingBadge,
    Color? badgeColor,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: iconColor, size: 24),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailingBadge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (badgeColor ?? const Color(0xFF0284C7)).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  trailingBadge,
                  style: TextStyle(
                    fontSize: 11,
                    color: badgeColor ?? const Color(0xFF0284C7),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
            const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
