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

  /// 生成会话历史的精炼摘要（用于把超出上下文滑动窗口的历史消息压缩为一段长期记忆基石）
  Future<String?> generateConversationSummary({
    required List<ChatMessage> oldMessages,
    required AppSettings settings,
    String? previousSummary,
  }) async {
    final activeEp = settings.activeEndpoint;
    if (activeEp == null || oldMessages.isEmpty) return previousSummary;

    String baseUrl = activeEp.endpoint.trim();
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    String requestUrl = baseUrl;
    if (requestUrl.endsWith('/chat/completions')) {
    } else if (requestUrl.endsWith('/v1') || requestUrl.contains('/v3')) {
      requestUrl = '$requestUrl/chat/completions';
    } else {
      requestUrl = '$requestUrl/v1/chat/completions';
    }

    final apiKey = activeEp.apiKey.trim();
    final model = activeEp.modelName.trim();

    final buffer = StringBuffer();
    if (previousSummary != null && previousSummary.trim().isNotEmpty) {
      buffer.writeln('【前文已有背景摘要】:\n$previousSummary\n');
    }
    buffer.writeln('【本次需浓缩的较早对话记录】:');
    for (final m in oldMessages) {
      final role = m.role == MessageRole.user ? '用户' : '助手';
      final text = m.content.trim();
      if (text.isNotEmpty) {
        buffer.writeln('$role: $text');
      }
    }

    final prompt = '''你是一个高效的对话记忆提炼助手。请将以上对话记录与前文背景摘要进行综合归纳，提炼出一份精炼、客观、保留所有核心需求、技术决策、关键实体和重要结论的《前文背景摘要》（控制在300字以内，纯文本，条理清晰）。''';

    try {
      final response = await _dio.post(
        requestUrl,
        data: {
          'model': model,
          'messages': [
            {'role': 'system', 'content': '你是一个专注做会话背景摘要浓缩的助手，直接输出精炼摘要正文，不要输出任何寒暄客套。'},
            {'role': 'user', 'content': '$buffer\n\n$prompt'}
          ],
          'temperature': 0.3,
          'max_tokens': 600,
        },
        options: Options(
          headers: {
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
      );

      if (response.data is Map && response.data['choices'] is List) {
        final choices = response.data['choices'] as List<dynamic>;
        if (choices.isNotEmpty) {
          final content = choices.first['message']?['content']?.toString()?.trim();
          if (content != null && content.isNotEmpty) {
            return content;
          }
        }
      }
    } catch (e) {
      // 摘要失败降级，保留原有摘要
    }
    return previousSummary;
  }

  /// 滑动窗口截断与 KV 缓存前缀固化算法 (Sliding Window Truncation with KV Prefix Anchor)
  /// 支持多模态（文本 + 高达 8K 超清图片 attachments），自动保留 system prompt 与 历史增量摘要
  List<Map<String, dynamic>> truncateHistoryBySlidingWindow({
    required List<ChatMessage> history,
    required String systemPrompt,
    required int maxContextLength,
    String? sessionSummary,
  }) {
    final List<Map<String, dynamic>> result = [];

    // 计算系统提示词长度与摘要基石长度
    int currentLength = systemPrompt.length + (sessionSummary?.length ?? 0);

    // 从最新的消息往旧的消息回溯累加，超出 contextLength 则滑动截断
    final reversedSelected = <Map<String, dynamic>>[];
    for (int i = history.length - 1; i >= 0; i--) {
      final msg = history[i];
      final role = msg.role == MessageRole.user ? 'user' : 'assistant';
      final msgPayload = msg.toAiPayloadMap();
      final content = msg.content;
      final attachments = (msgPayload['attachments'] as List<dynamic>?)?.map((e) => e.toString()).toList();

      final msgLen = content.length + 10;
      if (currentLength + msgLen > maxContextLength && reversedSelected.isNotEmpty) {
        break;
      }

      currentLength += msgLen;

      if (attachments != null && attachments.isNotEmpty) {
        // 多模态 content 格式 (OpenAI / Vision 标准兼容)
        final List<Map<String, dynamic>> multiContent = [];
        if (content.isNotEmpty) {
          multiContent.add({'type': 'text', 'text': content});
        }
        for (final att in attachments) {
          if (att.startsWith('data:image/')) {
            multiContent.add({
              'type': 'image_url',
              'image_url': {'url': att, 'detail': 'high'}
            });
          } else if (att.startsWith('data:application/octet-stream')) {
            multiContent.add({'type': 'text', 'text': '[文件附件]'});
          }
        }
        reversedSelected.add({
          'role': role,
          'content': multiContent.isNotEmpty ? multiContent : content,
        });
      } else {
        reversedSelected.add({
          'role': role,
          'content': content,
        });
      }
    }

    // 重新按正序排列
    final orderedHistory = reversedSelected.reversed.toList();

    // 1. 注入固定的 System Prompt（严禁掺入动态时间戳以稳固 KV Cache 前缀）
    if (systemPrompt.trim().isNotEmpty) {
      result.add({
        'role': 'system',
        'content': systemPrompt.trim(),
      });
    }

    // 2. 注入长期会话背景摘要基石（当早期消息被截断时，作为前缀记忆锚点）
    if (sessionSummary != null && sessionSummary.trim().isNotEmpty) {
      result.add({
        'role': 'system',
        'content': '【📜 前文对话核心背景摘要】:\n${sessionSummary.trim()}',
      });
    }

    result.addAll(orderedHistory);
    return result;
  }

  /// 发送聊天消息并以 Stream 形式实时返回
  Stream<Map<String, dynamic>> streamChatCompletion({
    required List<ChatMessage> history,
    required AppSettings settings,
    String? sessionSummary,
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

    // 执行滑动窗口截断并支持多模态 8K 图片结构与 KV 摘要基石
    final messagesPayload = truncateHistoryBySlidingWindow(
      history: history,
      systemPrompt: settings.systemPrompt,
      maxContextLength: activeEp.contextLength,
      sessionSummary: sessionSummary,
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
            final choices = json['choices'] as List<dynamic>?;
            if (choices != null && choices.isNotEmpty) {
              final delta = choices.first['delta'] as Map<dynamic, dynamic>?;
              if (delta != null) {
                final content = delta['content'] as String? ?? '';
                final reasoning = delta['reasoning_content'] as String? ?? '';
                yield {
                  'content': content,
                  'reasoning': reasoning,
                  'done': false,
                };
              }
            }
          } catch (_) {
            // 忽略非 JSON 行
          }
        }
      }
    }

    yield {'done': true};
  }
}
