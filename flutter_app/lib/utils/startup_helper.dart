import 'dart:io';

/// 开机自动启动（仅 Windows）。
///
/// **刻意不走 `AppSettings` + 云端同步**：开机自启是**这台设备**的属性，
/// 不是账号的属性 —— 手机端同步一个"开机自启=开"过来毫无意义，
/// 反而会让"在 A 电脑开的开关"莫名其妙影响 B 电脑。所以真相只有一个：
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 里那一项在不在。
///
/// 用 `reg.exe` 而不是 `win32` FFI：一次读写就完事，不需要为它多引一个原生依赖。
class StartupHelper {
  StartupHelper._();

  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// 与安装器写入的名字保持一致（安装器「开机自动启动」勾选项、卸载清理都认这个名字）
  static const String valueName = 'LxAI';

  static bool get supported => !Platform.isWindows ? false : true;

  /// 当前是否已开启（读注册表，失败一律当"没开"）
  static Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run(
        'reg',
        ['query', _runKey, '/v', valueName],
        runInShell: false,
      );
      // reg query 在"值不存在"时返回 1；存在时 stdout 里能看到值名
      return r.exitCode == 0 && '${r.stdout}'.contains(valueName);
    } catch (_) {
      return false;
    }
  }

  /// 开启/关闭。开启时把**当前 exe 的真实路径**写进去 ——
  /// 绿色版、安装版、开发期直跑构建产物，三种情况都能正确自启。
  static Future<void> setEnabled(bool enabled) async {
    if (!Platform.isWindows) return;
    if (enabled) {
      final exe = Platform.resolvedExecutable;
      await Process.run(
        'reg',
        [
          'add', _runKey,
          '/v', valueName,
          '/t', 'REG_SZ',
          '/d', '"$exe"',
          '/f',
        ],
        runInShell: false,
      );
    } else {
      await Process.run(
        'reg',
        ['delete', _runKey, '/v', valueName, '/f'],
        runInShell: false,
      );
    }
  }

  /// 读当前的注册表值（用于界面显示"指向哪个程序"，排查时很有用）
  static Future<String> currentCommand() async {
    if (!Platform.isWindows) return '';
    try {
      final r = await Process.run(
        'reg',
        ['query', _runKey, '/v', valueName],
        runInShell: false,
      );
      if (r.exitCode != 0) return '';
      for (final line in '${r.stdout}'.split('\n')) {
        if (line.contains('REG_SZ')) {
          final parts = line.trim().split(RegExp(r'\s{2,}'));
          if (parts.length >= 3) return parts.sublist(2).join('  ').trim();
        }
      }
      return '';
    } catch (_) {
      return '';
    }
  }
}
