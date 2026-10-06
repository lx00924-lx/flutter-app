# 核心架构与安全准则 (Critical Project Constraints)

## 1. 核心架构认知
- 本项目是【LxAI 官网介绍与下载门户 (Web) + Flutter 纯原生多端 App 客户端 (`flutter_app/`) + 本地 Agent 反向长连接内网穿透 (`lxai_bridge.py`)】的三位一体架构。
- **架构精简与原生化**：已彻底剥离早期 Capacitor/WebView 混合套壳依赖（`package.json` 中的 Capacitor/Ionic 依赖、`public/lxai_bridge.py` 旧副本与 `/api/agent/download-bridge` 旧控制台接口均已清除），移动与桌面端全面采用纯原生 Flutter 架构；Web 端（`src/`）现为**对外官网介绍与下载门户**，不再承担中继监控看板职能。
- **公网生产中继服务**：默认生产服务器域名为 **`https://www.lx00924ai.top`**，手机端扫码与电脑端 Bridge 均默认指向该地址。
- **核心业务功能**：手机/电脑客户端通过云端中继远程遥控内网电脑（无公网 IP）上的私有 Agent（Harness / 本地模型 / 本地自动化工作区），支持单点登录设备互斥、消息增量漫游与全局设置云端同步。
- **待办清单在 [`docs/TODO.md`](./docs/TODO.md)**：用户口头交代"先记一下、下次再做"的事项都记在那里（带文件与行号定位）。
  **动手改 App / 官网之前先扫一眼那一节**，避免重复劳动或漏做；做完一条就把该小节删掉（历史交给 git log，别在文件里堆"已完成"）。

## 2. 绝对受保护文件与目录（严禁删除、重构破坏或提议删除）
- `lxai_bridge.py`：电脑端反向长连接守护进程（用于解决无公网 IP 电脑连接云端中继、与 Harness 本地通信），属于核心生产力资产，**绝不可删除或废弃**！
- `flutter_app/`：整个 Flutter 纯原生跨端多平台工程，包含所有 Dart 源码、状态管理（Provider）、本地持久化、云端增量漫游与 Android/Windows 打包配置，**绝不可破坏或删除**！
- `server.ts`：包含 Harness 反向中继信道、Token 调度分配、消息持久化落盘、用户设置云端漫游（`messages_data/settings.json`）与单点登录互斥控制，**绝不可破坏核心逻辑**！
- `src/`：已精简的 LxAI 官网介绍与下载门户（Navbar / Hero / Features / Architecture / Downloads / ContactFooter），通过 GitHub Releases API 展示并分发多端安装包。

## 3. 云端同步与持久化规范
- **设置云端漫游**：Flutter 客户端（`SyncService` / `SettingsProvider`）与服务端（`/api/settings/:userId`）已建立双向增量防抖同步，换机或清除缓存登录即自动恢复所有 API 端点卡片、模型及外观设置。
- **单点登录互斥**：服务端严格维持 1 台手机 + 1 台电脑并行的互斥登录心跳策略。
- **账号注册与注销只在官网**（2026-10-02 起，别再往 App 里加注册）：
  - **注册**：官网 `POST /api/register` 要求 `{username, password, email, code}` —— 邮箱验证码 + Cloudflare Turnstile + **一邮一号**。App 登录页**已无注册入口**（`login_screen.dart` 只留「还没有账号？点击前往官网注册」跳转，用 `UrlLauncherHelper.openUrl(AppConfig.normalizedServerBaseUrl)`）。
    ⚠️ `SyncService.registerWithServer` / `SettingsProvider.registerWithServer` 已标 `@Deprecated`，只发 `username`+`password`，**调用必定被 400 打回**。
  - **注销**：`POST /api/account/delete-code`（发码）+ `POST /api/account/delete`（执行）。验证码**只发给服务端从 `users.json` 查出的绑定邮箱**，前端不提供"接收验证码的邮箱"输入框 —— 否则填别人的账号名 + 自己的邮箱就能注销别人的账号。
  - **删除范围**：`users.json`（数组，按用户名过滤）、`messages_v2.json` / `settings.json` / `active_sessions.json`（按用户名整键移除），各自在 `withFileLock` 内完成。
    ⚠️ **`messages_media/` 刻意不删**：文件名是 multer 随机生成的、不含用户信息，无法可靠判定归属，宁可少删也不误删他人文件。要支持得先把上传改成"按 userId 建子目录"。
  - 前置配置：`.env` 里的 SMTP（用授权码，不是登录密码；`SMTP_SECURE` 语义是"连上就立刻 TLS"，465 填 1、587 必须填 0）与 `TURNSTILE_SECRET` / `VITE_TURNSTILE_SITE_KEY`（后者是**构建期**注入，改完要 `npm run build`）。未配置时接口**明确返回 503/拒绝**，不静默失败。
  - 回归测试脚本：`F:\ai\flutter\lxai-delete-test\run-test.cjs`（本地沙箱实例 + 自建 SMTP 接收器，跑真实 `dist/server.cjs`，32 项断言）。

## 4. 操作与删除安全规范
- **严格确认机制**：只有在用户明确给出“确认更改”、“可以”等肯定指令后方可进行文件修改或写入操作；在日常咨询或问答中，只解释原因和提供建议。
- **严禁误删**：严禁擅自执行任何文件或目录删除操作（`delete_file` / `delete_dir`）。在涉及清理文件时，必须逐一核查文件的真实业务逻辑和调用链路，绝不可将核心脚本误认为临时文件。
- **多端对齐原则**：在后续修复 Bug 或新增功能时，需保持服务端（Express/TS）与 Flutter 端（Dart）的数据结构与通信协议严密对齐。

