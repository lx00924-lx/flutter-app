import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'providers/chat_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/chat_screen.dart';
import 'screens/login_screen.dart';
import 'screens/splash_screen.dart';

/// 全局导航 Key，供服务层在收到顶号通知时安全弹窗与跳转
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地持久化 Hive 数据库 (增加异常捕获及自动修复机制，确保绝不发生启动秒退)
  try {
    await Hive.initFlutter();
    await Hive.openBox('sessions_box');
    await Hive.openBox('messages_box');
    await Hive.openBox('settings_box');
  } catch (e, stack) {
    debugPrint('Hive init warning: $e\n$stack');
    try {
      await Hive.deleteBoxFromDisk('sessions_box');
      await Hive.deleteBoxFromDisk('messages_box');
      await Hive.deleteBoxFromDisk('settings_box');
      await Hive.openBox('sessions_box');
      await Hive.openBox('messages_box');
      await Hive.openBox('settings_box');
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
      child: const DeepSeekNativeApp(),
    ),
  );
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
