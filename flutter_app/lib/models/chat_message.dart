import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../utils/image_picker_helper.dart';

enum MessageRole { user, assistant, system }

class AgentExecutionRecord {
  final String status;
  final List<String> steps;
  final String? rawOutput;
  final String? timestamp;

  AgentExecutionRecord({
    required this.status,
    required this.steps,
    this.rawOutput,
    this.timestamp,
  });

  Map<String, dynamic> toMap() => {
    'status': status,
    'steps': steps,
    'rawOutput': rawOutput,
    'timestamp': timestamp,
  };

  factory AgentExecutionRecord.fromMap(Map<dynamic, dynamic> map) {
    return AgentExecutionRecord(
      status: map['status']?.toString() ?? 'completed',
      steps: (map['steps'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      rawOutput: map['rawOutput']?.toString(),
      timestamp: map['timestamp']?.toString(),
    );
  }
}

class ChatMessage {
  final String id;
  final String sessionId;
  final MessageRole role;
  String content;
  String? reasoningContent; // 思考链过程
  final DateTime createdAt;
  bool isStreaming;
  int? elapsedSeconds;
  List<String>? attachments;
  String status; // 'completed' | 'error' | 'sending'
  bool isAgentMode;
  AgentExecutionRecord? agentExecution;

  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.reasoningContent,
    DateTime? createdAt,
    this.isStreaming = false,
    this.elapsedSeconds,
    this.attachments,
    this.status = 'completed',
    this.isAgentMode = false,
    this.agentExecution,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 本地持久化与云端极速同步数据结构（图片仅同步轻量缩略图与元数据，极速不占云端存储）
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sessionId': sessionId,
      'role': role.name,
      'sender': role == MessageRole.user ? 'user' : 'ai',
      'content': content,
      'text': content,
      'reasoningContent': reasoningContent,
      'thought': reasoningContent,
      'createdAt': createdAt.toIso8601String(),
      'timestamp': createdAt.toIso8601String(),
      'elapsedSeconds': elapsedSeconds,
      'attachments': attachments,
      'status': status,
      'isAgentMode': isAgentMode,
      'agentExecution': agentExecution?.toMap(),
    };
  }

  /// 转换给大模型 API 视觉推理使用的 Payload：
  /// 若附件中带有本地原图路径且文件存在，自动读取本地最高 8K 超清原图传给大模型；
  /// 若本地文件不存在，则自动降级使用缩略图 Base64 传给大模型。
  Map<String, dynamic> toAiPayloadMap() {
    List<String>? aiAttachments;
    if (attachments != null && attachments!.isNotEmpty) {
      aiAttachments = attachments!.map((att) {
        if (att.startsWith('data:audio/') || att.startsWith('data:application/octet-stream')) {
          return att;
        }
        final localPath = ImagePickerHelper.extractLocalPathFromAttachment(att);
        if (localPath != null && localPath.isNotEmpty && !kIsWeb) {
          try {
            final f = File(localPath);
            if (f.existsSync()) {
              final bytes = f.readAsBytesSync();
              final ext = localPath.split('.').last.toLowerCase();
              final mime = (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
              return 'data:$mime;base64,${base64Encode(bytes)}';
            }
          } catch (e) {
            debugPrint('读取超清原图传给大模型异常: $e');
          }
        }
        // 降级使用缩略图
        if (att.contains('#localPath=')) {
          return att.split('#localPath=').first;
        }
        return att;
      }).toList();
    }

    String payloadContent = content;
    if (payloadContent.trim().isEmpty && (attachments != null && attachments!.any((att) => att.startsWith('data:audio/')))) {
      final audio = attachments!.firstWhere((att) => att.startsWith('data:audio/'));
      final durationMatch = RegExp(r'duration=(\d+)').firstMatch(audio);
      final durationSec = durationMatch?.group(1);
      final durText = durationSec != null ? '（时长约 $durationSec 秒）' : '';
      payloadContent = '[用户发送了一条语音消息$durText。提示：当前客户端未配置 ASR 语音识别转写服务，大模型接收到的是音频条。请直接回复已收到用户的语音消息，并提醒用户在 App「设置 ➔ 语音识别与合成」中配置 ASR 识别服务即可直接与 AI 进行语音文本交互。]';
    }

    return {
      'id': id,
      'sessionId': sessionId,
      'role': role.name,
      'sender': role == MessageRole.user ? 'user' : 'ai',
      'content': payloadContent,
      'text': payloadContent,
      'reasoningContent': reasoningContent,
      'thought': reasoningContent,
      'createdAt': createdAt.toIso8601String(),
      'timestamp': createdAt.toIso8601String(),
      'elapsedSeconds': elapsedSeconds,
      'attachments': aiAttachments,
      'status': status,
      'isAgentMode': isAgentMode,
      'agentExecution': agentExecution?.toMap(),
    };
  }

  factory ChatMessage.fromMap(Map<dynamic, dynamic> map) {
    String roleStr = (map['role'] ?? map['sender'] ?? 'user').toString().toLowerCase();
    if (roleStr == 'ai') roleStr = 'assistant';
    MessageRole role = MessageRole.user;
    for (var r in MessageRole.values) {
      if (r.name == roleStr) {
        role = r;
        break;
      }
    }
    final content = (map['content'] ?? map['text'] ?? '').toString();
    final reasoning = (map['reasoningContent'] ?? map['thought'])?.toString();
    final timeStr = (map['createdAt'] ?? map['timestamp'])?.toString();
    DateTime createdAt = DateTime.now();
    if (timeStr != null) {
      final parsed = DateTime.tryParse(timeStr);
      // 时间基准必须统一：**服务端**写 assistant 消息用的是 UTC（`...Z`，见 server.ts
      // 的 new Date().toISOString()），而 App 本地写的用户消息是本地时间（无时区）。
      // 直接 tryParse 会把 UTC 串当成"本地墙上时间"用，于是凌晨 3 点的 Agent 回复
      // 显示成"昨天 19:00"（差 8 小时还跨天，用户实测抓到过）。这里统一转本地。
      createdAt = parsed == null ? DateTime.now() : (parsed.isUtc ? parsed.toLocal() : parsed);
    }
    final sessId = (map['sessionId'] ?? 'default_session').toString();

    AgentExecutionRecord? agentExec;
    if (map['agentExecution'] is Map) {
      agentExec = AgentExecutionRecord.fromMap(map['agentExecution'] as Map<dynamic, dynamic>);
    }

    return ChatMessage(
      id: map['id']?.toString() ?? '',
      sessionId: sessId,
      role: role,
      content: content,
      reasoningContent: reasoning,
      createdAt: createdAt,
      elapsedSeconds: map['elapsedSeconds'] as int?,
      attachments: (map['attachments'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
      status: map['status']?.toString() ?? 'completed',
      isAgentMode: map['isAgentMode'] == true,
      agentExecution: agentExec,
    );
  }

  String toJson() => json.encode(toMap());
  factory ChatMessage.fromJson(String source) => ChatMessage.fromMap(json.decode(source));
}
