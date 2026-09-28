# LxAI Windows 安装器

用 **Inno Setup 6** 把 Flutter 的 Windows Release 产物 + 一份**私有 Python 运行时**
打包成标准安装程序（中文向导、可选安装目录、快捷方式、标准卸载入口）。

## 一键构建

```powershell
# 前置：先出 Flutter 产物
cd ..\flutter_app
flutter build windows --release

# 回到这里构建安装器
cd ..\installer
pwsh -File build-installer.ps1
```

产物：`output\LxAI-Setup-<版本>.exe`（约 22 MB）。版本号默认从 `flutter_app/pubspec.yaml` 读取。

## 依赖（都只需一次）

| 依赖 | 说明 |
| :--- | :--- |
| **Inno Setup 6** | 编译器 `ISCC.exe`。下载 <https://jrsoftware.org/isdl.php>；静默安装：<br>`innosetup-6.7.3.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-` |
| **本机 Python** | 仅用于 `pip download` 取 wheel（脚本会自己找 `python` 或 `py`），**不参与最终产物** |
| 网络 | 首次备料要下 Python embeddable 与 websockets wheel，之后走 `cache\` 缓存 |

## 目录说明

```
installer/
├── lxai-setup.iss            Inno Setup 脚本（入库）
├── prepare-runtime.ps1       备料：组装私有 Python 运行时（入库）
├── build-installer.ps1       一键构建（入库）
├── languages/
│   └── ChineseSimplified.isl 简体中文语言包（入库）
├── cache/                    ⛔ 下载缓存        （.gitignore）
├── runtime/python/           ⛔ 私有 Python 运行时（.gitignore）
└── output/                   ⛔ 编译产物        （.gitignore）
```

## 为什么内置一份 Python

桥接 `lxai_bridge.py` 是 Python 脚本，第三方依赖是 `websockets`。此前只能要求用户
自己装 Python 并 `pip install websockets` —— 既抬高门槛，又会把依赖装进用户的**全局**
Python 环境。内置一份私有运行时后：

* 用户装完 App 就能用远程遥控，**不需要任何额外步骤**；
* 依赖只落在 `{app}\python` 里，**不污染用户的 Python**（用户自己装没装、装什么版本都不影响）；
* 不同用户的 Python 版本差异不再影响桥接行为。

App 侧 `BridgeProcessManager._resolvePythonExecutable()` 会**优先**使用 `{应用目录}\python\python.exe`，
找不到才回退 PATH 里的 `python`（覆盖"开发机直接跑构建产物"与"免安装绿色版"两种场景）。

实现细节见 `prepare-runtime.ps1` 的注释（要点：Python **embeddable** 默认关闭
`site-packages`，必须打开 `python3xx._pth` 里的 `import site`，否则 `import websockets` 会失败）。

## 已知事项

* **未做代码签名**：用户首次运行会看到 Windows SmartScreen 的"未知发布者"提示，
  需点"仍要运行"。这是 Windows 的机制，与安装器本身无关；要消除它需购买代码签名证书
  （EV 证书可立即获得信任）。
* **Inno Setup 的许可**：其 `license.txt` 明确允许"any purpose, including commercial
  applications"；官网对商业用户是"请求"购买许可（非强制）。本项目的安装器按
  `license.txt` 条款使用。
* 语言包 `languages/ChineseSimplified.isl` 取自社区翻译项目
  <https://github.com/kira-96/Inno-Setup-Chinese-Simplified-Translation>，
  Inno Setup 官方包不含简体中文。

## 修改安装器时的注意事项

* `lxai-setup.iss` 里的 **`AppId` GUID 永远不要改** —— 卸载程序靠它识别同一个应用，
  改了会导致"装了新版、旧版留在控制面板里删不掉"。
* 卸载**刻意保留用户数据**：聊天记录与登录态在 `%USERPROFILE%\Documents`（Hive），
  不在安装目录。`[UninstallDelete]` 只清安装目录里运行时生成的文件。
* 改了 `[Files]` 的来源目录后，记得同步更新 `build-installer.ps1` 里的校验路径。
