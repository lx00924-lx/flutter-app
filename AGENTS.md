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

## 3. `git add -A` 会把临时文件带进提交

- **现象**：提交信息文件、探测脚本、报告文件被一起提交（本仓库已发生两次）。
- **做法**：一律 `git add <显式路径>`；提交信息临时文件提交后立刻删除；
  写信息文件用 `[IO.File]::WriteAllText(..., New-Object Text.UTF8Encoding($false))`，避免 BOM 混进 commit subject。

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
| 插件仓库 `lxai-app-bridge` | `LICENSE` / `NOTICE` / `package.json#license` / README 许可章节 / `lib/index.js` 头部注释 |
| `lxai_bridge.py` 头部 | SPDX + 版权（脚本会被单独下载运行） |
| App「开源许可与署名」页 | `showLicensePage` + `applicationLegalese`（本项目摘要 + 免责声明 + 第三方依赖自动汇总） |

历史坑：官网页脚曾长期写 `Released under the MIT License`（改协议时漏改，且在公网生效），
插件源码头部曾写 `AGPL-3.0-only`（与其仓库的 Apache-2.0 矛盾）。**改许可时用全仓搜索复核**：
`MIT`、`AGPL`、`Released under`（注意 `.tsx` 容易被漏掉，PowerShell 的 `-match` 默认还不区分大小写）。

## 8. 运行环境事实（排查时容易找错地方）

- 桌面 App 的本地数据在 **`C:\Users\lx\Documents`**（Hive：`settings_box.hive` / `sessions_box.hive` / `messages_box.hive`），
  **不在安装目录**；清缓存或换机会丢登录态与本地会话。
- 中继按 `NODE_ENV` 决定官网前端走 Vite 开发中间件还是 `dist/` 静态文件；`start-relay.bat` 已设 `NODE_ENV=production`，
  改完前端要 `npm run build`（`vite build` 出 `dist/`，`esbuild` 出 `dist/server.cjs`）。
- 干净的 cmd 环境里 `node` **不在 PATH** 上：启动脚本用绝对路径 `C:\nvm4w\nodejs\node.exe`；桥接用 `C:\Python314\python.exe`。
- 生产中继目录 `F:\ai\flutter-app` **不是 Git 仓库**，源码靠手工同步：
  改完仓库要同步 `server.ts` / `lxai_bridge.py` / `docs/`，再 `npm run build` 并重启中继。
- 用户插件**没有热重载**：`lib/index.js` 改完必须重启宿主 web 服务才生效（`dsh plugin` 子命令只管安装）。
- 桥接「注册成功 → 推出第一份目录」约 **4 秒**（40 余次重启实测）。这期间 `/api/agent/sessions`
  的 `online=true` 但 `workspaces/sessions/models` 全是空数组 —— 用户此时点刷新会看到
  "在线但没取到目录"。App 侧已按此自动重试两次并给"正在同步"提示，排查时不要误判成宿主忙。
- 中继重启后桥接恢复分两段：**注册**（归属反查要读 6.6MB 的 settings.json，启动期查不到 →
  现在返回 503 可重试，而非 403 token 失效）与**切回 WebSocket**（临时失败冷却 15 秒、其它失败 60 秒）。

