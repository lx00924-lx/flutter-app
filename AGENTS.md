# 核心架构与安全准则 (Critical Project Constraints)

## 1. 核心架构认知
- 本项目是【LxAI 官网介绍与下载门户 (Web) + Flutter 纯原生多端 App 客户端 (`flutter_app/`) + 本地 Agent 反向长连接内网穿透 (`lxai_bridge.py`)】的三位一体架构。
- **架构精简与原生化**：已彻底剥离早期 Capacitor/WebView 混合套壳依赖（`package.json` 中的 Capacitor/Ionic 依赖、`public/lxai_bridge.py` 旧副本与 `/api/agent/download-bridge` 旧控制台接口均已清除），移动与桌面端全面采用纯原生 Flutter 架构；Web 端（`src/`）现为**对外官网介绍与下载门户**，不再承担中继监控看板职能。
- **公网生产中继服务**：默认生产服务器域名为 **`https://www.lx00924ai.top`**，手机端扫码与电脑端 Bridge 均默认指向该地址。
- **核心业务功能**：手机/电脑客户端通过云端中继远程遥控内网电脑（无公网 IP）上的私有 Agent（Harness / 本地模型 / 本地自动化工作区），支持单点登录设备互斥、消息增量漫游与全局设置云端同步。

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

## 8. 运行环境事实（排查时容易找错地方）

- **推 GitHub 要走 Clash 的混合端口，不能靠直连**（2026-10-02 实测）：
  本机 `github.com:443` **直连不通**（`Test-NetConnection github.com -Port 443` = False），
  而 **git 不读 Windows 的"系统代理"设置**（`HKCU\...\Internet Settings` 里那个 7890 只对 WinINET 程序生效），
  所以不带参数直接 `git push` 会报 `Failed to connect to github.com port 443`。
  正确姿势是**显式指定代理**（一次性 `-c`，不改仓库配置）：

  ```powershell
  git -c http.proxy=http://127.0.0.1:7890 -c https.proxy=http://127.0.0.1:7890 push
  ```

  端口取自 `~/.config/clash/config.yaml` 的 **`mixed-port`**（当前 7890；换配置会变，
  以 `Get-NetTCPConnection -LocalPort 7890 -State Listen` 为准）。
  - 代理**没起来**时的现象是 `Empty reply from server` / `Recv failure: Connection was reset` /
    `Failed to connect ... port 443`，**看起来像 GitHub 挂了，其实是本地代理断了**。
  - 判据：**Clash 的 UI 进程活着不代表核心在跑** —— 实测出现过「4 个 `Clash for Windows` 进程都在、
    但 7890 没有任何监听」，此时代理实际是断的。先确认端口有没有在监听，再怀疑网络。
  - `web_fetch` 走的是同一条链路，代理断了它也会一起失败。
  - 局域网内的其它目标（如 `F:\ai\flutter-app` 与 `F:\ai\flutter\123` 之间互 fetch）不受影响，代理断了也能用。

- 桌面 App 的本地数据在 **`C:\Users\lx\Documents`**（Hive：`settings_box.hive` / `sessions_box.hive` / `messages_box.hive`），
  **不在安装目录**；清缓存或换机会丢登录态与本地会话。
- 中继按 `NODE_ENV` 决定官网前端走 Vite 开发中间件还是 `dist/` 静态文件；`start-relay.bat` 已设 `NODE_ENV=production`，
  改完前端要 `npm run build`（`vite build` 出 `dist/`，`esbuild` 出 `dist/server.cjs`）。
