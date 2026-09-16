import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

/// 全局网络客户端助手：标准直连客户端与 SSL 容错
class HttpClientHelper {
  /// 为 Dio 实例配置标准直连适配器与通用容错
  static void configureProxy(Dio dio) {
    if (kIsWeb) return;

    if (dio.httpClientAdapter is IOHttpClientAdapter) {
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        final client = HttpClient();
        client.findProxy = (uri) => 'DIRECT';
        client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
        return client;
      };
    }
  }

  /// 创建标准直连的原生 HttpClient
  static HttpClient createHttpClient() {
    final client = HttpClient();
    if (!kIsWeb) {
      client.findProxy = (uri) => 'DIRECT';
      client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    }
    return client;
  }
}

