import 'dart:convert';

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
      createdAt = DateTime.tryParse(timeStr) ?? DateTime.now();
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