- 干净的 cmd 环境里 `node` **不在 PATH** 上：启动脚本用绝对路径 `C:\nvm4w\nodejs\node.exe`。
- **桥接用哪个 Python**（2026-09-29 起，别再用旧结论排查）：`BridgeProcessManager._resolvePythonExecutable()`
  的顺序是 ① `{应用目录}\python\python.exe`（**安装器自带的私有运行时**，装了安装版就走这个）
  ② PATH 里的 `python`（开发机直跑构建产物 / 免安装绿色版）③ 都没有才报错。
  所以「桥接用 `C:\Python314\python.exe`」**只是开发机的情形，不是通用事实** ——
  排查「桥接起不来」时先确认这两条路径；改 Python 相关逻辑时**不要**删掉 ①，否则内置运行时白带。
- **桥接的退出语义**（2026-09-30 调整，别再改回去）：托盘菜单现在有两个退出项 ——
  「退出 LxAI（桥接保持在线）」与「退出 LxAI 并停止桥接」（`exitApp(stopBridge:)`，默认停）。
  桥接是 `detachedWithStdio` 启动的，**不主动 kill 就会变成看不见的孤儿进程** —— 用户以为退干净了，
  实际它还在后台连着中继（这正是用户报「退出应用后手机反而能连上」的原因）。
  历史上曾是"退出不带走桥接"（为减少反复测试时等它重新注册的麻烦），但那个需求现在由
  **「点 X = 收进托盘」**满足（App 与桥接都继续跑），所以"退出"可以放心做成完全退出。
- **桥接的 stdio 必须排空，否则永久卡死**（2026-09-30 修；这是「App 拉起的桥接从来不上线」的真因）：
  `BridgeProcessManager.start()` 用 `ProcessStartMode.detachedWithStdio` 起桥接，**必须紧跟 `_drainStdio(process)`**。
  Windows 匿名管道的内核缓冲区只有几 KB，而桥接启动时要打印品牌横幅 + 终端二维码
  （`print_terminal_qr` 一屏 35~41 行 ANSI，实测约 8~10 KB）—— 父进程不读走，缓冲区写满后桥接的
  下一个 `print()` 就**永久阻塞在 write 上**，永远走不到后面的 `websockets.connect`。
  - 症状极具迷惑性：**进程活着、CPU≈0、`bridge-run.log` 停在二维码那一行、零外网 TCP 连接**，
    中继侧显示「从未上线」—— 极易误判成网络不通 / Token 失效 / 中继故障。
  - 判据：`Get-NetTCPConnection -OwningProcess <桥接PID>` 中**没有到中继 443 的 Established**；
    且 `bridge-run.log` 里最后一次 `[✓ 成功上线]` 之后的所有启动都缺这一行。
  - 实测对照（同一条命令行 / 同一个 token / 同一台中继）：App 拉起的 3 次全部卡死；
    改用带真实控制台的 `Start-Process` 启动则 **2 秒上线**，并同步出 20 个会话。
  - **排查手法**：别只在 App 里反复试，直接用 `{app}\python\python.exe` 按同样参数手动跑一遍做对照 ——
    能上线就说明网络与 Token 都没问题，问题在本地进程/管道侧。
- **桥接默认校验证书，别再改回 CERT_NONE**（2026-10-02 修）：
  `create_resilient_ssl_context()` 原本**无条件**返回 `check_hostname=False` + `verify_mode=CERT_NONE` 的上下文，
  等于对中继的**所有** HTTPS 请求都不验证书；而 WebSocket 链路（`websockets.connect` 没传 `ssl=`）
  走的是库默认值**会**校验 —— 两条链路行为还不一致。中间人（恶意 Wi-Fi / 被劫持的代理 / 装了根证书的抓包工具）
  可以冒充中继，拿到的是**配对 Token**，也就是能直接驱动用户电脑上的 Agent。
  - 现在：`create_ssl_context(insecure=False)` 默认 `ssl.create_default_context()`（校验证书 + 主机名）；
    需要放开的环境走**显式**开关 `--insecure` / `LXAI_INSECURE_TLS=1`，并在启动时打印醒目警告。
  - WS 路径现在也把同一个上下文传进 `websockets.connect(ssl=...)`，两条链路语义统一。
  - 证书失败**不走静默降级**：`is_cert_error()` 把它和"代理不通/DNS 失败"区分开，措辞不同，
    最终失败时 `print_cert_error_help()` 打出可操作说明。允许"绕开代理直连"再试一次
    （代理做 MITM 时直连确实可能正常），但**不会**自动降级成不校验。
  - 实测：系统 Python 3.14 与 App 私有运行时 Python 3.13 都能通过 `create_default_context()`
    验证 `https://www.lx00924ai.top` 的证书（`/api/health` 返回 200），所以打开校验**不影响本项目的部署**。
  - ⚠️ App 拉起的桥接不传 `--insecure`，要走这条通道得设系统环境变量。
