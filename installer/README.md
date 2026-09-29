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
├── assets/                   向导外观素材（入库）
│   ├── wizard-large.png      向导侧边大图（纯白底 + 产品图标）
│   ├── wizard-small.png      向导右上角小图
│   └── slides/               安装过程中的轮播图（4 张功能截图）
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

## 外观与安装过程（这块踩过三个坑，改之前务必看）

| 现象 | 根因 | 做法 |
| :--- | :--- | :--- |
| 编译报 `Unknown type 'TTimer'` | Inno 的 Pascal Script **没有 `TTimer` 支持类**，脚本层也没有自己的消息循环 | 轮播改由 `CurInstallProgressChanged` 驱动 —— 按安装进度把 4 张图均匀铺开（0~25% 第 1 张、25~50% 第 2 张…），比定时器更贴合安装流程 |
| 编译报 `Unknown identifier 'PICTURE'` | `TBitmapImage` 的属性是 **`Bitmap` / `PngImage`**，**没有 `Picture`** | 素材是 PNG，所以用 `SlideImage.PngImage.LoadFromFile(...)` |
| 安装时反复抛「内部错误：Cannot call file extractor recursively」 | `CurInstallProgressChanged` 发生在 Inno **正在写文件**的过程中，此时不允许再调 `ExtractTemporaryFile` | 改为进入安装页时用 `ExtractTemporaryFiles('*.png')` **一次性全部提取**，之后只做 `LoadFromFile` |

另外两条容易踩的点：

* **Pascal 的花括号本身就是注释定界符** —— 注释正文里不能再写花括号（例如写 `{tmp}` 会把外层注释提前闭合，报出位置莫名其妙的 Syntax error）。
* **轮播图用 `dontcopy`**：只打进安装包、**不落到目标目录**（实测确认目标目录里没有这些 png），安装结束后由 Inno 自动清理临时目录。

## 安装前会停掉占用目标目录的桥接

桥接跑的是 App 自带的私有 Python（应用目录下的 `python` 子目录）。它一旦变成孤儿进程
（App 退出时没带走 —— 旧版本的行为，现已在托盘退出项里修掉），就占着安装目录里的 `python.exe`，
Inno 的 RestartManager 无法自动关闭它，安装会以「安装程序无法自动关闭所有应用程序」**直接中止**
（实测：退出码 5，日志里可见 `RestartManager found an application using one of our files: Python`）。

所以 `[Code]` 的 `PrepareToInstall` 会先跑 `StopBridgeInAppDir()`：用 PowerShell 精确结束
**「可执行文件路径位于应用目录下」**的 python —— **绝不动用户自己环境里的 Python**。
实测对比：同一场景下，加这段之前安装失败（退出码 5），加了之后安装成功（退出码 0）且占用进程被清掉。

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
