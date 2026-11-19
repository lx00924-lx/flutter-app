import 'package:hive/hive.dart';
import 'dart:convert';
import 'sync_debug.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/app_settings.dart';

class StorageService {
  static final StorageService instance = StorageService._();
  StorageService._();

  String? _scope;
  String get _scopeSuffix => _scope == null ? '' : '_$_scope';
  String get _sessionsBoxName => 'sessions_box$_scopeSuffix';
  String get _messagesBoxName => 'messages_box$_scopeSuffix';
  String get _settingsBoxName => 'settings_box$_scopeSuffix';

  Box? get _sessionsBox => Hive.isBoxOpen(_sessionsBoxName) ? Hive.box(_sessionsBoxName) : null;
  Box? get _messagesBox => Hive.isBoxOpen(_messagesBoxName) ? Hive.box(_messagesBoxName) : null;
  Box? get _settingsBox => Hive.isBoxOpen(_settingsBoxName) ? Hive.box(_settingsBoxName) : null;

  static String scopeForAccount(String account) {
    // Account names are normalized to lowercase for case-insensitive login identity.
    // UTF-8 hex is reversible and Hive-name safe; distinct normalized accounts cannot collide.
    final bytes = utf8.encode(account.trim().toLowerCase());
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> openAccountScope(String account) async {
    final nextScope = scopeForAccount(account);
    if (nextScope.isEmpty || nextScope == _scope) return;
    await closeAccountScope();

    final oldNames = ['sessions_box', 'messages_box', 'settings_box'];
    final newNames = [
      'sessions_box_$nextScope',
      'messages_box_$nextScope',
      'settings_box_$nextScope',
    ];
    await Future.wait([
      for (final name in newNames)
        if (!Hive.isBoxOpen(name)) Hive.openBox(name),
    ]);

    // The pre-scope boxes belong to the sole historical user of this installation.
    // Persist each copied key in the destination box before marking it migrated. If
    // interrupted, the next run idempotently repeats puts by key, never duplicates data.
    const migrationMarker = 'box_scope_migrated_v1';
    final authBox = Hive.isBoxOpen('auth_box') ? Hive.box('auth_box') : null;
    final migrationAlreadyDone = authBox?.get(migrationMarker) == true;
    var legacyKeyCount = 0;
    var copiedKeyCount = 0;
    if (!migrationAlreadyDone) {
      for (var i = 0; i < oldNames.length; i++) {
        final oldName = oldNames[i];
        if (!await Hive.boxExists(oldName)) continue;
        final source = Hive.isBoxOpen(oldName) ? Hive.box(oldName) : await Hive.openBox(oldName);
        final destination = Hive.box(newNames[i]);
        final keys = source.keys.toList();
        legacyKeyCount += keys.length;
        for (final key in keys) {
          if (!destination.containsKey(key)) {
            await destination.put(key, source.get(key));
            copiedKeyCount++;
          }
        }
      }
      await authBox?.put(migrationMarker, true);
    }
    _scope = nextScope;
    final migrationStatus = migrationAlreadyDone ? 'already-done' : 'completed';
    SyncDebug.log(
      'openAccountScope: scope=$nextScope, migration=$migrationStatus, '
      'legacyKeys=$legacyKeyCount, copiedKeys=$copiedKeyCount',
    );
  }

  Future<void> closeAccountScope() async {
    final names = [_sessionsBoxName, _messagesBoxName, _settingsBoxName];
    for (final name in names) {
      if (Hive.isBoxOpen(name)) await Hive.box(name).close();
    }
    _scope = null;
  }

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

  /// 消息库里出现过的所有 sessionId（含**没有任何会话指向**的那些）。
  ///
  /// 用途：把"孤儿的消息"重新接回会话。会话被误删时，聊天记录有可能还躺在
  /// messages_box 里 —— 没有会话指向它，界面上就一条都看不见，用户以为数据没了。
  /// 这个方法是那条找回路径的起点（见 ChatProvider._rebuildOrphanSessions）。
  Set<String> getAllSessionIdsFromMessages() {
    final box = _messagesBox;
    final ids = <String>{};
    if (box == null) return ids;
    for (var key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        final sid = (val['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty) ids.add(sid);
      }
    }
    return ids;
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
  /// 上次从云端拉消息拉到了第几个（服务端的 seq，1 开始，0 = 还没拉过）。
  ///
  /// 用途：只在**增量拉取**时作为游标传给 `/api/messages/:userId?afterSeq=N`，
  /// 这样每轮只传"上次之后新增的那几条"，而不是把整张消息表（现在 4.1MB）重传一遍。
  ///
  /// ⚠️ 它**只**用来回答"还有哪些没拿过"，**绝不用来判断谁被删了** ——
  /// 删除必须由明确的删除指令驱动（2026-10-22 误删事故的教训）。
  /// 所以这个值算错最多导致"多拉一次"，不会导致数据丢失。
  int getLastSyncedSeq() {
    final box = _settingsBox;
    if (box == null) {
      SyncDebug.log('getLastSyncedSeq: settings_box 为 null（box 没打开？）');
      return 0;
    }
    try {
      final v = box.get('last_synced_seq');
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
    } catch (_) {}
    return 0;
  }

  Future<void> setLastSyncedSeq(int seq) async {
    final box = _settingsBox;
    if (box == null) {
      SyncDebug.log('setLastSyncedSeq($seq): settings_box 为 null，写不进去');
      return;
    }
    if (seq < 0) return;
    try {
      final current = getLastSyncedSeq();
      SyncDebug.log('setLastSyncedSeq($seq): current=$current');
      // 只增不减 —— 但**允许重置为 0**。
      //
      // 0 是"重新全量拉"的显式信号：服务端的 seq 是数组下标+1，删消息会让它回退
      // （用户删光后 210 条变 4 条），这时旧游标 212 会把所有消息永久过滤掉。
      // 调用方发现回退后置 0，下一轮走全量重拉一遍（重复保存是幂等的）。
      // 注意要把 0 真正写进 box：直接 return 的话旧值还在，等于没重置。
      if (seq > current) {
        await box.put('last_synced_seq', seq);
        SyncDebug.log('setLastSyncedSeq($seq): 已写入，回读=${getLastSyncedSeq()}');
      } else if (seq == 0 && current > 0) {
        await box.put('last_synced_seq', 0);
        SyncDebug.log('setLastSyncedSeq(0): 强制重置（seq 回退保护），回读=${getLastSyncedSeq()}');
      }
    } catch (e) {
      SyncDebug.log('setLastSyncedSeq($seq) 抛异常: $e');
    }
  }

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

  AppSettings? loadSettingsFromBox(Box box) {
    try {
      final val = box.get('app_settings');
      if (val is Map) return AppSettings.fromMap(val);
    } catch (_) {}
    return null;
  }

  /// 读**当前已打开 scope** 的账号设置；没开 scope、或那个箱里还没有设置时返回 null。
  ///
  /// 为什么不能用 `auth_box` 顶替：`auth_box` 存的是「最后一次登录时的整份设置」，
  /// 换账号之后那份还是**上一个账号**的。启动流程里 `openAccountScope()` 只负责
  /// 打开箱，不会替换 `SettingsProvider._settings` —— 所以启动时必须优先读这里。
  AppSettings? loadSettingsFromCurrentScope() {
    final box = _settingsBox;
    if (box == null) return null;
    return loadSettingsFromBox(box);
  }

  Future<void> saveAuthSettings(AppSettings settings) async {
    try {
      if (Hive.isBoxOpen('auth_box')) {
        await Hive.box('auth_box').put('app_settings', settings.toMap());
      }
    } catch (_) {}
  }

  Future<void> saveSettings(AppSettings settings) async {
    try {
      final box = _settingsBox;
      if (box != null) {
        await box.put('app_settings', settings.toMap());
      }
      await saveAuthSettings(settings);
    } catch (_) {}
  }
}
