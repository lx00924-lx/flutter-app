import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../services/storage_path_service.dart';

/// `compute` 入口：把图片解码后压进"字节预算"里。
///
/// 放在顶层（isolate 入口必须是顶层/静态函数），返回 JPEG 字节；解码失败返回 null。
/// 策略：先按最长边缩到 [maxDimension]（仅当原图更大），再按 82 质量编码 JPEG；
/// 若仍超过 [maxBytes] 就每轮 ×0.75 继续降分辨率，最多 6 轮或到 64px 为止。
Uint8List? _compressImageToBudget(Map<String, dynamic> request) {
  final bytes = request['bytes'] as Uint8List?;
  final maxDimension = (request['maxDimension'] as int?) ?? 1024;
  final maxBytes = (request['maxBytes'] as int?) ?? 256 * 1024;
  if (bytes == null || bytes.isEmpty) return null;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var current = decoded;

  final longest = current.width >= current.height ? current.width : current.height;
  if (longest > maxDimension) {
    current = current.width >= current.height
        ? img.copyResize(current, width: maxDimension, interpolation: img.Interpolation.average)
        : img.copyResize(current, height: maxDimension, interpolation: img.Interpolation.average);
  }

  var encoded = img.encodeJpg(current, quality: 82);
  var round = 0;
  while (encoded.length > maxBytes && round < 6) {
    round++;
    final nextWidth = (current.width * 0.75).round();
    final nextHeight = (current.height * 0.75).round();
    if (nextWidth < 64 || nextHeight < 64) break;
    current = img.copyResize(
      current,
      width: nextWidth,
      height: nextHeight,
      interpolation: img.Interpolation.average,
    );
    encoded = img.encodeJpg(current, quality: 82);
  }
  return encoded;
}

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

  /// 转成 DSH 宿主 prompt 需要的图片结构（`{data, mediaType, name}`）。
  ///
  /// 几个必须踩准的点：
  /// - **用 highResBase64 而不是 thumbnailBase64**：后者是给界面列表显示用的 400px 缩略图，
  ///   发给模型等于让它看糊图。
  /// - **剥掉 `data:image/png;base64,` 前缀**：宿主收的是裸 base64 字符串，而且会逐字节
  ///   校验规范性（`decoded.toString('base64') !== data` 就报 INVALID_IMAGE_BASE64）。
  ///   Dart 的 base64Encode 本身产出的就是规范 base64，所以这里只做切分、**绝不重新编码**。
  /// - **只放行 png / jpeg / webp**：宿主的 mediaTypes 就这三种，gif 之类塞过去会被
  ///   UNSUPPORTED_IMAGE_TYPE 拒收。返回 null 让调用方跳过并提示，好过整轮任务失败。
  ///
  /// @returns 可直接放进 `images` 数组的 Map；格式不受支持时返回 null。
  Map<String, dynamic>? toDshImagePart({String? name}) {
    final uri = highResBase64;
    if (!uri.startsWith('data:')) return null;
    final comma = uri.indexOf(',');
    if (comma < 0) return null;
    final header = uri.substring(5, comma); // 形如 image/png;base64
    final data = uri.substring(comma + 1);
    if (data.isEmpty) return null;
    final mediaType = header.split(';').first.trim().toLowerCase();
    const accepted = {'image/png', 'image/jpeg', 'image/webp'};
    if (!accepted.contains(mediaType)) return null;
    return {
      'data': data,
      'mediaType': mediaType,
      if (name != null && name.isNotEmpty) 'name': name,
    };
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

  /// 1. 从手机系统相册选择图片（优先调起系统应用分发意图，让用户直接选择“图片库/相册”，双通道安全兜底）
  static Future<ProcessedImageResult?> pickImageFromGallery() async {
    // 优先通道：使用标准系统媒体选择意图 (ACTION_GET_CONTENT)，直接唤起多相册选择面板
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        Uint8List? bytes = file.bytes;
        if ((bytes == null || bytes.isEmpty) && file.path != null && file.path!.isNotEmpty) {
          final ioFile = File(file.path!);
          if (await ioFile.exists()) {
            bytes = await ioFile.readAsBytes();
          }
        }
        if (bytes != null && bytes.isNotEmpty) {
          final ext = (file.extension ?? (file.name.contains('.') ? file.name.split('.').last : 'png')).toLowerCase();
          return await processRawImageBytes(bytes, extension: ext, prefix: 'gallery');
        }
      } else if (result == null) {
        // 用户主动取消选择
        return null;
      }
    } catch (e) {
      debugPrint('FilePicker gallery primary failed, fallback to ImagePicker: $e');
    }

    // 备用通道：ImagePicker 兜底
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
    } catch (e2) {
      debugPrint('ImagePicker gallery fallback error: $e2');
    }

    return null;
  }

  /// 从相册**多选**图片（一次可挑多张）。
  ///
  /// 与单数版的分工：单数版留给"选一张替换"的场景（头像、背景、启动图），
  /// 这个专门给聊天附件 —— 用户可以一次挑好几张，也可以反复进来追加
  /// （调用方把结果 `addAll` 进待发列表即可）。
  ///
  /// 刻意只走 FilePicker 的 allowMultiple，不保留 image_picker 兜底：
  /// 后者在聊天附件这条路上本来就没用到，而多一张兜底就多一条"同一个操作
  /// 在不同机型上行为不一致"的排查路径。单张失败只跳过那一张，不中断整批 ——
  /// 用户选了 10 张、其中一张坏了，不该让另外 9 张也发不出去。
  static Future<List<ProcessedImageResult>> pickImagesFromGallery() async {
    final out = <ProcessedImageResult>[];
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return out;
      for (final file in result.files) {
        try {
          Uint8List? bytes = file.bytes;
          if ((bytes == null || bytes.isEmpty) && file.path != null && file.path!.isNotEmpty) {
            final ioFile = File(file.path!);
            if (await ioFile.exists()) bytes = await ioFile.readAsBytes();
          }
          if (bytes == null || bytes.isEmpty) continue;
          final ext = (file.extension ?? (file.name.contains('.') ? file.name.split('.').last : 'png')).toLowerCase();
          final processed = await processRawImageBytes(bytes, extension: ext, prefix: 'gallery');
          if (processed != null) out.add(processed);
        } catch (e) {
          debugPrint('多选相册：单张处理失败已跳过（$e）');
        }
      }
    } catch (e) {
      debugPrint('多选相册失败: $e');
    }
    return out;
  }

  /// 把**已有的** data URI 压进预算（用于历史遗留的超大图片字段）。
  ///
  /// 与 [pickImageAsBase64] 共用同一条压缩链路，失败返回 null（调用方保留原值）。
  static Future<String?> compressImageDataUri(
    String dataUri, {
    required int maxDimension,
    required int maxBytes,
  }) async {
    try {
      if (!dataUri.startsWith('data:image/') || !dataUri.contains(',')) return null;
      final bytes = base64Decode(dataUri.split(',').last);
      if (bytes.isEmpty) return null;
      final compressed = await compute(_compressImageToBudget, <String, dynamic>{
        'bytes': bytes,
        'maxDimension': maxDimension,
        'maxBytes': maxBytes,
      });
      if (compressed == null || compressed.isEmpty) return null;
      return 'data:image/jpeg;base64,${base64Encode(compressed)}';
    } catch (e) {
      debugPrint('compressImageDataUri error: $e');
      return null;
    }
  }

  /// 选择图片并直接转为 Base64 字符串（用于头像、背景图、启动图等设置项）
  ///
  /// [maxBytes] > 0 时启用**预算压缩**：解码 → 按最长边缩放 → JPEG 编码，仍超预算
  /// 就继续降分辨率（最多 6 轮），全程在后台 isolate 里做。
  ///
  /// 为什么必须预算压缩：这些字段跟着设置一起走云端漫游，历史上出现过一张
  /// **6.14 MB 的 base64 头像**（旧实现把照片缩到 1024px 后仍用 PNG 无损编码，
  /// `quality` 参数根本没生效）→ 每次改设置都要整包上传 6.6 MB → 中继的设置写锁
  /// 被长时间占住：桥接注册的归属反查（要读 6.9 MB 设置文件）12 次重试全落空报
  /// **403**、App 的设置推送连续 **2 分钟超时**、SSE 流被拖断（用户看到"连接中断"）。
  /// 头像在界面上只有几十像素，背景也不需要原图分辨率，压到预算内完全够用。
  static Future<String?> pickImageAsBase64({
    int maxDimension = 1024,
    int maxBytes = 0,
  }) async {
    try {
      final processed = await pickImageFromGallery();
      if (processed == null) return null;

      final rawBase64 = processed.highResBase64.contains(',')
          ? processed.highResBase64.split(',').last
          : processed.highResBase64;
      final rawBytes = base64Decode(rawBase64);

      // 预算模式：交给后台 isolate 压到目标字节数以内（JPEG）
      if (maxBytes > 0) {
        final compressed = await compute(_compressImageToBudget, <String, dynamic>{
          'bytes': rawBytes,
          'maxDimension': maxDimension,
          'maxBytes': maxBytes,
        });
        if (compressed != null && compressed.isNotEmpty) {
          return 'data:image/jpeg;base64,${base64Encode(compressed)}';
        }
        debugPrint('预算压缩未产出结果，退回 PNG 缩放路径');
      }

      if (maxDimension > 0) {
        final resized = await resizeImageBytes(rawBytes, maxDimension: maxDimension);
        final mime = processed.highResBase64.startsWith('data:image/jpeg')
            ? 'image/jpeg'
            : processed.highResBase64.startsWith('data:image/webp')
                ? 'image/webp'
                : 'image/png';
        return 'data:$mime;base64,${base64Encode(resized)}';
      }
      return processed.highResBase64;
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
