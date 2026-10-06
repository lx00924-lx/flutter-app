# LM Studio Bionic 四项能力调研（含信息来源与不确定性标注）

> 调研日期：2026-10-03　｜　调研对象：**LM Studio Bionic**（Element Labs, Inc. 出品，与 LM Studio 本体是两个独立应用）
> 当前最新版：**Bionic 1.1.7 (build 7)**，发布于 2026-10-01
>
> **证据分级约定**
> - 【官方】= lmstudio.ai 官方文档 / 官方 changelog / 官方博客 明确写了
> - 【实测】= 本次调研在本机文件系统 / 网络端点上的直接观察（非官方文档）
> - 【第三方】= 非 Element Labs 的第三方文档（如 Jumper、Cloudflare、博客），可信但非官方
> - 【未找到】= 官方或可靠来源中查不到依据，**不能确认**，本文不做推测性断言

---

## 问题 1：Bionic 有没有对外开放的可编程接口？

### 结论

**没有面向"驱动 Bionic agent"的可编程接口。**

- 官方文档全站无任何 Bionic 的开发者 / API / 本地端口 / CLI / headless 章节 →【官方（以缺失为证）】
- Bionic 内部自带一个 **OpenAI 兼容的本地模型推理服务（端口 1234）**，但它**只做模型推理**，不承载 Bionic 的 agent 会话 →【第三方 + 实测】
- **没有 CLI、没有 headless 模式**（CLI/headless 全部属于 LM Studio 本体的 `lms` / `llmster`）→【官方 + 实测】
- 官方 issue 追踪器里，**"从外部应用访问/监控 Bionic" 仍是一条 open 的功能请求**，等于官方尚未提供该能力 →【第三方（官方仓库 issue）】

### 证据

**（1）官方文档结构里根本没有 Bionic 的开发者页**

官方文档仓库 `lmstudio-ai/docs` 的完整文件树（`GET https://api.github.com/repos/lmstudio-ai/docs/git/trees/main?recursive=1`，实测拉取）中，Bionic 侧只有这些页面：

```
0_bionic/0_root/index.mdx                     → /docs/bionic
0_bionic/0_root/projects-and-sessions.md
0_bionic/0_root/quick-start.md
0_bionic/1_accounts-plans-and-billing/...
0_bionic/2_agent/{code-project,skills,work-project}.mdx
0_bionic/4_models/{index,download-local-models}.mdx
0_bionic/5_voice-input/index.md
```

**没有** api / settings / mcp / server / cli / headless 任何一页。实测 `https://lmstudio.ai/docs/bionic/api.md`、`/docs/bionic/settings.md`、`/docs/bionic/agent/mcp.md` 全部返回 **404**。

对照：LM Studio 本体的开发者文档在 `1_developer/` 下，含 `0_core/mcp.mdx`、`0_core/headless.md`、`2_rest/`、`3_cli/` —— 这些**全部是 LM Studio 本体的**，不是 Bionic 的。

来源：<https://lmstudio.ai/docs/bionic>、<https://lmstudio.ai/docs/developer>

**（2）Bionic 确实自带端口 1234 的模型推理服务，但仅限推理**

Jumper（第三方 App）的官方集成文档写得最明确：

> "Jumper's `get_thumbnail` tool writes a JPEG to disk and returns the path to it. The `describe_thumbnail` tool then sends that image to a local OpenAI-compatible server on port `1234`... **Bionic starts that server itself, with just-in-time model loading**, so there is nothing to switch on. You will find it under **Settings → Local Model API**, or you can confirm it from a terminal: `curl http://localhost:1234/v1/models`
> LM Studio requires you to start the same server by hand from the menu bar every time. **Bionic does not.**"

来源：<https://docs.getjumper.io/guides/bionic>

> ⚠️ 关键限定：Jumper 文档描述的这个 1234 服务的**唯一用途是"把图片发给模型拿描述"**，也就是纯粹的模型推理。**没有任何来源显示可以通过 1234 端口把消息送进 Bionic 的 agent 会话、或拿到 agent 的回复。**

