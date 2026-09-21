import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 系统通知（本地通知）服务。
///
/// 用途：DSH 在电脑上请求授权时，App 可能不在前台 —— 光靠应用内弹窗看不到。
/// 这里发一条高优先级通知，点一下就能回到 App 处理。
///
/// 权限：Android 13+ 需要 POST_NOTIFICATIONS 运行时授权（清单里已声明），
/// 首次使用会向用户申请。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const String _channelId = 'lx_approval';
  static const String _channelName = '需要授权';
  static const String _channelDesc = '电脑端本地 Agent 请求执行敏感操作时提醒';
  static const int _approvalNotificationId = 8801;

  /// 选择框（ask_user_question）用独立渠道/独立 id：两条通知可以同时在，
  /// 互不覆盖；用户也能单独关掉其中一类提醒。
  static const String _questionChannelId = 'lx_question';
  static const String _questionChannelName = '需要选择';
  static const String _questionChannelDesc = '电脑端 Agent 提问、等你选一个答案时提醒';
  static const int _questionNotificationId = 8802;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// 用户点了通知（payload 为 approvalId）
  void Function(String approvalId)? onApprovalTapped;

  /// 用户点了选择框通知（payload 为 questionId）
  void Function(String questionId)? onQuestionTapped;

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(android: android, iOS: darwin, macOS: darwin),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload ?? '';
          if (payload.isEmpty) return;
          if (payload.startsWith('q:')) {
            onQuestionTapped?.call(payload.substring(2));
            return;
          }
          onApprovalTapped?.call(payload);
        },
      );
      _initialized = true;
      debugPrint('[Notify] 通知服务已初始化');
    } catch (e) {
      debugPrint('[Notify] 初始化失败: $e');
    }
  }

  /// 申请通知权限（Android 13+ / iOS）。返回是否已授权。
  Future<bool> ensurePermission() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      await init();
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final enabled = await android?.areNotificationsEnabled();
      if (enabled == true) return true;
      final granted = await android?.requestNotificationsPermission();
      debugPrint('[Notify] 通知权限申请结果: $granted');
      return granted ?? false;
    } catch (e) {
      debugPrint('[Notify] 申请通知权限失败: $e');
      return false;
    }
  }

  /// 当前是否已授权通知
  Future<bool> hasPermission() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      await init();
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return await android?.areNotificationsEnabled() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 弹出"电脑端等待授权"通知
  Future<void> showApprovalRequest({
    required String approvalId,
    required String tool,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await init();
      if (!await hasPermission()) return;
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          autoCancel: true,
          ongoing: false,
        ),
      );
      await _plugin.show(
        id: _approvalNotificationId,
        title: '电脑端等待你的授权',
        body: '本地 Agent 想执行：$tool（点击处理）',
        notificationDetails: details,
        payload: approvalId,
      );
      debugPrint('[Notify] 已发出授权提醒通知（$tool）');
    } catch (e) {
      debugPrint('[Notify] 发送通知失败: $e');
    }
  }

  /// 授权处理完了，撤掉通知
  Future<void> cancelApprovalRequest() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await init();
      await _plugin.cancel(id: _approvalNotificationId);
    } catch (_) {}
  }

  /// 弹出"电脑端 Agent 在问你"通知（选择框）
  Future<void> showQuestionRequest({
    required String questionId,
    required String title,
    String body = '',
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await init();
      if (!await hasPermission()) return;
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _questionChannelId,
          _questionChannelName,
          channelDescription: _questionChannelDesc,
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          autoCancel: true,
          ongoing: false,
        ),
      );
      await _plugin.show(
        id: _questionNotificationId,
        title: title.isEmpty ? '电脑端 Agent 在等你选择' : title,
        body: body.isEmpty ? '点击选择一个答案（本地 Agent 正在等待）' : body,
        notificationDetails: details,
        payload: 'q:$questionId',
      );
      debugPrint('[Notify] 已发出选择框提醒通知（$questionId）');
    } catch (e) {
      debugPrint('[Notify] 发送选择框通知失败: $e');
    }
  }

  /// 选择框处理完了，撤掉通知
  Future<void> cancelQuestionRequest() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await init();
      await _plugin.cancel(id: _questionNotificationId);
    } catch (_) {}
  }
}
