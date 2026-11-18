# 待办事项（Backlog）

> 这里放**已确认要做、但还没做**的改动。用户口头交代"先记一下、下次再做"的条目也记在这。
> 做完一条就把对应小节删掉（别留"已完成"的历史 —— 那属于 git log 的职责）。

---

**当前有 1 条待办**（第 1 条，用户 2026-10-14 报的「回复推不到 App」，确认要修但先不动）。
下面三条是**已完结或"以后再做"**的规划项，留在这里只为备查：
第 2 条是将来才启动的 Linux 适配，第 3 条是安装器的收尾记录（提权那条代码已写完，已决定不单独实测），
第 4 条是 M5 的评估结论（**已决定先不做**）。

---

## 1. 回复推不到 App（用户 2026-10-14 报，先记不改）

**要什么**：一轮里只要出现过工具调用，**最后产出的回复要能可靠送到 App**。现在它会静默丢掉，
而且 App 上看不出"丢了"——只看到角色没说话。

**为什么**：用户 2026-10-14 一上午撞了三次，原话是「又发送失败了，先记一下吧，以后修」。
代价最大的一次是 10-13 21:51 那条打包含令：中继把它判成"等待用户处理"、超时顺延 30 分钟后
`[Agent Execution Failed]: 本地 Agent 执行超时`，用户在浏览器里盯着以为角色没收到，最后在手机上打断重发。

**已确认的事实**（别再重新查一遍）：

- **回复是产出过的**：中继日志里那轮末尾有
  `[Server Background Gen] 跳过二次润色：用户已关闭该功能（直接用电脑端输出）`
  —— 模型输出已经拿到，丢在**推送**那一段。
- **下拉刷新救不回来**：用户实测过，App 的增量补拉不带这类消息。所以它不是"补拉"能修的，
  只能从发送端修（这条推翻过一次"刷新一下就好"的建议，别再提）。
- **桥接的中继连接每 ~23 秒断一次重连**（`bridge-run.log`，形态固定）：
  `[↻ 恢复] → [WS 握手受阻 WinError 64] → [✗ 注册被拒] HTTP 403 → [✓ 监听中]`。
  可疑点在「中继 → 桥接」这一跳：中继把结果塞进 `pendingPollResolvers` / `queuedTasks`
  （`server.ts` 里 `/api/agent/answer-question` 和任务派发两处同构），
  **若正好塞在桥接重连的窗口里，payload 可能落进一个马上被替换掉的对象**。⚠️ **这条尚未证死。**

**怎么做 / 注意事项**：

- 先把**三个**症状分清（现在混在一起）：① 回复丢 ② 选择框答复到不了宿主 ③ 僵尸待办拖死任务。
  ②③ 已能定性 —— **待办的生命周期没跟宿主同步**（宿主被重启打断、没机会发 resolved，
  中继就留着 24 小时，`server.ts` 的 `pendingQuestions` 与 `QUESTION_TTL_MS`）。
  **① 还没定位**，是这次的真正目标。
- ⚠️ **别用"再加一层重试"糊过去**：这三条都是"状态没同步"的形状（旧任务/旧快照盖住新状态），
  重试只会把重复消息一起带进来。
- 复现入口：App 发一条会让角色调工具的消息，然后对照 `server-run.log` 的 `跳过二次润色`
  与手机上是否出现回复。

## 2. Linux 桌面适配（以后再计划）

**要什么**：让 App 能在 Linux 桌面跑起来（`flutter build linux`），并产出 `.deb` / AppImage。

**为什么现在不做**：安装器选型（见下）已确定**只管 Windows**，Linux 那边不需要"安装向
导"这种东西，所以不阻塞当前开发。等 Linux 真成为目标再启动。

**先说结论，免得下次走弯路**：