**（3）Bionic changelog 承认存在"本地 API server"设置项，但未定义其 agent 语义**

Bionic 1.0.8（2026-08-17）release notes 原文：

> "Fixed **local API server** start/stop errors not appearing in settings."

来源：<https://lmstudio.ai/changelog/bionic-v1.0.8>

同时 Bionic 1.1.0（2026-08-27）release notes 提到：

> "Support for Images in tool call results in the **/v1/responses, /v1/chat/completions, and /v1/messages** APIs"

来源：<https://lmstudio.ai/changelog/bionic-v1.1.0>

⚠️ 这两个端点集合与 LM Studio 本体的 OpenAI 兼容 + Anthropic 兼容端点完全一致。**官方从未说明这些端点可访问 Bionic 的会话**。

**（4）端口 1234 是"共用"，不是"Bionic 的 agent 入口"**

- LM Studio 本体的 1234 端点官方文档：`GET /v1/models`、`POST /v1/chat/completions`、`POST /v1/embeddings`、`POST /v1/completions`（来源：<https://lmstudio.ai/docs/developer/openai-compat>）
- Jumper 文档明确两者共享同一个 `~/.lmstudio` 配置目录与 `mcp.json`，并各自都能起 1234

**结论：外部程序通过 1234 只能得到"模型推理"，得不到 Bionic 的 agent 会话。**

**（5）本机实测：1234 默认不监听**

```
port 1234 : not listening      ← Bionic 未运行 / 本地模型 API 未开启
port 3080 <- pid 2796 node     ← DSH Web GUI
port 3000 <- pid 7636 node     ← 本项目中继
```

【实测，2026-10-03，本机】Bionic 配置文件 `C:\Users\lx\.lmstudio\apps\bionic\settings.json` 中 `"enableLocalService": false`——即本地服务**默认关闭**。

**（6）没有 CLI / headless**

- Bionic 是纯 GUI 桌面应用，官方文档站无 CLI 章节。
- `lms`（LM Studio CLI）与 `llmster`（headless daemon）都明确归属 LM Studio 本体：官方文档 "Install `llmster` for headless deployments — `llmster` is LM Studio's core, packaged as a daemon for headless deployment on servers, cloud instances, or CI. The daemon runs standalone, and it is not dependent on the LM Studio GUI."
  来源：<https://lmstudio.ai/docs/developer>
- Bionic 1.1.7 changelog 只提到 "`lms` runtime installations now show installation progress"，即 Bionic 内部**调用** `lms` 装运行时，而不是 Bionic 自己有 CLI。

**（7）官方仓库 issue：外部访问仍是未实现的功能请求**

`lmstudio-ai/lmstudio-bug-tracker` issue **#2328「Request MCP server for Bionic」**（2026-08-26 提出，**state: open**，0 条回复）：

> "i want to access & monitor bionic from another app/ agent."

来源：<https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2328>

issue **#2468**（2026-10-02，open）"Encrypted companion access to Bionic sessions from a smartphone" 更直白地描述现状：

> "**there is no way to check on or continue a session from the device we actually carry around all day — the smartphone.**
> Today the only routes are **power-user setups (exposing the local REST API over a VPN such as Tailscale)**. Non-technical users have nothing; and even for power users, **there is no mobile-aware view of Bionic sessions.**"

来源：<https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2468>

> 📌 这条 issue 是**问题 1 的最强证据**：连"把 Bionic 会话暴露到手机"都还需要用户自己拿 VPN 转发本地 REST API，且作者明确说该 REST API 连的是 "LM Studio's **engines**"（引擎），并直言"没有 Bionic 会话的视图"。

---

## 问题 2：Bionic 能不能自定义人格 / 系统提示？

### 结论

**分三小问：**