## 5. 代码质量与零语法错误准则 (Zero Syntax Error & Build Protection)
- **静态类型与语法完整性**：每次修改 Dart（`flutter_app/`）、TypeScript（`server.ts`, `src/`）或 Python（`lxai_bridge.py`）代码时，必须保证语法 100% 正确，严禁出现拼写错误、漏闭合括号/分号、类型不匹配或未导入依赖包。
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

---

# 🔀 本地开发与打包工作流（双目录分离，严禁混用）

> 本节记录了仓库历史重构后确立的本地工作方式，以及两次真实事故的教训。**每次开始工作前先按本节执行**。

## 一、两个目录的分工

| 目录 | 角色 | 允许的操作 |
| :--- | :--- | :--- |
| `F:\ai\flutter\123` | **源码编辑仓**（唯一提交/推送的地方） | 改代码、`git commit`、`git push` |
| `F:\ai\flutter\flutter-app` | **打包测试目录**（单向使用） | `git fetch` + `git reset --hard origin/main`、构建、测试 |

**为什么要分开**：构建过程会产生 `build/`、`.dart_tool/`、`windows/flutter/ephemeral/`、Gradle 缓存等大量中间产物，与"待提交的源码"混在同一目录时极易误提交、污染仓库。两个目录共用同一远端 `https://github.com/lx00924-lx/flutter-app`，靠 Git 同步，**永远不要手动复制粘贴源码**。

## 二、标准操作流程

**改代码（在 123）**
```powershell
cd F:\ai\flutter\123
# ...修改源码...
git add <显式路径>          # 不要用 git add -A：临时/报告文件会被误提交（见文末「已知陷阱」§3）
git commit -F 信息文件.md    # 中文多行提交信息用文件传入；文件用 UTF-8 无 BOM 写
git push
```

**打包测试（在 flutter-app）**
```powershell
cd F:\ai\flutter\flutter-app
git fetch origin ; git reset --hard origin/main     # 抓取仓库最新源码
cd flutter_app
flutter build apk --release                          # 或 flutter build windows --release
```

## 三、三条禁令

1. **禁止在 `flutter-app` 执行 `git clean -fdx`。** 该目录存在被 `.gitignore` 忽略但本地必需的签名文件 `flutter_app/android/key.properties` 与 `flutter_app/android/app/AI.jks`，`clean -fdx` 会将其删除、导致正式签名失效。更新源码只用 `fetch` + `reset --hard`。
2. **禁止在 `flutter-app` 提交代码。** 它是"拉最新 → 打包"的单向目录，本地提交会被下一次 `reset --hard origin/main` 丢弃。
3. **`123` 内没有签名密钥（刻意如此）。** 在 123 执行 `flutter build apk --release` 得到的是 debug 签名包；若确需在 123 出正式包，再从 `flutter-app` 复制那两个文件过去（二者均已被 gitignore，不会误提交）。

## 四、临时目录 / 缓存清理规范

