# 核心架构与安全准则 (Critical Project Constraints)

## 1. 核心架构认知
- 本项目是【云端中继管理与监控看板 (Web) + Flutter 纯原生多端 App 客户端 (`flutter_app/`) + 本地 Agent 反向长连接内网穿透 (`deepseek_bridge.py`)】的三位一体架构。
- **架构精简与原生化**：已彻底剥离早期 Capacitor/WebView 混合套壳依赖，移动与桌面端全面采用纯原生 Flutter 架构；Web 端聚焦于轻量级云端中继监控、扫码配对与实时通信流观测。
- **公网生产中继服务**：默认生产服务器域名为 **`https://www.lx00924ai.top`**，手机端扫码与电脑端 Bridge 均默认指向该地址。
- **核心业务功能**：手机/电脑客户端通过云端中继远程遥控内网电脑（无公网 IP）上的私有 Agent（Harness / 本地模型 / 本地自动化工作区），支持单点登录设备互斥、消息增量漫游与全局设置云端同步。

## 2. 绝对受保护文件与目录（严禁删除、重构破坏或提议删除）
- `deepseek_bridge.py`：电脑端反向长连接守护进程（用于解决无公网 IP 电脑连接云端中继、与 Harness 本地通信），属于核心生产力资产，**绝不可删除或废弃**！
- `flutter_app/`：整个 Flutter 纯原生跨端多平台工程，包含所有 Dart 源码、状态管理（Provider）、本地持久化、云端增量漫游与 Android/Windows 打包配置，**绝不可破坏或删除**！
- `server.ts`：包含 Harness 反向中继信道、Token 调度分配、消息持久化落盘、用户设置云端漫游（`messages_data/settings.json`）与单点登录互斥控制，**绝不可破坏核心逻辑**！
- `src/`：已精简的 Web 端中继控制台、Flutter App 扫码绑定面板、Bridge 穿透状态监测及网络事件流看板。

## 3. 云端同步与持久化规范
- **设置云端漫游**：Flutter 客户端（`SyncService` / `SettingsProvider`）与服务端（`/api/settings/:userId`）已建立双向增量防抖同步，换机或清除缓存登录即自动恢复所有 API 端点卡片、模型及外观设置。
- **单点登录互斥**：服务端严格维持 1 台手机 + 1 台电脑并行的互斥登录心跳策略。

## 4. 操作与删除安全规范
- **严格确认机制**：只有在用户明确给出“确认更改”、“可以”等肯定指令后方可进行文件修改或写入操作；在日常咨询或问答中，只解释原因和提供建议。
- **严禁误删**：严禁擅自执行任何文件或目录删除操作（`delete_file` / `delete_dir`）。在涉及清理文件时，必须逐一核查文件的真实业务逻辑和调用链路，绝不可将核心脚本误认为临时文件。
- **多端对齐原则**：在后续修复 Bug 或新增功能时，需保持服务端（Express/TS）与 Flutter 端（Dart）的数据结构与通信协议严密对齐。

## 5. 代码质量与零语法错误准则 (Zero Syntax Error & Build Protection)
- **静态类型与语法完整性**：每次修改 Dart（`flutter_app/`）、TypeScript（`server.ts`, `src/`）或 Python（`deepseek_bridge.py`）代码时，必须保证语法 100% 正确，严禁出现拼写错误、漏闭合括号/分号、类型不匹配或未导入依赖包。
- **打包兼容性检查**：
  - **Flutter/Dart 端**：严格遵循 Dart 空安全（Null-safety），禁止引入破坏性构造函数改动，确保各种 Platform Channels、Provider 状态监听以及 JSON 序列化字段严密对齐。
  - **Android Gradle 构建**：严禁随意更改 Gradle 依赖版本或混淆规则（`proguard-rules.pro`），确保与 Release 签名（`AI.jks`）完全兼容。
- **本地零阻碍打包**：所有交付代码必须经过严密的自检与校验，杜绝因低级语法或引用错误导致用户本地 `flutter build apk` 或 `npm run build` 打包失败。
# 🛠️ Flutter 移动端 Android Release 打包故障排查与防护指南

> 本文档记录了项目在进行 `flutter build apk --release` 编译打包过程中的典型报错、根因分析及根治方案，作为团队与后续迭代的防错避坑规范。