| 子问题 | 结论 |
| --- | --- |
| 能设 system prompt / persona / 自定义指令吗？ | **官方文档未记载任何此类设置项；未找到官方依据，不能确认** |
| 能自定义行为吗？ | **能，但唯一官方途径是 Skills（`SKILL.md`），不是"人格/系统提示"** |
| 能加载自己微调的本地模型吗？ | **能（GGUF/MLX，经 LM Studio 运行时），但官方文档未覆盖"自行导入本地文件"的完整路径** |

### 证据

**（1）官方文档里只有一个"行为定义"入口：Skills**

> "**Skills** let you give Bionic reusable instructions for a specific capability, body of knowledge, or repeatable task. They use the standard **Agent Skills** format: a `SKILL.md` file with instructions and optional supporting files.
> If you already have a `SKILL.md` file, add it in **Settings → Skills** to make it available to Bionic.
> To manage these skills, go to **Settings → Skills → Use skills found in other apps**."

来源：<https://lmstudio.ai/docs/bionic/agent/skills>

**（2）官方文档没有任何 "system prompt" / "persona" / "custom instructions" 页面**

- 实测 `/docs/bionic.md`（官方原始 Markdown 源）全文无 system prompt / persona / instructions 字样。
- 官方文档树（见问题 1 第 1 条）中**没有 Settings 类页面**。

**（3）本机实测：Bionic 的配置结构里根本没有人格字段**

【实测，本机】`C:\Users\lx\.lmstudio\apps\bionic\.internal\settings.json` 的完整顶层结构：

```json
{
  "appLanguage", "bionicLocalModelLogsLineLimit", "desktopControl",
  "dismissedContentIdentifiers", "appearance", "browser", "cloudInference",
  "developer", "downloads", "miniWindow", "notifications", "onboarding",
  "localModels", "skills", "sessions", "voice", "updates"
}
```

其中与"行为定义"相关的只有两项：

```json
"skills": {
  "globalSkillOverrides": [],
  "enabledOtherHarnessDirectories": []      ← 对应官方说的 "Use skills found in other apps"
},
"sessions": {
  "reviewerPreference": "",                 ← 仅用于 shell 命令的 Auto Review 权限判断
  "reviewerPreferenceEnabled": false,
  ...
}
```

**没有 `systemPrompt` / `persona` / `instructions` / `customInstructions` / `agentPrompt` 等任何字段。**

【实测，本机】每个项目的配置 `C:\Users\lx\.lmstudio\apps\bionic\projects\<uuid>\project.json` 内容**仅有两行**：

```json
{ "name": "Default Project", "projectType": "regular" }
```

→ **项目级别也没有系统提示字段。**

**（4）⚠️ 需要纠正一条流行但未经官方确认的说法**

第三方博客 <https://gyanaangan.in/blog/lm-studio-bionic-system-prompts-for-coding-agents-templates-you-can-actually-copy>（2026-09-12）声称：

> "the system prompt you set generally applies **at that project level**"
> "Bionic's project structure lets you set a system prompt per project"

**但该博客未给出 UI 截图、设置项名称或官方链接，且与上述本机配置结构（project.json 无该字段）不符。本调研无法在官方文档或本地配置中复现该说法 → 标记为【未经证实】，不应据此设计架构。**

（该博客同时也**没有**说是通过什么界面设置的，全篇只是给出可粘贴的提示词模板文本。）

**（5）能用自己的模型——能，走 LM Studio 运行时**

> "Downloaded models can run on your computer without using cloud inference credits.
> Open **Settings** → **Local Models** → **Library** to see indexed models on the device. Then open a Bionic session and select the model from the list to use it in a session."

来源：<https://lmstudio.ai/docs/bionic/models/download-local-models>

> "**Local models in Bionic are powered by the LM Studio runtime.**"

来源：官方博客 <https://lmstudio.ai/blog/introducing-lm-studio-bionic>

【第三方】Jumper 文档补充了配置目录共享的关键事实：

> "Bionic and LM Studio are made by the same team and **share a configuration directory, `~/.lmstudio`**... That covers `mcp.json`, **your downloaded models, and more besides.** In practice you can install both, configure Jumper once, and switch between them freely. **Models you have already downloaded show up in either app.**"

