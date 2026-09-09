import 'dart:convert';

class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  String? model;
  String? workspace;

  ChatSession({
    required this.id,
    required this.title,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.model,
    this.workspace,
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
    );
  }

  String toJson() => json.encode(toMap());
  factory ChatSession.fromJson(String source) => ChatSession.fromMap(json.decode(source));
}
