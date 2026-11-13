import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../services/storage_path_service.dart';
import '../utils/app_colors.dart';

class StorageSettingsScreen extends StatefulWidget {
  const StorageSettingsScreen({super.key});

  @override
  State<StorageSettingsScreen> createState() => _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends State<StorageSettingsScreen> {
  double _cacheSizeMb = 0.0;
  String _defaultPath = '';
  bool _isClearing = false;
  bool _isMigrating = false;
  /// 迁移进度：[已搬, 总数]；总数 0 表示还在统计文件
  final ValueNotifier<List<int>> _migrateProgress = ValueNotifier<List<int>>([0, 0]);

  @override
  void dispose() {
    _migrateProgress.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initPaths();
  }

  Future<void> _initPaths() async {
    final defaultPath = await StoragePathService.instance.getDefaultDirectoryPath();
    final size = await StoragePathService.instance.calculateCacheSizeMb();
    if (mounted) {
      setState(() {
        _defaultPath = defaultPath;
        _cacheSizeMb = size;
      });
    }
  }

  Future<void> _refreshCacheSize() async {
    final size = await StoragePathService.instance.calculateCacheSizeMb();
    if (mounted) {
      setState(() {
        _cacheSizeMb = size;
      });
    }
  }

  /// 恢复为系统默认目录
  Future<void> _resetToDefault() async {
    final sp = context.read<SettingsProvider>();
    final oldPath = sp.settings.customDataPath;
    if (oldPath.isEmpty) return;

    final targetPath = _defaultPath.isNotEmpty
        ? _defaultPath
        : await StoragePathService.instance.getDefaultDirectoryPath();
    if (targetPath.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
          const SnackBar(content: Text('取不到系统默认目录，请稍后重试')),
        );
      }
      return;
    }

    final migration = await _migrateWithProgress(oldPath: oldPath, newPath: targetPath);
    if (!mounted || migration == null) return;