来源：<https://docs.getjumper.io/guides/bionic>

【实测，本机】Bionic 的 `downloadsFolder` 指向 `C:\Users\lx\.lmstudio\models`，与 LM Studio 本体同一个模型目录；Bionic 自身的配置文件在 `C:\Users\lx\.lmstudio\apps\bionic\`（独立子目录）。

【第三方】第三方教程提到可"Point Bionic at a local OpenAI-compatible endpoint"，但**官方文档未见此功能的说明** → 标记为【未经官方证实】。
来源：<https://synapsewire.com/en/posts/lm-studio-bionic-local-agent-tutorial-2026/>

> **⚠️ 关于"自行导入微调模型"**：官方 **Bionic 文档只写了"从 Bionic 内下载模型"**；"导入外部 GGUF/MLX 文件"的官方说明只在 **LM Studio 本体**文档里（`lms import` / 模型目录结构，来源 <https://lmstudio.ai/docs/cli>、llms-full.txt 的 "Import Models" 节）。因两应用共享 `~/.lmstudio/models`，**路径上是通的**【第三方+实测】，但**Bionic 官方文档未覆盖该流程**。

---

## 问题 3：Bionic 的 MCP 支持是客户端还是服务端？（最关键）

### 结论

**(a) 是 MCP 客户端 —— 确认，且能添加自定义本地 MCP server。**【第三方证据充分】
**(b) 不是 MCP 服务端 —— 确认没有。**【官方文档无 + 官方仓库有 open 的功能请求】

### 证据 —— (a) MCP 客户端

**配置位置：Settings → Connected Apps**

Jumper 官方集成文档（第三方，但给出了完整可复现的 UI 路径与截图）：

> "Go to **Settings → Connected Apps**, find **Manual MCP server setup**, and click **+ Add custom MCP**.
> Fill in the configuration:
> - **Name**: `Jumper`
> - **Connection**: **Web address**. Jumper runs as a local server rather than a command, so **On this computer** is the wrong option here.
> - **Server address**: `http://127.0.0.1:6699/mcp`
> - **Authentication**: **Automatic**
>
> Click **Add MCP**, then quit and reopen Bionic. Connections do not always take effect until you restart."

来源：<https://docs.getjumper.io/guides/bionic>

**两条本地 MCP 配置途径都支持：**

> "Prefer to edit a config file? **Bionic reads the same `mcp.json` that LM Studio uses**, which lives at `~/.lmstudio/mcp.json`... Because the two apps share this file, setting Jumper up in one of them configures it in the other."

```json
{
  "mcpServers": {
    "jumper": {
      "url": "http://127.0.0.1:6699/mcp"
    }
  }
}
```

→ **`127.0.0.1:PORT` 形式的本地 HTTP MCP server 明确支持**；`command` 形式的 stdio MCP server 也支持（见下）。

**Cloudflare 官方文档交叉验证（第三方，大厂文档）：**

> "In Bionic, add Cloudflare as a **remote Model Context Protocol (MCP) server** using the following URL: `https://mcp.cloudflare.com/mcp`"
> "When Bionic prompts you, complete the OAuth authorization flow in your browser and choose the permissions to grant."

来源：<https://developers.cloudflare.com/agent-setup/bionic/>

**本机实测证据链（最强）：**

【实测，本机】`C:\Users\lx\.lmstudio\mcp.json` 已存在并配置了**两个本地 stdio MCP server**：

```json
{
  "mcpServers": {
    "tian qi":  { "command": "python", "args": ["F:\\ai\\MCP\\天气.py"] },
    "lian wang": { "command": "python", "args": ["F:\\ai\\MCP\\联网.py"] }
  }
}
```

→ 证明 `command` + `args`（本地进程 stdio）形式的自定义 MCP server 是被读取的。

【实测，本机】Bionic 配置里存在对应开关：

```json
"skills": { "enabledOtherHarnessDirectories": [] }
```

