import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../models/app_settings.dart';
import '../models/chat_message.dart';

class ApiService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 120),
    ),
  );

  /// 智能从指定端点获取可用模型列表（兼容 OpenAI、DeepSeek、火山方舟、Ollama、LM Studio 等）
  Future<List<String>> fetchModelList({
    required String endpoint,
    required String apiKey,
  }) async {
    String cleanUrl = endpoint.trim();
    if (cleanUrl.endsWith('/')) {
      cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
    }
    // 自动兼容末尾路径
    String targetUrl = cleanUrl;
    if (!targetUrl.contains('/models')) {
      if (targetUrl.endsWith('/v1')) {
        targetUrl = '$targetUrl/models';
      } else {
        targetUrl = '$targetUrl/v1/models';
      }
    }

    try {
      final response = await _dio.get(
        targetUrl,
        options: Options(
          headers: {
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
            'Content-Type': 'application/json',
          },
        ),
      );

      final List<String> modelIds = [];
      if (response.data is Map && response.data['data'] is List) {
        for (var item in response.data['data']) {
          if (item is Map && item['id'] != null) {
            modelIds.add(item['id'].toString());
          }
        }
      } else if (response.data is List) {
        for (var item in response.data) {
          if (item is Map && item['id'] != null) {
            modelIds.add(item['id'].toString());
          } else if (item is String) {
            modelIds.add(item);
          }
        }
      }

      return modelIds.isNotEmpty ? modelIds : ['deepseek-chat', 'deepseek-reasoner'];
    } catch (e) {
      // 若 /v1/models 失败，尝试直接根路径 /models
      try {
        final fallbackUrl = cleanUrl.endsWith('/models') ? cleanUrl : '$cleanUrl/models';
        final response = await _dio.get(
          fallbackUrl,
          options: Options(
            headers: {
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
          ),
        );
        final List<String> modelIds = [];
        if (response.data is Map && response.data['data'] is List) {
          for (var item in response.data['data']) {
            if (item is Map && item['id'] != null) {
              modelIds.add(item['id'].toString());
            }
          }
        }
        return modelIds.isNotEmpty ? modelIds : ['deepseek-chat', 'deepseek-reasoner'];
      } catch (_) {
        rethrow;
      }
    }
  }

  /// 滑动窗口截断算法 (Sliding Window Truncation)
  /// 保证 system prompt 始终保留，若历史超出 contextLength，则从最旧的历史依次丢弃
  List<Map<String, String>> truncateHistoryBySlidingWindow({
    required List<ChatMessage> history,
    required String systemPrompt,
    required int maxContextLength,
  }) {
    final List<Map<String, String>> result = [];

    // 计算系统提示词长度
    int currentLength = systemPrompt.length;

    // 从最新的消息往旧的消息回溯累加，超出 contextLength 则滑动丢弃
    final reversedSelected = <Map<String, String>>[];
    for (int i = history.length - 1; i >= 0; i--) {
      final msg = history[i];
      final role = msg.role == MessageRole.user ? 'user' : 'assistant';
      final content = msg.content;
      final msgLen = content.length + 10;

      if (currentLength + msgLen > maxContextLength && reversedSelected.isNotEmpty) {
        // 超出滑动窗口，停止追加旧历史
        break;
      }

      currentLength += msgLen;
      reversedSelected.add({
        'role': role,
        'content': content,
      });
    }

    // 重新按正序排列
    final orderedHistory = reversedSelected.reversed.toList();

    // 注入 System Prompt
    if (systemPrompt.trim().isNotEmpty) {
      result.add({
        'role': 'system',
        'content': systemPrompt.trim(),
      });
    }

    result.addAll(orderedHistory);
    return result;
  }

  /// 发送聊天消息并以 Stream 形式实时返回
  Stream<Map<String, dynamic>> streamChatCompletion({
    required List<ChatMessage> history,
    required AppSettings settings,
    CancelToken? cancelToken,
  }) async* {
    final activeEp = settings.activeEndpoint;
    if (activeEp == null) {
      throw Exception('未找到可用的 API 端点配置，请在设置中添加');
    }

    String baseUrl = activeEp.endpoint.trim();
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    // 智能防重复拼接
    String requestUrl = baseUrl;
    if (requestUrl.endsWith('/chat/completions')) {
      // 已经是完整接口
    } else if (requestUrl.endsWith('/v1')) {
      requestUrl = '$requestUrl/chat/completions';
    } else if (requestUrl.contains('/v3')) {
      // 火山方舟特定端点
      requestUrl = '$requestUrl/chat/completions';
    } else {
      requestUrl = '$requestUrl/v1/chat/completions';
    }

    final apiKey = activeEp.apiKey.trim();
    final model = activeEp.modelName.trim();

    // 执行滑动窗口截断
    final messagesPayload = truncateHistoryBySlidingWindow(
      history: history,
      systemPrompt: settings.systemPrompt,
      maxContextLength: activeEp.contextLength,
    );

    final requestBody = {
      'model': model,
      'messages': messagesPayload,
      'stream': true,
      'temperature': activeEp.temperature,
      'max_tokens': activeEp.maxTokens,
    };

    final response = await _dio.post<ResponseBody>(
      requestUrl,
      data: requestBody,
      cancelToken: cancelToken,
      options: Options(
        headers: {
          if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        },
        responseType: ResponseType.stream,
      ),
    );

    final stream = response.data!.stream;
    String buffer = '';

    await for (final Uint8List chunk in stream) {
      final text = utf8.decode(chunk, allowMalformed: true);
      buffer += text;

      final lines = buffer.split('\n');
      buffer = lines.removeLast();

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith(':')) continue;

        if (trimmed.startsWith('data:')) {
          final dataStr = trimmed.substring(5).trim();
          if (dataStr == '[DONE]') {
            yield {'done': true};
            return;
          }

          try {
            final json = jsonDecode(dataStr);
            if (json['choices'] != null && (json['choices'] as List).isNotEmpty) {
              final choice = json['choices'][0];
              final delta = choice['delta'];
              if (delta != null) {
                final content = delta['content'] as String? ?? '';
                final reasoning = delta['reasoning_content'] as String? ??
                    delta['reasoning'] as String? ??
                    '';

                yield {
                  'content': content,
                  'reasoning': reasoning,
                  'done': false,
                };
              }
            }
          } catch (_) {}
        }
      }
    }

    yield {'done': true};
  }
}
