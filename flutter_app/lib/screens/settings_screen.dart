import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/app_settings.dart';
import '../providers/settings_provider.dart';
import '../services/update_service.dart';
import '../services/keep_alive_service.dart';
import '../services/notification_service.dart';
import '../utils/url_launcher_helper.dart';
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

          // --- 后台运行与通知（手机端专属：电脑端不需要这些系统授权）---
          const _BackgroundPermissionCard(),
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

          // 2. GitHub 官方更新源 (支持 Android / Windows 自动平台固件匹配与检测)
          const _GithubReleaseCard(),
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

/// 后台运行与通知权限卡片（仅 Android 有意义）。
///
/// 这三项决定了"手机能不能在后台持续收消息 / 收到授权提醒"：
/// · 通知权限：Android 13+ 必须授权，否则收不到授权提醒（保活通知也不可见）；
/// · 电池优化白名单：不加白名单，系统随时可能把后台进程回收；
/// · 后台数据：部分机型默认限制后台流量，需要在系统设置里手动放开
///   （没有公开 API，只能把用户送到应用详情页）。
class _BackgroundPermissionCard extends StatefulWidget {
  const _BackgroundPermissionCard();

  @override
  State<_BackgroundPermissionCard> createState() => _BackgroundPermissionCardState();
}