【实测，本机】Bionic 发现技能/外部 harness 时**实际读取的目录**（这些目录在本机存在）：

```
C:\Users\lx\.lmstudio\skills      (存在，空)
C:\Users\lx\.agents\skills        (存在，含 dsh-fix-duplicate-loader-id)
C:\Users\lx\.codex\skills         (存在，含 .system/*)
```

官方 changelog 侧证（`https://lmstudio.ai/changelog`）：

- Bionic 1.0.2（2026-07-19）："修复 **MCP OAuth** 相关问题，包括公共发现、重新认证和自定义作用域。"（<https://lm-studio.cn/changelog/bionic-v1.0.2> 中文镜像；英文原文见 changelog 列表）
- Bionic 1.0.8（2026-08-17）："Clearer button to complete authentication for **OAuth MCP servers**."
- Bionic 1.1.3（2026-09-15）："**Request timeout controls for custom MCP servers.**" + "**Organization-managed MCPs** for enterprise deployments."
- Bionic 1.1.3："Fixed per-folder skill toggles and **`.agents` skill discovery**."（1.0.8 条目）

→ "custom MCP servers" 一词在官方 changelog 中出现，佐证用户可添加自定义 MCP server。

**⚠️ 已记录的 MCP 客户端缺陷（来自官方 issue 追踪器，非官方文档）：**

- **#2469**（open，2026-10-02）："Duplicate MCP tool names across servers are **shadowed instead of namespaced**"——两个 MCP server 暴露同名工具时，后者覆盖前者。复现：Linear MCP 与 GitHub MCP 都有 `list_issues`，同时启用时只有 GitHub 的可用。
  来源：<https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2469>
- **#2338**（open）："Bionic **silently truncates MCP text tool results at 50,000 characters** with no continuation mechanism"
- **#2415**（open）："MCP callback url options needed - can't use MCP"
- **#2356**（open）："MCP Stdio client fails to render multi-line stdout output"
- 另有 #2242（Slack MCP server 运行正常但未暴露给 agent）、#2361（MCP registration 不发送 `grant_types`/`response_types`）

### 证据 —— (b) 不是 MCP 服务端

**（1）官方文档与 changelog 中零证据**

- 官方文档树（问题 1 第 1 条）中 Bionic 侧无 MCP 页面；`/docs/bionic/agent/mcp.md` 实测 **404**。
- `https://lmstudio.ai/changelog` 全 18 条 Bionic release notes（实测抓取分页）中，**没有任何一条提到 Bionic 对外暴露 MCP server / 提供 MCP 端点**。
- 官方文档中唯一的 MCP **服务端**内容在 LM Studio 本体的开发者文档 `1_developer/0_core/mcp.mdx`，讲的是 **LM Studio 作为 MCP 客户端**（"Using MCP via API"），也不是对外当服务端。
  来源：<https://lmstudio.ai/docs/developer/core/mcp>

**【未找到】任何官方来源说明 Bionic 可作为 MCP 服务端。不能确认该能力存在。**

**（2）官方仓库 feature request #2328 反证**

标题即 "**Request MCP server for Bionic**"（2026-08-26，**open**，0 评论）：

> "i want to access & monitor bionic from another app/ agent."

来源：<https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2328>

→ 若已具备该能力，此请求不会以 open 状态存在且无人指出"已经有了"。

---

## 问题 4：平台支持现状

### 结论

| 平台 | 是否发布 | 依据 |
| --- | --- | --- |
| **macOS Apple Silicon (arm64)** | ✅ **已发布** | 下载页 `Download Bionic` 重定向 + 安装包 200 |
| **Windows x64** | ✅ **已发布** | 下载页明确给出按钮 + 安装包 200 |
| **Windows ARM64** | ✅ 有构建（下载页未列入口） | 安装包路径 200 |
| **Linux x64** | ✅ **已发布** | changelog 1.1.2 + 安装包 200 |
| **Linux ARM64** | ✅ 有构建（下载页未列入口） | changelog 1.1.2 + 安装包 200 |
| **macOS Intel (x64)** | ❌ **未发布（404）** | 安装包路径 404 + 官方系统要求"Intel Macs are currently not supported" |