- **桥接脚本有两份副本，改完必须同步**：仓库根 `lxai_bridge.py` 与
  `flutter_app/assets/scripts/lxai_bridge.py`（App 分发给用户/导出 bat 用的是后者），
  **没有自动同步机制**，靠手工 `Copy-Item`。两份当前逐字节相同，用 SHA256 核对。
- **桥接脚本的下载路径只保留新名**（2026-10-01）：`server.ts` 原先同时挂了三个旧别名做兼容 ——
  `/deepseek_bridge.py`、`/api/download/deepseek_bridge.py`、`/api/download/bridge.py`。
  确认旧版 App 与历史教程都不再请求后**已全部下线**，现在只剩 `/lxai_bridge.py` 与
  `/api/download/lxai_bridge.py`（App 侧 `bridge_script_helper.dart` 用的就是后者）。
  - 要恢复兼容前先查清外部还有谁在请求（全仓搜旧名 + 确认还有没有老客户端在用）；
    **别只因为"可能有人用"就加回来** —— 那等于继续对外分发带第三方商标的文件名。
  - `__pycache__` 里可能残留旧名的 `.pyc`（`deepseek_bridge.cpython-*.pyc`）：
    `.gitignore` 已忽略，但本地清理别漏 —— 脚本改名后旧缓存不会被自动覆盖。
- **App 内日志页此前几乎是空的**（2026-09-30 修）：`main()` 里把全局 `debugPrint` 桥接进了
  `AppLogger`。在此之前两者**互不相通** —— App 的诊断输出全是 `debugPrint`（只写 stdout，
  双击启动的桌面应用没有控制台，输出直接丢掉），而设置页「调试日志」读的是 `AppLogger`，
  全项目只有日志页自己在写它。所以用户报"抓不到日志"时，先确认这个桥接在不在，别去找日志文件。
- **Windows 分发走安装器**（2026-09-29 新增，位于 `installer/`）：
  - 一键构建 `pwsh -File installer/build-installer.ps1`（先校验 Flutter Release 产物，版本号自动读 `pubspec.yaml`）；
    产物在 `installer\output\LxAI-Setup-<版本>.exe`（约 22 MB）。
  - **捆绑私有 Python 运行时**到 `{app}\python`（Python 3.13 embeddable + websockets），
    所以用户**不需要自己装 Python**；依赖只落在该私有目录，**不进用户的全局环境**。
  - 安装目录由向导让用户选（默认 `{autopf}\LxAI`），并可切换「为所有用户 / 仅为我」（后者免管理员、不弹 UAC）。
  - ⚠️ `.iss` 里的 **`AppId` GUID 永远不要改**：卸载程序靠它识别同一个应用，改了会在控制面板留下删不掉的旧版本。
  - 卸载**刻意保留用户数据**（`Documents` 里的 Hive），只清安装目录里运行时生成的文件。
  - ⚠️ **改了 App 代码后必须重新 `flutter build windows --release` 再编译安装器** ——
    安装器打包的是 Release 目录的产物，曾出现「源码比 app.so 新」导致装出来的 App 不含最新改动。
  - 仓库只入库脚本 + `.iss` + 语言包（合计约 40 KB）；`cache/` `runtime/` `output/` 已在 `.gitignore`，
    clone 后跑一次构建脚本即可重建。细节与注意事项见 `installer/README.md`。
