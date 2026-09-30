<div align="center">

# LxAI · 官网介绍页 + 多端 App + 内网穿透 Bridge

**无公网 IP，也能远程遥控内网电脑上的私有 Agent（DeepSeek Harness / 本地模型 / 本地自动化工作区）。**

Flutter 纯原生多端客户端（Android / Windows） · Node + React 官网介绍与下载门户 · Python 反向长连接内网穿透

</div>

---

## 一、这套东西是什么

三位一体架构，三部分可以独立部署：

| 模块 | 目录 | 技术栈 | 作用 |
| :--- | :--- | :--- | :--- |
| **① 云端中继服务（含官网介绍页）** | `/`（`server.ts`、`src/`） | Express + TypeScript + React + Vite | 会话鉴权、Token 调度分配、消息持久化与增量漫游、设置云端同步、单点登录互斥、反向信道桥接；`src/` 为对外官网介绍与下载门户 |
| **② 多端 App 客户端** | `flutter_app/` | Flutter（纯原生，无 WebView 套壳） | 手机/电脑遥控端：聊天、语音、扫码配对、本地 Agent 控制 |
| **③ 本地反向长连接 Bridge** | `lxai_bridge.py` | Python 3.8+ | 跑在**无公网 IP** 的电脑上，主动向云端建立反向长连接，把本地 Harness 暴露给 App |

核心能力：单点登录设备互斥（1 台手机 + 1 台电脑）、消息增量漫游、全局设置云端同步、扫码即配对。

---

## 二、环境要求