**→ Windows 版已发布，用户的机器可以用。**

### 证据

**（1）下载页实际内容**

`https://lmstudio.ai/download` 实测抓取，页面有**两块分别的下载区**：

> **Download LM Studio Bionic** — "An agent made for open models. Natively local. Built for creativity, work, and code."
> `[Microsoft_logo] Download Bionic for Windows` → `/download/bionic/latest/win32/x64?redirectVersion=2`
>
> **Download LM Studio** — "Experiment with LLMs on your computer. Chat interface and programmable API."
> `[Download LM Studio for Windows　0.4.25]`

来源：<https://lmstudio.ai/download>

⚠️ 下载页的**自动平台探测**只渲染出 Windows 按钮；这与本机是 Windows 一致。macOS/Linux 入口需换平台 UA 或直接用 URL 探测（下面做了）。

**（2）安装包端点实测（最硬的证据）**

【实测】`https://lmstudio.ai/download/bionic/latest/<platform>/<arch>` 返回 302，指向 `bionic-installers.lmstudio.ai`，**当前版本号 1.1.7-7**：

```
win32/x64    → https://bionic-installers.lmstudio.ai/win32/x64/1.1.7-7/Bionic-1.1.7-7-x64.exe
darwin/arm64 → https://bionic-installers.lmstudio.ai/darwin/arm64/1.1.7-7/Bionic-1.1.7-7-arm64.dmg
linux/x64    → https://bionic-installers.lmstudio.ai/linux/x64/1.1.7-7/Bionic-1.1.7-7-x64.AppImage
```

对上述文件做 HEAD 请求，结果：

```
win-x64            200  size=669,445,576
win-arm64          200  size=342,262,752
mac-arm64          200  size=633,033,649
mac-x64(intel)     404  size=0
linux-x64          200  size=1,121,135,099
linux-arm64        200  size=1,371,045,441
```

**（3）官方 changelog 侧证 Linux 支持**

Bionic 1.1.2（2026-09-08）release notes：

> "**Bionic for Linux (x64 and ARM64).**"

来源：<https://lmstudio.ai/changelog>

**（4）官方系统要求页（属 LM Studio 本体，但同源同引擎，Intel Mac 结论一致）**

> "### macOS
> - Chip: **Apple Silicon (M1/M2/M3/M4).**
> - macOS 13.4 or newer is required.
> - **Intel-based Macs are currently not supported.** Chime in [here] if you are interested in this."

来源：llms-full.txt 内 "System Requirements" 节 / <https://lmstudio.ai/docs/app/system-requirements>

---

## 总结：如果外部程序要驱动 Bionic 里的 agent，今天能做到吗？

### 一句话答案

**❌ 不能。今天没有任何官方支持的方式能让外部程序（Python 脚本、另一个 agent 框架、手机 App）把消息送进 Bionic 的 agent 会话并拿到回复。**

### 能做什么 / 不能做什么

| 需求 | 今天可行？ | 说明 |
| --- | --- | --- |
| 外部程序调用 **Bionic 里的模型做推理** | ✅ 可以 | 通过 Bionic 的本地模型 API（端口 1234，OpenAI 兼容）。但**这是模型推理，不是 agent** |
| 外部程序**把消息送进 Bionic 的 agent 会话** | ❌ 不行 | 无 API、无 CLI、无 headless、无 MCP 服务端；官方文档零记载 |
| 外部程序**读取 Bionic 的会话内容** | ❌ 不行（无官方途径） | Bionic 会话是本地 sqlite：`~/.lmstudio/apps/bionic/.internal/{bionic,ng-sessions}.sqlite`【实测】。**直读文件不是官方接口，格式无保证** |
| 让 Bionic **主动调用外部程序** | ✅ 可以 | 把外部程序包成 **MCP server**，在 Bionic 的 `Settings → Connected Apps`（或 `~/.lmstudio/mcp.json`）里注册。**方向是 Bionic→外部，不是外部→Bionic** |
| 手机 App 远程跟 Bionic agent 聊天 | ❌ 不行（官方无） | issue #2468 明确：目前只能用户自己用 VPN（Tailscale）转发本地 REST API，且"没有 Bionic 会话的视图" |

