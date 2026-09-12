import 'dart:convert';

class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  String? model;
  String? workspace;
  String? summary; // 会话历史增量摘要 (KV 缓存前缀压缩基石)
  int lastSummarizedIndex; // 上次已摘要的历史消息截止索引

  ChatSession({
    required this.id,
    required this.title,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.model,
    this.workspace,
    this.summary,
    this.lastSummarizedIndex = 0,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'model': model,
      'workspace': workspace,
      'summary': summary,
      'lastSummarizedIndex': lastSummarizedIndex,
    };
  }

  factory ChatSession.fromMap(Map<dynamic, dynamic> map) {
    return ChatSession(
      id: map['id'] as String,
      title: map['title'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      model: map['model'] as String?,
      workspace: map['workspace'] as String?,
      summary: map['summary'] as String?,
      lastSummarizedIndex: (map['lastSummarizedIndex'] as num?)?.toInt() ?? 0,
    );
  }

  String toJson() => json.encode(toMap());
  factory ChatSession.fromJson(String source) => ChatSession.fromMap(json.decode(source));
}
