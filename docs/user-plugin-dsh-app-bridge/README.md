# dsh-app-bridge 用户插件的本地修复（勿删）

DSH 里那个给手机 App / `deepseek_bridge.py` 提供 REST 接口的**用户插件**，
位于 `~/.dsh/user-plugins-group/plugins/dsh-app-bridge/`。
本目录保存的是它的**已修复副本**，用于版本管理，以及 **DSH 升级或重装把插件覆盖后恢复**。

## 修复内容（两处）

### 1. 失效的 AbortSignal 导致所有会话读写必挂

原代码在模块加载时创建一个信号并永久复用：

```js
const TURN_TIMEOUT_MS = 600_000
const TURN_SIGNAL = AbortSignal.timeout(TURN_TIMEOUT_MS)   // ← 只创建一次
```

该信号 10 分钟后永久进入 aborted 状态，而插件被 DSH 热加载后模块不会重新求值，
于是此后**所有** `session.list` / `page` 调用都会立刻抛出
`The operation was aborted due to timeout`（实测 `GET /v1/sessions` 稳定在 0.05 秒内返回 500）。

修复：改为按需创建

```js
const turnSignal = () => AbortSignal.timeout(TURN_TIMEOUT_MS)
// 原本 8 处 TURN_SIGNAL 引用统一改为 turnSignal()
```

### 2. 取不到工作区时编造 `deepseek-agent`

原 `workspacesPayload()` 在 `workspaceController.list()` 拿不到数据时，返回一个
硬编码的假工作区 `[{ id: 'deepseek-agent', name: 'deepseek-agent', ... }]`。
用户磁盘上并不存在这个目录，App 里却会显示它。

修复：
- `declaredWorkspaces()`：只负责取声明式工作区，取不到返回空数组
- `workspacesPayload(sessionItems)`：声明式取不到时，**从会话的真实 `cwd` 归纳**；
  仍然没有就返回空数组，让 App 明确显示"未取到目录"而不是展示假值
- 会话行缺少 `cwd` 时 `workspace` 留空字符串，不再回退到假名称

## 何时需要这个副本

| 情况 | 处理 |
| :--- | :--- |
| DSH 升级后 `/v1/sessions` 又返回 500 或 0 会话 | 把本目录 `index.js` 覆盖回插件目录，然后重启 `dsh web` |
| DSH 升级后 App 显示 `deepseek-agent` 这种不存在的目录 | 同上 |
| 想确认线上插件是否有修复 | 在插件目录执行 `Select-String -Pattern "const turnSignal = \(\) =>" lib\index.js` |

## 恢复方法

```powershell
$dst = "$env:USERPROFILE\.dsh\user-plugins-group\plugins\dsh-app-bridge\lib\index.js"
Copy-Item "F:\ai\flutter\123\docs\user-plugin-dsh-app-bridge\index.js" $dst -Force
node --check $dst          # 语法自检
# 然后重启 dsh web（插件模块常驻内存，不重启不生效）
```

## 重要提醒

- **插件改动只在重启 `dsh web` 后生效**（无热重载机制，`dsh` 仅有 `web` / `plugin` 两个子命令）
- 重启 `dsh web` 会**终止正在运行的 DSH 会话**
- 本目录的 `index.js` 是**副本**，DSH 实际加载的是 `~/.dsh/...` 下那一份；改完需同步过去
