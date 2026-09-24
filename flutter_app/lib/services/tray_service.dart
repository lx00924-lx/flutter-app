// tray_manager 0.7 把底层换成了 nativeapi 的 FFI 句柄接口，官方同时保留了这个兼容库
// （legacy.dart）给既有代码用。我们这里只用「图标 / 悬停提示 / 右键菜单」三件事，
// 走兼容库比直接操作 TrayIcon/MenuBackend 句柄更稳；等它真被移除时再迁到 nativeapi。
// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';

/// 托盘图标状态（优先级从上到下：越靠上越"有事要做"）。
enum TrayStatus {
  /// 有选择框 / 审批在等用户处理 —— 最高优先级，必须一眼看见
  waiting,

  /// 桥接离线（电脑端 Agent 不可用）
  offline,

  /// 有新的 Agent 回复还没看
  message,

  /// 在线空闲
  idle,
}

/// Windows 托盘常驻：关窗口 = 收进托盘继续跑，托盘图标体现"有没有事要做"。
///
/// 只在不支持平台的判断下启用（Android/iOS/Web 完全不受影响）。
/// 图标 4 态设计（assets/icons/tray/*.ico，16/32/48 多尺寸）：
///   idle 灰蓝圆 · message 绿圆+倒三角 · question 橙圆+惊叹号 · offline 玫红圆+横杠
class TrayService with TrayListener, WindowListener {
  TrayService._();

  static final TrayService instance = TrayService._();

  bool _inited = false;
  bool _windowActive = true;
  TrayStatus _status = TrayStatus.idle;
  String? _appliedTooltip;

  bool get supported => !kIsWeb && Platform.isWindows;
  bool get isReady => _inited;
  TrayStatus get status => _status;

  /// 在 `runApp` 之前调用：初始化窗口管理器 + 托盘图标与右键菜单。
  Future<void> init() async {
    if (!supported || _inited) return;
    await windowManager.ensureInitialized();
    // 等窗口真正就绪再显示，避免启动时先闪一下白屏
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(center: true),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    // 关键：关闭按钮 = 收进托盘（真正退出走托盘菜单）
    windowManager.addListener(this);

    try {
      _windowActive = await windowManager.isFocused();
    } catch (_) {
      _windowActive = true;
    }

    // 顺序很重要：**先把托盘建起来，再开启"关闭即隐藏"**。
    // 万一托盘图标没建成（原生插件异常）却已经把关闭拦了，用户就只能去任务管理器
    // 结束进程 —— 那种"关不掉"的体验比没有托盘更糟。
    var trayReady = false;
    try {
      await trayManager.setIcon(_iconFor(TrayStatus.idle));
      await trayManager.setToolTip(_tooltipFor(TrayStatus.idle));
      _appliedTooltip = _tooltipFor(TrayStatus.idle);
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '显示主窗口'),
            // 「收进托盘」已按用户要求移除：窗口本来就靠关闭按钮收进托盘，
            // 菜单里再放一项等于让人在托盘菜单里把已经看不见的窗口再藏一次。
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出 LxAI'),
          ],
        ),
      );
      trayManager.addListener(this);
      trayReady = true;
    } catch (e) {
      debugPrint('[Tray] 托盘图标创建失败，保持普通关闭行为: $e');
    }

    if (!trayReady) return;
    await windowManager.setPreventClose(true);
    _inited = true;
    debugPrint('[Tray] 托盘常驻已就绪（关闭窗口 = 收进托盘）');
  }

  /// 由界面层在状态变化时调用；内部去重，不会反复刷图标。
  ///
  /// 规则：窗口在前台时不显示"有未读"（人就在看着），但**等待用户处理**照常显示 ——
  /// 选择框/审批是"卡住了"，不管窗口在不在前台都得提示。
  Future<void> sync({
    required bool agentOnline,
    required bool waitingForUser,
    required bool unreadMessage,
  }) async {
    if (!_inited) return;
    final effectiveUnread = unreadMessage && !_windowActive;
    final next = waitingForUser
        ? TrayStatus.waiting
        : (!agentOnline
            ? TrayStatus.offline
            : (effectiveUnread ? TrayStatus.message : TrayStatus.idle));
    final tip = _tooltipFor(next);
    if (next == _status && tip == _appliedTooltip) return;
    _status = next;
    _appliedTooltip = tip;
    try {
      await trayManager.setIcon(_iconFor(next));
      await trayManager.setToolTip(tip);
    } catch (e) {
      debugPrint('[Tray] 更新托盘状态失败: $e');
    }
  }

  /// 把主窗口调出来并置前（托盘单击 / 菜单「显示主窗口」）。
  Future<void> showWindow() async {
    if (!supported) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('[Tray] 显示窗口失败: $e');
    }
  }

  /// 收进托盘。
  Future<void> hideToTray() async {
    if (!supported) return;
    try {
      await windowManager.hide();
    } catch (e) {
      debugPrint('[Tray] 隐藏窗口失败: $e');
    }
  }

  /// 真正退出（托盘菜单「退出 LxAI」）。
  Future<void> exitApp() async {
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (e) {
      debugPrint('[Tray] 退出时出错（继续结束进程）: $e');
    }
    exit(0);
  }

  String _iconFor(TrayStatus status) => switch (status) {
        TrayStatus.waiting => 'assets/icons/tray/tray_question.ico',
        TrayStatus.offline => 'assets/icons/tray/tray_offline.ico',
        TrayStatus.message => 'assets/icons/tray/tray_message.ico',
        TrayStatus.idle => 'assets/icons/tray/tray_idle.ico',
      };

  String _tooltipFor(TrayStatus status) => switch (status) {
        TrayStatus.waiting => 'LxAI · Agent 正在等你选择 / 授权（点击回到窗口）',
        TrayStatus.offline => 'LxAI · 电脑端桥接离线',
        TrayStatus.message => 'LxAI · 有新的 Agent 回复',
        TrayStatus.idle => 'LxAI · Agent 在线',
      };

  //#region 托盘 / 窗口事件

  @override
  void onTrayIconMouseDown() {
    // 左键单击：回到窗口（Windows 上最符合直觉的行为）
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
      case 'exit':
        exitApp();
      default:
    }
  }

  /// 关闭按钮拦截：收进托盘，而不是结束进程。
  @override
  void onWindowClose() {
    windowManager.isPreventClose().then((prevent) async {
      if (prevent) await hideToTray();
    });
  }

  @override
  void onWindowFocus() {
    _windowActive = true;
  }

  @override
  void onWindowBlur() {
    _windowActive = false;
  }
  //#endregion
}
