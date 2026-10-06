# LxAI 安全审计记录（内部参考）

> ⚠️ **这份文件是内部审计存档，不要对外发布、不要贴进站点、不要附在分发包里。**
>
> 它写的是"当时哪里有问题、怎么利用、怎么验证"，属于**武器化说明**。仓库代码是开源的，
> 修复本身在代码里看得见 —— 但"能从代码看出改过"和"直接拿到一份排查清单"是两回事。
> 公开它等于替攻击者省掉最费时的侦查步骤。
>
> 它的用途只有一个：**以后排查回归时知道测过什么、用什么判据、踩过哪些坑。**

审计日期：2026-10-06
被测对象：`server.ts`（生产中继，`F:\ai\flutter-app` 是同一份代码的运行副本）

---

## 一、修复清单（按发现顺序）

| # | 问题 | 影响 | 修法要点 |
| :--- | :--- | :--- | :--- |
| 1 | 9 个接口只认 URL/body 里的 `userId` | 无凭据即可读/写/删聊天记录、改设置、远程停桥接 | 加 `verifyUserIdentity()` 守卫，认 `x-client-session-id`（登录签发的 UUID v4，存 `active_sessions.json` 槽位） |
| 2 | 凭证失效有 3 条"静默"路径 | App 界面正常但云端同步全废、两头都不报错 | `/api/check-session` 槽位不存在不再回 `{valid:true}`；`/ws/app` 握手不再对空槽位放行；两者统一用 `401 + FORCE_LOGOUT`（**别新造错误码**，旧客户端只认这个） |
| 3 | `pending-approvals` / `pending-questions` 过滤器写成"参数为空就不过滤" | 不登录即可读**所有人**的待办，泄漏 Agent Token 与"正在等批准的命令原文" | 过守卫 + **强制**按 `userId` 过滤 |
| 4 | `/api/login` 无失败限流 | 用户名是手机号/顺序数字，可无限试密码 | 用户名 + 来源 IP 双维度计数，超 5 次指数退避；**取真实 IP 必须读 `cf-connecting-ip`**（生产走 Cloudflare，`socket.remoteAddress` 恒为 127.0.0.1） |
| 5 | 非法 JSON 回 HTML 错误页 | 响应体泄漏部署绝对路径、依赖版本、堆栈 | 加错误中间件统一回 `400 + INVALID_JSON_BODY`；**位置必须在 `/api/health` 之前**（Express 错误中间件只对它注册之前的路由生效） |
| 6 | CORS 允许任意来源 + `Allow-Headers` 动态反射；socket.io 也是 `origin:"*"` | 放大器：一旦凭证泄漏，任意网站可读走全部数据 | 两处共用 `isCorsOriginAllowed()` 白名单；**比较前先剥掉 `www.`**（否则裸域被拦）；无 Origin 请求一律放行（CORS 只管浏览器） |
| 7 | **ASR 代理端点 SSRF** | 任何人可拿中继当跳板打内网 / 云元数据 / 本机服务 | 新增 `ssrfViolation()` + `isBlockedIp()`：只放行 http/https；回环/内网/链路本地/CGNAT 全拒；域名先解析再判；私有地址只能用 `ASR_ALLOWED_HOSTS` 显式声明 |
| 8 | DNS 重绑定 | 预检解析一次、`fetch` 连接时再解析一次，中间可换 IP | 改用 `requestAsrPinned()`（`http(s).request` + 自定义 `lookup`）：解析结果直接交给连接；**禁止跟随重定向** |
| 9 | ASR 端点无认证 | 被白嫖当公网代理 | 加身份守卫（经核实**不影响 App**：`AsrService` 是直连用户配置的 ASR 端点，不走中继） |
| 10 | **bat 生成的地址取自 `x-forwarded-host`** | **命令注入**：地址被插进 `urlretrieve('<地址>')` / `--server "<地址>"`，塞个引号即可闭合执行命令 | `run_bridge.bat` 不再信任任何请求头（用 `SERVER_BASE_URL`）；`download-bat` 的参数过 `safeScriptUrl()`（http/https + 禁引号/反斜杠/空白） |

## 二、测过但**没打穿**的

### 外部攻击清单（四类，35 项）

