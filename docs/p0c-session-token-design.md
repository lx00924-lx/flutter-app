# P0-c 设计：会话令牌替代「传 userId 即身份」

> 状态：**设计完成，未实现**（P0-a / P0-b 已实现并推送：`698f66b`、`b746886`）
> 影响面实测：服务端 **15 处**接收 userId，Flutter 端 **45 处**发送 userId

## 1. 要解决的问题

当前服务端把请求体/查询串里的 `userId` 直接当作身份：

```ts
const { userId, messages } = req.body;   // 传谁的 id，就以谁的身份操作
```

后果：`/api/messages/:userId`、`/api/sync-messages`、`/api/settings/:userId`、
`/api/delete-message`、`/api/change-password` 等接口**无需登录即可读写任意用户数据**——
只要猜到/知道用户名（用户名通常就是可见的账号名）。P0-a 只堵住了 Agent 通道，
这条「以 userId 为凭据」的通道仍在。

## 2. 目标

登录成功后服务端签发**会话令牌**；受保护接口只认令牌，**userId 一律从令牌解析**，
不再信任请求里携带的 userId。保留短暂兼容期以避免客户端强制升级造成中断。

## 3. 令牌设计

采用**不透明随机令牌 + 服务端存储**（而非 JWT）：

| 项 | 方案 |
| :--- | :--- |
| 格式 | `sess_` + 32 字节随机（`crypto.randomBytes(32).toString('base64url')`） |
| 存储 | `messages_data/sessions_tokens.json`：`tokenHash -> { userId, clientSessionId, deviceType, issuedAt, expiresAt, lastSeenAt }` |
| 存储方式 | 只存 **SHA-256 哈希**，明文令牌仅返回给客户端一次（服务端被读也无法伪造） |
| 传输 | `Authorization: Bearer <token>` |
| 有效期 | access 24 小时；滑动续期（`lastSeenAt` 每次请求刷新）；超过 30 天未活动则失效 |
| 撤销 | 登出删除记录；顶号（单点互斥）时同样撤销旧设备令牌；改密码后撤销该用户全部令牌 |

**为什么不用 JWT**：需要"立即撤销"（登出 / 顶号 / 改密码），JWT 需要额外黑名单；
本项目单机 + 文件存储，不透明令牌更简单且可即时撤销。

## 4. 分阶段实施（每阶段可独立部署、可独立验证）

### 阶段 1：签发令牌（纯增量，不破坏现有调用）
- 新增 `issueSessionToken()` / `verifySessionToken()` / `revokeSessionToken()`
- `/api/login` 响应体增加 `sessionToken` 字段（**现有字段全部保留**）
- 新增 `requireSession` 中间件：解析 `Authorization: Bearer`，成功则把
  `req.authUserId` 写入请求上下文；**解析失败不拦截**（兼容期）
- 验证：登录返回 token；带 token 请求任意接口，服务端日志能打印 `req.authUserId`

### 阶段 2：App 侧携带令牌
- `SyncService` 统一在 Dio 拦截器里附加 `Authorization: Bearer <token>`
- 令牌持久化到 `AppSettings.sessionToken`，登录成功写入、登出清除
- 验证：抓包/日志确认每个请求都带上了头；令牌过期时能自动重新登录

### 阶段 3：服务端收紧（关键一步）
- 受保护接口改为：`const userId = req.authUserId ?? <兼容期回退>`；
  并**交叉校验**——若请求同时带了 userId 且与令牌不一致，直接 403
- 验证：**模拟攻击**（无令牌 + 伪造 userId）→ 403/401；合法令牌 → 200
- 兼容期开关：`REQUIRE_SESSION_TOKEN=true` 时彻底忽略请求里的 userId

### 阶段 4：清理
- 移除请求里的 userId 传递（服务端 15 处、App 45 处逐步收敛）
- 打开 `REQUIRE_SESSION_TOKEN=true` 作为默认值

## 5. 必须同步处理的连带项

| 项 | 原因 |
| :--- | :--- |
| 单点登录互斥 | 顶号时应撤销被顶设备的令牌，否则旧令牌仍可读写 |
| `/api/change-password` | 改密后撤销该用户所有令牌，强制其它设备重新登录 |
| Socket.IO 连接 | 目前 socket 加入 `user_${userId}` 房间未鉴权，需在握手时校验令牌 |
| `messages_data/settings.json` | 内含各用户 API Key，仍明文；建议同期用主密钥加密（P1-⑧） |
| 令牌存储文件 | 加入 `.gitignore` 检查（`messages_data/` 已忽略，天然安全） |

## 6. 验证清单（实现后必须逐条跑）

1. 无令牌 + 伪造 userId 读取他人消息 → **401/403**
2. 合法令牌读取自己消息 → **200**
3. 令牌与 userId 不一致 → **403**
4. 登出后旧令牌 → **401**
5. 顶号后旧设备令牌 → **401**
6. 改密码后其它设备令牌 → **401**
7. 令牌过期（把 expiresAt 改到过去）→ **401**
8. 伪造/篡改令牌（改一个字符）→ **401**

## 7. 风险与回退

- **风险**：阶段 3 收紧过早会让未升级的旧客户端全部 401。
  缓解：先用 `REQUIRE_SESSION_TOKEN` 开关灰度，确认所有活跃客户端已升级再打开。
- **回退**：三个提交独立，可按阶段 revert；令牌文件删除即可全部失效。
