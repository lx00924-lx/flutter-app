import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

/// 全局网络覆盖：为整个 Flutter 进程注入默认系统/环境代理、本地代理工具端口，并放行代理 SSL 握手
class AppHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      // 1. 优先读取系统/运行环境代理（HTTP_PROXY / HTTPS_PROXY / ALL_PROXY）
      final envProxy = HttpClient.findProxyFromEnvironment(uri);
      if (envProxy.isNotEmpty && envProxy != 'DIRECT') {
        return '$envProxy; DIRECT';
      }
      // 2. 默认直连（在开启 TUN 虚拟网卡或系统代理规则时由操作系统/网络驱动无缝分流）
      return 'DIRECT';
    };
    // 3. 放行代理工具自签证书与中间人握手，杜绝 HandshakeException
    client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    return client;
  }
}

/// 全局网络客户端助手：零配置自动适配系统/环境代理与本地代理工具
class HttpClientHelper {
  /// 为任意 Dio 实例注入自动代理与 SSL 握手兼容配置
  static void configureProxy(Dio dio) {
    if (kIsWeb) return;

    if (dio.httpClientAdapter is IOHttpClientAdapter) {
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        final client = HttpClient();
        client.findProxy = (uri) {
          final envProxy = HttpClient.findProxyFromEnvironment(uri);
          if (envProxy.isNotEmpty && envProxy != 'DIRECT') {
            return '$envProxy; DIRECT';
          }
          return 'DIRECT';
        };
        client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
        return client;
      };
    }
  }

  /// 创建一个已配置好自动代理与 SSL 容错的原生 HttpClient
  static HttpClient createHttpClient() {
    final client = HttpClient();
    if (!kIsWeb) {
      client.findProxy = (uri) {
        final envProxy = HttpClient.findProxyFromEnvironment(uri);
        if (envProxy.isNotEmpty && envProxy != 'DIRECT') {
          return '$envProxy; DIRECT';
        }
        return 'DIRECT';
      };
      client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    }
    return client;
  }
}
