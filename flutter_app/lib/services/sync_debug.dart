import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 同步链路的**诊断日志**，追加写到 `Documents/LxAI_sync.log`。
///
/// 为什么需要它：release 版的 Windows App **没有控制台**，`debugPrint` 的输出
/// 在用户机器上根本看不到。于是任何一处「静默 return / catch 吞掉」都会表现为
/// 「同步就是不动」，而排查的人（我）只能对着代码猜 —— 2026-10-23 为了确认
/// 一条消息拉取到底走没走到，猜错了三轮。
///
/// 用法：只在**排查期**打点，正常路径不要刷屏。超过 512KB 自动截断。
///
/// ⚠️ 这个类不该长期留在关键路径上：确认问题后，把打点收敛成真正需要长期
/// 观测的那几处（例如同步失败），否则日志会变成没人看的噪音。
class SyncDebug {
  static const int _maxBytes = 512 * 1024;

  /// 是否启用。排查期间改成 false 即可静音，不用删调用点。
  static bool enabled = true;

  static void log(String message) {
    if (!enabled) return;
    debugPrint('[SyncDebug] $message');
    // 不 await：诊断日志不该拖慢同步本身
    _append('[${DateTime.now().toIso8601String()}] $message\n');
  }

  static Future<void> _append(String line) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/LxAI_sync.log');
      if (await file.exists() && await file.length() > _maxBytes) {
        await file.writeAsString('', flush: true);
      }
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // 记日志失败就算了，绝不能反过来影响同步
    }
  }
}