---

## 一、 核心故障与根治方案全景表

| 序号 | 报错类型 | 报错位置 | 根因分析 (Why) | 修复方案 (How) |
| :--- | :--- | :--- | :--- | :--- |
| **1** | **三方库平台抽象接口断层** | `record_linux-0.7.2` | `pub.dev` 官方仓库的底层接口包 `record_platform_interface` 升级到 `1.6.0`（新增了 `startStream` 与 `hasPermission` 命名参数），但 `record_linux (0.7.2)` 尚未发布新实现，导致 Flutter 在编译全平台桩代码时报错 `missing implementations`。 | 在 `flutter_app/pubspec.yaml` 中通过 `dependency_overrides` 强制锁定 `record_platform_interface: 1.2.0`，彻底消除接口冲突。 |
| **2** | **作用域未定义变量** | `lib/providers/chat_provider.dart` | `sendMessage` 中重构为多消息发送列表 `userMsgsToSend`，但在 `onError` 和 `catch` 异常捕获块中仍残留旧变量名 `userMsg`。 | 改为从 `userMsgsToSend` 列表中安全提取末尾消息：`final lastUserMsg = userMsgsToSend.isNotEmpty ? userMsgsToSend.last : null` 并更新状态。 |
| **3** | **组件构造传参不匹配** | `lib/widgets/message_bubble.dart` | 1. `TextSelectionModal` 构造函数要求 `required this.message`，但传参为 `text: message.content`。<br>2. `VoiceMessageBubble` 构造参数为 `audioDataUri`，误传为 `audioUri`。 | 1. 修正为 `TextSelectionModal(message: message)`。<br>2. 修正为 `VoiceMessageBubble(audioDataUri: att, isUser: isUser)`。 |
| **4** | **模型字段与构造错误** | `lib/widgets/text_selection_modal.dart` | `ChatMessage` 模型构造函数中时间字段为 `createdAt`，会话 ID 为必填项 `sessionId`，此处误传了不存在的 `timestamp` 且缺少 `sessionId`。 | 修正为 `sessionId: widget.message.sessionId` 与 `createdAt: widget.message.createdAt`。 |

---

## 二、 后续开发防错与避坑准则

### 1. 跨平台依赖版本锁定准则
- 对于包含多平台子插件的生态库（如 `record`、`audioplayers`、`file_picker`），若遇到 `The non-abstract class ... is missing implementations for these members` 报错：
  - **切勿盲目升级次级子插件**，因为子平台插件的发布进度各不相同；
  - **首选在 `dependency_overrides` 中锁定 `platform_interface` 的稳定版本**，防止 `pub.dev` 自动拉取激进的最新抽象接口破坏现有代码。

### 2. 重构与异常处理链路对齐
- 修改主要业务数据流变量名（如消息列表由单条变量改为集合）时，必须同时检查其下游的 **`onError`**、**`onDone`** 以及 **`catch (e)`** 异常回滚分支，确保全链路变量命名严格一致。

### 3. 组件与模型构造规范
- 在调用非基础数据类型的组件或构造实体类（如 `ChatMessage`）时，务必检查模型定义文件（`lib/models/`）中的必填字段（`required this.sessionId`）与时间字段命名（`createdAt`），杜绝手写臆测字段名。

### 4. 标准编译与打包自检流水线
在本地进行版本交付或打包测试时，必须使用标准四步流水线进行验证：
```bash
cd flutter_app
flutter clean
flutter pub get
flutter analyze          # 提前捕获所有语法与类型错误
flutter build apk --release
```

---

## 三、 控制台常规输出解读（非错误）

1. **`Font asset "MaterialIcons-Regular.otf" was tree-shaken... (99.0% reduction)`**  
   - Flutter 开启的字体摇树优化，自动剔除未使用的 Material 图标，为 APK 瘦身约 1.6MB。
2. **`Warning: Flutter support for your project's Gradle version...`**  
   - Flutter 官方对未来版本 Gradle 升级的常规预警，当前 Gradle 8.14 与 AGP 8.11 完全稳定运行。
3. **`警告: [options] 源值 8 已过时...`**  
   - 第三方 Android 原生依赖库底层针对 Java 8 的编译提示，完全不影响 APK 安装与运行。
