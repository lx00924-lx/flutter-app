/// 全局可配置项的统一入口。
///
/// 默认值全部指向本项目的生产环境，fork / 自建部署时**无需修改源码**，
/// 打包时用 `--dart-define` 覆盖即可：
///
/// ```bash
/// flutter build apk     --release --dart-define=SERVER_BASE_URL=https://your.domain
/// flutter build windows --release --dart-define=SERVER_BASE_URL=https://your.domain
/// flutter run                            --dart-define=SERVER_BASE_URL=http://192.168.1.10:3000
/// ```
class AppConfig {
  const AppConfig._();

  /// 默认中继服务器地址（生产环境）。
  static const String _defaultServerBaseUrl = 'https://www.lx00924ai.top';

  /// 中继服务器基地址：App 端登录 / 注册 / 消息同步 / 设置漫游 / 扫码配对 /
  /// 本地 Bridge 启动命令 全部基于它拼接。
  ///
  /// 未传 `--dart-define=SERVER_BASE_URL=...` 时回落到默认生产地址。
  static const String serverBaseUrl = String.fromEnvironment(
    'SERVER_BASE_URL',
    defaultValue: _defaultServerBaseUrl,
  );

  /// 归一化后的中继服务器地址：去掉首尾空格与末尾斜杠，空值回退默认地址。
  ///
  /// 拼接 `'$base/api/xxx'` 时请使用它，否则自定义地址带末尾斜杠会拼出 `//api`。
  static String get normalizedServerBaseUrl {
    final url = serverBaseUrl.trim();
    if (url.isEmpty) {
      return _defaultServerBaseUrl;
    }
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }
}
