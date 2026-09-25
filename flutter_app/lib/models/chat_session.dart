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
  bool isSynced; // 是否已成功与云端服务器完成同步

  ChatSession({
    required this.id,
    required this.title,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.model,
    this.workspace,
    this.summary,
    this.lastSummarizedIndex = 0,
    this.isSynced = false,
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
      'isSynced': isSynced,
    };
  }

  factory ChatSession.fromMap(Map<dynamic, dynamic> map) {
    return ChatSession(
      id: map['id'] as String,
      title: map['title'] as String,
      // 同 chat_message：服务端可能写入 UTC 串，统一转本地再参与显示/排序
      createdAt: _parseLocal(map['createdAt'] as String?),
      updatedAt: _parseLocal(map['updatedAt'] as String?),
      model: map['model'] as String?,
      workspace: map['workspace'] as String?,
      summary: map['summary'] as String?,
      lastSummarizedIndex: (map['lastSummarizedIndex'] as num?)?.toInt() ?? 0,
      isSynced: (map['isSynced'] as bool?) ?? true, // 历史存量数据默认兼容视为已同步
    );
  }

  /// 解析时间串并统一成本地时区（服务端写的是带 Z 的 UTC，本地写的是本地时间）。
  static DateTime _parseLocal(String? raw) {
    final parsed = raw == null ? null : DateTime.tryParse(raw);
    if (parsed == null) return DateTime.now();
    return parsed.isUtc ? parsed.toLocal() : parsed;
  }

  String toJson() => json.encode(toMap());
  factory ChatSession.fromJson(String source) => ChatSession.fromMap(json.decode(source));
}
