import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 缓存迁移结果对象
class CacheMigrationResult {
  final bool success;
  final int movedFilesCount;
  final double movedBytes;
  final String? error;

  const CacheMigrationResult({
    required this.success,
    this.movedFilesCount = 0,
    this.movedBytes = 0.0,
    this.error,
  });

  double get movedMb => movedBytes / (1024 * 1024);
}

/// 统一本地文件与缓存路径管理服务（支持用户选定自定义存储路径、原图本地落盘、缓存清理与自动迁移）
class StoragePathService {
  static final StoragePathService instance = StoragePathService._internal();
  StoragePathService._internal();

  String _customPath = '';

  void setCustomPath(String path) {
    _customPath = path.trim();
  }

  /// 系统默认缓存根目录（**App 独占**）。
  ///
  /// 桌面端**不能**用 `getTemporaryDirectory()`：Windows 上那指向全用户共享的
  /// `%TEMP%`（`C:\Users\<user>\AppData\Local\Temp`）。指到那里有两个实际后果：
  ///   1. `calculateCacheSizeMb()` 会把整个 `%TEMP%` 的大小算成"App 缓存"；
  ///   2. 迁移缓存时会把**别的程序**的临时文件一起搬到用户选的目录里。
  /// 所以桌面端改用 `getApplicationSupportDirectory()/cache`，移动端仍用 App 私有 cache。
  Future<Directory> _defaultCacheRoot() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/cache');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    return await getTemporaryDirectory();
  }

  /// 获取系统默认的缓存物理绝对路径
  Future<String> getDefaultDirectoryPath() async {
    if (kIsWeb) return 'Web In-Memory Cache';
    try {
      final dir = await _defaultCacheRoot();
      return dir.path;
    } catch (e) {
      // 拿不到就如实返回空串，让界面显示"正在读取"，**不要**回一个写死的
      // Android 路径 —— 电脑端会照着它把手机目录显示成自己的默认值。
      debugPrint('获取默认缓存路径失败: $e');
      return '';
    }
  }

  /// 获取当前生效的缓存根目录（优先使用用户在资源管理器中指定的路径）
  Future<Directory> getActiveCacheDirectory() async {
    if (_customPath.isNotEmpty && !kIsWeb) {
      final customDir = Directory(_customPath);
      if (await customDir.exists()) {
        return customDir;
      } else {
        try {
          await customDir.create(recursive: true);
          return customDir;
        } catch (e) {
          debugPrint('无法创建自定义缓存路径: $e，将回退到系统临时目录');
        }
      }
    }
    return await _defaultCacheRoot();
  }

  /// 获取本地原图专用存储目录
  Future<Directory> getImagesDirectory() async {
    final baseDir = await getActiveCacheDirectory();
    final imagesDir = Directory('${baseDir.path}/images');
    if (!await imagesDir.exists() && !kIsWeb) {
      await imagesDir.create(recursive: true);
    }
    return imagesDir;
  }

  /// 将拍摄或选取的原图无损保存到本地自定义存储目录，返回持久化文件绝对路径
  Future<String?> saveRawImageToDisk({
    required Uint8List bytes,
    required String extension,
    String prefix = 'raw_img',
  }) async {
    if (kIsWeb) return null;
    try {
      final dir = await getImagesDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final ext = extension.startsWith('.') ? extension : '.$extension';
      final filePath = '${dir.path}/${prefix}_$timestamp$ext';
      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);
      return filePath;
    } catch (e) {
      debugPrint('saveRawImageToDisk error: $e');
      return null;
    }
  }

  /// 获取临时音频/TTS 生成文件完整路径
  Future<String> generateFilePath({required String prefix, required String extension}) async {
    final dir = await getActiveCacheDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = extension.startsWith('.') ? extension : '.$extension';
    return '${dir.path}/${prefix}_$timestamp$ext';
  }

  /// 获取当前缓存占用大小 (MB)
  Future<double> calculateCacheSizeMb() async {
    if (kIsWeb) return 0.0;
    try {
      final dir = await getActiveCacheDirectory();
      int totalBytes = 0;
      if (await dir.exists()) {
        await for (final file in dir.list(recursive: true, followLinks: false)) {
          if (file is File) {
            totalBytes += await file.length();
          }
        }
      }
      return totalBytes / (1024 * 1024);
    } catch (e) {
      debugPrint('计算缓存大小失败: $e');
      return 0.0;
    }
  }

  /// 清空当前缓存目录下的音视频、临时文件及本地原图缓存（保留聊天记录中的缩略图正常回显）
  Future<void> clearCache() async {
    if (kIsWeb) return;
    try {
      final dir = await getActiveCacheDirectory();
      if (await dir.exists()) {
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final name = entity.path.toLowerCase();
            if (_isCacheFile(name)) {
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      }
    } catch (e) {
      debugPrint('清空缓存失败: $e');
    }
  }

  /// 将旧路径下的缓存文件无缝迁移至新选定的目录
  Future<CacheMigrationResult> migrateCacheToNewDirectory({
    required String oldPath,
    required String newPath,
  }) async {
    if (kIsWeb || oldPath.trim() == newPath.trim()) {
      return const CacheMigrationResult(success: true, movedFilesCount: 0, movedBytes: 0);
    }

    try {
      Directory oldDir;
      if (oldPath.trim().isNotEmpty) {
        oldDir = Directory(oldPath.trim());
      } else {
        oldDir = await getTemporaryDirectory();
      }

      final targetDir = Directory(newPath.trim());
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      // 预先探测目标目录写入权限
      try {
        final probeFile = File('${targetDir.path}/.probe_write_${DateTime.now().millisecondsSinceEpoch}.tmp');
        await probeFile.writeAsString('ok');
        if (await probeFile.exists()) {
          await probeFile.delete();
        }
      } catch (probeErr) {
        return CacheMigrationResult(
          success: false,
          error: '目标文件夹无写入权限，请选择其他目录或在系统设置中允许应用管理文件 ($probeErr)',
        );
      }

      if (!await oldDir.exists()) {
        _customPath = newPath.trim();
        return const CacheMigrationResult(success: true, movedFilesCount: 0, movedBytes: 0);
      }

      // 源目录是不是**共享的系统临时目录**（桌面端历史默认就是 %TEMP%，整个用户共用）：
      // 是的话只能按白名单挑自己的文件，绝不能整份搬。
      bool oldDirIsSharedTemp = false;
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        try {
          final temp = await getTemporaryDirectory();
          oldDirIsSharedTemp = oldDir.path == temp.path;
        } catch (_) {}
      }

      int movedCount = 0;
      double totalBytes = 0;

      await for (final entity in oldDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final relativePath = entity.path.substring(oldDir.path.length);
          // 跳过第三方插件目录；共享临时目录下只搬自己的媒体文件
          if (_shouldSkipInMigration(relativePath, oldDirIsSharedTemp)) continue;

          try {
            final targetFilePath = '${targetDir.path}$relativePath';
            final targetParent = File(targetFilePath).parent;
            if (!await targetParent.exists()) {
              await targetParent.create(recursive: true);
            }

            final fileSize = await entity.length();
            try {
              await entity.rename(targetFilePath);
            } catch (_) {
              await entity.copy(targetFilePath);
              try {
                await entity.delete();
              } catch (_) {}
            }

            movedCount++;
            totalBytes += fileSize;
          } catch (fileErr) {
            debugPrint('单个缓存文件迁移跳过: ${entity.path} -> $fileErr');
          }
        }
      }

      _customPath = newPath.trim();

      return CacheMigrationResult(
        success: true,
        movedFilesCount: movedCount,
        movedBytes: totalBytes,
      );
    } catch (e) {
      debugPrint('迁移缓存文件失败: $e');
      _customPath = newPath.trim();
      return CacheMigrationResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// 判断是否属于缓存与临时多媒体文件
  bool _isCacheFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.m4a') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.tmp') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.contains('audio_msg_') ||
        lower.contains('tts_output_') ||
        lower.contains('raw_img_');
  }

  /// 迁移时是否跳过这个文件（传**相对路径**即可）。
  ///
  /// 规则分两层：
  /// 1. **永远跳过已知第三方插件的临时目录**（`file_picker` 等）—— 里面可能有别的
  ///    进程正在持有的只读锁文件，搬走会让插件本身出错；
  /// 2. 如果源目录是**共享的系统临时目录**（桌面端历史遗留的 `%TEMP%`），只搬我们自己
  ///    产生的媒体文件（[_isCacheFile] 白名单），否则会把别人的临时文件一起搬走；
  ///    其余情况（App 独占目录）**整份搬**。
  bool _shouldSkipInMigration(String relativePath, bool oldDirIsSharedTemp) {
    final lower = relativePath.toLowerCase().replaceAll('\\', '/');
    for (final marker in const ['/file_picker/', '/flutter_', '/.trash/']) {
      if (lower.contains(marker)) return true;
    }
    if (oldDirIsSharedTemp) return !_isCacheFile(lower);
    return false;
  }
}
