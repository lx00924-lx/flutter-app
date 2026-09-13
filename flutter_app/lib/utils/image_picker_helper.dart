import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../services/storage_path_service.dart';

/// 选取的通用文件元数据
class PickedFileData {
  final String name;
  final int size;
  final String? extension;
  final String? path;
  final String base64Data;

  PickedFileData({
    required this.name,
    required this.size,
    this.extension,
    this.path,
    required this.base64Data,
  });
}

/// 选取的图片完整包结构（包含本地原图路径、用于云端极速同步的轻量缩略图、以及发给大模型的8K超清Base64）
class ProcessedImageResult {
  final String? localFilePath;
  final String thumbnailBase64;
  final String highResBase64;
  final int originalBytesLength;

  ProcessedImageResult({
    this.localFilePath,
    required this.thumbnailBase64,
    required this.highResBase64,
    required this.originalBytesLength,
  });

  /// 格式化为持久化存储的附件字符串
  /// 协议格式: data:image/...;thumbnail=...;localPath=...;base64,...
  String toAttachmentString() {
    if (localFilePath != null && localFilePath!.isNotEmpty) {
      return '$thumbnailBase64#localPath=${Uri.encodeComponent(localFilePath!)}';
    }
    return thumbnailBase64;
  }
}

/// 图片选择、相机拍摄与通用文件编解码工具类，支持最大 8K 高清模型直传与本地原图落盘
class ImagePickerHelper {
  static final ImagePicker _imagePicker = ImagePicker();