| 用途 | 需要 |
| :--- | :--- |
| 服务端 / 官网介绍页 | Node.js **20+**、npm |
| 打包 Flutter App | Flutter **3.44+**（含 Dart 3.12+） |
| 打包 Windows 客户端 | Visual Studio 2022，勾选「使用 C++ 的桌面开发」 |
| 制作 Windows 安装程序 | Inno Setup **6**（见 [`installer/README.md`](./installer/README.md)） |
| 打包 Android 客户端 | JDK 17+、Android SDK（含 build-tools / platform 36） |
| 手动运行本地 Bridge | Python **3.8+**（用安装版分发时**用户无需 Python**，见 [4.2](#42-打包成-windows-安装程序推荐分发方式)） |

```bash
flutter doctor -v      # 确认 Flutter / VS / Android 工具链齐全
node -v && npm -v
python --version
```

---

## 三、跑起来（服务端 + 官网介绍页）

```bash
npm install

# 开发模式（Express + Vite 中间件，默认端口 3000）
npm run dev

# 生产模式
npm run build      # 产出 dist/（前端静态产物 + dist/server.cjs）
npm start
```

浏览器打开 `http://localhost:3000` 即可看到 LxAI 官网介绍与下载门户。

---

## 四、打包 Flutter 客户端

```bash
cd flutter_app
flutter pub get
```

### 4.1 打包 Windows

```bash
flutter build windows --release
# 产物：build/windows/x64/runner/Release/LxAI.exe（整个 Release 目录一起分发）
```

### 4.2 打包成 Windows 安装程序（推荐分发方式）

直接分发 Release 目录，用户还得自己准备 Python 环境才能跑本地 Bridge。用安装器分发则
**用户无需任何 Python 环境**：它把 Flutter 产物与一份**私有 Python 运行时**
（Python 3.13 embeddable + websockets）打在一起，依赖只落在 `{app}\python`，
**不污染用户自己的 Python**，也就不受各人 Python 版本差异影响。

```powershell
cd installer
pwsh -File build-installer.ps1
# 产物：installer/output/LxAI-Setup-<版本>.exe（约 22 MB，版本号自动读 pubspec.yaml）
```

带中文向导、可选安装目录、桌面与开始菜单快捷方式、标准卸载入口；卸载**刻意保留**
`Documents` 里的用户数据（聊天记录与登录态），只清安装目录里运行时生成的文件。

> ⚠️ 改了 App 代码后必须**先重新 `flutter build windows --release` 再编译安装器**——
> 安装器打包的是 Release 目录的产物，否则会打出「源码比 app.so 新」的包。
> 三个 Inno 踩坑记录与安装前清理逻辑见 [`installer/README.md`](./installer/README.md)。

### 4.3 打包 Android

```bash
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

> **注意**：仓库里**不包含任何签名密钥**。没有配置签名时，构建会自动回退到 debug 签名
> —— **可以正常打包自测，但不能用于发布**。要出正式签名包，按下节配置你自己的密钥。

### 4.4 换成你自己的 Android 签名

```bash
# 1) 生成属于你自己的密钥
keytool -genkeypair -v -keystore AI.jks -keyalg RSA -keysize 2048 -validity 10000 -alias key0
```

2. 把 `AI.jks` 放到 `flutter_app/android/app/AI.jks`
3. 新建 `flutter_app/android/key.properties`：

```properties
storePassword=你的口令
keyPassword=你的口令
keyAlias=key0
storeFile=AI.jks
```

4. 重新执行 `flutter build apk --release` → 立即变成你自己的正式签名。

`key.properties` 与 `*.jks` 已被 `.gitignore` 忽略，**请永远不要提交它们**（详见 `flutter_app/android/SIGNING_README.md`）。

### 4.5 换成你自己的服务器地址

**无需修改任何源码**，打包时用 `--dart-define` 传入即可：

```bash
flutter build apk     --release --dart-define=SERVER_BASE_URL=https://your-domain.com
flutter build windows --release --dart-define=SERVER_BASE_URL=https://your-domain.com
flutter run                                 --dart-define=SERVER_BASE_URL=http://192.168.1.10:3000
```

该参数会统一作用于 App 的**全部**中继通信与本地 Bridge 启动命令：登录、注册、消息同步、
设置漫游、扫码配对、以及 App 内「一键启动 / 下载 bat / 二维码」里生成的 `--server` 地址。

不传该参数时，默认指向本项目作者的生产环境地址（见 `flutter_app/lib/config/app_config.dart`）。

服务端与官网介绍页同样可配置（见 `.env.example`）：

```bash
cp .env.example .env
# SERVER_BASE_URL      服务端生成 Bridge 启动命令时使用的地址
# VITE_SERVER_BASE_URL 前端静态产物指向的后端地址（默认自适应当前访问域名）
# VITE_ALLOWED_HOSTS   追加 Vite dev server 的 Host 白名单
```

### 4.6 改包名 / 应用名（发布前建议改掉）

- **Android 包名**：`flutter_app/android/app/build.gradle` 里的 `namespace` 与 `applicationId`（当前 `com.lx.app`）
- **Android 桌面显示名**：`flutter_app/android/app/src/main/AndroidManifest.xml` 里的 `android:label`（当前 `LxAI`）
- **Windows 可执行文件名**：`flutter_app/windows/CMakeLists.txt` 里的 `BINARY_NAME`（当前 `LxAI`）

> 仓库里没有 `android/app/src/main/res/values/strings.xml`，`android:label` 直接写在 manifest 中，
> 改完重新打包即可生效（手机桌面上显示的就是它）。

---

## 五、连接你的本地 Agent（Bridge）

Bridge 跑在**无公网 IP** 的那台电脑上，主动向云端建立反向长连接。两种启动方式：

**① 装了 Windows 安装版（推荐）—— 无需任何 Python 环境**

安装器已把 Bridge 脚本与私有 Python 一并装好。在 App 内进入
**设置 → 本地 Agent 设置**，确认「配对 Token」与「Harness 服务地址」后点**「启动」**即可上线；
打开同页的「启动应用时自动启动桥接」开关后，之后每次启动 LxAI 都会自动拉起，无需再手动点。
也支持**由另一台设备（手机端）远程下发启动指令**。

关闭主窗口只是收进托盘（App 与桥接都继续运行）。需要真正退出时，托盘菜单有两项：
「退出 LxAI（桥接保持在线）」与「退出 LxAI 并停止桥接」。若想让手机端随时能连上，
选前者；桥接是脱离 App 独立运行的，不主动停止就会一直在后台保持连接。

**② 免安装 / 手动运行 —— 自己跑脚本**

```bash
pip install websockets
python lxai_bridge.py --token "<App 里显示的配对 Token>" \
                          --server "https://your-domain.com" \
                          --harness-url "http://127.0.0.1:3080"
```

唯一需要的第三方依赖是 `websockets`；未安装时会自动降级为 HTTP 长轮询通道。
也支持环境变量：`SERVER_URL` / `HARNESS_URL`。

**③ 端口填哪个 —— 取决于你用的是哪种 DSH**

桥接连的是本机 DSH 的 HTTP 服务，**端口随 DSH 形态而变**：

| 你用的 DSH | 怎么启动 | 端口 | `--harness-url`（App 里对应「Harness 服务地址」） |
| :--- | :--- | :--- | :--- |
| **桌面版** | 双击 DeepSeek Harness | **19387** | `http://127.0.0.1:19387` |
| **web 版** | `dsh web` | **3080** | `http://127.0.0.1:3080` |
| **npx** | `npx @deepseek-ai/dsh web` | **3080** | `http://127.0.0.1:3080` |

- **19387 是写死的**：桌面版由 `dsh-desktop-host` 以 `--port 19387` 启动，不是随机端口，
  可以放心写进配置或脚本，重启也不会变。
- **3080 是 `dsh web` 的默认端口**，可用 `--port` 覆盖；改了这里也要跟着改。
- **切换形态时只需改一处**：App 的「设置 → 本地 Agent 设置 → Harness 服务地址」，
  改完重启桥接即可。桥接同一时刻只连一个宿主，两种形态不需要同时跑。
- **App 默认预填桌面版的 19387**（2026-10-01 起）。若你用 `dsh web` 或 `npx`，
  把它改成 `127.0.0.1:3080` —— 端口填错时桥接会一直报"连不上宿主"，
  但中继侧仍显示在线，这一点容易误判（见 §七 常见问题）。

两种方式下，App 内「设置 → 本地 Agent 设置」都会给出带 Token 的启动命令、
`run_bridge.bat` 一键脚本与配对二维码。

---

## 六、目录结构

```
├── server.ts                     # 云端中继服务端（鉴权/调度/持久化/漫游/桥接）
├── src/                          # LxAI 官网介绍与下载门户（React）
├── lxai_bridge.py            # Bridge 主程序（反向长连接，唯一真源）
├── flutter_app/                  # Flutter 纯原生多端 App
│   ├── lib/config/app_config.dart    # 全局可配置项（服务器地址等）
│   ├── lib/services/                 # 网络、同步、录音、TTS、本地 Agent
│   ├── lib/providers/                # Provider 状态管理
│   ├── assets/scripts/               # 内置 Bridge 脚本（App 分发给本地电脑）
│   ├── android/  windows/            # 各平台打包配置
│   └── pubspec.yaml
├── installer/                    # Windows 安装器（Inno Setup + 私有 Python 运行时）
├── docs/                         # 设计与集成文档（Token 设计、用户插件）
└── .env.example                  # 自建部署配置示例
```

---

## 七、常见问题

**Q：全新 clone 后直接打包会失败吗？**
不会。三条链路都已验证过开箱可构建：`flutter build windows --release`、
`flutter build apk --release`（debug 签名）、`npm install && npm run build`。
Windows 端首次构建需要 VS C++ 工具链；Android 端需要 SDK 与 JDK。

**Q：构建产物 / 缓存会不会被提交？**
不会。`build/`、`.dart_tool/`、`windows/flutter/ephemeral/`、
`GeneratedPluginRegistrant.java`、`key.properties`、`*.jks` 等均已加入 `.gitignore`。

**Q：`record_platform_interface` 为什么被锁在 1.2.0？**
`record_linux 0.7.2` 尚未适配新版抽象接口，`dependency_overrides` 锁版本是为了避免全平台编译失败，详见 `AGENTS.md`。

**Q：App 提示「未检测到本地 Harness 桥接连接」？**
说明 Bridge 没在运行或连到了别的服务器。确认 `python lxai_bridge.py --server ...`
里的 `--server` 与 App 打包时使用的 `SERVER_BASE_URL` 完全一致。

**Q：桥接明明「已上线」，但手机下发的任务一直失败？**
先查「Harness 服务地址」的**端口** —— 这是最常见的坑：

| 你用的 DSH | 该填 |
| :--- | :--- |
| 桌面版 | `127.0.0.1:19387` |
| `dsh web` / `npx` | `127.0.0.1:3080` |

端口填错时，**中继侧照样显示桥接在线**（它连上的是云端，与宿主无关），但桥接连不上
本机 DSH，于是任务永远发不出去 —— 症状很容易被误判成"桥接没起来"。判定方法：看桥接
日志里有没有 `✓ 成功上线`（连上中继）**以及**后续的目录同步；只有前者就说明是宿主侧
端口不对。详见 §五 ③。

---

## 八、安全提醒

- **签名密钥（`key.properties` / `*.jks`）绝不能入库。** 一旦提交，任何 clone 仓库的人都能签出与你正式包同签名、可覆盖安装的 APK。
- 服务端数据落盘在 `messages_data/`、媒体在 `messages_media/`，两者均已在 `.gitignore` 中，不会误提交用户数据。
- 公网部署请自行配置 HTTPS 反向代理，并妥善保管 `messages_data/settings.json`（内含各用户的 API Key）。

---

## 九、开源许可

本项目以 **Apache License 2.0** 发布，全文见 [`LICENSE`](./LICENSE)，第三方名称与商标说明见 [`NOTICE`](./NOTICE)。

| 你可以 | 你需要 |
| :--- | :--- |
| 自由使用、修改、分发，**包括闭源与商业用途** | 保留版权声明与许可声明（Apache-2.0 第 4 条） |
| 自建中继、自己提供服务 | 若修改后分发，需说明修改过（不得暗示官方背书） |

Apache-2.0 第 6 条明确：**本许可不授予任何商标权**——不得使用本项目的名称做背书。

---

## 十、使用条款、隐私与免责（对外提供服务时必读）

本软件按**“现状”**提供，不附带任何担保；作者不对使用后果承担赔偿责任。**使用者只能对自己拥有所有权或已获合法授权的设备使用远程控制能力。**

- 完整条款：[`TERMS.md`](./TERMS.md)（用户协议 / 服务条款）
- 数据处理说明：[`PRIVACY.md`](./PRIVACY.md)（保存什么、存多久、怎么删）

App 内可在 **设置 → 用户协议 / 隐私政策** 查看，并在登录时确认。

---

## 十一、第三方名称与商标声明

- 本项目为**第三方独立开发**，与任何被兼容或被提及的产品、服务提供方**无任何隶属、合作、赞助或背书关系**。
- 相关名称与标识归其各自权利人所有；本项目仅在**说明兼容性与互操作性**的范围内提及（指称性合理使用），不表示任何官方认证或授权。
- 本项目**不含**任何被兼容产品的官方代码：本地能力通过其对外提供的运行时接口调用。
- 其余第三方组件（Flutter / Dart pub 生态、Node npm 生态等）版权归各自作者所有，完整清单见 App 内「关于 → 开源许可」页。
- 使用本项目访问任何第三方服务时，请遵守对应服务商的条款。

