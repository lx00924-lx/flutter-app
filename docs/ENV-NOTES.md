# 运行环境细节手册（从 AGENTS.md §8 拆出）

> 为什么拆：DSH 的工作区指令有 **65536 字节预算**，AGENTS.md 塞不下全部细节，
> 超了会被截断（**末尾读不到**，比缺细节更危险）。
> 这里放**排查过程与历史**；`AGENTS.md` §8 只留"约束与判据"。
> 改动环境相关逻辑前，两份都值得扫一眼。

---

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
- **Windows 分发走安装器 —— 2026-10-03 起主line 换成自研原生版（D 方案）**：
  - **新主line**：独立仓库 **`lxai-setup-flutter`**（GitHub `lx00924-lx/lxai-setup-flutter`），
    **C++ 管安装逻辑 + WebView2 渲染 HTML/CSS 界面**。
    一键出**单文件**：`tool\build-installer.ps1` → `output\LxAI-Setup-<版本>.exe`（约 25.5 MB）。
    - 界面（HTML/图标）由 `native\ui\ui.rc` 编进 exe 资源；
      素材（私有 Python + App 本体）压缩后**追加在 exe 尾部**（32 字节定长尾部标记 `LXAIZIP1`），
      运行时用 vendored 的 miniz 解到临时目录。**界面靠虚拟主机 `https://lxai.setup/` 供给**
      （不能用 `NavigateToString`：那样页面没有基准 URL，`<img src="app_icon.png">` 会裂图）。
    - 卸载器 = **同一个 exe 截掉素材段**（约 450 KB），靠 `--uninstall` 或"住在 `uninstaller\` 下"识别身份。
      注册表卸载项用**与旧 Inno 版同一个 GUID**，所以是原地升级、控制面板里不会出现两个 LxAI。
      卸载器的自毁交给 `wscript.exe` 跑 VBS（它删不掉自己）。
    - 覆盖安装**先杀后装**：结束所有"可执行文件位于安装目录下"的进程（按路径判、不按进程名）。
    - ⚠️ **`native\third_party\miniz\` 必须入库**（`.gitignore` 里特意开了例外）——
      它是构建必需品，不像 WebView2 SDK 那样能现拉。
  - **旧 Inno 版（`installer/`）仍在，但现在只是"私有 Python 运行时的存放与生成处"**：
    - ✅ **必须保留**：`installer\runtime\python`（新安装器的 `tool\build-payload.ps1` 直接读它）
      与 **`installer\prepare-runtime.ps1`**（它是**唯一**能重建那份运行时的脚本，
      新安装器报错时提示的就是它）。`cache\` 是它的 wheel 缓存，离线重建靠它。
    - ❌ 已废但**先别删**：`lxai-setup.iss` / `build-installer.ps1` / `assets\wizard-*` / `languages\`
      —— 留作回退路径，等新安装器在真实机器上跑够再清。
    - 安装目录由向导让用户选（默认 `{autopf}\LxAI`），并可切换「为所有用户 / 仅为我」（后者免管理员、不弹 UAC）。
    - ⚠️ `.iss` 里的 **`AppId` GUID 永远不要改**：卸载程序靠它识别同一个应用，改了会在控制面板留下删不掉的旧版本。
    - 卸载**刻意保留用户数据**（`Documents` 里的 Hive）—— 新旧两版都是这个口径。
  - ⚠️ **改了 App 代码后必须先 `flutter build windows --release` + 重打素材**（`tool\build-payload.ps1`）**再编安装器** ——
    安装器打包的是 Release 目录的产物，曾出现「源码比 app.so 新」导致装出来的 App 不含最新改动。
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