### 最可行的路（按可行性排序）

**路线 A（最现实）：不用 Bionic 当 agent 宿主，只用它的模型。**

在 Bionic 里加载自己微调的本地模型 → 开 Bionic 的本地模型 API（Settings → Local Model API，端口 1234）→ **外部 agent 框架（DSH）把 Bionic 当作一个 OpenAI 兼容的推理后端**。
- 优点：**官方支持的路径**（OpenAI 兼容端点有正式文档，只是 Bionic 侧的开关说明较弱）
- 代价：人格层与执行层都落在 DSH 一侧，**Bionic 的 GUI/agent 能力完全用不上**

**路线 B：把 DSH 包成 MCP server，接进 Bionic。**
让 Bionic 当唯一入口，通过 MCP 调 DSH 的能力。
- 优点：**MCP 客户端方向是官方支持的**（Jumper/Cloudflare 都这么接）
- 代价：**方向反了**——是"Bionic 驱动 DSH"，不是"DSH 驱动 Bionic"。手机端仍无法接入

**路线 C：直读本地 sqlite 硬桥接。**
- ⚠️ **强烈不建议**：非官方接口、格式无保证、官方 issue #2438 显示用户已经在靠"找隐藏目录 + 手动删文件"绕过限制，说明这条路官方不背书。Bionic 任意一次更新都可能改 schema 导致桥接静默失效。

**路线 D：等官方。**
跟踪 issue #2328（MCP server for Bionic）与 #2468（手机伴侣访问）。两者都是 open、0 回复，**无任何官方排期迹象**。

### 硬约束（架构必须面对的）

1. **Bionic 是封闭的 agent 宿主。** 官方文档全站无一行关于外部驱动它的说明；唯一相关的官方仓库 issue 是"请求加上这个能力"。
2. **端口 1234 是"模型推理口"，不是"agent 口"。** 这个区分是整个架构成立与否的关键——把 1234 当成"能跟 Bionic agent 对话"会直接导致架构失败。
3. **Bionic 与 LM Studio 共用 `~/.lmstudio`**（模型、`mcp.json`、config-presets），但**运行时与配置主体分开**（Bionic 在 `~/.lmstudio/apps/bionic/`）【第三方+实测】。共用意味着"模型只下载一份"，也意味着**在任一边改 `mcp.json` 会影响另一边**。
4. **没有 headless，Bionic 必须开着 GUI 窗口跑。** 桌面 App 关掉即没有 agent。
5. **Bionic 的"会话"是本地 sqlite，不随账号漫游。** issue #2467（open）原文："Conversations and sessions are **stored locally on each machine**... sessions created on one machine are stranded there." → **换机/重装会丢**，手机端也读不到。
6. **人格层无法用官方 system prompt 实现。** 官方唯一的可编程行为定义是 **Skills（`SKILL.md`）**，它是"按需加载的指令包"，语义上接近"技能"而不是"人格"；且**官方文档没有说明它能否强制定制语气/人格**。
7. **本地模型需有 Tool Use 才能驱动 agent。** Jumper 文档："**Tool Use.** Required. Without it, the model cannot operate Jumper at all."（来源：<https://docs.getjumper.io/guides/bionic>）→ 自己微调的轻量模型**如果没训过 tool calling，在 Bionic 里当 agent 主模型会不可用**。
8. **平台**：Windows x64 ✅ 已发布；**macOS Intel ❌ 不支持**（若用户有 Intel Mac，此方案在此平台不成立）。

### 明确标注为"未找到官方依据，不能确认"的项