- 生产中继目录 `F:\ai\flutter-app` **是同仓库的一份老旧克隆，但日常只能手工同步**（2026-09-29 核实）：
  - 它确实是 `https://github.com/lx00924-lx/flutter-app` 的 clone，但 **HEAD 停在 `3e3f2a5`（2026-09-20），落后远端 19 个提交**，
    而且有 **27 处本地改动/删除** —— 就是这一路手工覆盖上去的 `server.ts`、`docs/`、`AGENTS.md`、`package.json` 等；
  - 所以改完仓库要**手工同步文件**（`server.ts` / `lxai_bridge.py` / `docs/`）→ `npm run build` → 重启中继；
  - ⚠️ **绝不要在那里 `git pull` / `reset --hard` / `checkout -f`**：会把手工同步的（更新的）内容回退到 9-20 的老版本，
    而生产跑的正是这份目录（`dist/server.cjs` + 老 `server.ts` 曾长期不一致也会混淆排查）；
  - 它的 `messages_data/`（消息/设置/会话数据）在 `.gitignore` 里，git 操作不会动它，但也不要挪动。
  - ⚠️ 别和**打包目录** `F:\ai\flutter\flutter-app` 搞混（不同目录，一个 `flutter-app`、一个 `flutter\flutter-app`）。
- 用户插件**没有热重载**：`lib/index.js` 改完必须重启宿主 web 服务才生效（`dsh plugin` 子命令只管安装）。
- 桥接「注册成功 → 推出第一份目录」约 **4 秒**（40 余次重启实测）。这期间 `/api/agent/sessions`
  的 `online=true` 但 `workspaces/sessions/models` 全是空数组 —— 用户此时点刷新会看到
  "在线但没取到目录"。App 侧已按此自动重试两次并给"正在同步"提示，排查时不要误判成宿主忙。
- 中继重启后桥接恢复分两段：**注册**（归属反查要读 6.6MB 的 settings.json，启动期查不到 →
  现在返回 503 可重试，而非 403 token 失效）与**切回 WebSocket**（临时失败冷却 15 秒、其它失败 60 秒）。
- **环境灾备**（2026-10-01 建立）：桌面 `C:\Users\lx\Desktop\DSH备份-<日期>\` 存放 DSH 环境快照，
  目的是**即使 DSH 桌面预览版把现有 web 版环境改坏且不可逆，LxAI 项目也能照它恢复**。三部分：
  - `.dsh\` —— DSH 全部数据（`sessions/` 会话与聊天记录、`settings.yaml`、`user-plugins-group/` 自写插件源码等）。
  - `LxAI-App数据\` —— `Documents` 下的 Hive（`messages_box` / `sessions_box` / `settings_box`），
    即 **LxAI App 自己的聊天记录与设置**，换机或清缓存靠它恢复。
  - `DSH环境快照.md` —— DSH CLI 版本（`0.1.5-rc.2` → `npm i -g @deepseek-ai/dsh@0.1.5-rc.2`）、
    关键路径、插件清单、恢复顺序与验证命令。
  - ⚠️ **备份含明文凭据**（`.dsh/.credentials.yaml`）与 App 聊天数据，**不要上传网盘、不要分享、不要入库**。
  - ⚠️ DSH CLI 安装体（`C:\nvm4w\nodejs\node_modules\@deepseek-ai\dsh`，223 MB / 2.5 万文件）**刻意不备份**，
    照快照里的版本号重装即可 —— 所以**动桌面版之前必须先记下当前 CLI 版本号**。
  - ⚠️ 备份是**时间点快照**：`sessions/` 会随对话持续增长，重要操作前重新跑一次
    （`robocopy <源> <目标> /E /XJ /R:1 /W:1`，**绝不加 `/MIR`** —— 见上文 §四 关于 junction 的警告）。

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