    sp.updateCustomDataPath('');
    await _refreshCacheSize();
    if (!mounted) return;

    ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
      SnackBar(
        content: Text(
          migration.success
              ? '已恢复为默认存储路径 (${migration.movedFilesCount} 个文件已迁回)'
              : '已切回默认路径，但有文件没搬完: ${migration.error ?? "未知错误"}',
        ),
        backgroundColor: migration.success ? Colors.green : Colors.orange,
      ),
    );
  }

  /// 迁移缓存，期间显示一个**关不掉的进度框**；返回 null 表示迁移直接抛异常。
  ///
  /// 为什么用模态对话框而不是只加一层遮罩：迁移那几十秒里，用户最容易手滑去点别的
  /// （切会话、看原图、发语音），那些操作全都会往缓存目录写新文件。模态框 +
  /// `PopScope(canPop:false)` 把返回键也一起挡住，才算真的"整个 App 被禁用"。
  Future<CacheMigrationResult?> _migrateWithProgress({
    required String oldPath,
    required String newPath,
  }) async {
    _migrateProgress.value = [0, 0];
    setState(() => _isMigrating = true);

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<List<int>>(
          valueListenable: _migrateProgress,
          builder: (_, progress, __) {
            final done = progress.isNotEmpty ? progress[0] : 0;
            final total = progress.length > 1 ? progress[1] : 0;
            return AlertDialog(
              title: const Text('正在迁移缓存'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    total > 0 ? '已搬 $done / $total 个文件' : '正在统计文件…',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '迁移期间请勿关闭 App。中途断开也没关系 —— '
                    '下次启动会自动接着搬完，或者退回原目录。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ));

    try {
      return await StoragePathService.instance.migrateCacheToNewDirectory(
        oldPath: oldPath,
        newPath: newPath,
        onProgress: (moved, total) => _migrateProgress.value = [moved, total],
      );
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) setState(() => _isMigrating = false);
    }
  }

  /// 打开系统资源管理器 / 文件夹选择器供用户选定目录
  Future<void> _pickDirectoryFromExplorer() async {
    try {
      final selectedDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择缓存与多媒体存储根目录',
        lockParentWindow: true,
      );

      if (selectedDirectory == null || selectedDirectory.trim().isEmpty) return;

      final newPath = selectedDirectory.trim();
      final sp = context.read<SettingsProvider>();
      final oldPath = sp.settings.customDataPath;

      if (newPath == oldPath.trim()) {
        if (mounted) {
          ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
            const SnackBar(content: Text('已是当前目录，无需更改')),
          );
        }
        return;
      }

      final migration = await _migrateWithProgress(oldPath: oldPath, newPath: newPath);
      if (!mounted || migration == null) return;

      if (migration.success) {
        // 更新持久化设置
        sp.updateCustomDataPath(newPath);
        await _refreshCacheSize();
        if (!mounted) return;

        ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
          SnackBar(
            content: Text(
              '缓存目录已更新！已自动迁移 ${migration.movedFilesCount} 个文件 (${migration.movedMb.toStringAsFixed(2)} MB)',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
          SnackBar(
            content: Text('缓存目录迁移出现异常: ${migration.error ?? "未知错误"}'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      debugPrint('打开资源管理器选择目录异常: $e');
      if (mounted) {
        setState(() => _isMigrating = false);
        ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
          SnackBar(
            content: Text('选择路径失败: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  /// 清空本地临时缓存与原图文件（聊天记录中的缩略图不受影响）
  Future<void> _clearCache() async {
    setState(() => _isClearing = true);
    await StoragePathService.instance.clearCache();
    await _refreshCacheSize();
    if (mounted) {
      setState(() => _isClearing = false);
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
        const SnackBar(
          content: Text('已成功清理本地原图、语音与临时文件缓存（聊天记录缩略图保留）'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final s = sp.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('数据与缓存路径设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. 自定义缓存路径卡片
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.folder_special_outlined, color: Color(0xFF0284C7)),
                      SizedBox(width: 8),
                      Text(
                        '自定义缓存与原图存储路径',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '指定本地拍摄原图、录音、TTS 语音合成与临时文件的落盘目录。修改路径时将自动将现存缓存完整迁移至新位置。',
                    style: TextStyle(fontSize: 12, color: AppColors.secondary(context)),
                  ),
                  const SizedBox(height: 14),

                  // 路径展示框
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
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
                            Icon(
                              s.customDataPath.isNotEmpty ? Icons.folder_special : Icons.folder_open,
                              size: 20,
                              color: const Color(0xFF0284C7),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              s.customDataPath.isNotEmpty ? '自定义外部目录' : '默认沙盒存储目录',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0284C7)),
                            ),
                            const Spacer(),
                            if (s.customDataPath.isNotEmpty)
                              InkWell(
                                onTap: _isMigrating ? null : _resetToDefault,
                                borderRadius: BorderRadius.circular(4),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.restore, size: 14, color: Colors.orange),
                                      SizedBox(width: 4),
                                      Text(
                                        '恢复默认',
                                        style: TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          s.customDataPath.isNotEmpty
                              ? s.customDataPath
                              : (_defaultPath.isNotEmpty ? _defaultPath : '（正在读取系统默认目录…）'),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontFamily: 'monospace',
                            color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 打开资源管理器选择路径大按钮（不提供手动输入，直接选择）
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: _isMigrating
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.drive_folder_upload, size: 18),
                      label: Text(
                        _isMigrating ? '正在迁移缓存数据至新目录...' : '打开资源管理器选择路径',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _isMigrating ? null : _pickDirectoryFromExplorer,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. 缓存管理卡片
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.cleaning_services_outlined, color: Colors.orange),
                      SizedBox(width: 8),
                      Text(
                        '本地原图与临时缓存清理',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '清理后将释放设备存储空间。历史聊天记录将保留轻量缩略图继续正常回显。',
                    style: TextStyle(fontSize: 12, color: AppColors.secondary(context)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('当前临时文件与原图占用：', style: TextStyle(fontSize: 14)),
                      Text(
                        '${_cacheSizeMb.toStringAsFixed(2)} MB',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF0284C7)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: _isClearing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.redAccent),
                            )
                          : const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: Text(_isClearing ? '正在清理...' : '一键清理本地原图与缓存'),
                      onPressed: _isClearing ? null : _clearCache,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