- **Linux 不需要"再开发一个安装器"**。那边没有"下一步、下一步"的向导文化，用户通过
  包管理器装。对应物是**打安装包**，不是写安装程序：

  | 格式 | 怎么产出 | 要写 UI 吗 | 用户怎么装 |
  | :--- | :--- | :---: | :--- |
  | `.deb`（Debian/Ubuntu） | `dpkg-deb --build` 或 `fpm`，一条命令 | ✗ | `apt install ./x.deb` 或软件中心双击 |
  | `.rpm`（Fedora/RHEL） | `rpmbuild` 或 `fpm` | ✗ | `dnf install ./x.rpm` |
  | **AppImage** | `linuxdeploy` + `appimagetool` | ✗ | **双击直接运行，不用安装** |

- **AppImage 天然满足"单文件"**，而且比 Windows 更彻底（不是"一个文件安装"，是"一个文件直接跑"）。
- ⚠️ **Linux 包必须在 Linux 上构建**（`dpkg-deb` 是 Debian 的工具，Windows 上产不出）。
  推荐放 **GitHub Actions 的 ubuntu runner**，tag 一推自动出 `.deb` + AppImage，本机不用装 Linux 环境。
- ⚠️ WebView2 是 Windows 独有的；Linux 上渲染 HTML 的等价物是 **WebKitGTK**（Tauri 在 Linux
  就是这么做的）。但既然 Linux 不需要自定义向导，这条基本不会用到。

**真正的工作量在"App 根本没移植过 Linux"**（2026-10-04 实测，非推测）：

```
flutter_app/linux/ 平台目录   ✘ 不存在（从未为 Linux 构建过）
Platform.isWindows           27 处
Platform.isAndroid           29 处
Platform.isLinux             15 处   ← 当初留过口子，但没成体系
```

插件支持逐个核过 `pubspec.yaml` 的平台声明，**大部分没问题**：

| ✅ 声明了 Linux | ❌ 没有 Linux 实现 |
| :--- | :--- |
| `window_manager`、`flutter_local_notifications`、`record`、`audioplayers`、`image_picker`、`file_picker`、`path_provider`、`shared_preferences` | **`flutter_tts`** → 朗读功能要另找方案<br>**`mobile_scanner`** → 扫码配对要另想办法（或 Linux 上只支持手输 Token） |

- ⚠️ `tray_manager 0.7` 只是个**兼容壳**（底层已换成 nativeapi 那套，见
  `lib/services/tray_service.dart` 顶部注释），它的 Linux 托盘支持**要单独确认**。
  不过 App 里 `TrayService.supported` 现在写死 `Platform.isWindows`，本来也要补分支。
- 要重写的 Windows 专属逻辑：**托盘、开机自启（注册表 `HKCU\...\Run` →
  `~/.config/autostart/*.desktop`）、桥接进程管理**。

**好消息**：后端天然跨平台 —— 中继是 Node、桥接是 `lxai_bridge.py`（Python），**一行都不用改**。

**建议的顺序**（打包是整条链里最省事的一步，别和"移植 App"混在一起估工作量）：

1. **App 移植**：`flutter create --platforms=linux .` 生成平台目录 → 补上面那些平台分支 →
   解决 `flutter_tts` / `mobile_scanner` 两个缺口；
2. **打包**：`.deb` + AppImage，几十行脚本，放 CI 跑；
3. **自定义 UI 的安装向导只做 Windows**，Linux 走包管理器那套标准流程。

## 3. Windows 安装器：已完结，只剩一条未实测

主仓库的 `installer/` 是**旧的 Inno Setup 版**，已不再迭代；自研安装器在**独立仓库**
`F:\ai\flutter\lxai-setup-flutter`（GitHub `lx00924-lx/lxai-setup-flutter`），
**D 方案（C++ 安装逻辑 + WebView2 渲染 HTML/CSS 界面）已实现并发布** ——
`tool\build-installer.ps1` 一键出单文件 `output\LxAI-Setup-<版本>.exe`（约 25.5 MB），
单文件、卸载器、注册表卸载项、快捷方式、开机自启全部落地并实测过。

