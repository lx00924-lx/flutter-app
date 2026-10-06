# DSH 程序化驱动入口、MCP 现状与鉴权边界

> 只读调查记录（2026-10-06）。DSH 安装根记作 `{DSH}` =
> `.../node_modules/@deepseek-ai/dsh/`。行号以 LF 计数为准。
> 本文只回答一件事：**外部程序要驱动本机 DSH，有哪些现成入口、哪些要自己写。**

---

## 一、已存在、可直接用（零代码）

| 入口 | 命令 | 形态 | 代价 |
| :--- | :--- | :--- | :--- |
| **一次性任务** | `dsh --profile headless "<task>"` | 子进程 + stdout 出最终答案 + 退出码 0/1，不开端口 | 每任务一个新会话、拿不到工具过程 |
| **进程内多轮** | `dsh --profile sdk` | stdio 上换行分隔 JSON-RPC 2.0，长驻 | **无 per-prompt 结果**（自己按 `turn/end` / idle 判定）、**无 cancel/close**（只能杀进程）、零鉴权 |
| **标准自动化协议** | `dsh --profile acp` | ACP v1 长驻；`session/new` 可声明 stdio/HTTP **MCP server**；`session/request_permission` 可程序化应答权限 | `authenticate` **无需凭据直接成功** |
| **复用已在跑的 web 宿主** | `POST http://127.0.0.1:3080/v1/agent/prompt[/stream]` | 自装插件 `dsh-app-bridge` 已提供：`/v1/agent/prompt`（同步）、`/v1/agent/prompt/stream`（SSE：`reasoning`/`content`/`tool_start`/`tool_end`/`waiting_approval`/`done`）、`/v1/sessions`、`/v1/models`、`/v1/agent/approve`、`/v1/user-questions/*` | 只坐在 Host/Origin 栅栏下、**无身份认证**、仅本机可达 |

关键证据：

- CLI：`{DSH}/lib/bin.js:32-42`（HELP_EXAMPLES）、`:85`（`--profile` / `--from-default-profile` / `--patch`）、`:28-30`（拒绝 `--profile desktop`）
- profile 模板表：`dsh-app-boot/lib/index.js:327-349`（`acp` / `web` / `headless` / `sdk` / `sdk-minimal`）、`:323-326`（`$DSH_HOME/profiles/<name>`）
- headless：`dsh-headless/README.md:12`（无 GUI、无 server、无浏览器；退出码 0=完成 / 1=中止或出错）、`:122-126`（一次一任务、中间工具输出不打印）
- sdk：`dsh-sdk-app/README.md:12,26`（stdout 只走 JSON-RPC 帧；stdin EOF → bounded shutdown）；协议 `dsh-sdk-protocol/README.md:32-48`（方法表：client→server `initialize`/`session/prompt`/`shutdown`；server→client `session.event`/`session.status`/`subagent.started`/`subagent.finished`）
- acp：`dsh-acp/README.md:60-76`（方法表）、`:171`（"MCP tools only"）、`:76`（"ACP clients are trusted controllers"）

---

## 二、MCP 现状：只有客户端，没有服务端

- **客户端已有**：`@deepseek-ai/dsh-mcp-client`（`{DSH}/package.json:58`）。把外部 MCP server 的工具注册成原生工具，名为 `mcp__<serverName>__<toolName>`（`dsh-mcp-client/lib/index.js:121`）。支持 `stdio`（`:42`）与 `streamable-http`（`:48`）两种传输。
  - 配置契约：`dsh-mcp-client/lib/types/index.d.ts:25-48`（`StdioConfig`）、`:50-69`（`StreamableHttpConfig`）；README `:34-66` 有 `cordis.patch.yml` 样例，`serverName` 须匹配 `[A-Za-z0-9_-]{1,32}`。
  - ⚠️ **只桥接 tools**，Resources / Prompts 没有消费方（README `:191`）。
- **服务端：完全没有**。`McpServer` / `StdioServerTransport` / `StreamableHTTPServerTransport` 在全部 `@deepseek-ai/*` 包中**零命中**；服务端符号只出现在 `dsh-mcp-client` 的客户端用法里。
- ✅ **但 SDK 已在磁盘上**：`{DSH}/node_modules/@modelcontextprotocol/sdk`，版本 **1.30.0**，`exports` 含 `./server`、`./client`，`dist/esm/server/` 下 `stdio.js` / `streamableHttp.js` / `sse.js` 俱全 —— **写 MCP 服务端不需要新装依赖**。

---

## 三、插件能拿到哪些 agent 能力

插件 API 里"程序化跑一轮并拿结果"是完整的一条链路：`sessionController.create()` → `selectModel()` → `prompt()` → `follow()` 拉事件流 → 按 `turn/end` 收尾。

