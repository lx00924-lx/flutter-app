# 同步说明：仓库版 ⇄ 本地安装版

> ⚠️ 本插件的 `package.json` **在两个地方必须不同**。
> 互相覆盖会造成「仓库发布配置被破坏」或「插件加载失败」，且**都不会立刻报错**。

---

## 一、两个版本的分工

| | 本仓库（发布版） | 本地安装目录（运行版） |
| :--- | :--- | :--- |
| 路径 | 仓库根 | `%USERPROFILE%\.dsh\user-plugins-group\plugins\dsh-app-bridge\` |
| `package.json` 的 `name` | `lxai-app-bridge` | **`dsh-app-bridge`** |
| `version` | 对外发布版本 | 不参与发布，可不动 |
| 额外字段 | `repository` / `bugs` / `keywords` / `files` / `dsh.bundle` | 无（只保留运行必需字段） |
| 作用 | 供人 clone、发布、参考 | 被 DSH 按目录名加载并实际运行 |

## 二、为什么 `name` 必须不同

DSH 的 profile 用 **`link:`** 协议挂载本地插件，键名、目录名、`package.json` 的 `name`
**三者必须完全一致**：

```json
// %USERPROFILE%\.dsh\profiles\web\package.json
"dependencies": {
  "dsh-app-bridge": "link:C:/Users/<你>/.dsh/user-plugins-group/plugins/dsh-app-bridge"
}
```

- 若把**仓库版**覆盖到本地 → `name` 变成 `lxai-app-bridge`，与依赖键 `dsh-app-bridge` 不匹配，
  插件静默不加载（表现是 LxAI 的「选择框转发 / 审批 / 权限切换」全部失效）。
- 若把**本地版**覆盖到仓库 → 丢失 `repository` / `files` / `dsh.bundle` 等字段，
  别人 clone 后无法按说明安装，npm 也认不出 DSH 插件入口。

## 三、同步代码的正确做法

**只覆盖 `lib/index.js`**，两个 `package.json` 各留各的：

```powershell
gh repo clone lx00924-lx/lxai-app-bridge "$env:TEMP\lxai-app-bridge-sync"

# 用最新的实现覆盖（本地运行版与 LxAI 仓库内的副本应当一致）
Copy-Item "<最新源码>\index.js" "$env:TEMP\lxai-app-bridge-sync\lib\index.js" -Force

cd "$env:TEMP\lxai-app-bridge-sync"
git diff --stat          # 确认只有 lib/index.js 变更
# 手动把 package.json 的 version 递增
git commit -am "fix: ..."
git push
```

**核对清单**（推送前逐项确认）：

- [ ] `git diff --stat` 里**只有** `lib/index.js`
- [ ] `package.json` 的 `name` 仍是 `lxai-app-bridge`
- [ ] `package.json` 的 `version` 已递增
- [ ] 本地安装目录的 `name` 仍是 `dsh-app-bridge`（没被反向覆盖）

## 四、曾经踩过的坑（2026-09-28）

本地在 `.dsh\user-plugins-group\plugins\dsh-app-bridge\lib\index.js` 修掉了两个实测 bug，
但**只改了本地、忘了推回本仓库**，仓库因此停留在有问题的版本 —— 谁照仓库安装都会重新踩：

1. **思维链永远为空**：`assistant/message` 帧的 `data.message.content` 是**块数组**
   （`reasoning` / `text` / `tool-call`），旧实现用 `blocks.map(b => b.text).join('')`
   把思考当成正文推出去，`reasoning` 通道一个事件都没有。
   修法：按块类型分流（`emitBlock`），同一块在后续帧变长时只推增量，新块之间补空行。

2. **工具名恒为 `"tool"`**：`tool/result` 帧里**没有工具名**，只有 `callId`；
   旧实现读 `message.toolName` / `data.name`，两个字段都不存在。
   修法：用 `toolNameByCallId` Map 在 `tool/call` 帧记下名字，收到结果时按 `callId` 取回。

**教训**：本地运行目录就是「事实上的源码」，改完必须显式同步回仓库，不能指望它自动一致。

## 五、版本号约定

改动 `lib/index.js` 后，**仓库版的 `version` 手动 +1**（补丁位即可）。
本地运行版的版本号不参与发布，保持不动以免与目录名约定混淆。