import 'dart:convert';
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

/// 上次没跑完的缓存迁移，被启动时收拾成什么样了。
class CacheMigrationRecovery {
  /// `none` = 没有待收拾的（或收拾失败）；`forward` = 已补完并切到新路径；`rollback` = 已回滚到原路径
  final String action;
  final String path;
  final int movedFiles;
  final String? error;

  const CacheMigrationRecovery({
    required this.action,
    this.path = '',
    this.movedFiles = 0,
    this.error,
  });

  bool get hasAnything => action != 'none';
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

  /// 将旧路径下的缓存文件无缝迁移至新选定的目录。
  ///
  /// 三个防坑点（2026-11-14 补）：
  /// 1. **进度**：先数一遍要搬的文件数，再逐个搬，通过 [onProgress] 回传「已搬 / 总数」；
  /// 2. **兜底**：切换 `_customPath` 之后**再扫一遍旧目录** —— 迁移期间后台新写入的文件、
  ///    以及「当时被别的进程占用而 rename 失败」的文件，都在这遍里捞回来；
  /// 3. **崩溃恢复**：动手搬之前先写一个标记文件，收尾后删掉。中途被强杀/断电时标记还在，
  ///    下次启动由 [recoverInterruptedMigration] 接手（能前滚就前滚，否则回滚）。
  Future<CacheMigrationResult> migrateCacheToNewDirectory({
    required String oldPath,
    required String newPath,
    void Function(int moved, int total)? onProgress,
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
      final probeError = await _probeWritable(targetDir);
      if (probeError != null) {
        return CacheMigrationResult(success: false, error: probeError);
      }

      if (!await oldDir.exists()) {
        _customPath = newPath.trim();
        return const CacheMigrationResult(success: true, movedFilesCount: 0, movedBytes: 0);
      }

      // 源目录是不是**共享的系统临时目录**（桌面端历史默认就是 %TEMP%，整个用户共用）：
      // 是的话只能按白名单挑自己的文件，绝不能整份搬。
      final oldDirIsSharedTemp = await _isSharedTempDir(oldDir);

      // 标记必须在**动手搬之前**写：它代表"这次迁移开始了、还没收尾"。
      await _writeMarker(oldDir.path, targetDir.path);

      // 第一遍：先数总数（只读元数据，很快），再逐个搬并回传进度
      final total = await _countMigratable(oldDir, oldDirIsSharedTemp);
      onProgress?.call(0, total);
      var movedCount = 0;
      var totalBytes = 0.0;
      await _moveBatch(
        oldDir: oldDir,
        targetDir: targetDir,
        oldDirIsSharedTemp: oldDirIsSharedTemp,
        onMoved: (size) {
          movedCount++;
          totalBytes += size;
          onProgress?.call(movedCount, total);
        },
      );

      // 先切路径：让**此后新的写入**立刻落到新目录，第二遍才扫得干净
      _customPath = newPath.trim();

      // 第二遍（兜底）：迁移期间后台生成的、以及当时被占用没搬走的，都在这遍捞
      await _moveBatch(
        oldDir: oldDir,
        targetDir: targetDir,
        oldDirIsSharedTemp: oldDirIsSharedTemp,
        onMoved: (size) {
          movedCount++;
          totalBytes += size;
        },
      );

      await _clearMarker();

      return CacheMigrationResult(
        success: true,
        movedFilesCount: movedCount,
        movedBytes: totalBytes,
      );
    } catch (e) {
      debugPrint('迁移缓存文件失败: $e');
      // 这里**故意不切 `_customPath`、也不清标记**：留下现场让下次启动的
      // recoverInterruptedMigration() 接手（能前滚就前滚，否则回滚）。
      // 否则会出现「一半在新目录、一半在旧目录，而路径已经指向新目录」的最坏状态。
      return CacheMigrationResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// 探测目录可写；返回 null 表示可写，否则返回给用户看的错误文案。
  Future<String?> _probeWritable(Directory dir) async {
    try {
      final probeFile = File('${dir.path}/.probe_write_${DateTime.now().millisecondsSinceEpoch}.tmp');
      await probeFile.writeAsString('ok');
      if (await probeFile.exists()) {
        await probeFile.delete();
      }
      return null;
    } catch (e) {
      return '目标文件夹无写入权限，请选择其他目录或在系统设置中允许应用管理文件 ($e)';
    }
  }

  /// 这个目录是不是「全用户共享的系统临时目录」（桌面端的 `%TEMP%`）。
  Future<bool> _isSharedTempDir(Directory dir) async {
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return false;
    try {
      final temp = await getTemporaryDirectory();
      return dir.path == temp.path;
    } catch (_) {
      return false;
    }
  }

  /// 数一遍**这次迁移会搬走**的文件数（只读元数据，不读内容）。
  Future<int> _countMigratable(Directory oldDir, bool oldDirIsSharedTemp) async {
    var count = 0;
    try {
      await for (final entity in oldDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relativePath = entity.path.substring(oldDir.path.length);
        if (_shouldSkipInMigration(relativePath, oldDirIsSharedTemp)) continue;
        count++;
      }
    } catch (_) {}
    return count;
  }

  /// 搬一遍：把 [oldDir] 里该搬的文件移到 [targetDir]，每成功一个回调 [onMoved]（传文件字节数）。
  ///
  /// 单文件失败只跳过、不中断整体 —— 典型是「文件正被别的进程占用」。
  Future<void> _moveBatch({
    required Directory oldDir,
    required Directory targetDir,
    required bool oldDirIsSharedTemp,
    void Function(int size)? onMoved,
  }) async {
    await for (final entity in oldDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
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
        onMoved?.call(fileSize);
      } catch (fileErr) {
        debugPrint('单个缓存文件迁移跳过: ${entity.path} -> $fileErr');
      }
    }
  }

  // ===== 迁移标记（崩溃恢复） =====
  //
  // 为什么要它：迁移是「先搬、最后才切路径」，中途被强杀/断电会出现
  // 「旧目录被搬走一部分 + 新目录里一堆孤儿 + 设置仍指旧目录」的三不像状态。
  // 标记文件放在 App 数据目录（**不能放缓存目录**，那里会被搬走或清掉）。

  static const String _markerName = '.cache_migrate_in_progress.json';

  Future<File> _markerFile() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(support.path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$_markerName');
  }

  Future<void> _writeMarker(String oldPath, String newPath) async {
    try {
      final f = await _markerFile();
      // ⚠️ `flush: true` 不能省。
      //
      // 默认 flush=false 时，数据只落到操作系统的页缓存就返回了。进程被强杀没关系
      // （OS 自己会刷），但**突然断电**时这份标记可能根本没落盘 —— 下次开机会读不到它，
      // 于是「以为从没迁过」，而现场其实是「旧目录搬走一半 + 新目录一堆孤儿 + 设置还指旧目录」，
      // 正是这套崩溃恢复要防的那种三不像。
      // 加上 flush 之后，只要这一行返回了，断电再开也一定能走到 recoverInterruptedMigration。
      await f.writeAsString(
        jsonEncode({
          'oldPath': oldPath,
          'newPath': newPath,
          'startedAt': DateTime.now().millisecondsSinceEpoch,
        }),
        flush: true,
      );
    } catch (e) {
      // 写不了标记不该阻断迁移本身
      debugPrint('写迁移标记失败（本次迁移继续）: $e');
    }
  }

  Future<Map<String, dynamic>?> _readMarker() async {
    try {
      final f = await _markerFile();
      if (!await f.exists()) return null;
      final decoded = jsonDecode(await f.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearMarker() async {
    try {
      final f = await _markerFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 启动时收拾上次没跑完的缓存迁移（App 被强杀、电脑断电都走这里）。
  ///
  /// 策略：**能前滚就前滚**（把旧目录剩下的继续搬过去、切到新路径），
  /// 目标不可用（比如选的 U 盘拔了）就**回滚**（把新目录里已搬过去的搬回旧目录）。
  /// 两种情况都不留「两边都不完整」。
  Future<CacheMigrationRecovery> recoverInterruptedMigration() async {
    if (kIsWeb) return const CacheMigrationRecovery(action: 'none');

    final marker = await _readMarker();
    if (marker == null) return const CacheMigrationRecovery(action: 'none');

    final oldPath = (marker['oldPath'] ?? '').toString().trim();
    final newPath = (marker['newPath'] ?? '').toString().trim();

    if (oldPath.isEmpty || newPath.isEmpty) {
      await _clearMarker();
      return const CacheMigrationRecovery(action: 'none');
    }

    final oldDir = Directory(oldPath);
    final targetDir = Directory(newPath);

    // ---- 前滚 ----
    if (await targetDir.exists()) {
      final probeError = await _probeWritable(targetDir);
      if (probeError == null) {
        try {
          if (await oldDir.exists()) {
            final sharedTemp = await _isSharedTempDir(oldDir);
            await _moveBatch(
              oldDir: oldDir,
              targetDir: targetDir,
              oldDirIsSharedTemp: sharedTemp,
            );
          }
          _customPath = newPath;
          await _clearMarker();
          debugPrint('[StoragePath] 上次的缓存迁移已补完，路径切到 $newPath');
          return CacheMigrationRecovery(action: 'forward', path: newPath);
        } catch (e) {
          debugPrint('[StoragePath] 补完迁移失败，转回滚: $e');
        }
      }
    }

    // ---- 回滚 ----
    var rolledBack = 0;
    try {
      if (await oldDir.exists() && await targetDir.exists()) {
        await for (final entity in targetDir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final relativePath = entity.path.substring(targetDir.path.length);
          // 只搬"我们自己认得的缓存文件"，别动用户放在那个目录里的其它东西
          if (!_isCacheFile(relativePath)) continue;
          try {
            final backPath = '${oldDir.path}$relativePath';
            final parent = File(backPath).parent;
            if (!await parent.exists()) {
              await parent.create(recursive: true);
            }
            await entity.rename(backPath);
            rolledBack++;
          } catch (_) {}
        }
      }
      await _clearMarker();
      debugPrint('[StoragePath] 上次的缓存迁移已回滚（$rolledBack 个文件搬回原目录）');
      return CacheMigrationRecovery(action: 'rollback', path: oldPath, movedFiles: rolledBack);
    } catch (e) {
      return CacheMigrationRecovery(action: 'none', error: e.toString());
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