⚠️ 但 `installer/runtime/python` **不能删也不能挪**：新安装器的
`tool/build-payload.ps1` 硬编码从这里取私有 Python 运行时（`$RepoRoot\installer\runtime\python`）。
（完整口径见根 `AGENTS.md` §8 的安装器一节。）

**已有但未实测**：UAC 提权路径（`RelaunchElevated`，`ShellExecuteEx` + `runas`）。**代码是完整的，已决定不专门去测。**

- 链路：安装报"没权限"→ 界面露出「以管理员身份重试」→ `elevate` 消息 → 原生 `ShellExecuteEx(runas)`
  带 `--elevated --auto --dir` 把自己重新拉起 → 新进程自动开装并关掉旧窗口。参数解析、自动安装触发
  都在（`native/src/main.cpp` 的 `RelaunchElevated` / `g_autoInstallDir`，界面在 `native/ui/index.html`）。
- **为什么不必测**：默认装到 `%LOCALAPPDATA%\Programs\LxAI`（免管理员、不弹 UAC），用户不改路径就永远走不到
  这条分支；真走到时的行为也是良性的（UAC 点"否"→ 旧窗口原地不动、错误说明还在，用户仍可改目录）。
- 真要验证时再按 `AGENTS.md` §8 的沙箱流程隔离跑，别拿真机当试验场。

## 4. Windows 安装器 M5：评估过，**决定先不做**

M5 的原始定义在**同一层的研究目录** `lxai-installer-research`（与 `123`、`lxai-setup-flutter` 并列）
的 `笔记-04-自研安装器方案.md` 里程碑表里：**代码签名 + 与 App 自更新链路对接**，
验收是"首次运行无 SmartScreen；老用户能一键升级"。

**拆开看，一半其实早就做完了** —— 自更新侧现在是通的（2026-10-04 核对）：

`update_service.dart` 的 `checkUpdate()` 拉 GitHub Releases 并按平台匹配 asset → 设置页弹更新对话框
→ **应用内流式下载**（有进度/可取消/通知栏，不是开浏览器）→ 下载完自动拉起本地安装包
→ `launchWindowsInstaller()` 脱钩启动后 App 自己 `exit(0)` 释放句柄 → 安装器覆盖安装。
浏览器兜底只在 GitHub 里匹配不到 asset 时才走。

**真正的缺口只剩两项**：

| 缺口 | 现状 |
| :--- | :--- |
| **代码签名** | 没买证书。唯一作用是消掉用户**首次下载运行时**的 SmartScreen「未知发布者」 |
| **静默升级（`/S`）** | **完全没有**。原生安装器命令行只认 `--uninstall` / `--elevated` / `--auto` / `--dir`；`registry.cpp` 的注释直说了"我们没做静默模式"。差别是：现在下载完会**弹出四步向导**，用户还要点「下一步 → 安装」 |

**为什么先不做**：

- **签名不影响"能不能替换原文件"**。Windows 上未签名的 exe 照样运行、照样能覆盖自己的安装目录；
  签名只影响下载时的信任提示。代价就是首次那一次警告，点「更多信息 → 仍要运行」即可，
  日常使用和之后每次覆盖更新都不受影响。**Android 才有硬约束**（换了签名密钥的 APK 无法覆盖安装）。
- **静默模式省不了多少**：用户点「立即下载更新」之后，只比"一键"多两下点击。要换来的是一条无界面
  安装分支 + 进度反馈 + 出错兜底，还得处理"装到 `Program Files` 时弹 UAC 打断静默"这个分叉。
- **包完整性校验目前是缺的**（Windows 侧没有 hash 比对，Android 侧有）：下载走 GitHub HTTPS，
  实际风险低，跟签名一样属于"要不要投入"的取舍。

