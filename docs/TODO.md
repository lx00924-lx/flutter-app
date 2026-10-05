# 待办事项（Backlog）

> 这里放**已确认要做、但还没做**的改动。用户口头交代"先记一下、下次再做"的条目也记在这。
> 做完一条就把对应小节删掉（别留"已完成"的历史 —— 那属于 git log 的职责）。

---

**当前没有待办。** 下面两条都是**已完结或"以后再做"**的规划项，留在这里只为备查：
第 1 条是将来才启动的 Linux 适配，第 2 条是安装器的收尾记录（只剩一条未实测）。

---

## 1. Linux 桌面适配（以后再计划）

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

## 2. Windows 安装器：已完结，只剩一条未实测

主仓库的 `installer/` 是**旧的 Inno Setup 版**，已不再迭代；自研安装器在**独立仓库**
`F:\ai\flutter\lxai-setup-flutter`（GitHub `lx00924-lx/lxai-setup-flutter`），
**D 方案（C++ 安装逻辑 + WebView2 渲染 HTML/CSS 界面）已实现并发布** ——
`tool\build-installer.ps1` 一键出单文件 `output\LxAI-Setup-<版本>.exe`（约 25.5 MB），
单文件、卸载器、注册表卸载项、快捷方式、开机自启全部落地并实测过。

⚠️ 但 `installer/runtime/python` **不能删也不能挪**：新安装器的
`tool/build-payload.ps1` 硬编码从这里取私有 Python 运行时（`$RepoRoot\installer\runtime\python`）。
（完整口径见根 `AGENTS.md` §8 的安装器一节。）

**唯一没验证过的**：UAC 提权路径（`RelaunchElevated`，`ShellExecuteEx` + `runas`）。
默认安装目录是 `%LOCALAPPDATA%\Programs\LxAI`（免管理员、不弹 UAC），
所以"装到 `Program Files`"这条分支**至今没在真机上跑过**。
等哪天真要装到 `Program Files` 时，先按 `AGENTS.md` §8 的沙箱流程隔离验证。

---

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
