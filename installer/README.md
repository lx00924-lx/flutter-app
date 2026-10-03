# `installer/` —— 私有 Python 运行时的存放与生成处

> ⚠️ **先读这段，别按目录名想当然。**
>
> 这个目录**曾经**是 Inno Setup 版的安装器（2026-09-29 ～ 2026-10-03）。
> 2026-10-03 起 Windows 分发的**主线换成了自研原生版**，在**独立仓库**
> `lxai-setup-flutter`（GitHub `lx00924-lx/lxai-setup-flutter`，C++ + WebView2）。
>
> 但**这个目录不能删** —— 新安装器要用的那份「私有 Python 运行时」就住在这里。

---

## 一、这里的东西分别归谁

| 内容 | 归谁用 | 能不能动 |
| :--- | :--- | :--- |
| **`runtime/python/`**（118 文件 / 21.4 MB，gitignored） | **新安装器**：`lxai-setup-flutter\tool\build-payload.ps1` 硬编码读 `$RepoRoot\installer\runtime\python` | ✅ 留着。**删了/挪了新安装器直接造不出安装包** |
| **`prepare-runtime.ps1`** | **新安装器**：这是**唯一**能重建上面那份运行时的脚本 | ✅ 留着。新机器 clone 后 `runtime/` 是空的（gitignored），必须靠它 |
| `cache/`（gitignored） | `prepare-runtime.ps1` 的 wheel 缓存 | ✅ 留着 —— 见下面「为什么缓存不能删」 |
| `lxai-setup.iss` / `build-installer.ps1` / `assets/wizard-*` / `languages/` | 旧 Inno 版，**已不再迭代** | ⏸ 先别删，留作回退路径 |
| `output/`（22 MB，gitignored） | 旧 Inno 版的产物 | 🗑 可随时删，纯占地方 |

---

## 二、新安装器怎么用这里的东西

新安装器**不读这个目录**，它读的是**由这里产出的素材**。完整链路：

```powershell
# ① 在打包目录构建 App（必须，安装器打包的是构建产物）
cd F:\ai\flutter\flutter-app
git fetch origin ; git reset --hard origin/main      # 绝不用 git clean -fdx（会删签名密钥）
cd flutter_app ; flutter build windows --release

# ② 组装素材 —— 这一步会从 installer\runtime\python 取私有运行时
cd F:\ai\flutter\lxai-setup-flutter
powershell -ExecutionPolicy Bypass -File tool\build-payload.ps1
#   产出：payload\app\（App 产物）+ payload\python\（私有运行时）+ 许可与图标
#   ⚠️ 它优先读「打包目录」的 Release，其次才是源码仓 123 的 —— 源码仓那份可能更旧

# ③ 打单文件安装包
powershell -ExecutionPolicy Bypass -File tool\build-installer.ps1
#   产出：output\LxAI-Setup-1.0.1.exe（约 25.5 MB，双击即装的单文件）
```

**`prepare-runtime.ps1` 什么时候用**：只在 `installer/runtime/python` 不存在或损坏时。
`build-payload.ps1` 发现缺了会提示「先跑 `installer\prepare-runtime.ps1`」，照做即可：

```powershell
powershell -ExecutionPolicy Bypass -File installer\prepare-runtime.ps1
```

它做的事：拉 Python 3.13 **embeddable** 包 → 解开 `python313._pth` 打开 `site`
（否则 `import` 不到 `site-packages`）→ 解压 `websockets` 的 `cp313` wheel →
跑一次导入自检。**不用 pip**（embeddable 版没有 pip，装不进去）。

### 为什么 `cache/` 不能删

`prepare-runtime.ps1` 的注释里记着实测结论：本机（以及不少国内网络环境）**走代理/透明网关时，
`pypi.org` 会被解析到不可达的内网地址**（实测 `198.18.0.41`，与 `github.com → 198.18.0.x` 同源）。
旧写法"无条件先下载"会让整个构建卡死在这一步，而 `cache/` 里其实早就躺着版本完全匹配的 wheel。
所以在缓存时**就不再联网**：既能离线重建，重复构建也快得多。

---

## 三、旧 Inno 版（已弃用，留档）

万一新安装器出了没法快速修的问题，可以用它顶一次 —— 脚本齐全，一键出 22 MB 单文件：

```powershell
powershell -File installer\build-installer.ps1     # 产物在 installer\output\
```

它自带卸载器、快捷方式、注册表卸载项与 UAC 提权，久经使用。

⚠️ 与旧版的兼容点：`lxai-setup.iss` 里的 **`AppId` GUID 永远不要改**
（`{8CC1E567-9691-46FF-914C-B7A24B230C39}`）—— 卸载程序靠它识别同一个应用，
改了会在控制面板留下删不掉的旧版本。新安装器的注册表卸载项**用的是同一个 GUID**，
所以新旧两版之间是原地升级，控制面板里不会出现两个 LxAI。

---

## 四、两版共同的口径

- **卸载刻意保留用户数据**：`Documents` 下的 Hive（聊天记录、登录态、设置）不动，
  只清安装目录。重装后数据原样回来。
- **改了 App 代码 → 必须先 `flutter build windows --release` + 重打素材再编安装器**。
  曾出现过「源码比 `app.so` 新」导致装出来的 App 不含最新改动。