  /// 将大尺寸图片等比缩放至目标分辨率，最大支持 8K (7680px)
  static Future<Uint8List> resizeImageBytes(Uint8List bytes, {required int maxDimension, int quality = 85}) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: maxDimension,
      );
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        return byteData.buffer.asUint8List();
      }
    } catch (e) {
      debugPrint('resizeImageBytes fallback: $e');
    }
    return bytes;
  }

  /// 生成极轻量缩略图 (最长边 400px，仅几十 KB)
  static Future<String> generateThumbnail(Uint8List rawBytes, String mime) async {
    try {
      final thumbBytes = await resizeImageBytes(rawBytes, maxDimension: 400);
      final b64 = base64Encode(thumbBytes);
      return 'data:$mime;base64,$b64';
    } catch (e) {
      debugPrint('generateThumbnail error: $e');
      final b64 = base64Encode(rawBytes);
      return 'data:$mime;base64,$b64';
    }
  }

  /// 处理原始图片字节：
  /// 1. 保存原图到用户指定的自定义路径 (localPath)
  /// 2. 生成轻量缩略图 (供云端同步与本地缓存清理后兜底回显)
  /// 3. 生成大模型超清可用 Base64
  static Future<ProcessedImageResult?> processRawImageBytes(
    Uint8List rawBytes, {
    required String extension,
    String prefix = 'raw_img',
  }) async {
    if (rawBytes.isEmpty) return null;

    final ext = extension.replaceAll('.', '').toLowerCase();
    final mime = (ext == 'jpg' || ext == 'jpeg')
        ? 'image/jpeg'
        : ext == 'webp'
            ? 'image/webp'
            : ext == 'gif'
                ? 'image/gif'
                : 'image/png';

    // 1. 本地原图落盘保存到自定义路径 (安全容错)
    String? savedPath;
    try {
      savedPath = await StoragePathService.instance.saveRawImageToDisk(
        bytes: rawBytes,
        extension: ext,
        prefix: prefix,
      );
    } catch (e) {
      debugPrint('saveRawImageToDisk error: $e');
    }

    // 2. 快速生成 Base64 Data URI
    final rawBase64 = base64Encode(rawBytes);
    final fullDataUri = 'data:$mime;base64,$rawBase64';

    // 3. 生成缩略图 (若大于 200KB 则压缩缩略图，否则直接使用原图)
    String thumbB64 = fullDataUri;
    if (rawBytes.lengthInBytes > 200 * 1024) {
      try {
        final thumbBytes = await resizeImageBytes(rawBytes, maxDimension: 400);
        thumbB64 = 'data:$mime;base64,${base64Encode(thumbBytes)}';
      } catch (_) {
        thumbB64 = fullDataUri;
      }
    }

    return ProcessedImageResult(
      localFilePath: savedPath,
      thumbnailBase64: thumbB64,
      highResBase64: fullDataUri,
      originalBytesLength: rawBytes.lengthInBytes,
    );
  }

  /// 1. 从手机系统相册选择图片（支持 ImagePicker + FilePicker 双通道双重兜底）
  static Future<ProcessedImageResult?> pickImageFromGallery() async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      if (photo != null) {
        final Uint8List bytes = await photo.readAsBytes();
        final ext = photo.name.contains('.') ? photo.name.split('.').last.toLowerCase() : 'png';
        return await processRawImageBytes(bytes, extension: ext, prefix: 'gallery');
      }
    } catch (e) {
      debugPrint('ImagePicker gallery error, trying FilePicker fallback: $e');
    }

    // 兜底通道：使用系统文件/媒体选择器
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        Uint8List? bytes = file.bytes;
        if (bytes == null && file.path != null && file.path!.isNotEmpty) {
          final ioFile = File(file.path!);
          if (await ioFile.exists()) {
            bytes = await ioFile.readAsBytes();
          }
        }
        if (bytes != null && bytes.isNotEmpty) {
          final ext = (file.extension ?? 'png').toLowerCase();
          return await processRawImageBytes(bytes, extension: ext, prefix: 'gallery');
        }
      }
    } catch (e2) {
      debugPrint('FilePicker gallery fallback error: $e2');
    }

    return null;
  }

  /// 选择图片并直接转为 Base64 字符串（用于头像、背景图、启动图等设置项）
  static Future<String?> pickImageAsBase64({int maxDimension = 1024}) async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (photo == null) return null;

      Uint8List bytes = await photo.readAsBytes();
      if (maxDimension > 0) {
        bytes = await resizeImageBytes(bytes, maxDimension: maxDimension);
      }
      final ext = photo.name.split('.').last.toLowerCase();
      final mime = (ext == 'jpg' || ext == 'jpeg')
          ? 'image/jpeg'
          : ext == 'webp'
              ? 'image/webp'
              : ext == 'gif'
                  ? 'image/gif'
                  : 'image/png';
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (e) {
      debugPrint('pickImageAsBase64 error: $e');
      return null;
    }
  }

  /// 2. 调用手机硬件相机拍照
  static Future<ProcessedImageResult?> takePhotoFromCamera() async {
    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        // 保持相机 100% 原始画质与分辨率
        imageQuality: 100,
      );
      if (photo == null) return null;

      final Uint8List bytes = await photo.readAsBytes();
      final ext = photo.name.split('.').last.toLowerCase();
      return await processRawImageBytes(bytes, extension: ext, prefix: 'camera');
    } catch (e) {
      debugPrint('takePhotoFromCamera error: $e');
      return null;
    }
  }

  /// 3. 打开系统文件管理器选择任意文件
  static Future<PickedFileData?> pickGenericFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return null;
      final file = result.files.first;

      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null && file.path!.isNotEmpty) {
        final ioFile = File(file.path!);
        if (await ioFile.exists()) {
          bytes = await ioFile.readAsBytes();
        }
      }

      if (bytes == null || bytes.isEmpty) return null;

      final base64String = base64Encode(bytes);
      final ext = (file.extension ?? '').toLowerCase();
      final prefix = 'data:application/octet-stream;name=${Uri.encodeComponent(file.name)};base64,';

      return PickedFileData(
        name: file.name,
        size: file.size,
        extension: ext,
        path: file.path,
        base64Data: '$prefix$base64String',
      );
    } catch (e) {
      debugPrint('pickGenericFile error: $e');
      return null;
    }
  }

  /// 将可能包含 data:image/...;base64, 或带 #localPath 扩展属性的字符串安全提取为 Base64 解码后的 Uint8List
  static Uint8List? decodeBase64Image(String? source) {
    if (source == null || source.trim().isEmpty) return null;
    try {
      String cleanBase64 = source.trim();
      if (cleanBase64.contains('#localPath=')) {
        cleanBase64 = cleanBase64.split('#localPath=').first;
      }
      if (cleanBase64.contains(',')) {
        cleanBase64 = cleanBase64.split(',').last;
      }
      cleanBase64 = cleanBase64.replaceAll('\n', '').replaceAll('\r', '').replaceAll(' ', '');
      return base64Decode(cleanBase64);
    } catch (e) {
      debugPrint('decodeBase64Image error: $e');
      return null;
    }
  }

  /// 解析附件字符串中的本地原图路径
  static String? extractLocalPathFromAttachment(String attachment) {
    if (attachment.contains('#localPath=')) {
      try {
        final encodedPath = attachment.split('#localPath=').last;
        return Uri.decodeComponent(encodedPath);
      } catch (_) {}
    }
    return null;
  }
}