**将来真要开工的顺序**：先补 `/S` 静默模式 + 包完整性校验（**纯代码、不花钱**），签名等有证书了随时补
（它不影响前两者的实现）。

---

## 5. 改完但**还没验**的（2026-11-18 02:2x 清空）

> ⚠️ 这一节和上面几条性质不同：上面是"还没做"，这里**代码已经写完、包也装过**，只是没实测。
> **验过一条就从表里删掉那一行** —— 留着会让人以为它还是坏的。
> 标"服务端已部署"的，说明 `F:\ai\flutter-app` 那份运行副本已经重编重启过了（不用再部署）。

| # | 改了什么 | 提交 | 怎么验 | 备注 |
| :--- | :--- | :--- | :--- | :--- |





**2026-11-17 凌晨实测通过（已从表里删，结论留档）**：

- **改密码真调服务端**（`097fa5e`）：改完能用新密码登上 ✅
- **离线登录兜底已删**（`097fa5e`）：停中继后登录明确报错、没有静默进 App ✅
  （文案是「请检查网络设置」这一类，不是「连接不到服务器」，语义对但不够准）
- **录音文件出公共目录**（`c9413ff`）✅
- **#18 ⑥ 崩溃迁移恢复**（`4a3addf`）✅ —— 中途强杀后重开是**前滚**，路径切到新目录、标记被清
- **#13 桥接端点**（`/v1/user-questions`）✅ —— 2026-11-17 扫码直连后桥接窗口打出三重证据：`[✓ 成功上线] WebSocket 长连接` + `[✓ 会话同步] 本地 **1** 个宿主会话、**18** 个可用模型`（原来是 `Synced 0 sessions`）+ `[选择框] 轮询已启动：ask_user_question 会经中继转发到 App`。长轮询模式下永远不会跑会话同步，所以「打出会话同步」本身就是走 WS 的证据。
- **#35 CAS 登录时序**（`e9b6390`）✅ —— 2026-11-17 实测两组路径：真实双机同时登录（V60/V30 都登进去、V30 被顶后**明确弹「账号已下线」**，不是静默 403），外加脚本打三组 `baseVersion`（0→409、999→409、正确值→200 且 version 递增）。**关键：409 分支在写槽位之前 return，冲突不会改动槽位。**
- **#36 扫码配对误报**（`57261c1`）✅ —— 用户原话：「之前是百分百报错，连上桥接了，报错也是必提示」；这次扫码**直接提示配对成功、零报错**。说明 8s→60s 的超时放宽确实盖住了隧道往返

- **设置页锁退不回**（`a5d4f44`）✅
- **语音没转成文字就拦下**（`4947155`）✅
- **改密码后弹「去登录」**（`4b2ff34`）✅

**✅ 2026-11-17 04:05 状态：这一节已经清空 —— 没有任何"改完没验"的东西了。**

> 唯一一个测不了的（`a82d09b` 的 `flush: true`，只有突然断电才触发）已由用户决定按「已修」记档。
> 以后再往这里加东西时，**验完立刻删行**，别再攒。
⚠️ **同一晚补的一处**（`a82d09b`）：`_writeMarker` 加 `flush: true`。

> **2026-11-17 用户决定按「已修」记档**：它的作用场景是突然断电，正常使用触发不了、没法实测；代码改动本身是确定的一行（`flush: true`），风险接受。
理由见下 —— 强杀能恢复不代表断电也能，标记本身不落盘就白搭：

> `writeAsString` 默认 flush=false，数据只进 OS 页缓存。强杀没事（OS 会刷），
> **断电时标记可能根本没落盘** → 下次开机读不到 → 「以为从没迁过」，
> 而现场是「旧目录搬一半 + 新目录一堆孤儿 + 设置指旧目录」——正是要防的三不像。
> 清标记那侧不用改：清完断电只会多跑一次幂等的恢复。

