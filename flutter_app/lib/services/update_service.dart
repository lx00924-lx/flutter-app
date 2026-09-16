import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_settings.dart';
import '../utils/http_client_helper.dart';
import '../utils/url_launcher_helper.dart';

class UpdateCheckResult {
  final bool isSuccess;
  final String? errorMessage;
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;
  final String releaseName;
  final String releaseNotes;
  final String releaseUrl;
  final String platformName;
  final String? matchedAssetFileName;
  final String? downloadUrl;
  final int fileSize;

  UpdateCheckResult({
    required this.isSuccess,
    this.errorMessage,
    this.hasUpdate = false,
    this.currentVersion = AppSettings.currentVersion,
    this.latestVersion = AppSettings.currentVersion,
    this.releaseName = '',
    this.releaseNotes = '',
    this.releaseUrl = AppSettings.officialGithubReleasesUrl,
    this.platformName = '通用设备',
    this.matchedAssetFileName,
    this.downloadUrl,
    this.fileSize = 0,
  });

  String get formattedFileSize {
    if (fileSize <= 0) return '';
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class UpdateService {
  static final Dio _dio = () {
    final dio = Dio(
      BaseOptions(
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'LxAI-Flutter-App',
        },
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    HttpClientHelper.configureProxy(dio);
    return dio;
  }();

  // 全局下载状态（支持弹窗关闭后在后台持续运行，重新打开秒恢复）
  static bool isDownloading = false;
  static String activeDownloadingVersion = '';
  static final ValueNotifier<double> downloadProgressNotifier = ValueNotifier<double>(0.0);
  static final ValueNotifier<String> downloadStatusNotifier = ValueNotifier<String>('');
  static CancelToken? _activeCancelToken;

  /// 检查本地是否已经下载过该版本的完整安装包
  static Future<File?> checkCachedPackage(String version, String? fileName, int expectedSize) async {
    if (kIsWeb) return null;
    try {
      final filePath = await getLocalPackagePath(version, fileName);
      final file = File(filePath);
      if (await file.exists()) {
        final length = await file.length();
        if (expectedSize > 0) {
          if (length == expectedSize) return file;
        } else if (length > 1024 * 1024) {
          return file;
        }
      }
    } catch (e) {
      debugPrint('检查本地已下载安装包失败: $e');
    }
    return null;
  }

  /// 获取本地固件存储的标准安全绝对路径
  static Future<String> getLocalPackagePath(String version, String? fileName) async {
    final dir = await getTemporaryDirectory();
    final cleanVer = version.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    String ext = '';
    if (fileName != null && fileName.contains('.')) {
      ext = fileName.substring(fileName.lastIndexOf('.'));
    } else {
      if (Platform.isAndroid) {
        ext = '.apk';
      } else if (Platform.isWindows) {
        ext = '.exe';
      } else {
        ext = '.bin';
      }
    }
    return '${dir.path}/LxAI_Update_v$cleanVer$ext';
  }

  /// 直接调起本地安装
  static Future<bool> installCachedPackage(String filePath) async {
    if (kIsWeb) return false;
    try {
      if (Platform.isAndroid) {
        return await UrlLauncherHelper.installApk(filePath);
      } else if (Platform.isWindows) {
        return await UrlLauncherHelper.launchWindowsInstaller(filePath);
      }
    } catch (e) {
      debugPrint('调起安装失败: $e');
    }
    return false;
  }

  /// 取消当前下载
  static void cancelDownload() {
    if (isDownloading && _activeCancelToken != null) {
      _activeCancelToken?.cancel('用户取消下载');
      isDownloading = false;
      downloadStatusNotifier.value = '已取消下载';
      if (!kIsWeb && Platform.isAndroid) {
        UrlLauncherHelper.cancelNotification();
      }
    }
  }

  /// 应用内流式分块下载并在完成后自动调起原生安装
  static Future<bool> startInAppDownload({
    required UpdateCheckResult result,
    VoidCallback? onComplete,
  }) async {
    final downloadUrl = result.downloadUrl;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      return false;
    }

    if (isDownloading) return true;

    isDownloading = true;
    activeDownloadingVersion = result.latestVersion;
    downloadProgressNotifier.value = 0.0;
    downloadStatusNotifier.value = '准备下载...';
    _activeCancelToken = CancelToken();

    final targetPath = await getLocalPackagePath(result.latestVersion, result.matchedAssetFileName);
    final tempPath = '$targetPath.downloading';

    try {
      // 在 Android 13+ 环境下，提前触发通知权限动态申请，确保状态栏进度条能正常展示
      if (!kIsWeb && Platform.isAndroid) {
        await UrlLauncherHelper.requestNotificationPermission();
      }

      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      int lastNotificationTime = 0;
      int lastNotificationProgress = -1;

      final response = await _dio.download(
        downloadUrl,
        tempPath,
        cancelToken: _activeCancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = received / total;
            downloadProgressNotifier.value = progress;
            final receivedMb = (received / 1024 / 1024).toStringAsFixed(1);
            final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
            final percentInt = (progress * 100).toInt();

            downloadStatusNotifier.value = '$receivedMb MB / $totalMb MB ($percentInt%)';

            // 节流更新系统通知栏（至少间隔 350ms 或进度递增 ≥ 2%）
            final now = DateTime.now().millisecondsSinceEpoch;
            if (percentInt != lastNotificationProgress &&
                (percentInt - lastNotificationProgress >= 2 || now - lastNotificationTime > 350)) {
              lastNotificationTime = now;
              lastNotificationProgress = percentInt;

              UrlLauncherHelper.showDownloadNotification(
                progress: percentInt,
                max: 100,
                title: '正在下载 LxAI v${result.latestVersion}',
                content: '$receivedMb MB / $totalMb MB ($percentInt%)',
              );
            }
          } else {
            final receivedMb = (received / 1024 / 1024).toStringAsFixed(1);
            downloadStatusNotifier.value = '已下载 $receivedMb MB';
          }
        },
      );

      if (response.statusCode == 200 || response.statusCode == 206) {
        // 下载完成，原子重命名为正式目标文件
        final downloadedTemp = File(tempPath);
        if (await downloadedTemp.exists()) {
          final targetFile = File(targetPath);
          if (await targetFile.exists()) {
            await targetFile.delete();
          }
          await downloadedTemp.rename(targetPath);
        }

        downloadProgressNotifier.value = 1.0;
        downloadStatusNotifier.value = '下载完成，正在调起安装...';

        // Android 更新常驻完成通知（可点击重新安装）
        if (!kIsWeb && Platform.isAndroid) {
          await UrlLauncherHelper.completeDownloadNotification(
            apkPath: targetPath,
            title: 'LxAI v${result.latestVersion} 下载完成',
            content: '点击立即安装新版本',
          );
        }

        // 自动弹出系统安装界面 / Windows 独立脱钩拉起
        await installCachedPackage(targetPath);

        if (onComplete != null) onComplete();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('应用内下载发生异常: $e');
      downloadStatusNotifier.value = '下载中断: $e';
      if (!kIsWeb && Platform.isAndroid) {
        UrlLauncherHelper.cancelNotification();
      }
      return false;
    } finally {
      isDownloading = false;
    }
  }

  /// 检查 GitHub 官方发布源的最新 Releases，并根据当前操作系统自动匹配安装包文件
  static Future<UpdateCheckResult> checkUpdate() async {
    final currentVer = AppSettings.currentVersion;
    final owner = AppSettings.officialGithubOwner;
    final repo = AppSettings.officialGithubRepo;
    final apiUrl = 'https://api.github.com/repos/$owner/$repo/releases/latest';

    try {
      final response = await _dio.get(apiUrl);
      if (response.statusCode != 200 || response.data == null) {
        return UpdateCheckResult(
          isSuccess: false,
          errorMessage: '检查失败: HTTP ${response.statusCode}',
        );
      }

      final Map<String, dynamic> data = response.data is Map
          ? (response.data as Map).cast<String, dynamic>()
          : <String, dynamic>{};

      final tagName = (data['tag_name'] as String? ?? '').trim();
      final releaseName = (data['name'] as String? ?? tagName).trim();
      final releaseNotes = (data['body'] as String? ?? '暂无更新日志说明').trim();
      final releaseHtmlUrl = (data['html_url'] as String? ?? AppSettings.officialGithubReleasesUrl).trim();

      // 去除可能的前缀 'v' 或 'V'
      final cleanLatest = tagName.replaceAll(RegExp(r'^[vV]'), '').trim();
      final cleanCurrent = currentVer.replaceAll(RegExp(r'^[vV]'), '').trim();

      final bool hasUpdate = _isVersionNewer(cleanLatest, cleanCurrent);

      // 自动识别当前运行平台
      String platformName = '通用设备';
      String? matchedFileName;
      String? downloadUrl;
      int fileSize = 0;

      final assets = (data['assets'] as List<dynamic>?) ?? [];

      if (!kIsWeb) {
        if (Platform.isAndroid) {
          platformName = 'Android';
          // 优先匹配 .apk 文件
          for (final rawAsset in assets) {
            final asset = rawAsset as Map<dynamic, dynamic>;
            final name = (asset['name'] as String? ?? '').toLowerCase();
            if (name.endsWith('.apk')) {
              matchedFileName = asset['name'] as String?;
              downloadUrl = asset['browser_download_url'] as String?;
              fileSize = (asset['size'] as num?)?.toInt() ?? 0;
              break;
            }
          }
        } else if (Platform.isWindows) {
          platformName = 'Windows';
          // 优先匹配 .exe 或 .zip
          for (final rawAsset in assets) {
            final asset = rawAsset as Map<dynamic, dynamic>;
            final name = (asset['name'] as String? ?? '').toLowerCase();
            if (name.endsWith('.zip') || name.endsWith('.exe')) {
              matchedFileName = asset['name'] as String?;
              downloadUrl = asset['browser_download_url'] as String?;
              fileSize = (asset['size'] as num?)?.toInt() ?? 0;
              break;
            }
          }
        } else if (Platform.isMacOS) {
          platformName = 'macOS';
          for (final rawAsset in assets) {
            final asset = rawAsset as Map<dynamic, dynamic>;
            final name = (asset['name'] as String? ?? '').toLowerCase();
            if (name.endsWith('.dmg') || name.endsWith('.zip')) {
              matchedFileName = asset['name'] as String?;
              downloadUrl = asset['browser_download_url'] as String?;
              fileSize = (asset['size'] as num?)?.toInt() ?? 0;
              break;
            }
          }
        } else if (Platform.isLinux) {
          platformName = 'Linux';
          for (final rawAsset in assets) {
            final asset = rawAsset as Map<dynamic, dynamic>;
            final name = (asset['name'] as String? ?? '').toLowerCase();
            if (name.endsWith('.appimage') || name.endsWith('.tar.gz') || name.endsWith('.deb')) {
              matchedFileName = asset['name'] as String?;
              downloadUrl = asset['browser_download_url'] as String?;
              fileSize = (asset['size'] as num?)?.toInt() ?? 0;
              break;
            }
          }
        }
      }

      // 如果未找到平台专门附件，退回到该 Release 网页地址
      downloadUrl ??= releaseHtmlUrl;

      return UpdateCheckResult(
        isSuccess: true,
        hasUpdate: hasUpdate,
        currentVersion: currentVer,
        latestVersion: cleanLatest.isNotEmpty ? cleanLatest : tagName,
        releaseName: releaseName,
        releaseNotes: releaseNotes,
        releaseUrl: releaseHtmlUrl,
        platformName: platformName,
        matchedAssetFileName: matchedFileName,
        downloadUrl: downloadUrl,
        fileSize: fileSize,
      );
    } catch (e) {
      debugPrint('检查更新失败: $e');
      return UpdateCheckResult(
        isSuccess: false,
        errorMessage: '连接更新服务器失败: $e',
      );
    }
  }

  /// 语义化版本号比对 (X.Y.Z)
  static bool _isVersionNewer(String latest, String current) {
    if (latest.isEmpty) return false;
    try {
      final latestParts = latest
          .split('.')
          .map((e) => int.tryParse(RegExp(r'\d+').stringMatch(e) ?? '0') ?? 0)
          .toList();
      final currentParts = current
          .split('.')
          .map((e) => int.tryParse(RegExp(r'\d+').stringMatch(e) ?? '0') ?? 0)
          .toList();

      while (latestParts.length < 3) latestParts.add(0);
      while (currentParts.length < 3) currentParts.add(0);

      for (int i = 0; i < 3; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
      return false;
    } catch (_) {
      return latest != current;
    }
  }
}
