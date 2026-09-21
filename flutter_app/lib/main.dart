import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'providers/chat_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/chat_screen.dart';
import 'screens/login_screen.dart';
import 'screens/splash_screen.dart';
import 'services/notification_service.dart';
import 'services/tray_service.dart';

/// 全局导航 Key，供服务层在收到顶号通知时安全弹窗与跳转
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地持久化 Hive 数据库 (并发异步打开，大幅提升启动速度；增加异常自动恢复机制)
  try {
    await Hive.initFlutter();
    await Future.wait([
      Hive.openBox('sessions_box'),
      Hive.openBox('messages_box'),
      Hive.openBox('settings_box'),
    ]);
  } catch (e, stack) {
    debugPrint('Hive init warning: $e\n$stack');
    try {
      await Future.wait([
        Hive.deleteBoxFromDisk('sessions_box'),
        Hive.deleteBoxFromDisk('messages_box'),
        Hive.deleteBoxFromDisk('settings_box'),
      ]);
      await Future.wait([
        Hive.openBox('sessions_box'),
        Hive.openBox('messages_box'),
        Hive.openBox('settings_box'),
      ]);
    } catch (fallbackError) {
      debugPrint('Hive fallback failed: $fallbackError');
    }
  }

  // 配置沉浸式透明状态栏
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  // 初始化本地通知：电脑端请求授权时要能在后台提醒到人
  // （初始化本身很轻，权限在真正要用时再申请，避免冷启动打断用户）
  unawaited(NotificationService.instance.init());

  // Windows：托盘常驻（关闭窗口 = 收进托盘；托盘图标体现 Agent 状态）
  // 失败不影响启动 —— 托盘只是锦上添花，不能因为一个原生插件挂掉就打不开 App
  if (!kIsWeb && Platform.isWindows) {
    try {
      await TrayService.instance.init();
    } catch (e) {
      debugPrint('Tray init failed: $e');
    }
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProxyProvider<SettingsProvider, ChatProvider>(
          create: (ctx) => ChatProvider(ctx.read<SettingsProvider>()),
          update: (ctx, settings, previous) =>
              previous ?? ChatProvider(settings),
        ),
      ],
      child: const TrayStatusBinder(
        child: DeepSeekNativeApp(),
      ),
    ),
  );
}

/// 把「Agent 在线 / 等待用户处理 / 有未读回复」这三点变化喂给托盘图标。
///
/// 单独做成一个组件：托盘状态是**跨页面**的（用户可能停在设置页或已经收进托盘），
/// 挂在 Provider 树最外层才能一直跟着状态走。
class TrayStatusBinder extends StatefulWidget {
  const TrayStatusBinder({super.key, required this.child});

  final Widget child;

  @override
  State<TrayStatusBinder> createState() => _TrayStatusBinderState();
}

class _TrayStatusBinderState extends State<TrayStatusBinder>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 窗口回到前台：未读清掉，托盘图标跟着回到「空闲」
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<ChatProvider>().clearAgentUnread();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final chat = context.watch<ChatProvider>();
    final waitingForUser =
        chat.pendingQuestion != null || chat.pendingApproval != null;
    final agentOnline = sp.settings.isHarnessOnline == true;
    final unread = chat.hasUnreadAgent;

    // build 期间不能直接做异步副作用，挪到帧后执行
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(TrayService.instance.sync(
        agentOnline: agentOnline,
        waitingForUser: waitingForUser,
        unreadMessage: unread,
      ));
    });

    return widget.child;
  }
}

class DeepSeekNativeApp extends StatelessWidget {
  const DeepSeekNativeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'DeepSeek Native AI',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: settings.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: const Color(0xFF0284C7), // 现代化科技蓝
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFFE2E8F0), width: 1),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 1,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF38BDF8),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        cardTheme: const CardThemeData(
          color: Color(0xFF1E293B),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFF334155), width: 1),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F172A),
          elevation: 0,
          scrolledUnderElevation: 1,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: Color(0xFFF8FAFC),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      home: settings.enableSplash
          ? const SplashScreen()
          : (settings.isLoggedIn ? const ChatScreen() : const LoginScreen()),
    );
  }
}