**语音消息这一整块（2026-11-16 凌晨）已验完**，不用再查：
底色/固定长度/进度竖线/20 根柱子的已播未播分色/暂停继续/长按重新播放/不落盘播放（`BytesSource` 在 Windows 后端可用）。
关键坑记两条：① `audioplayers` 的 Windows 后端（Media Foundation）**处理不了含空格的路径**，所以改成完全不落盘；
② 播放失败以前被 `catch` 静默吞掉，现在是 AppLogger + SnackBar，**不许再改回静默**。

## 8. 语音输入的四条路（2026-11-17 摸清，**先不做**）

**背景**：现在「没填转写 Key 就拦下不发」（`4947155`）是按「模型听不见音频」设计的。用户提出：
如果填的是**支持语音输入的模型**（GPT-4o / Qwen-Omni 这类），转写就是多余的中间层。

**2026-11-17 逐条查清的事实**：

| 路 | 可行 | 判定依据 |
| --- | --- | --- |
| ① 模型原生听音频（走 DSH） | ❌ | `dsh-api-remotes` 里 `inputModalities` 只认 `text` / `image`，**没有 `audio`**。已把 `0.2.2-rc.3` 的包下下来搜过 `literal("audio")` —— **仍然没有**。升级 DSH 解决不了 |
| ② DSH 内置 SenseVoice 转写 | ✅ 但只服务浏览器麦克风 | `dsh-experimental-voice-input-bundle` 本地已装（0.2.1 就有），描述是 `Experimental voice input with local SenseVoice`，**0.2.2 描述一字未改** |
| ③ 音频发桥接 → DSH 转写 | ✅ 需要自己接一层 | 桥接/插件要加 `audio` 通道，把音频喂进 `speechToText` 服务 |
| ④ 普通模式直发 `input_audio` | ✅ 但 App 没实现 | `api_service.dart` 的 `multiContent` 只处理 `text` / `image_url`，音频落进 `[文件附件]` 占位；`chat_provider.dart:1806` 在没转写时发的是`「语音消息」`四个字 |

**⚠️ ④ 的前置条件没定**：用户 2026-11-17 说「普通 API 聊天我还再想要不要砍掉」——**如果砍掉普通模式，④ 这条也就不存在了**。所以这件事要等那个决定，别先做。

**要的最终形态**是四层降级（按优先级）：填了 ASR Key → App 转写；没 Key + 模型支持音频 + 普通模式 → 直发 `input_audio`；没 Key + DSH 模式 → 发桥接让 DSH 转写；都不满足 → 拦下提示。

**注意**：`input_audio` 不是所有端点都收（DeepSeek 就不收），发错会 400。所以必须配一个「该模型支持音频输入」的开关，不要做能力探测。

**DSH 升级的独立结论**（跟语音无关，留档）：本地 `0.2.1-rc.2` vs npm `0.2.2-rc.3`，依赖 86→91。新增 `dsh-cua-bundle`（Computer Use Agent）、`dsh-deepseek-chat-import`、`dsh-personalized-recommendations`、`dsh-experimental-liveshare`、`dsh-official-bundles`、`dsh-experimental-forge-bundle`；移除 `dsh-experimental-agent-team-profile`。**没有 changelog，只能从包名推断**，所以无法评估行为变化。**用户 2026-11-17 决定先不升。**

## 9. 中继安全审计 26 条（2026-11-17 用户明确「安全我不懂，你独立做完」）

> **状态：26 条全部处理完毕（2026-11-18 凌晨）** —— 25 条已修并部署，1 条（㉔）核实后不适用。
> 其中两条的 **App 侧改动要重新打包才生效**：③（扫码带身份头）、⑯（改密码 8 位校验）。
> 每条都有实测判据（拦截请求 / 正常路径不误伤），不是"改完就算"。

