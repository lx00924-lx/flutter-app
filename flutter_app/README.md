# DeepSeek Native AI (Flutter 多平台原生应用)

本项目已成功通过 **方案 A** 重构为纯正的 **Flutter 多平台原生工程**。彻底移除了网页套壳（WebView），采用 Flutter 自绘引擎、原生 Material 3 控件树、SSE 流式打字机管道以及本地 Hive 数据库。

---

## 🚀 核心架构与特性

1. **纯原生自绘渲染**：
   - 无浏览器内核、无 DOM 树性能瓶颈，支持 60/120Hz 高刷与原生物理阻尼回弹。
2. **彻底解决存储溢出**：
   - 基于 **Hive NoSQL 数据库**，直接在手机闪存/电脑硬盘读写，永久保存历史会话与超长思维链，无任何容量上限报错。
3. **原生 DeepSeek-R1 思考链渲染**：
   - 原生 `ReasoningView` 组件，支持折叠展开、动态思考时间计时与 Markdown 代码块一键复制。
4. **多平台一套源码编译**：
   - 📱 **Android** (APK / AAB)
   - 💻 **Windows** (.exe 桌面程序)
   - 🍎 **macOS / iOS**

---

## 🛠️ 本地运行与编译打包指南

### 1. 前置准备
- 安装 [Flutter SDK](https://flutter.dev/docs/get-started/install)（推荐 Flutter 3.19 及以上）。
- 安装 Android Studio（打包安卓）或 Visual Studio（打包 Windows .exe）。

### 2. 获取依赖
在终端中进入 `flutter_app` 目录：
```bash
cd flutter_app
flutter pub get
```

### 3. 本地调试运行（支持秒级 Hot Reload）
连接真机或启动模拟器后执行：
```bash
flutter run
```

### 4. 一键打包发布

#### 📱 打包 Android 原生 APK：
```bash
flutter build apk --release
```
> 输出路径：`build/app/outputs/flutter-apk/app-release.apk`

#### 💻 打包 Windows 原生 .exe 桌面端：
```bash
flutter build windows --release
```
> 输出路径：`build/windows/x64/runner/Release/`

---

## 📁 目录结构概览
```text
flutter_app/
├── pubspec.yaml                  # 原生依赖管理 (Dio, Hive, Markdown, Provider)
└── lib/
    ├── main.dart                 # 应用入口、主题配置、数据库初始化
    ├── models/                   # 数据模型 (ChatMessage, ChatSession, AppSettings)
    ├── services/                 # API 流式服务 (SSE)、本地存储、WebSocket 桥接
    ├── providers/                # 状态机 (ChatProvider, SettingsProvider)
    ├── widgets/                  # 原生自绘控件 (MessageBubble, ChatInputBar, ReasoningView)
    └── screens/                  # 原生页面 (ChatScreen, SettingsScreen)
```
