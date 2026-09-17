<div align="center">

# LxAI · 云端中继监控看板 + 多端 App + 内网穿透 Bridge

**无公网 IP，也能远程遥控内网电脑上的私有 Agent（DeepSeek Harness / 本地模型 / 本地自动化工作区）。**

Flutter 纯原生多端客户端（Android / Windows） · Node + React 云端中继看板 · Python 反向长连接内网穿透

</div>

---

## 一、这套东西是什么

三位一体架构，三部分可以独立部署：

| 模块 | 目录 | 技术栈 | 作用 |
| :--- | :--- | :--- | :--- |
| **① 云端中继服务（含 Web 看板）** | `/`（`server.ts`、`src/`） | Express + TypeScript + React + Vite | 会话鉴权、Token 调度分配、消息持久化与增量漫游、设置云端同步、单点登录互斥、反向信道桥接 |
| **② 多端 App 客户端** | `flutter_app/` | Flutter（纯原生，无 WebView 套壳） | 手机/电脑遥控端：聊天、语音、扫码配对、本地 Agent 控制 |
| **③ 本地反向长连接 Bridge** | `deepseek_bridge.py` | Python 3.8+ | 跑在**无公网 IP** 的电脑上，主动向云端建立反向长连接，把本地 Harness 暴露给 App |

核心能力：单点登录设备互斥（1 台手机 + 1 台电脑）、消息增量漫游、全局设置云端同步、扫码即配对。

---

## 二、环境要求

| 用途 | 需要 |
| :--- | :--- |
| 服务端 / Web 看板 | Node.js **20+**、npm |
| 打包 Flutter App | Flutter **3.44+**（含 Dart 3.12+） |
| 打包 Windows 客户端 | Visual Studio 2022，勾选「使用 C++ 的桌面开发」 |
| 打包 Android 客户端 | JDK 17+、Android SDK（含 build-tools / platform 36） |
| 运行本地 Bridge | Python **3.8+** |

```bash
flutter doctor -v      # 确认 Flutter / VS / Android 工具链齐全
node -v && npm -v
python --version
```

---

## 三、跑起来（服务端 + Web 看板）

```bash
npm install

# 开发模式（Express + Vite 中间件，默认端口 3000）
npm run dev

# 生产模式
npm run build      # 产出 dist/（前端静态产物 + dist/server.cjs）
npm start
```

浏览器打开 `http://localhost:3000` 即可看到中继监控看板。

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

### 4.2 打包 Android

```bash
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

> **注意**：仓库里**不包含任何签名密钥**。没有配置签名时，构建会自动回退到 debug 签名
> —— **可以正常打包自测，但不能用于发布**。要出正式签名包，按下节配置你自己的密钥。

### 4.3 换成你自己的 Android 签名

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

### 4.4 换成你自己的服务器地址

**无需修改任何源码**，打包时用 `--dart-define` 传入即可：

```bash
flutter build apk     --release --dart-define=SERVER_BASE_URL=https://your-domain.com
flutter build windows --release --dart-define=SERVER_BASE_URL=https://your-domain.com
flutter run                                 --dart-define=SERVER_BASE_URL=http://192.168.1.10:3000
```

该参数会统一作用于 App 的**全部**中继通信与本地 Bridge 启动命令：登录、注册、消息同步、
设置漫游、扫码配对、以及 App 内「一键启动 / 下载 bat / 二维码」里生成的 `--server` 地址。

不传该参数时，默认指向本项目作者的生产环境地址（见 `flutter_app/lib/config/app_config.dart`）。

服务端与 Web 看板同样可配置（见 `.env.example`）：

```bash
cp .env.example .env
# SERVER_BASE_URL      服务端生成 Bridge 启动命令时使用的地址
# VITE_SERVER_BASE_URL 前端静态产物指向的后端地址（默认自适应当前访问域名）
# VITE_ALLOWED_HOSTS   追加 Vite dev server 的 Host 白名单
```

### 4.5 改包名 / 应用名（发布前建议改掉）

- 包名：`flutter_app/android/app/build.gradle` 里的 `namespace` 与 `applicationId`（当前 `com.lx.app`）
- 桌面端可执行文件名：`flutter_app/windows/CMakeLists.txt` 里的 `BINARY_NAME`（当前 `LxAI`）

---

## 五、连接你的本地 Agent（Bridge）

在**无公网 IP** 的那台电脑上运行：

```bash
pip install websockets aiohttp urllib3
python deepseek_bridge.py --token "<App 里显示的配对 Token>" \
                          --server "https://your-domain.com" \
                          --harness-url "http://127.0.0.1:3080"
```

也支持环境变量：`SERVER_URL` / `HARNESS_URL`。

App 内「设置 ➔ 🤖 本地 Agent」会直接给出带 Token 的启动命令、`run_bridge.bat` 一键脚本与配对二维码。

---

## 六、目录结构

```
├── server.ts                     # 云端中继服务端（鉴权/调度/持久化/漫游/桥接）
├── src/                          # Web 中继监控看板（React）
├── public/deepseek_bridge.py     # 供 Web 端下载的 Bridge 脚本副本
├── deepseek_bridge.py            # Bridge 主程序（反向长连接）
├── flutter_app/                  # Flutter 纯原生多端 App
│   ├── lib/config/app_config.dart    # 全局可配置项（服务器地址等）
│   ├── lib/services/                 # 网络、同步、录音、TTS、本地 Agent
│   ├── lib/providers/                # Provider 状态管理
│   ├── assets/scripts/               # 内置 Bridge 脚本（App 分发给本地电脑）
│   ├── android/  windows/            # 各平台打包配置
│   └── pubspec.yaml
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
说明 Bridge 没在运行或连到了别的服务器。确认 `python deepseek_bridge.py --server ...`
里的 `--server` 与 App 打包时使用的 `SERVER_BASE_URL` 完全一致。

---

## 八、安全提醒

- **签名密钥（`key.properties` / `*.jks`）绝不能入库。** 一旦提交，任何 clone 仓库的人都能签出与你正式包同签名、可覆盖安装的 APK。
- 服务端数据落盘在 `messages_data/`、媒体在 `messages_media/`，两者均已在 `.gitignore` 中，不会误提交用户数据。
- 公网部署请自行配置 HTTPS 反向代理，并妥善保管 `messages_data/settings.json`（内含各用户的 API Key）。

## License

Apache-2.0
