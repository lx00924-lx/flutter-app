import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 设置图片（聊天背景 / 用户头像 / AI 头像）的**本地持久化**。
///
/// 为什么需要它（2026-11-18）：服务端把这三个字段从设置 JSON 里拆了出去
/// （`settings.data` 从 489 KB 降到 1.8 KB），设置里只留
/// `media:v1:<hash>.<ext>` 引用。于是 App 端必须自己回答两个问题：
///
///   ① **离线时还能不能显示？** 能 —— 图片存在本地这个目录里，不走网络。
///   ② **换机后怎么拿到？** 本地没有就按 id 去服务器取一次，取回来存这里。
///
/// ⚠️ 这是**持久化文件，不是可清缓存**。用户自己设的背景和头像属于他的数据，
/// 清掉就得重新下载，断网时直接显示不出来 —— 别把它当 `cache/` 处理。
class SettingsMediaCache {
  static Directory? _dir;

  /// 目录：App 私有支持目录下的 `settings_media/`。
  ///
  /// 用 `getApplicationSupportDirectory()` 而不是 `getApplicationCacheDirectory()`：
  /// 前者系统不会自动清，后者会被清 —— 头像被系统清掉属于"数据丢失"。
  static Future<Directory> _dirOf() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}settings_media');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  static Future<File> _fileOf(String fileName) async {
    final d = await _dirOf();
    return File('${d.path}${Platform.pathSeparator}$fileName');
  }

  /// 本地有就返回，没有返回 null。
  static Future<Uint8List?> read(String fileName) async {
    try {
      final f = await _fileOf(fileName);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// 存到本地。失败静默 —— 下次再取一遍就是了，不该为此打扰用户。
  static Future<void> write(String fileName, Uint8List bytes) async {
    try {
      final f = await _fileOf(fileName);
      // 先写临时文件再改名：中途被杀不会留下半张图
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  /// 本地有没有这张。给"要不要去取"做判断用。
  static Future<bool> has(String fileName) async {
    try {
      final f = await _fileOf(fileName);
      return await f.exists();
    } catch (_) {
      return false;
    }
  }
}
