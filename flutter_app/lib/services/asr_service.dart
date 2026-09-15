import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/app_settings.dart';

/// 统一 ASR 语音识别转写服务
class AsrService {
  AsrService._();
  static final AsrService instance = AsrService._();

  /// 将 Base64 音频转写为纯文本
  Future<String?> transcribeAudio({
    required String base64AudioData,
    required AppSettings settings,
  }) async {
    final endpointSetting = settings.asrHttpEndpoint.trim();
    if (endpointSetting.isEmpty) {
      debugPrint('AsrService: asrHttpEndpoint is not configured');
      return null;
    }

    try {
      final rawBase64 = base64AudioData.contains(',')
          ? base64AudioData.split(',').last
          : base64AudioData;
      final audioBytes = base64Decode(rawBase64);

      String endpoint = endpointSetting;
      if (endpoint.endsWith('/v1/audio') || endpoint.endsWith('/v1/audio/')) {
        endpoint = '${endpoint.replaceAll(RegExp(r'/+$'), '')}/transcriptions';
      }
      final model = settings.asrModel.trim();
      final apiKey = settings.asrApiKey.trim();

      final formMap = <String, dynamic>{
        'file': MultipartFile.fromBytes(audioBytes, filename: 'audio.m4a'),
        if (model.isNotEmpty) 'model': model,
      };
      if (endpoint.contains('10095') || endpoint.contains('funasr')) {
        formMap['audio'] = MultipartFile.fromBytes(audioBytes, filename: 'audio.m4a');
      }
      final formData = FormData.fromMap(formMap);

      final headers = <String, dynamic>{
        'Connection': 'close',
      };
      if (apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
        headers['x-asr-api-key'] = apiKey;
      }

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 25),
        receiveTimeout: const Duration(seconds: 30),
        headers: headers,
      ));

      final res = await dio.post(endpoint, data: formData);
      if (res.statusCode == 200 || res.statusCode == 201) {
        String resultText = '';
        if (res.data is Map) {
          resultText = (res.data['text'] ?? res.data['result'] ?? '').toString().trim();
        } else if (res.data is String) {
          resultText = res.data.toString().trim();
        }
        return resultText.isNotEmpty ? resultText : null;
      }
    } catch (e) {
      debugPrint('AsrService transcribeAudio error: $e');
    }
    return null;
  }
}