| 能力 | API | 位置 |
| :--- | :--- | :--- |
| 建/列/改会话 | `create` / `list` / `rename` / `fork` / `page` | `dsh-api-session-controller/lib/types/index.d.ts:73-163` |
| **跑一轮** | `prompt(request, signal)` | 同上 `:138`（载荷形状 `types.d.ts:292-300`） |
| **订阅事件流** | `follow(request, signal): AsyncIterable<SessionFollowFrame>` | 同上 `:171` |
| 打断 | `cancel(request)` | 同上 `:156` |
| 选模型 / 模型目录 | `selectModel` / `modelCatalog` | 同上 `:92` / `:97` |
| 权限预设 | `permissionPresets.set(session, name)` / `apply(...)` / `current()` | `dsh-permission-presets/lib/types/index.d.ts:118-158` |
| 审批（拦截钩子） | `ctx.on('approval/request', ...)` + `approval.setPolicy` | `dsh-user-approval/lib/types/index.d.ts:108,127` |
| 选择框（拦截钩子） | `ctx.on('user-questions/request', ...)` | `dsh-user-questions/lib/types/index.d.ts:44` + `types.d.ts:77` |
| 注册自定义工具 | `tools.register(definition)` | `dsh-tools/lib/types/index.d.ts:601` |
| 自建 HTTP 路由 | `webServer.register({kind:'exact'\|'prefix', path, handler})` | `dsh-host-webserver/lib/types/index.d.ts:90`；**handler 拥有完整响应生命周期 → SSE 可行**（`:37` 注释原文）；gzip 过滤器显式跳过 `text/event-stream`（实现 `:106-116`） |

插件实证（`docs/user-plugin-dsh-app-bridge/index.js`）：`startTurn` `:551-649`（create `:563` → selectModel `:585` → prompt `:641`）、`pumpSse` `:665-817`（5s 心跳 `:724-730`）、`collectTurn` `:1644-1687`（把 SSE 聚合成同步文本）。

⚠️ 坑：`register` 对重复 `(kind, path)` 直接 `throw`（实现 `:178`）——自建端点要用独立前缀（如 `/mcp`），别撞官方 `/api`、HMR、SPA。

---

## 四、鉴权：只有"浏览器会话 Cookie"，没有面向程序的凭据

- 身份 = 进程启动 token 换一次性 Cookie（HMAC 签名、绑 authority、HttpOnly / SameSite=Strict、默认 30 天）。密钥是 `$DSH_HOME/.credentials.yaml` 里 owner-scoped 的 `client-connection/browser-session` 记录。
- 官方明确：**不接受**根路径以外的 query token、**不接受** `Authorization` 头 token；**没有** API key / mTLS / Unix socket / "回环免鉴权"档位。原话见 `dsh-client-connection/README.md:35`："Every Host RPC method and WebSocket stream requires one browser session; **there is no method-specific loopback tier**."
- 栅栏语义：Host/Origin 校验失败 → **403**；可信但未认证 → **401**（README `:39`）。这个栅栏**不是鉴权层**，只防 DNS rebinding（`lib/types/api-request-trust.d.ts:1-13`）。
- ⚠️ **例外（也是本机程序唯一能用的口子）**：`ctx.webServer.register()` 挂的路由**完全自己负责安全**。桥接的 `/v1/*` 只调 `requestRejection()`（Host/Origin 校验，不做身份认证），所以对任何能访问 `127.0.0.1:3080` 的本机进程，**实际上是免鉴权的** —— 这是插件头注释 `:17-18` 里写明的有意设计。
- 想继承 Cookie 鉴权：改用 `ctx.connection.fetch.register({path, methods, requestBody, fetch})`（挂在 `/api` 下，走 `createSharedFetchHandler`）。

---

## 五、安全边界（结论）

四条程序化入口（headless / sdk / acp / 3080 插件路由）**全都没有身份认证**。这不是缺陷，而是分层的结果：

- **本机信任层** —— 同机进程互相驱动，不鉴权（前提是"这台电脑是我的"）；
- **用户通道层** —— 手机 App 那条链路有鉴权（账号 + `x-client-session-id` + token 归属校验）。

**这两层绝对不能混**：无鉴权的本地端点一个都不能经 Cloudflare Tunnel 或 `--host 0.0.0.0` 暴露出去（宿主本就拒绝 `0.0.0.0`，`dsh-web-app/lib/startup.js:40`）。

---

## 六、要自己写时，三条路（成本递增）

- **B1 纯外部 shim（零 DSH 改动）**：独立 Node 进程当 MCP server（用已在磁盘的 `@modelcontextprotocol/sdk@1.30.0`），工具实现转发到 `dsh --profile headless`（spawn）或 `http://127.0.0.1:3080/v1/agent/prompt`。最小工具面：`run_task{task, cwd?, model?, permission?}`。
- **B2 DSH 插件 + 内嵌 MCP server**：`inject = ['webServer']`，`ctx.effect(() => ctx.webServer.register({kind:'prefix', path:'/mcp', handler}), 'mcp-server')`，handler 用 SDK 的 `webStandardStreamableHttp` 直接吃 Fetch `Request`/`Response`（可复用插件已有的 `writeResponse()`）。鉴权要自己定（官方无 API key 机制）。
- **B3 新增 app profile**：照 `dsh-sdk-app` / `dsh-acp-app` 的形状写 bundle 包，成为 `dsh --profile <name>`。

---

## 附：一次实测结论（供未来参照）

**不要**把"模型推理口"当成"agent 口"。LM Studio / Bionic 的 OpenAI 兼容端口只做推理，不承载 agent 会话；DSH 这边的对应物是 `sessionController`，不是 `/v1/chat/completions`。
