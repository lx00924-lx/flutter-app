import 'dart:convert';
import 'package:hive/hive.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/app_settings.dart';

class StorageService {
  static final StorageService instance = StorageService._();
  StorageService._();

  Box? get _sessionsBox => Hive.isBoxOpen('sessions_box') ? Hive.box('sessions_box') : null;
  Box? get _messagesBox => Hive.isBoxOpen('messages_box') ? Hive.box('messages_box') : null;
  Box? get _settingsBox => Hive.isBoxOpen('settings_box') ? Hive.box('settings_box') : null;

  // --- 会话相关 ---
  List<ChatSession> getAllSessions() {
    final box = _sessionsBox;
    if (box == null) return [];
    final List<ChatSession> list = [];
    for (var key in box.keys) {
      final val = box.get(key);
      if (val != null) {
        try {
          if (val is Map) {
            list.add(ChatSession.fromMap(val));
          } else if (val is String) {
            list.add(ChatSession.fromJson(val));
          }
        } catch (_) {}
      }
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Future<void> saveSession(ChatSession session) async {
    final box = _sessionsBox;
    if (box != null) {
      await box.put(session.id, session.toMap());
    }
  }

  Future<void> deleteSession(String sessionId) async {
    final sBox = _sessionsBox;
    if (sBox != null) {
      await sBox.delete(sessionId);
    }
    // 级联删除该会话的所有消息
    final mBox = _messagesBox;
    if (mBox != null) {
      final keysToDelete = <dynamic>[];
      for (var key in mBox.keys) {
        final msg = mBox.get(key);
        if (msg != null && msg['sessionId'] == sessionId) {
          keysToDelete.add(key);
        }
      }
      await mBox.deleteAll(keysToDelete);
    }
  }

  bool hasSession(String sessionId) {
    final box = _sessionsBox;
    return box != null && box.containsKey(sessionId);
  }

  // --- 消息相关 ---
  List<ChatMessage> getMessagesForSession(String sessionId) {
    final box = _messagesBox;
    if (box == null) return [];
    final List<ChatMessage> list = [];
    for (var key in box.keys) {
      final val = box.get(key);
      if (val != null && val['sessionId'] == sessionId) {
        try {
          if (val is Map) {
            list.add(ChatMessage.fromMap(val));
          }
        } catch (_) {}
      }
    }
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  Future<void> saveMessage(ChatMessage message) async {
    final box = _messagesBox;
    if (box != null) {
      await box.put(message.id, message.toMap());
    }
  }

  bool hasMessage(String messageId) {
    final box = _messagesBox;
    return box != null && box.containsKey(messageId);
  }

  Future<void> deleteMessage(String messageId) async {
    final box = _messagesBox;
    if (box != null) {
      await box.delete(messageId);
    }
  }

  List<ChatMessage> getAllMessages() {
    final box = _messagesBox;
    if (box == null) return [];
    final List<ChatMessage> list = [];
    for (var key in box.keys) {
      final val = box.get(key);
      if (val != null) {
        try {
          if (val is Map) {
            list.add(ChatMessage.fromMap(val));
          }
        } catch (_) {}
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  int getMessageCountForSession(String sessionId) {
    final box = _messagesBox;
    if (box == null) return 0;
    int count = 0;
    for (var key in box.keys) {
      final val = box.get(key);
      if (val != null && (val['sessionId'] == sessionId || (val is Map && val['sessionId'] == sessionId))) {
        count++;
      }
    }
    return count;
  }

  /// 导出指定会话列表的数据（选中的会话 + 对应消息）
  Map<String, dynamic> exportSelectedSessions(List<String> sessionIds) {
    final allSessions = getAllSessions().where((s) => sessionIds.contains(s.id)).toList();
    final allMessages = getAllMessages().where((m) => sessionIds.contains(m.sessionId)).toList();
    return {
      'version': '1.0.0',
      'exportTime': DateTime.now().toIso8601String(),
      'sessions': allSessions.map((s) => s.toMap()).toList(),
      'messages': allMessages.map((m) => m.toMap()).toList(),
    };
  }

  /// 导出全部对话数据（会话 + 消息）
  Map<String, dynamic> exportAllData() {
    final sessions = getAllSessions();
    final allMessages = getAllMessages();
    return {
      'version': '1.0.0',
      'exportTime': DateTime.now().toIso8601String(),
      'sessions': sessions.map((s) => s.toMap()).toList(),
      'messages': allMessages.map((m) => m.toMap()).toList(),
    };
  }

  /// 导入并合并备份数据
  Future<int> importData(Map<String, dynamic> data) async {
    int importedCount = 0;
    final sessionsData = data['sessions'] as List?;
    final messagesData = data['messages'] as List?;
    if (sessionsData != null) {
      for (var s in sessionsData) {
        if (s is Map) {
          final session = ChatSession.fromMap(s);
          await saveSession(session);
        }
      }
    }
    if (messagesData != null) {
      for (var m in messagesData) {
        if (m is Map) {
          final message = ChatMessage.fromMap(m);
          await saveMessage(message);
          importedCount++;
        }
      }
    }
    return importedCount;
  }

  Future<void> clearAllData() async {
    final sBox = _sessionsBox;
    if (sBox != null) await sBox.clear();
    final mBox = _messagesBox;
    if (mBox != null) await mBox.clear();
  }

  // --- 设置持久化 ---
  AppSettings loadSettings() {
    try {
      final box = _settingsBox;
      if (box != null) {
        final val = box.get('app_settings');
        if (val != null && val is Map) {
          return AppSettings.fromMap(val);
        }
      }
    } catch (_) {}
    return AppSettings();
  }

  Future<void> saveSettings(AppSettings settings) async {
    try {
      final box = _settingsBox;
      if (box != null) {
        await box.put('app_settings', settings.toMap());
      }
    } catch (_) {}
  }
}