> 完整清单（病根、行号、修法、危害）在 `记忆/待办/42-安全审计.md` ——**那份是权威，这里只排期**。
> ⚠️ 行号基准 7323 行那版，现在已涨到 7350+，**认函数名不认行号**。
> ⚠️ 报告里另有 **15 项「查过没问题」**（别再重查）和 **7 项「未确认」**（改到相关条目时顺带查）。

### 已完成（2026-11-17）

| # | 漏洞 | 提交 | 状态 |
| :--- | :--- | :--- | :--- |
| ① | `/api/upload-chunk` 路径穿越（可覆盖 `dist/server.cjs`） | `ae4aaa0` | ✅ 已修 + **已实测拦截**（攻击请求返 403）+ 已部署 |
| ② | `rotate-token` 无身份校验 | `ae4aaa0` | ✅ 已加 `verifyUserIdentity` + 已部署 |

### 下一步：先查 7 项「未确认」（**都是本地命令，不改代码**）

这几项决定后面几条是「高危」还是「只是代码异味」，**先查再修，别按报告原判动手**：

| # | 要查什么 | 命令 |
| :--- | :--- | :--- |
| 1 | `.secrets/master.key` 有没有被 git 跟踪过 | `git log --all -- .secrets/master.key` + `git ls-files .secrets` |
| 2 | 生产 `settings.json` 里还有没有账号在用 `kLegacyDefaultAgentToken` | 读生产 settings 搜这个串 |
| 3 | `ttsApiKey` 实际有没有落盘 | 同上 |
| 4 | multer 的 CVE 命中 | `npm audit` |
| 5 | 生产有没有配 `GEMINI_API_KEY` | 看生产 `.env` |
| 6 | 源站安全组是否只放行 Cloudflare | 决定 ⑱ 可利用性（**这条要看你的服务器控制台**） |
| 7 | `resolveOrCreateUserAgentToken` 账号不存在时会不会写 settings | 读代码 |

### 再下一步：按依赖分组

**A. 我能独立改、无前置依赖**（改完一条验一条）

| # | 一句话 | 风险 |
| :--- | :--- | :--- |
| ④ | token 经 `io.emit` 全局广播 → 改 `io.to(user_<owner>)` | **高**（这条不修等于 token 人人可见） |
| ⑧ | 8 个 Agent 事件端点无归属校验 → 统一 `verifyAgentOwnership` | 高 |
| ⑨ | `.bat` 生成接口命令注入 → token 加字符白名单、harnessUrl 走 `safeScriptUrl` | 高 |
| ⑦ | `/api/funasr-ws` 无鉴权 + 无 SSRF 防护 + `rejectUnauthorized:false` | 中 |
| ⑩ | `check-session` 消费早于校验 + catch fail-open 回 token | 中 |
| ⑬ | `pending-decisions.json` 明文落盘 token → 落盘前删/哈希 | 中 |
| ⑭ | 日志打印完整 Agent Token → maskToken | 中 |
| ⑮ | `model-limits` POST 无鉴权 | 中 |
| ⑯ | `change-password` 无限流、新密码只要 6 位（注册要 8 位） | 中 |
| ⑳ | `auth-session` 用 `Math.random()` 生成配对码 → `crypto.randomBytes` | 中 |
| ㉓㉔㉕ | `ttsApiKey` 未清 / 硬编码 token 未排除 / `chat/cancel` 无校验 | 低 |

**B. 要 App 和服务端一起改**（不是单独改服务端就行）

| # | 一件事 | 卡在哪 |
| :--- | :--- | :--- |
| ③ | `auth-confirm` 只查「用户存在」 | **App 扫码时不带 `x-client-session-id`**（`scanner_screen.dart:110`）。先给 App 补 header，服务端才能收紧 —— **反了会把扫码配对打回 403** |

**C. 大改 / 要配套处理**（不能只改一处）