class _BackgroundPermissionCardState extends State<_BackgroundPermissionCard>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _notifyGranted = false;
  bool _ignoringBattery = false;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户从系统设置页回来时刷新状态
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (!_isAndroid) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final notify = await NotificationService.instance.hasPermission();
    final battery = await KeepAliveService.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _notifyGranted = notify;
      _ignoringBattery = battery;
      _loading = false;
    });
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool granted,
    required VoidCallback onTap,
    required String actionLabel,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: granted ? Colors.green : Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          granted
              ? const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('已允许', style: TextStyle(fontSize: 12, color: Colors.green)),
                )
              : OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                  ),
                  onPressed: onTap,
                  child: Text(actionLabel, style: const TextStyle(fontSize: 12)),
                ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAndroid) return const SizedBox.shrink();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.cloud_sync_outlined, size: 20, color: Color(0xFF0284C7)),
                SizedBox(width: 8),
                Text('后台运行与通知', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '这几项决定手机在后台还能不能持续收消息、以及电脑端请求授权时能不能提醒到你。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else ...[
              _row(
                icon: _notifyGranted ? Icons.notifications_active : Icons.notifications_off_outlined,
                title: '通知权限',
                subtitle: _notifyGranted
                    ? '已允许：电脑端请求授权时会弹通知提醒'
                    : '未允许：App 在后台时收不到授权提醒',
                granted: _notifyGranted,
                actionLabel: '去授权',
                onTap: () async {
                  await NotificationService.instance.ensurePermission();
                  await _refresh();
                },
              ),
              const Divider(height: 1),
              _row(
                icon: _ignoringBattery ? Icons.battery_charging_full : Icons.battery_alert_outlined,
                title: '电池优化白名单',
                subtitle: _ignoringBattery
                    ? '已加入：系统不会随意回收后台进程'
                    : '未加入：系统可能随时冻结后台，导致掉线',
                granted: _ignoringBattery,
                actionLabel: '去设置',
                onTap: () async {
                  await KeepAliveService.requestIgnoreBatteryOptimizations();
                  await Future.delayed(const Duration(seconds: 2));
                  await _refresh();
                },
              ),
              const Divider(height: 1),
              _row(
                icon: Icons.signal_cellular_alt,
                title: '后台数据',
                subtitle: '部分机型默认限制后台流量；此开关没有公开接口，需在系统设置里手动放开',
                granted: false,
                actionLabel: '打开设置',
                onTap: () => KeepAliveService.openAppSettings(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GithubReleaseCard extends StatefulWidget {
  const _GithubReleaseCard();

  @override
  State<_GithubReleaseCard> createState() => _GithubReleaseCardState();
}

class _GithubReleaseCardState extends State<_GithubReleaseCard> {
  bool _isChecking = false;

  Future<void> _handleCheckUpdate() async {
    if (_isChecking) return;
    setState(() => _isChecking = true);

    try {
      final result = await UpdateService.checkUpdate();
      if (!mounted) return;

      if (!result.isSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.errorMessage ?? '检查更新失败，请稍后重试'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      if (result.hasUpdate) {
        // 先检查本地是否已有下载好的安装包
        final cachedFile = await UpdateService.checkCachedPackage(
          result.latestVersion,
          result.matchedAssetFileName,
          result.fileSize,
        );

        if (!mounted) return;

        // 如果已经下载了安装包，直接呼出系统安装界面
        if (cachedFile != null && !kIsWeb && Platform.isAndroid) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已在本地检测到 v${result.latestVersion} 完整安装包，正在弹出系统安装...'),
              backgroundColor: const Color(0xFF10B981),
              duration: const Duration(seconds: 3),
            ),
          );
          await UpdateService.installCachedPackage(cachedFile.path);
        }

        _showUpdateDialog(result, cachedFile);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🎉 当前已是最新版本 (v${result.currentVersion}) · [${result.platformName}]'),
            backgroundColor: const Color(0xFF10B981),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('检测发生异常: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  void _showUpdateDialog(UpdateCheckResult result, File? cachedFile) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _UpdateDownloadDialog(result: result, initialCachedFile: cachedFile),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
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
                  onPressed: _isChecking ? null : _handleCheckUpdate,
                  child: _isChecking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text('检测新版本', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '官方仓库：${AppSettings.officialGithubOwner} / ${AppSettings.officialGithubRepo}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateDownloadDialog extends StatefulWidget {
  final UpdateCheckResult result;
  final File? initialCachedFile;

  const _UpdateDownloadDialog({
    required this.result,
    this.initialCachedFile,
  });

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  File? _cachedFile;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _cachedFile = widget.initialCachedFile;
    _isDownloading = UpdateService.isDownloading &&
        UpdateService.activeDownloadingVersion == widget.result.latestVersion;
  }

  void _triggerInstall() {
    if (_cachedFile != null) {
      UpdateService.installCachedPackage(_cachedFile!.path);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Platform.isAndroid ? '正在调起系统安装界面...' : '正在启动安装程序并退出旧版...'),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    }
  }

  void _startDownload() {
    setState(() {
      _isDownloading = true;
    });

    UpdateService.startInAppDownload(
      result: widget.result,
      onComplete: () async {
        if (!mounted) return;
        final file = await UpdateService.checkCachedPackage(
          widget.result.latestVersion,
          widget.result.matchedAssetFileName,
          widget.result.fileSize,
        );
        setState(() {
          _isDownloading = false;
          _cachedFile = file;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final res = widget.result;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF0284C7).withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.system_update_alt, color: Color(0xFF0284C7), size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '发现新版本 v${res.latestVersion}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  '当前版本: v${res.currentVersion}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 420),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 平台与下载就绪标识
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.devices, size: 16, color: Color(0xFF0284C7)),
                        const SizedBox(width: 6),
                        Text(
                          '当前设备: ${res.platformName}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ],
                    ),
                    if (res.matchedAssetFileName != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            _cachedFile != null ? Icons.check_circle : Icons.file_download_done,
                            size: 16,
                            color: const Color(0xFF10B981),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _cachedFile != null
                                  ? '安装包已在本地就绪 (${res.formattedFileSize})'
                                  : '匹配固件: ${res.matchedAssetFileName} (${res.formattedFileSize})',
                              style: const TextStyle(fontSize: 12, color: Color(0xFF10B981), fontWeight: FontWeight.w500),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // 正在下载时展示实时真实进度条
              if (_isDownloading || UpdateService.isDownloading) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF0284C7).withOpacity(0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0284C7)),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '正在应用内下载，通知栏同步显示...',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0284C7)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ValueListenableBuilder<double>(
                        valueListenable: UpdateService.downloadProgressNotifier,
                        builder: (context, progress, _) {
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: progress > 0 ? progress : null,
                              backgroundColor: Colors.grey.withOpacity(0.2),
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF0284C7)),
                              minHeight: 8,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<String>(
                        valueListenable: UpdateService.downloadStatusNotifier,
                        builder: (context, status, _) {
                          return Text(
                            status.isNotEmpty ? status : '准备中...',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 12),
              const Text('更新日志：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                  ),
                ),
                child: SelectableText(
                  res.releaseNotes,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_isDownloading ? '后台下载' : '稍后再说'),
        ),
        if (_cachedFile != null) ...[
          ElevatedButton.icon(
            icon: const Icon(Icons.install_mobile, size: 16),
            label: const Text('立即安装'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _triggerInstall,
          ),
        ] else if (_isDownloading) ...[
          ElevatedButton.icon(
            icon: const Icon(Icons.close, size: 16),
            label: const Text('取消下载'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              UpdateService.cancelDownload();
              setState(() => _isDownloading = false);
            },
          ),
        ] else ...[
          ElevatedButton.icon(
            icon: const Icon(Icons.download, size: 16),
            label: const Text('立即下载更新'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              if (res.matchedAssetFileName != null && res.downloadUrl != null) {
                _startDownload();
              } else {
                UrlLauncherHelper.openUrl(res.downloadUrl ?? res.releaseUrl);
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ],
    );
  }
}