- ❌ **Bionic 有 system prompt / persona 设置项** → 未找到官方依据，不能确认（本机配置结构中无该字段；第三方博客的说法未经证实）
- ❌ **Bionic 作为 MCP 服务端对外暴露能力** → 未找到官方依据，不能确认（且有 open 的 feature request 反证）
- ❌ **Bionic 有 CLI / headless 模式** → 未找到官方依据，不能确认
- ❌ **Bionic 可作为 agent 被外部程序调用（任何形式）** → 未找到官方依据，不能确认
- ⚠️ **Bionic 可指向外部 OpenAI 兼容端点（第三方 LM Studio）作为模型来源** → 仅在第三方教程中出现，官方文档未见，未确认
- ⚠️ **"项目级别设置 system prompt"** → 仅第三方博客声称，与本地 `project.json` 结构不符，未确认

---

## 附：本次调研使用的信息源清单

**官方（Element Labs / lmstudio.ai）**
- <https://lmstudio.ai/docs/bionic>
- <https://lmstudio.ai/docs/bionic/quick-start>
- <https://lmstudio.ai/docs/bionic/agent/skills>
- <https://lmstudio.ai/docs/bionic/agent/code-project>
- <https://lmstudio.ai/docs/bionic/models>
- <https://lmstudio.ai/docs/bionic/models/download-local-models>
- <https://lmstudio.ai/docs/developer>
- <https://lmstudio.ai/docs/developer/core/mcp>
- <https://lmstudio.ai/docs/developer/openai-compat>
- <https://lmstudio.ai/changelog>（Bionic 全 18 条 release notes）
- <https://lmstudio.ai/changelog/bionic-v1.0.8>、<https://lmstudio.ai/changelog/bionic-v1.1.7>
- <https://lmstudio.ai/blog/introducing-lm-studio-bionic>
- <https://lmstudio.ai/download>
- <https://lmstudio.ai/llms-full.txt>
- <https://api.github.com/repos/lmstudio-ai/docs/git/trees/main?recursive=1>（官方文档仓库完整文件树）
- <https://github.com/lmstudio-ai/lmstudio-bug-tracker>（官方 issue 仓库）

**官方仓库 issue（用户提交，非官方承诺）**
- <https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2328>（Request MCP server for Bionic，open）
- <https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2468>（手机伴侣访问 Bionic 会话，open）
- <https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2469>（MCP 工具重名被遮蔽，open）
- <https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2467>（跨设备会话同步，open）
- <https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2438>（Project Files 无法从 UI 删除）

**第三方（非 Element Labs，可信度中等）**
- <https://docs.getjumper.io/guides/bionic>（Jumper 官方集成文档；给出了 Connected Apps / mcp.json / 端口 1234 / 共享配置目录的最详细描述）
- <https://docs.getjumper.io/guides/lm-studio>（对照：LM Studio 侧需手动起 1234）
- <https://developers.cloudflare.com/agent-setup/bionic/>（Cloudflare 官方 × Bionic 集成指南）
- <https://gyanaangan.in/blog/lm-studio-bionic-system-prompts-for-coding-agents-templates-you-can-actually-copy>（**声称**项目级 system prompt，未经证实）
- <https://synapsewire.com/en/posts/lm-studio-bionic-local-agent-tutorial-2026/>（第三方教程）
- <https://lm-studio.cn/changelog/bionic-v1.0.2>（中文镜像，MCP OAuth 条目）

**本机实测（2026-10-03）**
- `~/.lmstudio/` 目录结构、`mcp.json`、`settings.json`（含 `enableLocalService`）
- `~/.lmstudio/apps/bionic/settings.json`、`.internal/settings.json`、`projects/<uuid>/project.json`、`.internal/projects-registry.json`
- 技能发现目录：`~/.lmstudio/skills`、`~/.agents/skills`、`~/.codex/skills`
- 端口 1234/3080/3000 监听状态
- Bionic 安装包端点 HEAD 探测（`bionic-installers.lmstudio.ai`，版本 1.1.7-7）