| # | 一件事 | 为什么算大改 |
| :--- | :--- | :--- |
| ⑤ | socket.io 整段无鉴权 | App 已不用它，**最干净是整段删掉**；但 `io.emit` 有 57 处在用，得一起处理 |
| ⑥ | `chat/generate` + `chat/stream` 无鉴权：SSRF + key 外带 | 要复用 ASR 那套 `ssrfViolation`，**并且禁止回退服务端 key** |
| ⑪ | 任意 ≥16 字符 token 可注册假 Agent | 涉及 register/poll/heartbeat/ws 四条路 |
| ⑫ | `bridge-transition` / `cancel` 无身份校验 | 低代价 DoS |
| ⑰ | 注销不删 `device_tokens.json`，旧凭证可复活 | 要同步改注销流程 |
| ⑱ | `listen(0.0.0.0)` + 无条件信任 `cf-connecting-ip` | **改完可能影响隧道**，要先确认源站暴露面 |
| ⑲ | `.gitignore` 没有 `.secrets/` | 先自查历史，再补 ignore |
| ㉑ | multer 已知 DoS CVE | 要 `npm audit` 确认后再决定升不升 |
| ㉒ | `/api/upload` 无鉴权 + 扩展名不限 → 存储型 XSS | 加鉴权 + 扩展名白名单 |

### 动手时的两条铁律（审计报告里写的）

1. **别因为「报告说是高危」就直接改**：①②③④ 是我逐行核实过的，其余是报告原判。**改之前把那条代码重新读一遍**。
2. **改完要走完整链路**：登录 → 收发消息 → 桥接上线 → 发任务。**加守卫把正常请求挡成 403 的事，这个项目历史上发生过**（见 `习惯.md`「改中继之后怎么部署」）。

## 10. 跨账号数据隔离缺失（2026-11-17 用户实测发现）

**用户原话**：「切换账号会加载上一个账号的设置和聊天记录等，没有做的不同账号隔离」

**现象**：在 App 里退出 A 账号、登录 B 账号后，界面会先出现 **A 账号的设置和聊天记录**，
而不是 B 账号自己的（或空白起步）。

**性质**：这是**跨账号数据泄漏**，不是体验问题 —— 两个账号本该互不可见，现在 A 的东西
会出现在 B 的屏幕上。服务器侧一直是按 `userId` 分文件存的（`messages_v2.json` 按 userId
分键、`settings.json` 按 userId 分键），所以**最可能漏在客户端**：退出登录时没把 Hive 里的
`sessions` / `messages` / `settings` 三个 box 清干净，或新账号登录后第一次拉取拿旧的本地缓存当底。

⚠️ **还没定位到具体代码**，下次动手前先查这几处：

| 查哪 | 为什么 |
| --- | --- |
| `settings_provider.logout()` / 退出登录流程 | 退出时是否 `box.clear()`，尤其 `sessions` box |
| `chat_provider.loadSessions()` | 登录切换后是否重新 load，还是沿用内存里的旧列表 |
| `hive_service.dart` 的 box 打开方式 | 按 userId 分 box 还是全局单 box（**全局单 box 就是根因**） |
| 冷启动 vs 热切换 | 杀进程重开是否复现（只有热切换复现 → 问题在内存） |

**验证判据**（三条全过才算修好）：

1. A 登录 → 发 3 条消息 → 退出 → B 登录：**B 看不到那 3 条**；
2. B 改一个设置（如背景色）→ 退出 → A 登录：**A 的设置没被 B 改掉**；
3. 反过来的顺序再来一遍。

⚠️ **别再犯的坑**：修这个时容易顺手"登录时清空本地库" —— 那会连带清掉
**还没同步上云的消息**（离线期间发的）。正确做法是**按 userId 分库/分键**，不是"登录时清空"。

## 11. 数据库迁移第三期（**11.2 已完成，11.1 等 App 端一起改**）

第一、二、三期（11.2 部分）已上线并验证（提交 `499dc2f` / `cbab4c0` / `f57ef24` / `d847047`）：
`settings` / `sessions` / `messages` / `kv` 四张表已经在 `messages_data/lxai.db` 里。
详细记录见 `docs/数据库迁移-2026-11-18复核.md` §7 / §9 / §10。

