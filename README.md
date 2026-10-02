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

核心能力：官网邮箱注册与自助注销、单点登录设备互斥（1 台手机 + 1 台电脑）、消息增量漫游、全局设置云端同步、扫码即配对。

> ⚠️ **clone 下来自己部署，请先看 §五「自建 / fork 部署：必须修改的地方」。**
> 仓库里有若干**写死的作者域名与仓库地址**（中继地址、官网下载源、App 更新检查源、Bridge 脚本兜底地址）——
> 不改的话，你的官网会分发作者的安装包、你的 App 会提示更新成作者的包、你的用户桥接会连到作者的服务器。
> 只想跑一个最小实例的话，照 §5.7 的「最小清单」做即可。

---

## 二、环境要求

| 用途 | 需要 |
| :--- | :--- |
| 服务端 / 官网介绍页 | Node.js **20+**、npm |
| 打包 Flutter App | Flutter **3.44+**（含 Dart 3.12+） |
| 打包 Windows 客户端 | Visual Studio 2022，勾选「使用 C++ 的桌面开发」 |
| 打包 Android 客户端 | JDK 17+、Android SDK（含 build-tools / platform 36） |
| 手动运行本地 Bridge | Python **3.8+**（用安装版分发时**用户无需 Python**，见 [4.2](#42-打包成-windows-安装程序推荐分发方式)） |
| 制作 Windows 安装程序（**旧 Inno 版，已不再迭代**） | Inno Setup **6**（见 [`installer/README.md`](./installer/README.md)） |

> ⚠️ **平台支持现状**：App **只适配了 Android 与 Windows**。
> `flutter_app/linux/` 目录不存在、从未为 Linux 构建过，`macos/` `ios/` `web/` 同样没有。
> Linux 的现状、插件缺口与打包路线见 [`docs/TODO.md`](./docs/TODO.md) 第 1 节。
>
> 自研的 Windows 安装器已迁到**独立仓库** `lx00924-lx/lxai-setup-flutter`；
> 本仓库 `installer/` 是旧的 Inno Setup 版（仍能独立构建，只是不再迭代）。
>
> ⚠️ `installer/runtime/python`（私有 Python 运行时）**不要删、不要挪**：新安装器的
> `tool/build-payload.ps1` 硬编码从这里取它。

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

### 3.1 开启「官网注册 / 自助注销」（可选；对外提供服务时建议开）

注册与注销**只在官网进行，App 内没有注册入口** —— App 登录页底部只留一个
「还没有账号？点击前往官网注册」的跳转（用系统默认浏览器打开官网）。

| 功能 | 位置 | 流程 |
| :--- | :--- | :--- |
| **注册** | 官网右上角「注册」 | 填邮箱 → 收邮箱验证码 → 填账号名与密码。**一个邮箱只能注册一个账号**（一邮一号） |
| **注销** | 官网注册弹窗底部「注销账号」 | 验证码发到**该账号绑定的邮箱** → 验证通过后永久删除账号及其云端数据 |

两条链路都强制 **Cloudflare Turnstile** 人机验证，并带发送冷却（60 秒）与频率配额。

> **为什么注册不放 App 里**：邮箱验证码、人机验证这类东西本来就该在浏览器里做；
> 而且官网刻意**没有登录态**，注册流程完全不碰「1 台手机 + 1 台电脑」的单点互斥逻辑
>（网页端一旦登录就得占某个槽位，会牵动那套很微妙的互斥判断）。

不配置下面两项时，注册接口会**明确返回 503 / 拒绝**，不会静默失败：

```bash
cp .env.example .env
# —— 第一段：SMTP 发信（验证码邮件）——
# SMTP_HOST / SMTP_PORT / SMTP_SECURE / SMTP_USER / SMTP_PASS / SMTP_FROM / SMTP_FROM_NAME
#   用邮箱服务商给的**授权码**，不要用登录密码。
#   ⚠️ SMTP_SECURE 的语义是「连上就立刻 TLS（隐式 TLS）」而不是「启用加密」：
#      465 填 1；587 是"先明文再 STARTTLS"，必须填 0，否则报
#      SSL routines:tls_validate_record_header:wrong version number。
#      0 / false / no / off 都算假。
# —— 第二段：Cloudflare Turnstile ——
# TURNSTILE_SECRET        服务端密钥（只给后端，绝不要放进前端）
# VITE_TURNSTILE_SITE_KEY 前端站点密钥，**构建时**注入 —— 改完要 npm run build 才生效
```

> **注销会删什么、不删什么**（页面完成时会如实回显实际删除项）：
> `users.json`（账号本体）、`messages_v2.json`（聊天记录）、`settings.json`（云端设置）、
> `active_sessions.json`（登录槽位）里该账号的部分会被删除；
> **`messages_media/` 里的图片 / 语音等媒体文件不删** —— 那些文件名是随机生成的、不含用户信息，
> 无法可靠判定归属，宁可少删也不误删他人的文件。要支持得先把上传改成"按 userId 建子目录"。
>
> 另外，注册功能上线前创建的**老账号没有绑定邮箱**，无法邮箱验证自助注销，接口会返回 409 并说明原因。

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

该参数会统一作用于 App 的**全部**中继通信与本地 Bridge 启动命令：登录、消息同步、
设置漫游、扫码配对、以及 App 内「一键启动 / 下载 bat / 二维码」里生成的 `--server` 地址。
登录页「还没有账号？点击前往官网注册」按钮打开的地址同样取自它 ——
所以自建部署时**不需要改任何源码**，注册链接会自动指向你自己的站点。

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

## 五、自建 / fork 部署：必须修改的地方

> 这一节是给「clone 下来自己部署」的人的核对清单。**每一项都实测过"不改会怎样"**，
> 不是泛泛而谈。只想要一个能跑的最小实例，照文末的「最小清单」做即可。

### 5.1 服务端（`server.ts` + `.env`）

| 要改什么 | 在哪 | 不改会怎样 |
| :--- | :--- | :--- |
| **对外地址** | `.env` 的 `SERVER_BASE_URL` | 生成的 Bridge 启动命令、`run_bridge.bat`、配对二维码**全部指向作者的域名** —— 你的用户会把桥接连到别人的服务器上 |
| **SMTP 发信** | `.env` 的 `SMTP_HOST/PORT/SECURE/USER/PASS/FROM/FROM_NAME` | 注册与注销的验证码发不出去（接口**明确返回 503**，不会假装成功）。用你自己的邮箱**授权码**，不是登录密码 |
| **Turnstile** | `.env` 的 `TURNSTILE_SECRET` + **构建期**的 `VITE_TURNSTILE_SITE_KEY` | ⚠️ **必须在你自己的 Cloudflare 账号里、为"你自己的域名"新建一个 widget**。直接填作者的 key 会因为域名不匹配而**永远校验失败**，且报错只说"人机验证未通过" |
| **反代的真实 IP** | 代码里无需改（`server.ts` 的 `clientIpOf()`），但**反代要配对** | `clientIpOf()` 先读 `CF-Connecting-IP`、再读 `X-Forwarded-For` 的**第一段**。用 nginx / Caddy 时，反代必须**覆盖**该头（`proxy_set_header X-Forwarded-For $remote_addr;`）而**不是追加**（`$proxy_add_x_forwarded_for`）—— 追加的话客户端可以自己塞一个假 IP，**绕过注册限流，还能栽赃到别人 IP 上**。作者的部署走 Cloudflare，源站没有公网端口，所以那个头伪造不了；你的部署不一定有这个前提 |
| **加密主密钥** | `<部署目录>/.secrets/master.key`（可用 `SETTINGS_ENC_KEY` 覆盖） | 不备份 → 磁盘挂了以后所有用户的 API Key / Agent Token **永久解不开**；泄露 → 等于泄露全部用户的密钥。也可以设 `STORE_API_KEYS=0` 让密钥根本不落盘 |
| **Vite Host 白名单** | `vite.config.ts` 的 `allowedHosts`，用 `.env` 的 `VITE_ALLOWED_HOSTS="a.com,b.com"` 追加 | 开发模式下 Vite 会拒绝你的域名 |
| **HTTPS** | 反向代理 | 明文暴露登录口令、配对 Token 与全部消息 |

### 5.2 官网（`src/`）

| 要改什么 | 在哪 | 不改会怎样 |
| :--- | :--- | :--- |
| **Release 分发源 / 全部 GitHub 链接** | `.env` 的 `VITE_GITHUB_REPO="你的用户名/你的仓库"` | 你官网上「下载」区会列出并分发**作者的安装包**，导航栏 / Hero / 页脚 / 下载按钮也全部跳到原仓库 |
| **页面文案里的域名** | 无需改（`Architecture.tsx` 用 `getSiteHost()` 从 `VITE_SERVER_BASE_URL` 推导） | — |

> `VITE_GITHUB_REPO` 不填时回落到 `src/config.ts` 里的 `DEFAULT_GITHUB_REPO`。
> ⚠️ Vite 的环境变量是**构建期静态替换**，改完必须重新 `npm run build` 才生效。

### 5.3 App（`flutter_app/`）

| 要改什么 | 在哪 | 不改会怎样 |
| :--- | :--- | :--- |
| **中继地址** | 打包时 `--dart-define=SERVER_BASE_URL=https://你的域名` | 登录、消息同步、设置漫游、扫码配对、桥接启动命令**全部指向作者的服务器**。登录页「前往官网注册」按钮打开的地址也取自它 |
| **更新检查 / "官方仓库"** | 打包时 `--dart-define=GITHUB_OWNER=你的用户名 --dart-define=GITHUB_REPO=你的仓库` | App 会去查**作者的** Releases 并提示"有新版本"，用户点下去就装成**作者的包**。<br>⚠️ 这两个值随包固化，**故意设了空 setter 忽略云端/缓存写入**（防"设置被同步成别人的仓库"），所以只能靠 `--dart-define` 或改源码，**不能在设置界面里改** |
| **包名 / 显示名** | `android/app/build.gradle` 的 `namespace` 与 `applicationId`；`AndroidManifest.xml` 的 `android:label`；`windows/CMakeLists.txt` 的 `BINARY_NAME` | 与官方包**签名冲突、无法并存安装**，覆盖安装还会清掉用户数据 |
| **版本号（两处，要一致）** | `pubspec.yaml` 的 `version` **和** `lib/models/app_settings.dart` 的 `currentVersion` / `currentBuildNumber` | 更新判断错乱（App 以为自己是旧版，反复提示更新） |
| **Bridge 脚本（两份！）** | 仓库根 `lxai_bridge.py` **和** `flutter_app/assets/scripts/lxai_bridge.py` | 这两份是**逐字节相同的副本**（当前 SHA256 一致），**没有自动同步机制**。只改一份的话，App 分发给用户 / 导出的桥接脚本会回落到作者的服务器（脚本里的 `FALLBACK_SERVERS` 也写死了作者域名和两个已失效的 Cloud Run 地址） |
| **Android 签名** | `android/key.properties` + `android/app/AI.jks` | 用 debug 签名，无法发布。见 [4.4](#44-换成你自己的-android-签名) |

### 5.4 Windows 安装器（`installer/`）

| 要改什么 | 在哪 | 不改会怎样 |
| :--- | :--- | :--- |
| 应用名 / 发布者 / 产物名 | `installer/lxai-setup.iss` 的 `MyAppName`、`MyAppPublisher`、`OutputBaseFilename` 等（都在文件头部的 `#define` 区） | 装出来叫「LxAI」、发布者是作者 |
| **安装标识 GUID** | 同文件 `MyAppId` | ⚠️ 这里要求**恰好相反的两件事**，别搞混：<br>• **同一条产品线内永远不要改** —— 卸载程序靠它认出"这是同一个应用"，改了会在控制面板留下**删不掉的旧版本**；<br>• **fork 出去做成另一个产品时必须换成新的 GUID** —— 否则两个应用被 Windows 当成同一个，互相顶掉、卸载一个会把另一个也带走。 |

### 5.5 品牌（可选，但工作量大）

`LxAI` 在源码里出现 **92 处**、`Aether-X` **10 处**。要整套改名，至少覆盖这些地方：

- 官网：`index.html` 的 `<title>` 与 `og:*`、`metadata.json`
- App：`flutter_app/pubspec.yaml` 的 `name` / `description`、`lib/widgets/legal_documents.dart`
- 安装器：`installer/lxai-setup.iss` + `installer/assets/wizard-*.png`
- 图标：**唯一来源是 `tools/make_icons.py`** —— 改脚本里的设计参数后跑 `python tools/make_icons.py`，
  它会一次重生成 22 个文件（Android mipmap 全套 / Windows ico / 托盘 4 态）。**不要手工贴图**
- `NOTICE`（署名与商标声明）
- 邮件发件人显示名：`.env` 的 `SMTP_FROM_NAME`（**这个已经是环境变量，不用改代码**）

### 5.6 许可（Apache-2.0，改了要怎么做）

保留 `LICENSE` 与 `NOTICE` 里的版权与许可声明；**分发修改版时在 `NOTICE` 里说明你改了什么**
（Apache-2.0 第 4(b) 条），并且**不得暗示官方背书**（第 6 条明确不授予商标权）。

### 5.7 最小清单（只要一个能跑的自己实例）

```bash
# 1) 服务端
cp .env.example .env
#    SERVER_BASE_URL          = https://你的域名
#    SMTP_*                   = 你自己的邮箱授权码
#    TURNSTILE_SECRET         = 你自己 Cloudflare 账号里的 secret
#    VITE_TURNSTILE_SITE_KEY  = 同一个 widget 的 site key
#    VITE_ALLOWED_HOSTS       = 你的域名
#    VITE_GITHUB_REPO         = 你的用户名/你的仓库   ← 否则官网分发的是作者的安装包
npm install && npm run build && npm start

# 2) 反代 + HTTPS，并让反代【覆盖】X-Forwarded-For

# 3) App
cd flutter_app
flutter build windows --release \
  --dart-define=SERVER_BASE_URL=https://你的域名 \
  --dart-define=GITHUB_OWNER=你的用户名 \
  --dart-define=GITHUB_REPO=你的仓库
```

> 上面这几项**全都有配置入口，不需要改任何源码**。真正只能改源码的是第 5.4 / 5.5 节的
> 「安装器品牌」与「品牌名」—— 那属于"要不要做成自己的产品"的选择，不是能不能跑起来的前提。

---

## 六、连接你的本地 Agent（Bridge）

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

**③ TLS 证书校验（默认开启，别随手关掉）**

桥接**默认校验中继的 TLS 证书与主机名**（`ssl.create_default_context()`）。
证书校验失败时会**明确报错并拒绝继续**，而不是降级重试：

```
[✗ TLS 证书校验失败] 无法确认对端就是真的中继服务器：
    可能有人在中间人劫持，也可能是对端证书过期 / 自签名。
    桥接已拒绝继续 —— 配对 Token 一旦泄露，对方就能驱动你这台电脑上的 Agent。
```

为什么这么严：桥接与中继之间传递的是**配对 Token**，拿到它就能驱动你这台电脑上的
本地 Agent。如果能做中间人的攻击者（恶意 Wi-Fi、被劫持的代理、装了根证书的抓包工具）
可以冒充中继，那么"能连上"反而是最坏的结果。

确实需要放开的环境（**自签名证书的自建中继**、企业 MITM 代理）走**显式**开关，且启动时会打印醒目警告：

```bash
python lxai_bridge.py ... --insecure          # 等价于环境变量 LXAI_INSECURE_TLS=1
```

> ⚠️ 历史版本这里是无条件 `CERT_NONE` + `check_hostname=False` —— 也就是**根本不验证书**，
> 而且 WebSocket 链路和 HTTP 长轮询链路行为还不一致（前者走库默认值会验、后者不验）。
> 2026-10-02 已统一为"默认校验、显式降级"。用 App 启动桥接时它不传 `--insecure`，
> 需要放开的话设系统环境变量 `LXAI_INSECURE_TLS=1`。

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
  但中继侧仍显示在线，这一点容易误判（见 §八 常见问题）。

两种方式下，App 内「设置 → 本地 Agent 设置」都会给出带 Token 的启动命令、
`run_bridge.bat` 一键脚本与配对二维码。

---

## 七、目录结构

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

## 八、常见问题

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
端口不对。详见 §六 ③。

---

## 九、安全提醒

- **签名密钥（`key.properties` / `*.jks`）绝不能入库。** 一旦提交，任何 clone 仓库的人都能签出与你正式包同签名、可覆盖安装的 APK。
- **`.env` 里的 SMTP 授权码与 Turnstile Secret 等同密码。** 拿到 SMTP 授权码就能用你的邮箱发信（会被用来发钓鱼邮件，后果算在你头上），拿到 Turnstile Secret 就能绕过人机验证批量注册。`.env` 已被 `.gitignore` 忽略，**不要提交、不要贴进聊天记录或截图**；怀疑泄露时去邮箱服务商后台重置授权码、在 Cloudflare 控制台轮换 Secret。
- **`<部署目录>/.secrets/master.key` 是全部用户密钥的总钥匙。** 丢了 → 用户填的 API Key / Agent Token 永久解不开；泄露 → 等于泄露所有用户的密钥。要单独备份，**且不要和 `messages_data/` 放在同一个备份里**（那正是这一层设计要防的场景）。
- **别关掉桥接的 TLS 证书校验。** `--insecure` / `LXAI_INSECURE_TLS=1` 只给自签名中继与企业代理用；开着它时，同网络里能做中间人的人可以冒充中继拿到配对 Token（= 直接驱动你电脑上的 Agent）。见 §六 ③。
- **公网部署时，反代必须"覆盖"而不是"追加" `X-Forwarded-For`**，否则客户端能伪造 IP 绕过注册限流、或把限流栽赃到别人 IP 上。见 §5.1。
- 服务端数据落盘在 `messages_data/`、媒体在 `messages_media/`，两者均已在 `.gitignore` 中，不会误提交用户数据。
- 公网部署请自行配置 HTTPS 反向代理，并妥善保管 `messages_data/settings.json`（内含各用户的 API Key）。

---

## 十、开源许可

本项目以 **Apache License 2.0** 发布，全文见 [`LICENSE`](./LICENSE)，第三方名称与商标说明见 [`NOTICE`](./NOTICE)。

| 你可以 | 你需要 |
| :--- | :--- |
| 自由使用、修改、分发，**包括闭源与商业用途** | 保留版权声明与许可声明（Apache-2.0 第 4 条） |
| 自建中继、自己提供服务 | 若修改后分发，需说明修改过（不得暗示官方背书） |

Apache-2.0 第 6 条明确：**本许可不授予任何商标权**——不得使用本项目的名称做背书。

---

## 十一、使用条款、隐私与免责（对外提供服务时必读）

本软件按**“现状”**提供，不附带任何担保；作者不对使用后果承担赔偿责任。**使用者只能对自己拥有所有权或已获合法授权的设备使用远程控制能力。**

- 完整条款：[`TERMS.md`](./TERMS.md)（用户协议 / 服务条款）
- 数据处理说明：[`PRIVACY.md`](./PRIVACY.md)（保存什么、存多久、怎么删）

App 内可在 **设置 → 用户协议 / 隐私政策** 查看，并在登录时确认。

---

## 十二、第三方名称与商标声明

- 本项目为**第三方独立开发**，与任何被兼容或被提及的产品、服务提供方**无任何隶属、合作、赞助或背书关系**。
- 相关名称与标识归其各自权利人所有；本项目仅在**说明兼容性与互操作性**的范围内提及（指称性合理使用），不表示任何官方认证或授权。
- 本项目**不含**任何被兼容产品的官方代码：本地能力通过其对外提供的运行时接口调用。
- 其余第三方组件（Flutter / Dart pub 生态、Node npm 生态等）版权归各自作者所有，完整清单见 App 内「关于 → 开源许可」页。
- 使用本项目访问任何第三方服务时，请遵守对应服务商的条款。

