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
      final keyStr = key?.toString().trim() ?? '';
      if (keyStr.isEmpty) continue; // 坚决跳过空 session 键
      final val = box.get(key);
      if (val != null) {
        try {
          ChatSession? s;
          if (val is Map) {
            s = ChatSession.fromMap(val);
          } else if (val is String) {
            s = ChatSession.fromJson(val);
          }
          if (s != null && s.id.trim().isNotEmpty) {
            list.add(s);
          }
        } catch (_) {}
      }
    }
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// 清除本地所有无关联 session 或 sessionId 为空的孤儿残留数据
  Future<void> cleanOrphanData() async {
    final sBox = _sessionsBox;
    if (sBox != null) {
      final invalidKeys = sBox.keys.where((k) => k == null || k.toString().trim().isEmpty).toList();
      for (var k in invalidKeys) {
        await sBox.delete(k);
      }
    }
    final mBox = _messagesBox;
    if (mBox != null) {
      final orphanKeys = <dynamic>[];
      for (var key in mBox.keys) {
        final val = mBox.get(key);
        if (val == null) {
          orphanKeys.add(key);
        } else if (val is Map) {
          final sId = (val['sessionId'] ?? '').toString().trim();
          if (sId.isEmpty) {
            orphanKeys.add(key);
          }
        }
      }
      if (orphanKeys.isNotEmpty) {
        await mBox.deleteAll(orphanKeys);
      }
    }
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

  /// 按 id 取本地消息（取不到返回 null）。漫游对账要用它比较"哪边的版本更有内容"。
  ChatMessage? getMessageById(String messageId) {
    final box = _messagesBox;
    if (box == null) return null;
    final val = box.get(messageId);
    if (val is Map) {
      try {
        return ChatMessage.fromMap(val);
      } catch (_) {
        return null;
      }
    }
    return null;
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

  // --- 离线待删除会话队列 (Pending Deletions Queue) ---
  List<String> getPendingDeleteSessionIds() {
    final box = _settingsBox;
    if (box == null) return [];
    try {
      final list = box.get('pending_delete_session_ids');
      if (list is List) {
        return list.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> addPendingDeleteSessionId(String sessionId) async {
    final box = _settingsBox;
    if (box == null || sessionId.trim().isEmpty) return;
    try {
      final current = getPendingDeleteSessionIds();
      if (!current.contains(sessionId)) {
        current.add(sessionId);
        await box.put('pending_delete_session_ids', current);
      }
    } catch (_) {}
  }

  Future<void> removePendingDeleteSessionId(String sessionId) async {
    final box = _settingsBox;
    if (box == null) return;
    try {
      final current = getPendingDeleteSessionIds();
      if (current.remove(sessionId)) {
        await box.put('pending_delete_session_ids', current);
      }
    } catch (_) {}
  }

  // --- 离线待推送消息队列 (Pending Push Queue) ---
  //
  // 为什么需要它：推送失败以前**只打一行 debugPrint**（`pushMessages` 的 catch），
  // 于是"服务器没开时发的消息"就永远上不了云 —— 本地看得见、另一端永远看不到。
  // 这里记下"推失败的 message id"，等同步时按 id 从本地重新取出来补推。
  //
  // 刻意**只记本机自己推失败的 id**，而不是"服务端没有的本地消息全都补推"：
  // 后者会把另一台设备上已经删掉的消息又推回去（复活）。只补自己推失败的，
  // 语义上一定是"这条从没上过云"，不可能与删除冲突。
  List<String> getPendingPushMessageIds() {
    final box = _settingsBox;
    if (box == null) return [];
    try {
      final list = box.get('pending_push_message_ids');
      if (list is List) {
        return list.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> addPendingPushMessageIds(Iterable<String> messageIds) async {
    final box = _settingsBox;
    if (box == null) return;
    final add = messageIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (add.isEmpty) return;
    try {
      final current = getPendingPushMessageIds();
      var changed = false;
      for (final id in add) {
        if (!current.contains(id)) {
          current.add(id);
          changed = true;
        }
      }
      if (changed) await box.put('pending_push_message_ids', current);
    } catch (_) {}
  }

  Future<void> removePendingPushMessageIds(Iterable<String> messageIds) async {
    final box = _settingsBox;
    if (box == null) return;
    try {
      final current = getPendingPushMessageIds();
      var changed = false;
      for (final id in messageIds) {
        if (current.remove(id)) changed = true;
      }
      if (changed) await box.put('pending_push_message_ids', current);
    } catch (_) {}
  }

  // --- 设置补推标记 ---
  //
  // `pushSettings` 失败以前同样没人管（`_pushSettingsGated` 只返回 false），
  // 服务器没开时改的设置就一直躺在本地。用一个持久标记记着"还没推上去"，
  // 等同步时补推一次。设置是"最新状态覆盖"语义，所以只需要一个布尔量。
  bool get pendingSettingsPush {
    final box = _settingsBox;
    if (box == null) return false;
    try {
      return box.get('pending_settings_push') == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setPendingSettingsPush(bool pending) async {
    final box = _settingsBox;
    if (box == null) return;
    try {
      await box.put('pending_settings_push', pending);
    } catch (_) {}
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