**第三期剩一件事**（来自那份文档 §4）：

### 11.1 图片从设置里拆成静态文件 ⏸ 未做

`customBackground` 416 KB / `userAvatar` 47 KB / `aiAvatar` 25 KB，
现在整份 base64 存在 `settings.data` 这个 JSON 列里，占设置表体积的 99.5%。

拆法：落盘成静态文件、设置里只存路径。
⚠️ **这会改到 App 端**（`settings` 字段从 base64 变路径）—— 不是纯服务端改动，
属于跨端协议变更，得两端一起改、一起验。所以它没有随 11.2 一起做。

### 11.2 剩余 6 个小文件迁进库 ✅ 已完成（2026-11-18 18:00）

`users` / `active_sessions` / `deletion_signals` / `model_limits` /
`pending-decisions` / `login_attempts` 全部进 `kv` 表，**行为不变**（整份 JSON 存一格）。

验收：kv 表 6 行；5 个文件与 JSON 逐字节一致；`active_sessions` 只有 `lastActive` 变新
（这正是「每 60 秒节流落盘」在 DB 上正常工作的证据）；`check-session` 返回 `{"valid":true}`
证明**请求路径**读得到；重启两次指纹不变。

### 11.3 真实发消息的写入路径 ✅ 已实测通过（2026-11-18 20:04）

用户从电脑端 App 发了一条「测试，此条消息来自电脑端app」，实测结果：

- `messages` 15 → **17**（16 是用户消息、17 是 App 预生成的 assistant 占位）
- **seq 1..17 连续无断档**
- 前 15 条老数据**一条没丢** —— 这条最关键：`saveMessages` 是「DELETE 全部 + 重插」，
  写坏了会丢老消息
- 日志无 `Socket error saving message`、无 `SQLITE_*` 报错

## 12. 中继侧剩下的小尾巴（2026-11-18 20:57）

数据库迁移收尾后，中继（`server.ts`）这边只剩这几条：

| 项 | 现状 | 要不要处理 |
| :--- | :--- | :--- |
| **图片从设置拆成静态文件**（§11.1） | 未做，476 KB 还压在 `settings.data` 里 | **要 App 端一起改**，不是纯服务端活 |
| **`server-run.log` 到 1.5 MB** | 有 5 MB 轮转，还没到 | 不急。⚠️ 大头是 `[Agent Hub]` 把工具调用内容也写进日志（实测翻到过我的命令描述），想降噪可以只记工具名不记参数 |
| **幽灵 `node ... server.cjs` 进程** | 又冒了一个（父是宿主 `node.exe` 而非 `cmd.exe`） | 不监听端口、不写库（杀前杀后指纹一致），无害。判据与排查命令见 `docs/数据库迁移-2026-11-18复核.md` §10 |

**没有别的了。** 中继的存储、鉴权、登录互斥、删除同步、消息收发都在本次迁移里实测过。

## 记录格式（沿用即可）

每条至少写清四件事，否则下次还得重新摸一遍代码：

1. **要什么** —— 一句话说清最终效果；
2. **为什么** —— 用户的原话或实际痛点，避免下次凭感觉"优化"掉；
3. **现状定位** —— 文件 + 行号 + 关键函数名（**写行号时注明是哪天的代码**，
   行号会随改动漂移，函数名才是稳的）；
4. **怎么做 / 注意事项** —— 尤其是"别顺手把 X 也改了"这类边界。

## 备注

- 纯 App 端（Dart）的改动：`flutter analyze` 过一遍即可；
  要看到效果**需要重新打 App 包**（Windows / Android），网页端与此无关。
- App 打包流程见根 `README.md` §四；Windows 安装器见独立仓库 `lxai-setup-flutter`。
