# lxai-app-bridge（用户插件副本，勿删）

> 本目录保存的是本机正在使用的那份**用户插件源码副本**，对应安装位置：
> `~/.dsh/user-plugins-group/plugins/dsh-app-bridge/lib/index.js`。
> 保留它的作用：版本管理 + **宿主升级/重装把插件覆盖后可以一键恢复**。
>
> 对外发布的独立包在同一份代码上只差"包名与路径"：<https://github.com/lx00924-lx/lxai-app-bridge>

## 它做什么

给本地 Agent 宿主补一组 REST 接口，让 LxAI App 及其电脑端桥接脚本能够：

- 读模型目录、会话列表（每行带**真实生效**的模型 / 思考档位 / 权限预设）；
- 跑一轮 Agent 并把 reasoning / 正文 / 工具卡片以 **SSE** 流式回传；
- 转发宿主的**选择框**（ask_user_question）与**审批**请求到 App，并把答复送回宿主；
- 中止轮次、重命名/归档会话、读取已装插件清单。

## 三态设计（为什么不会"AI 自己把问题答了"）

选择框 / 审批会依次上报为：

| 状态 | 含义 | 行为 |
| --- | --- | --- |
| `pending` | 刚提出 | 正常等待 |
| `waiting` | 等超过 5 分钟 | **仍然挂起**，这一轮不交给模型（不会出现"超时后主模型自己回答了"） |
| `orphaned` | 挂满 24 小时 | 主动中止本轮，待办转为"可补答"；用户之后答复会以「续跑」重新起一轮 |

## 安装 / 恢复

```powershell
$dst = "$env:USERPROFILE\.dsh\user-plugins-group\plugins\dsh-app-bridge\lib"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item "F:\ai\flutter\123\docs\user-plugin-dsh-app-bridge\index.js" "$dst\index.js" -Force
# 然后重启宿主的 web 服务（插件模块只在启动时加载，没有热重载）
```

## 注意事项

- **插件改动只在重启宿主 web 服务后生效**（模块常驻内存）。
- 重启宿主 web 服务会**终止正在运行的会话**，请在空闲时操作。
- 本目录的 `index.js` 是**副本**，宿主实际加载的是安装目录那一份；改完记得同步过去。
- 安全边界：这些路由与官方 `/api` 一样处于浏览器信任栅栏之下（Host 必须回环），但**没有额外鉴权** ——
  任何能访问宿主端口的本机进程都能驱动智能体。不要把宿主 web 服务绑定到 `0.0.0.0`。

## 许可

与本仓库一致：Apache License 2.0（见仓库根目录 `LICENSE` / `NOTICE`）。
本插件为独立第三方项目，不含宿主项目源码，仅在运行时调用宿主对外暴露的服务。