| 类别 | 条目 | 结果 |
| :--- | :--- | :--- |
| 路径遍历 | `../../`、`....//`、`..\..\`、`/admin/.`、`/admin..`、`/./././` | 6/6 无问题 |
| 编码绕过 | `%2e%2e%2f`、`%252e`、全角、`%c0%af`、`%e0%80%af`、`%00`（末尾/中间） | 6/6 无问题 |
| 鉴权绕过 | 多斜杠、`/api/./`、尾部斜杠、大小写、`%09`/`%0a`/`%0d`/`%0b`/`%0c`、分号矩阵、查询串、`%23` | 9/9 无问题 |
| URL 衍生 | 绝对路径、开放重定向、`@` 劫持、主机头注入、动态参数遍历 | 5/5 无问题 |

- **开放重定向**：代码里**没有** `res.redirect` / `Location` / 3xx —— 该功能不存在，无从滥用。
- 另有 22 项"HTTP 200"看着可疑，其实全是 **SPA 兜底页**（`app.get("*")` 把前端页面发出来了），
  **不是 API 被触达**。判据：只有返回 **JSON** 才说明路由真匹配上了。

### 其它方向（清单之外，自己补的）

| 方向 | 覆盖 |
| :--- | :--- |
| SSRF | 22 项：内网/回环/`::ffff` 十六进制写法/`100.100.100.100`（阿里云，属 CGNAT）/`metadata.google.internal`/302 跳内网 —— 全拒；公网 ASR 正常转发 |
| 越权 | 双账号真实登录：A 的凭证读 B 的记录/设置/会话 → 403 |
| 跨域 | 15 项：任意自定义头不再被反射、恶意来源不发放行头、安全头到位 |
| bat 注入 | 6 项：双引号/单引号闭合/`file://`/带空格 → 全 400 |
| 登录爆破 | 第 6 次起 429（限流生效） |

## 三、踩过的坑（下次别再花时间）

1. **`http.request` 的自定义 `lookup`**：Node 可能以 `options = {hints:0, all:true}` 调用它，
   此时回调**必须给数组** `cb(null, [{address, family}])`；给单个地址会抛
   `ERR_INVALID_IP_ADDRESS: Invalid IP address: undefined`（`node:net` 的 emitLookup）。
   按 `all` 标志分两种回法。**表现出来是"公网请求全 500"，很容易误判成别的原因。**
2. **`new URL(...).hostname` 对 IPv4-mapped IPv6 返回十六进制**：
   `::ffff:127.0.0.1` → `[::ffff:7f00:1]`、`::ffff:10.0.0.7` → `[::ffff:a00:7]`。
   只按 `fc`/`fd`/`fe8` 前缀判断会漏掉这一族。要把后两段十六进制还原成 IPv4 再判。
   （`127.0.0.1`、`2130706433`、`0x7f000001` 会被 Node 规范化成同一个地址，所以"先规范化再判"天然正确。）
3. **测端点时记得给 token 做 URL 编码**：它是 `enc:v1:…` 形态、base64 里可能含 `+` `/`，
   不编码会被 query 截断 → 参数丢失 → 服务端走默认值返回 **200**，于是**误判成"校验没生效"**。
4. **测"302 重定向"要让入口先被放行**：跳板若跑在 `127.0.0.1`，入口就被 SSRF 检查拦了，
   根本走不到重定向那一步 —— 等于没测。用 `ASR_ALLOWED_HOSTS` 显式放行后才测得准。
5. **改了源码要重新构建再测**：`dist/server.cjs` 不会自动更新，跑旧产物会得到
   "修复没生效"的假结论（本项目踩过一次）。

## 四、脚本位置（都在 `.sandbox-demo/`，已被 `.gitignore` 忽略）

| 脚本 | 用途 |
| :--- | :--- |
| `_regression.mjs` | 身份守卫回归（32 项，含"被顶下线后旧凭证失效"） |
| `_attack-test.mjs` | 越权探测（13 项，修复前全 200 / 修复后全 403） |
| `_pentest-sandbox.mjs` | 沙箱双账号越权（13 项） |
| `_pentest-prod.mjs` | 生产边界探测（37 项） |
| `_test-traversal.mjs` / `_test-attacklist-full.mjs` | 路径遍历 / 编码绕过 / 鉴权绕过 |
| `_test-ssrf.mjs` / `_test-ssrf2.mjs` / `_test-ssrf-redirect.mjs` / `_ssrf-demo.mjs` | SSRF（含真实利用演示与 302 绕过） |
| `_test-cors.mjs` / `_test-ratelimit.mjs` / `_test-asr-auth.mjs` / `_test-bat-inject.mjs` | 跨域 / 限流 / ASR 认证 / bat 注入 |

## 五、仍然存在的小风险（已知、未处理）

1. **`/api/agent/approve` 与 `answer-question` 用 body 里的 token 兜底**：合法客户端都传 token，
   攻击者不传就走 `pending` 里的，所以实际路径要拿到有效凭证才行 —— 但"用 body token 兜底"
   这个写法本身容易踩坑，将来若有人改动 `pending*` 的校验到这里，会连带出问题。
2. **网络层出口封禁未做**：应用层已经是白名单式判断，但按纵深防御，最好在部署层再禁一次
   内网网段出站（这是运维动作，不在代码里）。