- **严禁使用 `robocopy /MIR` 清理构建目录。** robocopy 默认跟随目录链接（junction/symlink），而 `windows/flutter/ephemeral/.plugin_symlinks/` 指向 pub 缓存中的真实包目录，`/MIR` 会把 pub 缓存里对应的包**清空**（曾导致 9 个包被清空、本机 Flutter 构建全面失败）。确需使用 robocopy 时必须加 `/XJ`。
- 清理验证用副本统一使用：
  ```powershell
  Remove-Item -LiteralPath "\\?\<绝对路径>" -Recurse -Force
  ```
  PowerShell 7 的 `Remove-Item` 不跟随链接，`\\?\` 前缀可绕过 Windows 260 字符长路径限制。
- 若 pub 缓存已被清空：先删除那些**空目录**（pub 认为"目录存在 = 已缓存"，不会重新下载），再执行 `flutter pub get` 重新拉取。

## 五、两条硬性入库红线

1. **签名机密绝不入库**：`flutter_app/android/key.properties`、`flutter_app/android/app/*.jks`、`*.keystore`、`*.p12`、`*.pem` 一律由 `.gitignore` 拦截。历史上曾误提交 `AI.jks` 与明文口令，已通过重写全部 Git 历史清除，**不得再次引入**。
2. **构建缓存与生成物绝不入库**：`build/`、`.dart_tool/`、`windows/flutter/ephemeral/`、`windows/flutter/generated_plugins.cmake`、`windows/flutter/generated_plugin_registrant.*`、`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`、`android/.gradle/`、`.flutter-plugins-dependencies`、`node_modules/`。历史上曾误提交 76.82 MB 的 `app.dill`，已清除。

## 六、服务器地址与打包参数（禁止再硬编码）

自建 / fork 部署时，中继服务器地址**不再散落在源码各处**，统一由单一可配置入口提供：

- **Flutter 端**：`flutter_app/lib/config/app_config.dart` 的 `AppConfig.serverBaseUrl`（`String.fromEnvironment('SERVER_BASE_URL')`）；拼接 URL 一律使用 `AppConfig.normalizedServerBaseUrl`（已去除末尾斜杠）。
- **服务端**：`server.ts` 顶部的 `SERVER_BASE_URL` 常量（可用环境变量或 `.env` 覆盖）。
- **Web 端**：`src/config.ts` 的 `getApiBaseUrl()`（`VITE_SERVER_BASE_URL` → 自适应 `window.location.origin` → 兜底默认值）。

打包时替换地址：

```powershell
flutter build apk     --release --dart-define=SERVER_BASE_URL=https://你的域名
flutter build windows --release --dart-define=SERVER_BASE_URL=https://你的域名
```

**新增代码时严禁再写死 `https://www.lx00924ai.top`**，一律走上述入口；该默认值只允许出现在 `app_config.dart`、`server.ts`、`src/config.ts` 三处。

**GitHub 仓库地址同理**（2026-10-02 收拢）：历史上 `src/components/{Hero,Navbar,Downloads,ContactFooter}.tsx`
与 `src/App.tsx` 里**写死了 7 处** `github.com/lx00924-lx/flutter-app`，fork 部署的人官网上会分发**作者的安装包**。
现在统一由两个入口提供，新代码不要再写死：

| 端 | 入口 | 覆盖方式 |
| --- | --- | --- |
| 官网 | `src/config.ts` 的 `DEFAULT_GITHUB_REPO`，导出 `GITHUB_REPO` / `GITHUB_URL` / `GITHUB_RELEASES_URL` | `.env` 的 `VITE_GITHUB_REPO="owner/repo"`（**构建期**注入，改完要 `npm run build`） |
| App | `app_settings.dart` 的 `officialGithubOwner` / `officialGithubRepo` | 打包时 `--dart-define=GITHUB_OWNER=... --dart-define=GITHUB_REPO=...` |

- `Architecture.tsx` 里展示的域名也不再写死，用 `getSiteHost()` 从 `VITE_SERVER_BASE_URL` 推导。
- App 那两个常量**随包固化**：`githubOwner` / `githubRepo` 的 setter 是**故意写空的**，
  避免云端同步把仓库改成别人的；`fromJson` 里也直接传常量而不是读缓存值。
- ⚠️ 默认值仍需保留在 `src/config.ts` 与 `app_config.dart` 里（fork 者不配置时得有合理回落）。

完整的 fork 核对清单见根 `README.md` 的 §五 —— **改到服务端 / 官网 / App / 安装器的任何一处
"写死的作者信息"时，先去看那一节还在不在理**。

## 七、换用自己的 Android 签名（fork 者指引）

仓库**不含任何密钥**。放置 `flutter_app/android/key.properties` + `flutter_app/android/app/AI.jks` 即自动切换为正式签名；缺失时 `android/app/build.gradle` 会回退到 debug 签名，**构建不会失败**。详细步骤见 `flutter_app/android/SIGNING_README.md`。

---

# ⚠️ 已知陷阱与实测教训（改动前必读）

> 全部是真实踩过的坑，附现象与判据，下次直接对照排查，不要重新试错。

## 1. 发给 Windows 用户的 `.bat` 必须 CRLF，且注意编码

- **现象**：双击启动脚本刷一屏 `'cho' 不是内部或外部命令` / `'t' 不是内部或外部命令`，随即退出。
- **根因**：`cmd.exe` 按 CRLF 定位批处理行边界，LF-only 的文件会被逐字符吃掉（`echo`→`cho`、`title`→`t`）。
  三处下发模板（中继 `/api/download/run_bridge.bat`、`/api/agent/download-bat`、App 导出的 `run_bridge.bat`）
  都是 JS/Dart 模板字符串，换行天生是 LF。
- **判据**：`CR 数 == LF 数`；不相等即 LF-only。
- **做法**：中继侧一律过 `toCrlf()`；Dart 侧模板 `.replaceAll('\n','\r\n')`；
  本机启动器改完必须跑"解析自检"（把启动行换成 `echo` 再执行，看有没有 `is not recognized`）。
- **编码**：本机控制台码页是 **936（GBK）**，所以 `.bat` 里的中文要么存 GBK、要么整份纯 ASCII；
  存 UTF-8 会在 `chcp 65001` 生效前被按 GBK 解析而报错。另外**不要写 BOM**。

## 2. 从宿主子 shell 启动的程序，会被"重启宿主"连带杀掉

- **现象**：重启宿主后桌面 App 和它拉起的桥接一起消失，中继侧 `online=False`。
- **根因**：`restart-dsh.bat` 用 `taskkill /PID <3080监听者> /T /F` 清扫整棵进程树；
  Agent 工具调用里 `Start-Process` 起来的 App 正好在那棵树里（用户双击启动的则不会）。
- **做法**：用 WMI 派生启动（`Win32_Process.Create`，父进程显示为 `WmiPrvSE.exe`），启动后复核 `ParentProcessId`。

## 3. Git 提交与推送（三个真实的坑）

### 3.1 `git add -A` 会把临时文件带进提交

- **现象**：提交信息文件、探测脚本、报告文件被一起提交（本仓库已发生两次）。
- **做法**：一律 `git add <显式路径>`；提交信息临时文件提交后立刻删除；
  写信息文件用 `[IO.File]::WriteAllText(..., New-Object Text.UTF8Encoding($false))`，避免 BOM 混进 commit subject。

### 3.2 新 clone 的仓库没有 git 身份，commit 会直接失败

- **现象**：在临时 clone 出来的仓库里提交，报
  `Author identity unknown` / `*** Please tell me who you are.`（2026-10-01 同步插件仓库时遇到）。
- **根因**：本机的 git 身份**只配在仓库级**（`F:\ai\flutter\123` 的 local config：
  `lx00924-lx` / `lx00924@gmail.com`），**全局配置是空的** —— 任何新 clone 都不继承身份。
- **判据**：`git config --global user.name` 返回空字符串。
- **做法**：从主仓库读出来应用到新 clone：

  ```powershell
  $n = (git -C F:\ai\flutter\123 config user.name).Trim()
  $e = (git -C F:\ai\flutter\123 config user.email).Trim()
  git -C <新clone路径> config user.name $n
  git -C <新clone路径> config user.email $e
  ```

- **不会丢东西**：提交失败时暂存区仍在，补完身份直接 `git commit` 即可，不必重新 `add`。

### 3.3 插件仓库 ⇄ 本地安装目录：两边的 `package.json` 必须不同

自装 DSH 插件 `dsh-app-bridge` 同时存在于两个地方，**不能整目录互相同步**：

| | GitHub `lx00924-lx/lxai-app-bridge`（发布版） | `~/.dsh/user-plugins-group/plugins/dsh-app-bridge/`（运行版） |
| :--- | :--- | :--- |
| `package.json` 的 `name` | `lxai-app-bridge` | **`dsh-app-bridge`** |
| 额外字段 | `repository` / `bugs` / `keywords` / `files` / `dsh.bundle` | 无 |

- DSH 用 `link:` 挂载插件，**依赖键名 / 目录名 / `package.json` 的 `name` 三者必须一致**。
  拿仓库版覆盖本地 → 插件**静默不加载**（选择框转发、审批、权限切换全失效，且不报错）；
  拿本地版覆盖仓库 → 丢失发布配置，别人 clone 后装不上。
- **本地运行目录才是"事实上的源码"**：2026-09-28 在本地修掉了「思维链永远为空 + 工具名恒为 `tool`」
  两个 bug，却忘了推回仓库，仓库因此停留在有问题的版本，直到 2026-10-01 才发现并补推。
- 同步流程与推送前核对清单见插件仓库的 **`SYNC.md`**（本仓库内也留副本：
  `docs/user-plugin-dsh-app-bridge/SYNC.md`）。

## 4. 单点互斥 `clientSessionId` 的语义（改登录 / 会话逻辑前必读）

服务端 `messages_data/active_sessions.json` 按「1 手机 + 1 电脑」分槽记录，判定时**严格相等**比对：

1. 登录**成功之后**才把新 id 落盘（`settings_provider.loginWithServer`）。先改本地再发请求，
   一旦请求失败（中继重启/断网）并走"离线登录"兜底，就会留下一个**服务端从没见过的新 id**，
   之后每次握手/轮询都被判"已在另一台设备登录" —— 即"每次重启 App 都弹账号已下线"的假顶号。
2. 离线登录必须**沿用旧 id**。
3. 服务端 `canTakeover` 只在「该槽位 3 分钟无活跃」时下发，这是分叉的自愈通道；
   真在用的设备槽位始终新鲜，拿不到它，所以不会两台机器互抢。
4. `lastActive` **必须落盘**（60 秒节流）：只改内存副本会让活跃槽位三分钟后被误判过期。
5. 推送通道 `/ws/app` 的 `force_logout` **必须带 `kickedSessionId`**：缺了它，客户端只能按设备类型判断，
   同类型的每个实例（含刚启动的那个）都会把自己当成被顶下线。
6. 顶号广播只发给被顶的设备类型（`session_<旧id>` + `user_<用户名>_<设备类型>`），
   **不要**发 `user_<用户名>`（会让手机也被误通知）。

## 5. 降级兜底禁止"假成功"（附覆盖用户文件前的完整性检查）

- **反例（已删除）**：App 读取内置 `assets/scripts/lxai_bridge.py` 失败时，曾降级返回一个
  148 行的"空壳脚本"——自称 v3.6、打印"正在向云端调度服务注册反向长连接通道..."，
  实际只探活一次宿主就 `while True: sleep(5)`，永远不连中继。
- **为什么危险**：`BridgeProcessManager.ensureScriptUpToDate()` 会拿这个返回值**覆盖磁盘上
  能用的脚本**，于是"资产读取失败"静默演变成"桥接进程活着、电脑端永远离线"，
  用户看不到任何指向真因的报错；导出路径也会把空壳发给用户。
- **规则**：
  1. 兜底要么明确失败（返回 null / 报错退出），要么真的可用；**不要返回"长得像在用"的替身**。
  2. 任何**覆盖用户磁盘文件**的路径，写入前必须做内容合理性检查
     （见 `BridgeScriptHelper.isPlausibleBridgeScript()`：3 处稳定特征 + 体积下限），
     读取侧与写入侧各挡一道。
  3. 调用方一律显式处理失败（提示用户"重新安装 App / 从正规渠道重新下载"），不要静默 continue。

## 6. 严禁按"命令行文本"匹配去结束进程（已发生两次）

- **现象**：用
  `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'lxai_bridge\.py' } | Stop-Process`
  结束进程，结果把**自己这条命令的执行环境**也杀了 —— 宿主派生的 subprocess runner 的命令行里
  就含有正在执行的这段命令文本，于是工具调用以
  `subprocess-local: Windows Job runner exited with exit code 4294967295` 收场，且被杀的程序
  （这里是桥接）也没被重新拉起。
- **正确做法**：
  - 杀桥接：先按进程名过滤 `Get-CimInstance Win32_Process -Filter "Name='python.exe'"`，
    再在该结果里匹配 `lxai_bridge`（runner 是 node.exe，不会命中）；
  - 杀中继/宿主：按端口拿 PID（`(Get-NetTCPConnection -LocalPort 3000 -State Listen).OwningProcess`）
    再 `Stop-Process -Id`；
  - 一句话：**不要把"要杀的特征"写成会出现在自己命令行里的字符串**。

## 7. 开源许可：改一处要同步的地方（Apache-2.0）

**许可 = Apache License 2.0**（可闭源商用，只需保留版权与许可声明、说明实质性修改；不授予商标权）。
以下位置必须保持一致，改许可或改品牌时逐一对齐：

| 位置 | 内容 |
| --- | --- |
| 仓库根 `LICENSE` / `NOTICE` | 许可正文 + 署名与商标声明（**唯一正文来源**） |
| 仓库根 `TERMS.md` / `PRIVACY.md` | 用户协议 / 隐私政策（§六 含许可摘要） |
| 官网页脚 `src/components/ContactFooter.tsx` | 许可文案 + 三个入口；TERMS/PRIVACY 经 Vite `?raw` **构建时内联**，与根目录同一份 |
| App `assets/legal/{LICENSE,NOTICE}.txt` + `pubspec.yaml` | 打进包里（Apache-2.0 §4 要求随分发提供许可副本），设置页「许可全文」按钮读取 |
| App `lib/widgets/legal_documents.dart` | terms / privacy / **license** 三个枚举，switch 必须穷尽 |
| 插件仓库 `lxai-app-bridge`（GitHub 名；**本地安装目录叫 `dsh-app-bridge`**，别混） | `LICENSE` / `NOTICE` / `package.json#license` / README 许可章节 / `lib/index.js` 头部注释 |
| `lxai_bridge.py` 头部 | SPDX + 版权（脚本会被单独下载运行） |
| App「开源许可与署名」页 | `showLicensePage` + `applicationLegalese`（本项目摘要 + 免责声明 + 第三方依赖自动汇总） |

历史坑：官网页脚曾长期写 `Released under the MIT License`（改协议时漏改，且在公网生效），
插件源码头部曾写 `AGPL-3.0-only`（与其仓库的 Apache-2.0 矛盾）。**改许可时用全仓搜索复核**：
`MIT`、`AGPL`、`Released under`（注意 `.tsx` 容易被漏掉，PowerShell 的 `-match` 默认还不区分大小写）。

## 8. 运行环境事实（只留约束与判据）

> 📖 **排查过程与历史细节见 [`docs/ENV-NOTES.md`](./docs/ENV-NOTES.md)。**
> 本节只放"必须遵守什么 / 看到什么现象说明是什么问题"。

### 8.1 三条硬约束（改代码时最容易违反）

- **桥接 Python 的解析顺序不能动**：`BridgeProcessManager._resolvePythonExecutable()` 是
  ① `{应用目录}\python\python.exe`（安装器自带的私有运行时）② PATH 里的 `python`
  ③ 报错。**不要删掉 ①**，否则内置运行时白带。排查"桥接起不来"先确认这两条路径，
  别拿开发机的 `C:\Python314` 当通用事实。
- **桥接 stdio 必须排空**：`detachedWithStdio` 启动后必须紧跟 `_drainStdio(process)`。
  Windows 匿名管道只有几 KB，而桥接启动要打印 8~10 KB 的二维码 —— 父进程不读走，
  它会**永久阻塞在 write 上**，永远连不上中继。
  判据：进程活着、CPU≈0、`bridge-run.log` 停在二维码那行、**没有任何到中继的已建立连接**。
- **桥接默认校验证书，别改回 `CERT_NONE`**：要放开只能走显式开关
  `--insecure` / `LXAI_INSECURE_TLS=1`，且启动时打警告。HTTPS 与 WS 两条链路
  必须用同一个 SSL 上下文。

### 8.2 有副本的东西（改完必须手工同步）

| 东西 | 副本位置 | 同步方式 |
| --- | --- | --- |
| `lxai_bridge.py` | 仓库根 ↔ `flutter_app/assets/scripts/` | 手工 `Copy-Item`；**无自动同步** |
| 插件 `dsh-app-bridge` | GitHub 仓库 ↔ `~/.dsh/user-plugins-group/plugins/` | 见插件仓库 `SYNC.md`；两边 `package.json` **必须不同** |
| 生产中继 `F:\ai\flutter-app` | 同仓库的老克隆 | **手工同步文件** → `npm run build` → 重启；**禁止 `git pull` / `reset --hard`** |

### 8.3 排查判据速查

- **中继重启后**桥接恢复分两段：**注册**（归属反查要读 6.6 MB 的 settings.json，
  启动期查不到 → 返回 503 可重试，而非 403）与**切回 WebSocket**（冷却 15s / 60s）。
- **桥接注册成功 → 推出第一份目录约 4 秒**，此间 `/api/agent/sessions` 是
  `online=true` + 空数组 —— 不是故障。
- **用户插件没有热重载**：改完 `lib/index.js` 必须重启宿主 web 服务。
- **桌面 App 的本地数据在 `C:\Users\lx\Documents`**（Hive），**不在安装目录**。
- **干净的 cmd 里 `node` 不在 PATH**：启动脚本用绝对路径 `C:\nvm4w\nodejs\node.exe`。
- **App 日志页**读的是 `AppLogger`；`debugPrint` 的桥接在 `main()` 里装（缺了它日志页就是空的）。
- **Windows 分发主line = 独立仓库 `lxai-setup-flutter`**（C++ + WebView2 单文件）；
  本仓 `installer/` 只剩"`runtime/python` 的存放处 + `prepare-runtime.ps1`"这个用途，
  **两者都不能删**。改 App 后要 `flutter build windows --release` + 重打素材再编安装器。
- **环境灾备**在桌面 `DSH备份-<日期>\`（含明文凭据，**别上传网盘 / 别入库**）；
  动 DSH 桌面版前先记下 CLI 版本号。

## 9. 消息与过程链路的结构事实（2026-09-28 重构后，改这条链路前必读）

> 都是"接口真相"级别的：写错一处，整条链路看起来就会"时好时坏"，而且症状离真因很远。

### 9.1 一轮 Agent 回答 = **两条消息**（过程 + 回答）

- **过程消息** id = App 预生成的 `assistantMessageId`；正文 = **宿主自己说的话**
  （`agentExecution.rawOutput`）；`agentExecution.timeline` 存**有序**过程（思考/行动/提示）。
- **回答消息** id = 中继在进入润色阶段时生成的 `answerMessageId`（`server.ts` 的
  `polishAnswerId`）；正文 = 润色结果；`isAgentMode:false`（**不挂**过程卡片）。
- 客户端按 `answerMessageId` 路由润色 chunk；`done` 事件同时带 `answerMessageId` +
  `answerContent` 兜底（断线时也能把回答补齐）。
- **关闭二次润色**（`settings.agentPolish === false`）时：不调任何模型，**只有过程消息** ——
  不要再给它补一条回答气泡。

### 9.2 DSH 事件的字段真相（插件 `pumpSse` 依赖这些）

- `assistant/message.content` 是**块数组**：`reasoning`（模型真实思考，DSH 网页端显示的那份）/
  `text`（给用户看的正文）/ `tool-call`。**绝不能** `map(b => b.text).join('')` 混成一个字符串 ——
  那正是早期"思维链永远为空 + 思考被当成正文"的根因。
- `tool/call` 帧才有工具名：`data.callId` / `data.name` / `data.arguments`（**未解析的 JSON 字符串**）。
- **`tool/result` 帧里没有工具名**。结构是：
  `data.message.content[0] = { type:'tool-result', toolCallId, content:[文本块], isError? }`、
  `data.message.source = { kind:'tool', callId }`。工具名要按 `callId` 从 `tool/call` 时记下的
  Map 里取回（读 `message.toolName`/`data.name` 会恒为 `"tool"`，输出就折不到对应行动行上）。
- 系统提示是 **in-history** 的（`request/context` 只报 `systemPromptUpdate:"in-history"`）：
  往 prompt 前面塞指令会**出现在会话正文里**，用户可见。

### 9.3 过程数据有两份来源（App 侧）

- **跑着的时候**：`ChatProvider.liveTimeline / liveSteps / liveStepDetails`
  （`message.agentExecution` 要整轮结束才由 `_composeExecution` 写上去）。
- **结束后**：`message.agentExecution.timeline`（随消息落库、上云，换机/重装后仍在）。
- **任何"看过程"的入口都必须同时看这两份**，否则会出现"跑着点进去是空的"（实测踩过）。

### 9.4 展示定位（用户定调，别再自由发挥）

- 气泡里**只留索引**：默认一行（`已深度思考 · N 步 · 用时`），展开是紧凑行列表；
- **重内容**（工具参数、工具输出）在**独立「执行详情」页**（长按消息也有入口），不在气泡里弹；
- 思维链展开**不做内层滚动**（限高 + 内滚被用户否掉）；
- 行样式照 DSH：左侧 `⌄` + `标签 · 内容` 纯文本单行，无图标、无加粗；
- 头像在气泡**上方**单独一行（气泡吃满宽度）；同一发送者连续消息只在第一条显示头像。

### 9.5 中继的硬上限（都踩过）

- `AGENT_TASK_TIMEOUT_MS` 默认 **30 分钟**（同名环境变量可覆盖）；等用户拍板时**再顺延一个完整窗口**。
  历史值是 5 分钟 —— 会把 9 分钟就能成功的任务判死，而 DSH 那边还在跑（用户看到"执行超时"却发现过程还在长）。
- 设置负载 **2 MB 硬上限**（超了 413，`server.ts` 的 `settingsPayloadGuard`）。所以图像字段必须先在客户端压进预算：
  头像 512px/128KB、聊天背景 **1920px/640KB**、启动图 **1440px/400KB**（2026-09-29 调整，原为 1440/480 与 1080/320）。
  ⚠️ **这几个数是受 2 MB 上限反推出来的**：base64 长度 = 字节数 × 4/3，四者之和 × 4/3 + 其余字段必须 < 2 MB
  （即四者之和 ≤ 约 1.5 MB）。**要调大任何一项前先重算总和**，否则整次设置推送会被 413 打回、图片再也同步不上去；
  推导过程写在 `settings_provider.dart` 的 `_mediaBudgetBytes` 注释里。
- 图像字段**内容没变就不重传**（`omitMediaOnCloudPush` + FNV-1a 指纹），且**该判断跨 App 重启依然有效** ——
  推送成功时记指纹，另外 `pullCloudSettings()` 会用云端实际返回的内容重新校准（2026-09-29 修：此前指纹是
  实例字段，冷启动后的第一次推送会把四个字段全量重传，实测 525 KB，占云端设置 99.6%）；
  启动时会把历史遗留的超大图像**就地压缩**（实测把一个 6.14 MB 的头像压到 52 KB，
  云端设置从 6.59 MB 降到 0.50 MB）。

### 9.6 中文思考 = 用户 preset（不用改代码）

- 用户 preset 目录：`<dshHome>/.agent-presets/<id>/`（复制随包 preset 即成，id 必须是新名字）；
- 语言要求写在 `agent.cordis.yml` 的 **`persona.config.prefix`**（系统提示的真正落点）；
- 默认 preset：`<dshHome>/settings.yaml` 的 `agent-presets.default`（**创建会话时**读取）；
- **只有空会话能切 preset** —— 改完要在**新会话**里才生效，老会话永远保持创建时的组装。

### 9.7 会话恢复必须以「回调执行那一刻」为准（"新建会话后输入的内容跑进旧会话"的根因）

- **症状**（用户 2026-10-01 实测）：在历史对话面板点 `+` 新建会话 → 在新会话里输入并发送 →
  消息落进了**旧会话**，界面也悄悄切回了旧会话。
- **根因**：`ChatProvider._silentSyncFromServer()` 的回调原本用「**发起同步那一刻**捕获的
  `currentSessionId`」去恢复当前会话。云端同步要跑好几秒（`pullAndMergeMessages` 里多次
  await + 反向上传），期间用户完全可能刚新建/切换会话，旧回调一到就把 `_currentSession` 顶回去。
  更致命的是 `pullAndMergeMessages` 开头是 `if (cleanUserId.isEmpty || _isSyncing) return 0;` ——
  **新建会话那一次同步会被直接吞掉、回调根本不会注册**，于是没有任何后续同步来纠正，
  界面就永久停在旧会话上（直到用户下一次操作触发同步）。
- **修法**：回调里改读**执行此刻**的 `_currentSession`，并对「本地新建、尚未上云
  （`isSynced == false`）」的会话加保护 —— `saveSession` 是异步的，这一刻它可能还没落盘，
  不能拿「列表里没有 → 退回第一个」的兜底把它顶掉。`loadSessions()` 里同一形状的兜底照此办理。
- **判据**：这类 bug 的共同形状是「**用旧快照覆盖新状态**」＋「**失败被静默吞掉**」。
  写任何异步回调前先问一句：这个闭包捕获的值，在回调真正跑起来的时候还成立吗？

### 9.8 图片消息链路（App → 中继 → 桥接 → 插件 → DSH）

四段各司其职，**任何一段缺失都表现为"图发了但模型没看到"**。2026-10-03 全链路打通并实测。

- **载荷形状**：App `toDshImagePart()` 产出 `{data, mediaType, name?}` —— 与宿主
  `@deepseek-ai/dsh-attachment` 的 `EncodedImageAttachment` **逐字段一致**。
  `data` 必须是**裸的规范 base64**（无 `data:` 前缀）；宿主会解码后重新编码逐字节比对，
  不一致就 `INVALID_IMAGE_BASE64`。所以**中间任何一段都只准搬运、不准重新编码**。
  只放行 png/jpeg/webp（宿主声明支持的三种）。
- **图片只走 HTTP body 的两个位置**：桥接 SSE 的 `payload["images"]` 与同步端点的
  `prompt_payload["images"]`。
  ⚠️ **绝不能往 `content_list` 塞图片块** —— 那是「原生 WebSocket RPC 通道」的 payload，
  只认纯文本块；它位于候选循环**之前、最先尝试**，一挂就整轮降级，把正常的文字消息与
  预设切换一起牵连（2026-10-01 为此整体回退过图片功能）。
- ⚠️ **插件不要自己调 `ctx.attachments.admitPromptContent()`**。`sessions().prompt()`
  内部的 admit 路径**本来就会受理**（`dsh-api-session-controller` 的 `admit()`）。
  先受理一次的话，传下去的是 `{type:'image', attachment:{...}}`，宿主再受理时读不到
  `data`，而 `Buffer.from(undefined,'base64')` 抛的是**普通 TypeError、不是
  `AttachmentError`**，于是被兜底成一句毫无信息量的 `"prompt rejected"`
  （错误码还是 `session/agent-busy`），排查时完全看不出跟图片有关。
  **正确做法：把未受理的编码块原样交给宿主。**
- **桥接必须挑明插件的错误**：插件在 `startTurn` 抛错时返回的是
  **HTTP 200 + `{status:'error', error:{code,message,where}}`** —— 既不是 SSE 也没有
  错误码。桥接曾经只找正文、找不到就放弃，于是唯一的线索被丢掉，用户只看到兜底的
  "HTTP 404"。见 `extract_plugin_error()`。
- **诊断手法**（这次就是靠它定位的）：拿安装目录的私有 Python 直接调端点做对照实验 ——
  `dsh_headers()` 可以复用桥接自己的签名逻辑。同一提示词**不带图 200 / 带一张 1×1 PNG
  就失败**，一步就把范围从"整条链路"缩到"图片专属分支"。比反复在 App 里试点快得多。
- **手机端要单独重打 APK**：`LxAI-1.0.1.apk`（09-29 上传）比发图代码（10-01）还早，
  那份 App **根本没有发图功能**。

## 10. PowerShell 脚本必须带 UTF-8 BOM（本机只有 PS 5.1）

- **现象**：脚本在别处直接语法报错，错误信息里夹着乱码 ——
  `Unexpected token '缂栬瘧'`、`Missing closing '}' in statement block or type definition.`。
- **根因**：本机 PATH 里**没有 `pwsh`**（只有 Windows PowerShell **5.1**，`$PSVersionTable.PSEdition` = `Desktop`），
  而 5.1 读取**无 BOM 的 UTF-8** 脚本时按系统 ANSI（**936 / GBK**）解码 —— 中文注释与字符串被解成乱码字节，
  直接破坏语法（实测：`build-installer.ps1` 报 1 个错、`prepare-runtime.ps1` 报 6 个）。
- **判据**：文件前 3 字节是否为 `EF BB BF`；不是就必须加。
- **做法**（先按无 BOM 正确读出，再带 BOM 写回）：
  `$t = [IO.File]::ReadAllText($p, (New-Object Text.UTF8Encoding($false)))`；
  `[IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))`。
- **写完必须用 5.1 的解析器复验**（别等运行时才发现）：
  `$errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)`，
  然后检查 `$errs` 是否为空。
- 含非 ASCII 的 **`.iss`（Inno Setup）同理**，也要求带 BOM。
- 与 **§1**（`.bat` 必须 CRLF + 注意编码）属同一类问题：**给 Windows 的脚本，编码与换行都要显式处理**，
  不能依赖「在我机器上能跑」。

## 11. 品牌图标只有一个来源：`tools/make_icons.py`

- **历史问题**（2026-10-01 修）：App 自 2026-09-18 起的图标是一张**第三方动漫插画** ——
  `flutter_app/assets/icon/app_icon.png`、`flutter_app/windows/runner/resources/app_icon.ico`、
  Android mipmap 全套都是它；而安装向导（`installer/assets/wizard-*.png`）用的却是另一套自己画的标识。
  既有版权/商标风险，两处观感也不一致。
- **现在**：`python tools/make_icons.py` 用几何图形（深藏青圆角方块 + 两个浅色节点 +
  天蓝链路 + 琥珀色「中继」节点）**代码重绘**全套图标，一次写出 22 个文件（约 420 KB）。
  只用 numpy + 标准库 —— ⚠️ 本机**没有 Pillow、没有 ImageMagick**，别再往那两个方向试。

  | 目标 | 文件 |
  | --- | --- |
  | 源图 / 自适应前景 | `flutter_app/assets/icon/app_icon.png`、`app_icon_foreground.png`（1024²） |
  | Android | `mipmap-{m,h,xh,xxh,xxxh}dpi/` 下的 `ic_launcher.png`、`ic_launcher_round.png`、`ic_launcher_foreground.png` |
  | Windows 程序图标 | `flutter_app/windows/runner/resources/app_icon.ico`（16/24/32/48/64/128/256 七档） |
  | Windows 托盘 4 态 | `flutter_app/assets/icons/tray/tray_{idle,message,question,offline}.ico`（只换中继节点颜色） |
  | 安装向导 | `installer/assets/wizard-{large,small}.png`（此前已换，不由本脚本接管） |

- **改图标 = 改脚本里的设计参数再跑一遍**，不要手工贴图。
- ⚠️ **顺手补齐的缺口**：`AndroidManifest.xml` 同时引用 `@mipmap/ic_launcher_round`，
  但各密度目录里**从来没有** `ic_launcher_round.png`（只有 `mipmap-anydpi-v26/` 的 xml，
  即 API 26+ 才有）—— 现已随生成脚本补齐。
- ⚠️ **不要跑 `flutter_launcher_icons`**：`pubspec.yaml` 里它配的 android 名称是 `"launcher_icon"`，
  而 manifest 引用的是 `@mipmap/ic_launcher` —— 跑它只会生成一个**没人引用**的 `launcher_icon.png`，
  真正生效的图标纹丝不动（这正是"换了图标却没生效"的坑）；而且它用不透明图覆盖
  `ic_launcher_foreground.png`，会把自适应图标弄坏。
- ⚠️ **Windows 有图标缓存**：覆盖 exe 后任务栏/开始菜单可能仍显示旧图标，
  必要时 `ie4uinit.exe -show` 或重建图标缓存，别误判成"没替换成功"。

## 12. 接口安全的既有约定（改接口 / 加接口前必读）

> 完整审计记录（当时哪里有缺口、怎么验证、踩过什么坑）在
> [`docs/SECURITY-AUDIT.md`](./docs/SECURITY-AUDIT.md) —— ⚠️ **那份是内部参考，不要对外发布**。
> 本节只列**必须遵守的约定**，不写历史细节，也不列"已加固接口清单"。

### 12.1 身份与授权

- **身份一律走 `verifyUserIdentity()`**：认 `x-client-session-id`（登录时服务端签发、写进
  `messages_data/active_sessions.json` 槽位的 UUID v4），**不要**把 URL/body 里的 `userId`
  当身份 —— 它是公开可猜的（本项目就是顺序数字 / 手机号）。
  新加接口时先问一句：「**不传任何凭据时它返回什么？**」
- **列表类接口必须强制按 `userId` 过滤，且失败方向是拒绝**：
  写成 `if (item.userId !== userId) return false`，**不要**写成「参数为空就不过滤」——
  那等于把所有人的数据一次性给出去（这个写法本项目踩过一次）。
- **守卫失败一律回 403**，不要用 401：客户端只在 `401 + FORCE_LOGOUT` 时才走顶号流程，
  用 403 不会把"被拦截"误报成"账号在别处登录"。
- **校验不要做内存缓存**：被顶下线的旧凭证必须立刻失效，每次读盘（文件只有几百字节）。

### 12.2 「凭证失效」的表述（改服务端必读）

- 只能是 **`401 + error:"FORCE_LOGOUT"`**，形状与顶号一致（带 `kickedSessionId`、
  `canTakeover:false`）。**别新造错误码**：客户端的掉线判定只认这一个，换个码它整条忽略，
  于是 App 看着一切正常、其实每个请求都被守卫拦着，**云端同步静默失效**（实测过）。
- 另有两个出口必须一起管：`/api/check-session` 在**槽位完全不存在**时不能落到 `{valid:true}`；
  `/ws/app` 握手不能对空槽位直接放行（要 `send` 完 `force_logout` 再 `close(4002)`）。

### 12.3 限流与真实 IP

- **取真实 IP 用 `cf-connecting-ip`**：生产走 Cloudflare Tunnel，`socket.remoteAddress`
  恒为 127.0.0.1 —— 按它限流等于全局限流，会把所有用户一起锁掉。
- 登录失败计数按「用户名 + IP」双维度，且**首次失败立即落盘**（否则每次尝试后重启中继就能清零）。
  限流判定要放在读用户表 / 跑 bcrypt **之前**。

### 12.4 不要信任请求头

- `Host` / `X-Forwarded-Host` / `X-Forwarded-Proto` 都由请求方控制。这类值可能被写进 `.bat`
  （**命令注入**）或被当作请求目标（**SSRF**）。
- 服务自身的对外地址一律取 `SERVER_BASE_URL`；确实要让用户自定义的地址，过 `safeScriptUrl()`
  （只允许 http/https，且禁掉引号/反斜杠/空白）。
- **服务端主动发起的请求要过 `ssrfViolation()`，并且不要跟随重定向**；只放行 http/https，
  内网 / 回环 / 链路本地 / CGNAT 一律拒；私有地址只能用 `ASR_ALLOWED_HOSTS` 显式声明，
  **不预设任何内网例外**。

### 12.5 其它

- 引入新依赖前先确认它在 `node_modules` 里（服务端用 `--packages=external` 打包，运行时从本地解析）。
- 生产 `F:\ai\flutter-app` 与仓库的同步方式见 §8.2；那份是**运行副本**，改完要重编再重启。
