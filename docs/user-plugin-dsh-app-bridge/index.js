/**
 * dsh-app-bridge —— 手机 App 桥接脚本（deepseek_bridge.py）所需的本地 HTTP 接口
 *
 * 背景：`deepseek_bridge.py` 是一个「云端调度 ⇄ 本地 DSH」的反向桥接客户端。
 * 它对本地 DSH（默认 http://127.0.0.1:3080）会按顺序探测一组 REST 端点，
 * 官方 dsh 并没有这些端点 —— 本插件把它们补齐，且**不修改任何 @deepseek-ai 官方文件**。
 *
 * 提供的接口（全部相对 harness 根地址，例如 http://127.0.0.1:3080）：
 *
 *   GET    /health                          存活 + 端点清单
 *   GET    /v1/models                       模型列表（含推理档位）
 *   GET    /v1/sessions                     会话列表（含标题、工作区、**真实模型档位与权限预设**）
 *   GET    /v1/session/state?sessionId=     单个会话真实生效的 {permission, provider, model, reasoningEffort}
 *   POST   /v1/sessions                     新建会话
 *   PATCH  /v1/sessions/:id                 重命名
 *   DELETE /v1/sessions/:id                 归档
 *   POST   /v1/sessions/:id/abort           中止当前轮次
 *   POST   /v1/sessions/:id/approve         答复挂起的审批
 *   POST   /v1/agent/prompt                 跑一轮，同步返回最终文本
 *   POST   /v1/agent/prompt/stream          跑一轮，SSE 流式返回（App 主用）
 *   POST   /v1/agent/abort                  中止（`{sessionId}`）
 *   POST   /v1/agent/approve                答复审批（`{approvalId, action}`）
 *   GET    /v1/plugins                      已装插件清单（走 profile 判定，复用「用户插件」逻辑）
 *   GET    /v1/user-questions/pending       挂起中的选择框（桥接 1s 轮询，用于转发给 App）
 *   GET    /v1/agent/approvals/pending      挂起中的审批（桥接 1s 轮询，含 reason；与选择框同机制）
 *   POST   /v1/user-questions/answer        答复选择框（`{questionId, answers}`）
 *   POST   /v1/user-questions/decline       放弃在 App 上回答（`{questionId}`）→ 交回电脑端界面
 *
 * SSE 事件名与字段按 deepseek_bridge.py 的解析实现对齐：
 *   reasoning{content} / content{content} / tool_start{id,tool,input} / tool_end{id,tool,output,status}
 *   waiting_approval{approvalId,tool} / approval_resolved{approvalId,outcome} / done{sessionId,status,title?} / error{message}
 *
 * ⚠️ 这些路由与官方 /api 通道一样位于浏览器信任栅栏之下（Host 必须回环），
 * 但它们**没有额外的鉴权**：任何能访问 3080 的本机进程都能驱动智能体。
 * 不要把 dsh web 绑定到 0.0.0.0 或加入 --trusted-host 后暴露到局域网。
 *
 * @module dsh-app-bridge
 */

import { randomUUID } from 'node:crypto'

/** 插件名。 */
export const name = 'app-bridge'

/** 需要的服务（其余按需 ctx.get，缺失时优雅降级）。 */
export const inject = ['loader', 'webServer']

/** 模型目录缓存时长。 */
const CATALOG_TTL_MS = 30_000
/** 历史页读取条数。 */
const HISTORY_PAGE = 500
/** SSE 空闲心跳间隔。 */
const HEARTBEAT_MS = 5_000
/** 单轮默认上限（bridge 自己也有 600s 超时）。 */
const TURN_TIMEOUT_MS = 600_000
/**
 * 「等久了」提示阈值：App 在线时，问题/审批等了这么久还没答复，就把它标成
 * `state: 'waiting'`（卡片上提示"已等待较久"）。
 *
 * ⚠️ 注意这里**不再结束本轮、也不返回空答复**。
 * 上一版在到期时返回空答复，等于告诉 DSH"用户没答，你继续" —— 主模型于是接着
 * 说话（用户实测看到"超时后主聊天 API 也回复了"）。现在改为：继续挂着等，
 * 只有到 PARK_MAX_MS 才真正中止这一轮，期间模型不会说话。
 */
const WAIT_NOTICE_MS = 300_000
/** 审批同上。 */
const APPROVAL_WAIT_NOTICE_MS = 300_000
/**
 * 挂起硬上限（24 小时）：到点强制中止这一轮（**不交给模型**），并把待办转成
 * `state: 'orphaned'`——卡片继续留在 App/电脑端，用户答复时走「续跑」。
 *
 * 为什么不无限等：没人答的问题会把那个会话一直占住（DSH 一轮对话一次），
 * 24 小时足够覆盖"隔天才想起来"，再久就该收场了。用户也可以随时在 App 上
 * 点「停止」立刻结束这一轮。
 */
const PARK_MAX_MS = 24 * 60 * 60 * 1000
/**
 * 延后（已中止）待答项保留时长：24 小时，人隔天回来仍能看到并答复（走续跑）。
 */
const DEFERRED_TTL_MS = 24 * 60 * 60 * 1000
/** 桥接轮询心跳窗口：这段时间内来轮询过，才认为「App 侧在线、可以接管」。 */
const QUESTION_ARM_MS = 15_000
/**
 * 审批的接管窗口（同上，但审批由桥接轮询 `/v1/agent/approvals/pending` 维持心跳）。
 *
 * 为什么要判断：审批是无条件 claim 的话，手机不在线时两边都看不到（插件挂 30 分钟
 * 才超时，电脑前的人以为死机了）。只有 App 通路真的在轮询时才接管。
 */
const APPROVAL_ARM_MS = 15_000
/** 会话读写用的共享取消信号：dsh 的服务要求显式传入 signal。 */
const turnSignal = () => AbortSignal.timeout(TURN_TIMEOUT_MS)

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, PATCH, DELETE, OPTIONS',
  'access-control-allow-headers': 'Content-Type, Authorization',
  'access-control-max-age': '86400',
}

//#region 小工具

/** JSON 响应。 */
function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...CORS_HEADERS },
  })
}

/** 从任意形状里取 sessionId。 */
function readSessionId(value) {
  if (typeof value !== 'string') return undefined
  const trimmed = value.trim()
  return trimmed.length === 0 ? undefined : trimmed
}

/** 终态判断：把各种成功/失败形状归一。 */
function isOk(value) {
  if (value === null || typeof value !== 'object') return false
  if (value.ok === false) return false
  return true
}
//#endregion

export function apply(ctx) {
  const webServer = ctx.webServer
  if (webServer?.register === undefined) {
    ctx.logger?.warn?.('[app-bridge] 没有 webServer，接口未挂载')
    return
  }

  // 这些服务在自己的 fiber 激活前取不到（ctx.get 只看 active 的提供方），
  // 而本插件挂载得比它们早 —— 所以每次用到时现取，不要缓存成常量。
  const sessions = () => ctx.get('sessionController')
  const workspaces = () => ctx.get('workspaceController')
  const loader = ctx.loader

  /** 模型目录缓存。 */
  let catalogCache
  /** 会话标题缓存：sessionId → 标题。 */
  const titleCache = new Map()
  /** 挂起中的审批：approvalId → {sessionId, tool, reason, settle} */
  const pendingApprovals = new Map()
  /**
   * 延后待答（阻塞窗口到期后仍想被答复的项）：id → 条目。
   *
   * 与 pending* 的区别：这里的东西**不再阻塞任何一轮对话**（本轮已经结束了），
   * 只是"还欠用户一个决定"。App / 电脑端仍会看到卡片，答复时走续跑：
   * App 侧生成一条结构化消息重新起一轮，把原来的问题/申请和用户的决定带进去。
   */
  const deferredQuestions = new Map()
  const deferredApprovals = new Map()

  /** 把到期的选择框转进延后清单（保留原问题内容，供晚点答复与续跑）。 */
  function deferQuestion(entry) {
    deferredQuestions.set(entry.questionId, {
      questionId: entry.questionId,
      sessionId: entry.sessionId,
      questions: entry.questions,
      createdAt: entry.createdAt,
      deferredAt: Date.now(),
    })
    pruneDeferred()
  }

  /** 把到期的审批转进延后清单。 */
  function deferApproval(entry) {
    deferredApprovals.set(entry.approvalId, {
      approvalId: entry.approvalId,
      sessionId: entry.sessionId,
      tool: entry.tool,
      reason: entry.reason ?? '',
      createdAt: entry.createdAt,
      deferredAt: Date.now(),
    })
    pruneDeferred()
  }

  /** 延后项超过 24 小时就丢掉（人隔天回来仍能看到，再久就不留了）。 */
  function pruneDeferred() {
    const now = Date.now()
    for (const [id, item] of deferredQuestions) {
      if (now - item.deferredAt > DEFERRED_TTL_MS) deferredQuestions.delete(id)
    }
    for (const [id, item] of deferredApprovals) {
      if (now - item.deferredAt > DEFERRED_TTL_MS) deferredApprovals.delete(id)
    }
  }
  /** 挂起中的选择框：questionId → {sessionId, questions, settle, timer, createdAt} */
  const pendingQuestions = new Map()
  /** 桥接最近一次来轮询选择框的时间戳（用于判定 App 侧是否在线）。 */
  let lastQuestionPollAt = 0
  /** 桥接最近一次来轮询审批的时间戳（同上，审批与选择框各自独立计时）。 */
  let lastApprovalPollAt = 0

  /**
   * 按 sessionId 拿到 **会话对象**（不是 API 层的 sessionId 字符串）。
   *
   * 为什么需要：切换权限预设要用 `permissionPresets.apply(session, …)`，它内部会
   * `session.append('permission/preset', …)` —— 必须是真的会话对象。API 层的
   * sessionController 只吃 sessionId，拿不到它，所以这里走内部的 sessions 服务。
   */
  async function resolveSessionObject(sessionId) {
    const service = ctx.get('sessions')
    if (service === undefined) return undefined
    for (const method of ['get', 'resolve']) {
      if (typeof service[method] !== 'function') continue
      try {
        const found = await service[method](sessionId)
        if (found?.append !== undefined || found?.id === sessionId) return found
      } catch {
        /* 换下一个方法试 */
      }
    }
    if (typeof service.list === 'function') {
      try {
        for (const session of service.list()) {
          if (session?.id === sessionId) return session
        }
      } catch {
        /* 忽略：交给调用方报"会话不在活动列表" */
      }
    }
    return undefined
  }

  /** 找出该会话当前活跃的 agent（有它才能改"正在跑的这一轮"的审批策略）。 */
  function findLiveAgentForSession(sessionId) {
    const agents = ctx.get('agents')
    if (agents === undefined) return undefined
    const pool = []
    try {
      if (typeof agents.roots === 'function') pool.push(...agents.roots())
    } catch {
      /* 忽略 */
    }
    try {
      if (typeof agents.list === 'function') pool.push(...agents.list())
    } catch {
      /* 忽略 */
    }
    for (const agent of pool) {
      if (agent?.session?.id === sessionId) return agent
    }
    return undefined
  }

  /**
   * 真正切换某个会话的权限预设（= DSH 内置 `/permission` 命令的同一条路径）。
   *
   * 为什么抽成一个函数：**两处**调用点以前都靠"排一条 `/permission <preset>` 文本"，
   * 以为 DSH 会把它当命令执行 —— 实际只是一条普通用户消息。表现就是：用户每次从
   * 手机发消息，会话里都会多一条 `/permission xxx` 垃圾（和正文同一秒进同一个 turn，
   * 在 GUI 队列里看着像"成对消息"），而权限预设从未真正改变。现在两处统一走这里。
   *
   * @returns `{ ok, current, live, reason }`——ok 为 false 时 reason 说明原因
   */
  async function switchSessionPermission(sessionId, preset) {
    const service = ctx.get('permissionPresets')
    if (typeof service?.apply !== 'function') {
      return { ok: false, reason: 'permissionPresets.apply 不可用：DSH 版本过旧或插件未加载' }
    }
    const names = Array.isArray(service.names) ? service.names : []
    if (names.length > 0 && !names.includes(preset)) {
      return { ok: false, reason: `未知权限预设 "${preset}"（可用：${names.join(', ')}）` }
    }
    const session = await resolveSessionObject(sessionId)
    if (session === undefined) {
      return { ok: false, reason: `会话 ${sessionId} 不在活动列表里，无法即时切换` }
    }
    const agent = findLiveAgentForSession(sessionId)
    if (agent !== undefined && typeof ctx.get('approval')?.setPolicy === 'function') {
      // 会话正在跑：连"当前这轮"的审批策略一起改（内置命令用的是同一个实时写法）
      service.apply(session, preset, (policy) => ctx.get('approval').setPolicy(agent, policy))
    } else {
      // 没有活跃 agent：写持久化事实 + 会话级开关，下一轮生效
      service.set(session, preset)
    }
    const current = typeof service.current === 'function' ? service.current(session) : undefined
    return {
      ok: current === undefined ? true : current === preset,
      current,
      live: agent !== undefined,
    }
  }

  //#region 数据读取

  /** 读模型目录（带短缓存）。 */
  async function catalog() {
    const now = Date.now()
    if (catalogCache !== undefined && now - catalogCache.at < CATALOG_TTL_MS) return catalogCache.value
    if (sessions() === undefined) return { groups: [], failures: [], default: undefined }
    try {
      const value = await sessions().modelCatalog()
      catalogCache = { at: now, value }
      return value
    } catch (error) {
      ctx.logger?.warn?.(`[app-bridge] modelCatalog 读取失败: ${String(error?.message ?? error)}`)
      return { groups: [], failures: [], default: undefined }
    }
  }

  /** 找某个模型 id 属于哪个 provider。 */
  async function providerOf(modelId) {
    const value = await catalog()
    for (const group of value.groups ?? []) {
      for (const model of group.models ?? []) if (model.id === modelId) return group.id
    }
    return value.default?.provider
  }

  /** /v1/models 的载荷：把 provider 分组拍平成模型数组（bridge 直接透传给 App）。 */
  async function modelsPayload() {
    const value = await catalog()
    const models = []
    for (const group of value.groups ?? []) {
      for (const model of group.models ?? []) {
        models.push({
          id: model.id,
          name: model.name ?? model.id,
          provider: group.id,
          ...(model.description === undefined ? {} : { description: model.description }),
          ...(model.reasoning === undefined ? {} : {
            reasoningEfforts: (model.reasoning.efforts ?? []).map((effort) => effort.id),
            defaultEffort: model.reasoning.defaultEffort,
          }),
        })
      }
    }
    return {
      models,
      providers: (value.groups ?? []).map((group) => ({ id: group.id, name: group.name, count: (group.models ?? []).length })),
      failures: value.failures ?? [],
      default: value.default ?? null,
    }
  }

  /**
   * 取会话标题。dsh 的标题是**投影值**（`session.list` 的
   * `projections.values.title`），所以先直接吃投影；投影缺失时才退回翻日志里的
   * `session/title` 事件或第一条用户消息。
   */
  async function titleOf(sessionId, projected) {
    if (typeof projected === 'string' && projected.length > 0) {
      titleCache.set(sessionId, projected)
      return projected
    }
    if (titleCache.has(sessionId)) return titleCache.get(sessionId)
    let title
    if (sessions() !== undefined) {
      try {
        const page = await sessions().page({ address: { kind: 'session', sessionId }, throughSeq: Number.MAX_SAFE_INTEGER, maxMessages: 60 }, turnSignal())
        for (const record of [...(page?.records ?? [])].reverse()) {
          const event = record?.event
          if (event?.type === 'session/title') {
            const candidate = event.data?.title ?? event.data?.name
            if (typeof candidate === 'string' && candidate.length > 0) { title = candidate; break }
          }
          if (event?.type === 'user/message' && title === undefined) {
            const text = firstText(event.data)
            if (text !== undefined) title = text.slice(0, 40)
          }
        }
      } catch {
        /* 读不到标题就用兜底 */
      }
    }
    if (title === undefined) title = `会话_${sessionId.slice(0, 6)}`
    titleCache.set(sessionId, title)
    return title
  }

  /** 从消息事件里抠出第一段文本。 */
  function firstText(data) {
    const blocks = data?.message?.content ?? data?.content
    if (!Array.isArray(blocks)) return undefined
    for (const block of blocks) {
      if (typeof block?.text === 'string' && block.text.trim().length > 0) return block.text.trim()
    }
    return undefined
  }

  /** 声明式工作区列表（有 workspaces() 就用它）。拿不到时返回空数组。 */
  async function declaredWorkspaces() {
    if (workspaces() !== undefined) {
      try {
        const value = await workspaces().list()
        const items = (value?.items ?? []).map((item) => ({
          id: item.workspaceId,
          name: item.title ?? item.path,
          title: item.title,
          path: item.path,
          sessions: (item.sessionIds ?? []).length,
        }))
        if (items.length > 0) return items
      } catch {
        /* 交给调用方从会话 cwd 归纳 */
      }
    }
    return []
  }

  /**
   * 工作区列表。
   *
   * 此前 workspaceController.list() 取不到时直接编一个名为 'deepseek-agent' 的
   * 假工作区，用户会看到一个并不存在的目录名。改为：拿不到就**从会话的真实 cwd
   * 归纳**（会话列表本身是可用的），仍然拿不到才返回空数组，让 App 明确显示
   * "未取到目录"而不是展示假值。
   */
  async function workspacesPayload(sessionItems) {
    const declared = await declaredWorkspaces()
    if (declared.length > 0) return declared

    const seen = new Set()
    const derived = []
    for (const item of sessionItems ?? []) {
      const cwd = typeof item?.cwd === 'string' ? item.cwd.trim() : ''
      if (!cwd || seen.has(cwd)) continue
      seen.add(cwd)
      derived.push({ id: cwd, name: cwd, title: cwd })
    }
    return derived
  }

  /**
   * 从会话投影里读**真实生效**的模型档位与权限预设。
   *
   * 为什么需要：App 的 `agentModel / agentReasoningEffort / agentPermission` 此前
   * 只写不读 —— 首次启动时界面显示的是 App 自己存的旧值，和 DSH 会话里实际生效的
   * 档位对不上，而且下一条消息还会把旧值**推回** DSH，把电脑端的设置覆盖掉。
   *
   * 这两个投影本来就随会话列表一起下发（DSH 自己的 Web 端就是这么读的：
   * `modelSelection` 的视图是 `{lastUsed, next}`，`permissions` 的视图是
   * `{options, currentValue}`），直接透出去即可，不需要新接口。
   *
   * @param item - `session.list` 返回的会话摘要（含 `projections.values`）
   * @returns `{provider?, model?, reasoningEffort?, permission?}`；读不到的键直接不出现，
   *          让 App 保持原值，绝不拿空值覆盖用户设置
   */
  function sessionStateFields(item) {
    const fields = {}
    const selection = item?.projections?.values?.modelSelection
    // 视图是 {lastUsed, next}：next = 用户已选定但还没跑过的档位，也就是"下次请求会用"的档位
    const picked = selection?.next ?? selection?.lastUsed
    if (typeof picked?.provider === 'string' && picked.provider.length > 0) fields.provider = picked.provider
    if (typeof picked?.model === 'string' && picked.model.length > 0) fields.model = picked.model
    if (typeof picked?.reasoningEffort === 'string' && picked.reasoningEffort.length > 0) {
      fields.reasoningEffort = picked.reasoningEffort
    }
    const preset = item?.projections?.values?.permissions?.currentValue
    if (typeof preset === 'string' && preset.length > 0) fields.permission = preset
    return fields
  }

  /** /v1/sessions 的载荷。 */
  async function sessionsPayload() {
    const controller = sessions()
    const value = controller === undefined ? { items: [] } : await controller.list({}, turnSignal())
    const items = value?.items ?? []
    const workspaceList = await workspacesPayload(items)
    const rows = []
    for (const item of items) {
      // 会话没有 cwd 时不再编造名称，留空让 App 明确显示"未知目录"
      const workspace = typeof item.cwd === 'string' && item.cwd.length > 0
        ? item.cwd
        : (workspaceList[0]?.name ?? '')
      rows.push({
        id: item.sessionId,
        sessionId: item.sessionId,
        title: await titleOf(item.sessionId, item.projections?.values?.title),
        workspace,
        cwd: item.cwd,
        running: item.running === true,
        updatedAt: item.updatedAt ?? Date.now(),
        ...(item.parentSessionId === undefined ? {} : { parentSessionId: item.parentSessionId }),
        // 真实档位/权限（读不到就不出现这些键，App 侧保持原值）
        ...sessionStateFields(item),
      })
    }
    return { workspaces: workspaceList.map((entry) => entry.name), sessions: rows, items: rows }
  }
  //#endregion

  //#region 一轮对话

  /**
   * 起一轮对话：先对齐模型，再把 prompt 入队，然后开 SSE 帧流。
   * @returns {ReadableStream|null} SSE 流；入队失败时抛错。
   */
  async function startTurn(body) {
    if (sessions() === undefined) throw new Error('sessionController 服务缺失')
    const prompt = typeof body.prompt === 'string' ? body.prompt : (typeof body.text === 'string' ? body.text : '')
    if (prompt.trim().length === 0) throw new Error('缺少 prompt')
    const model = typeof body.model === 'string' && body.model.length > 0 ? body.model : undefined
    const effort = body.reasoningEffort ?? body.reasoning_effort
    const permission = typeof body.permission === 'string' && body.permission.length > 0 ? body.permission : undefined

    // 1) 会话：给定 id 就续聊，否则新建
    let sessionId = readSessionId(body.sessionId) ?? readSessionId(body.session_id)
    if (sessionId === undefined) {
      const cwd = await resolveCwd(body.workspace)
      const created = await sessions().create(cwd === undefined ? {} : { cwd })
      sessionId = created?.sessionId
      if (typeof sessionId !== 'string') throw new Error('新建会话失败')
    }

    // 2) 模型 / 推理档位
    if (model !== undefined || typeof effort === 'string') {
      const provider = typeof body.provider === 'string' && body.provider.length > 0 ? body.provider : await providerOf(model ?? '')
      if (provider !== undefined) {
        try {
          await sessions().selectModel({
            sessionId,
            provider,
            model: model ?? '',
            ...(typeof effort === 'string' && effort !== 'default' ? { reasoningEffort: effort } : {}),
          })
        } catch (error) {
          ctx.logger?.warn?.(`[app-bridge] selectModel 失败(忽略): ${String(error?.message ?? error)}`)
        }
      }
    }

    // 3) 权限预设：调真接口即时切换
    //
    // ⚠️ 这里以前是 sessions().prompt({ mode:'queue', content:[{text:`/permission ${permission}`}] })，，
    // 以为 DSH 会把排队的文本当命令执行。实测不是：它只是一条普通用户消息，于是
    // **用户每从手机发一条消息，会话里就多一条 /permission 垃圾**（和正文同一秒进
    // 同一个 turn，在 GUI 队列里看着就是"成对消息"），而权限预设从未真正改变。
    if (typeof permission === 'string' && permission.length > 0) {
      try {
        const switched = await switchSessionPermission(sessionId, permission)
        if (!switched.ok) {
          ctx.logger?.warn?.(
            `[app-bridge] 本轮权限下发未生效：${switched.reason ?? `current=${switched.current ?? '未知'}`}`,
          )
        }
      } catch (error) {
        ctx.logger?.warn?.(`[app-bridge] 本轮权限下发异常(忽略): ${String(error?.message ?? error)}`)
      }
    }

    // 4) 记下当前日志水位，之后只推更新的帧
    let sinceSeq = 0
    try {
      const page = await sessions().page({ address: { kind: 'session', sessionId }, throughSeq: Number.MAX_SAFE_INTEGER, maxMessages: 1 }, turnSignal())
      const records = page?.records ?? []
      const last = records[records.length - 1]?.event?.seq
      if (typeof last === 'number') sinceSeq = last
    } catch {
      /* 读不到就从 0 开始 */
    }

    // 5) 入队
    await sessions().prompt({
      requestId: randomUUID(),
      sessionId,
      mode: 'queue',
      content: [{ type: 'text', text: prompt }],
    }, turnSignal())

    return { sessionId, sinceSeq }
  }

  /** workspace 名 → cwd（能对应上工作区就用它的 path）。 */
  async function resolveCwd(workspace) {
    if (typeof workspace !== 'string' || workspace.length === 0) return undefined
    const list = await workspacesPayload()
    const hit = list.find((entry) => entry.name === workspace || entry.title === workspace || entry.id === workspace)
    return hit?.path
  }

  /**
   * 把会话帧流翻译成 bridge 认识的 SSE。
   * @param controller - ReadableStreamDefaultController
   * @param sessionId - 会话
   * @param sinceSeq - 只推 seq 大于它的事件
   */
  async function pumpSse(controller, sessionId, sinceSeq) {
    const encoder = new TextEncoder()
    const send = (event, data) => {
      try {
        controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`))
      } catch {
        /* 客户端已断开 */
      }
    }

    let emittedContent = ''
    let currentTurn
    let finished = false
    const heartbeat = setInterval(() => {
      try {
        controller.enqueue(encoder.encode(': keep-alive\n\n'))
      } catch {
        /* 已断开 */
      }
    }, HEARTBEAT_MS)

    try {
      const frames = sessions().follow({ address: { kind: 'session', sessionId }, maxMessages: HISTORY_PAGE }, turnSignal())
      for await (const frame of frames) {
        if (frame?.type === 'snapshot') {
          if (typeof frame.cursor === 'number' && frame.cursor > sinceSeq) sinceSeq = frame.cursor
          continue
        }
        const event = frame?.event
        if (event === undefined) continue
        if (typeof event.seq === 'number' && event.seq <= sinceSeq) continue

        const data = event.data ?? {}
        switch (event.type) {
          case 'turn/start': {
            currentTurn = data.turn
            break
          }
          case 'assistant/message': {
            const text = firstText(data) ?? textOfMessage(data?.message)
            if (text !== undefined && text.length > emittedContent.length && text.startsWith(emittedContent.slice(0, Math.min(24, emittedContent.length)))) {
              send('content', { content: text.slice(emittedContent.length) })
              emittedContent = text
            } else if (text !== undefined && !emittedContent.includes(text)) {
              send('content', { content: text })
              emittedContent += text
            }
            break
          }
          case 'tool/call': {
            send('tool_start', { id: data.callId, tool: data.name, input: data.arguments })
            break
          }
          case 'tool/result': {
            send('tool_end', {
              id: data.message?.toolCallId ?? data.callId,
              tool: data.message?.toolName ?? data.name ?? 'tool',
              output: shorten(data.message?.content),
              status: data.error === undefined ? 'success' : 'error',
            })
            break
          }
          case 'approval/asked': {
            send('waiting_approval', { approvalId: data.id, tool: data.toolName })
            break
          }
          case 'approval/decided': {
            send('approval_resolved', { approvalId: data.id, outcome: data.outcome })
            break
          }
          case 'turn/end': {
            if (currentTurn === undefined || data.turn === currentTurn) {
              finished = true
              send('done', { sessionId, status: 'completed' })
            }
            break
          }
          default:
            break
        }
        if (finished) break
      }
    } catch (error) {
      send('error', { message: String(error?.message ?? error) })
    } finally {
      clearInterval(heartbeat)
      try {
        controller.close()
      } catch {
        /* 已关闭 */
      }
    }
  }

  /** 把工具结果裁短，避免 SSE 行过长。 */
  function shorten(content, limit = 600) {
    if (typeof content === 'string') return content.length > limit ? `${content.slice(0, limit)}…` : content
    if (Array.isArray(content)) {
      const text = content.map((block) => (typeof block?.text === 'string' ? block.text : '')).join(' ').trim()
      return text.length > limit ? `${text.slice(0, limit)}…` : text
    }
    return ''
  }

  /** 从 AssistantMessage 里取文本。 */
  function textOfMessage(message) {
    const blocks = message?.content
    if (!Array.isArray(blocks)) return undefined
    const text = blocks.map((block) => (typeof block?.text === 'string' ? block.text : '')).join('')
    return text.trim().length === 0 ? undefined : text
  }
  //#endregion

  //#region 审批桥

  /**
   * 中止某个会话正在跑的那一轮。
   *
   * 用在哪：待答/待批挂满硬上限（24h）时，必须**主动结束这一轮**而不是把空答复
   * 交回模型 —— 后者会让主模型接着替用户说话（用户实测反馈过这个问题）。
   */
  async function abortTurnForSession(sessionId) {
    if (typeof sessionId !== 'string' || sessionId.length === 0) return
    const controller = sessions()
    if (controller === undefined || typeof controller.cancel !== 'function') return
    try {
      await controller.cancel({ sessionId }, turnSignal())
      ctx.logger?.info?.(`[app-bridge] 已中止会话 ${sessionId} 的当前轮次（挂起超时）`)
    } catch (error) {
      ctx.logger?.warn?.(`[app-bridge] 中止轮次失败（忽略）: ${String(error?.message ?? error)}`)
    }
  }

  // 挂上 answerer：App 没答复就一直挂着（dsh 侧等待），答复后返回结果。
  //
  // 只在桥接最近 APPROVAL_ARM_MS 内来轮询过时才接管（App 通路在线）；否则原样
  // next() 交给电脑端网页弹窗 —— 与选择框同一套"谁在线谁接手"的规矩。
  //
  // 为什么以前"文件沙箱审批到不了 App"：审批原先只走任务 SSE 流（waiting_approval），
  // 也就是只有"手机发起、且流还连着"的那一轮才可能被看到；DSH 网页端自己跑的任务、
  // 或沙箱越权升级（sandbox_permissions）产生的审批，手机侧永远收不到。现在审批和
  // 选择框一样由桥接 1 秒轮询取走，跟具体哪一轮、哪个流都无关。
  ctx.on('approval/request', (request, next) => {
    const sessionId = request?.agent?.session?.id
    if (typeof sessionId !== 'string') return next()
    const armed = Date.now() - lastApprovalPollAt <= APPROVAL_ARM_MS
    if (!armed) return next()
    const approvalId = typeof request?.id === 'string' ? request.id : randomUUID()
    const tool = typeof request?.toolName === 'string' ? request.toolName : 'tool'
    const reason = typeof request?.reason === 'string' ? request.reason : ''
    return new Promise((resolve) => {
      const entry = { approvalId, sessionId, tool, reason, settle: resolve, createdAt: Date.now() }
      pendingApprovals.set(approvalId, entry)
      ctx.logger?.info?.(`[app-bridge] 审批 ${approvalId} 等待 App 决定（${tool}${reason.length > 0 ? `｜${reason}` : ''}）`)
      const timer = setTimeout(() => {
        // 「等久了」：只打标记，继续挂着等 —— 不返回任何结果，模型不会说话
        const live = pendingApprovals.get(approvalId)
        if (live === undefined) return
        live.stale = true
        ctx.logger?.warn?.(`[app-bridge] 审批 ${approvalId} 已等待 ${Math.round(APPROVAL_WAIT_NOTICE_MS / 1000)}s，继续挂起（本轮不交给模型，卡片留在 App）`)
      }, APPROVAL_WAIT_NOTICE_MS)
      // 硬上限：中止这一轮（不替用户做否定决定），待办转成"已中止"，晚点批准走续跑
      const parkTimer = setTimeout(() => {
        const live = pendingApprovals.get(approvalId)
        if (live === undefined) return
        pendingApprovals.delete(approvalId)
        deferApproval(live)
        ctx.logger?.warn?.(`[app-bridge] 审批 ${approvalId} 挂起已满 ${Math.round(PARK_MAX_MS / 3600000)}h，中止本轮并转为延后待批（批准走续跑）`)
        abortTurnForSession(sessionId)
        resolve('cancelled')
      }, PARK_MAX_MS)
      entry.timer = timer
      entry.parkTimer = parkTimer
    })
  })

  /**
   * 答复一个审批。
   *
   * @returns `{settled, delivered, deferred}`：deferred=true 表示那一轮早就结束了
   *          （超过阻塞窗口后按"撤销"收场），App 侧应当走**续跑**重试该操作。
   */
  function answerApproval(approvalId, action) {
    const entry = pendingApprovals.get(approvalId)
    if (entry === undefined) {
      if (deferredApprovals.delete(approvalId)) {
        return { settled: true, delivered: false, deferred: true }
      }
      return { settled: false, delivered: false, deferred: false }
    }
    pendingApprovals.delete(approvalId)
    clearTimeout(entry.timer)
    clearTimeout(entry.parkTimer)
    const allow = action === 'allow' || action === 'allowed-once' || action === 'approve' || action === true
    entry.settle(allow ? 'allowed-once' : 'rejected')
    return { settled: true, delivered: true, deferred: false }
  }
  //#endregion

  //#region 选择框桥（ask_user_question）

  /**
   * 把 DSH 的 `ask_user_question` 接到 App 上。
   *
   * 背景：`ask_user_question` 走 `ctx.userQuestions`（waterfall 事件
   * `user-questions/request`），官方只有浏览器界面会应答；而桥接脚本吃的是
   * 任务事件流，里面根本没有 question 事件 —— 所以 App 在结构上永远收不到
   * 选择框（实测：问一句"3+3=几"，手机和电脑 App 全程静默，只有网页弹窗）。
   * 这里补上那个 answerer：问题排队 → 桥接脚本轮询取走 → 经中继推给 App。
   *
   * ⚠️ 必须 prepend 到最外层：内置网页端的 answerer 是浏览器连上来时才注册的，
   * 而且它**不调用 next()** 就直接接管（用户不点弹窗就永远等着）。实测过一次：
   * 问题被网页端吞掉，App 侧 3 分钟里一次都没被通知到。prepend 之后本插件先跑，
   * 再把 next() 并行接上 —— 网页端弹窗照旧，App 侧也能同时拿到，谁先答谁生效。
   *
   * 只在桥接最近 QUESTION_ARM_MS 内来过轮询时接管（App 不在线就原样 next()，
   * 行为和装这个功能之前完全一致）。
   */
  ctx.on('user-questions/request', async (request, next) => {
    const sessionId = readQuestionSessionId(request)
    const armed = Date.now() - lastQuestionPollAt <= QUESTION_ARM_MS
    ctx.logger?.info?.(`[app-bridge] 收到选择框请求（session=${sessionId ?? '未知'}，App 通路${armed ? '在线，交给 App' : '不在线，交回网页端'}）`)
    if (!armed) return next()

    const questionId = randomUUID()
    const questions = Array.isArray(request?.questions) ? request.questions : []
    let settle
    const answered = new Promise((resolve) => { settle = resolve })
    const entry = { questionId, sessionId, questions, settle, createdAt: Date.now(), timer: undefined }
    pendingQuestions.set(questionId, entry)
    ctx.logger?.info?.(`[app-bridge] 选择框 ${questionId} 已排给 App（${questions.length} 个问题）`)
    entry.timer = setTimeout(() => {
      // 「等久了」：只打标记，**不结束本轮、不返回空答复** ——
      // 一旦返回空答复，DSH 会认为"用户没答，继续"，主模型就会接着说话。
      const live = pendingQuestions.get(questionId)
      if (live === undefined) return
      live.stale = true
      ctx.logger?.warn?.(`[app-bridge] 选择框 ${questionId} 已等待 ${Math.round(WAIT_NOTICE_MS / 1000)}s，继续挂起（本轮不交给模型，卡片留在 App）`)
    }, WAIT_NOTICE_MS)

    // 硬上限：到点中止这一轮（模型不会说话），待办转为"已中止"，用户晚点答复走续跑
    entry.parkTimer = setTimeout(() => {
      const live = pendingQuestions.get(questionId)
      if (live === undefined) return
      pendingQuestions.delete(questionId)
      deferQuestion(live)
      ctx.logger?.warn?.(`[app-bridge] 选择框 ${questionId} 挂起已满 ${Math.round(PARK_MAX_MS / 3600000)}h，中止本轮并转为延后待答（答复走续跑）`)
      abortTurnForSession(sessionId)
      settle({ kind: 'deferred' })
    }, PARK_MAX_MS)

    // ⚠️ 这里**不再与网页端并发抢答**（曾经是 Promise.race）。
    //
    // 为什么改：两边同时弹框时，若 App 先答，插件这边就返回了、工具调用结束，
    // 但网页端那个 answerer 仍在等用户点 —— 它的弹窗会**一直挂在界面上**，
    // 用户以为"手机答了但 DSH 没反应"（截图确认过：手机已答、网页弹窗还在）。
    //
    // 现在 App 在线（桥接在轮询）时由 App 独占：问题只推给 App，网页端不弹框；
    // 只有 App 超时/主动放弃时才调用 next() 把问题交回网页端 —— 那一刻弹窗
    // 才出现，且不会再有"答完了还挂着"的脏状态。
    try {
      const outcome = await answered
      if (outcome?.kind === 'answered') return outcome.answers
      // 延后待答：本轮就此结束（返回空答复 = "用户没答"），不再 next() 去挂网页弹窗 ——
      // 那正是"人不在电脑前时整轮永久卡住"的来源。
      if (outcome?.kind === 'deferred') return { answers: [] }
      // App 主动放弃：这时才交回电脑端界面
      return await Promise.resolve().then(() => next())
    } finally {
      const live = pendingQuestions.get(questionId)
      if (live !== undefined) {
        pendingQuestions.delete(questionId)
        clearTimeout(live.timer)
        clearTimeout(live.parkTimer)
      }
    }
  }, { prepend: true })

  /** 取提问所属会话：DSH 不同版本给的字段位置不完全一样，都兜一下。 */
  function readQuestionSessionId(request) {
    const candidates = [request?.agent?.session?.id, request?.agent?.sessionId, request?.sessionId]
    for (const value of candidates) {
      if (typeof value === 'string' && value.length > 0) return value
    }
    return undefined
  }

  /**
   * 答复一个选择框：answers 形如 `[{id, selected:[...], custom?}]`。
   *
   * @returns `{settled, delivered, deferred}`：deferred=true 表示这条已经不在等
   *          任何一轮对话（本轮早已结束），App 侧应当走**续跑**把答案发回同一会话。
   */
  function answerQuestion(questionId, answers) {
    const entry = pendingQuestions.get(questionId)
    if (entry === undefined) {
      // 延后待答：这里只做"用户已处理"的销账，真正的续跑由 App 发起
      if (deferredQuestions.delete(questionId)) {
        return { settled: true, delivered: false, deferred: true }
      }
      return { settled: false, delivered: false, deferred: false }
    }
    pendingQuestions.delete(questionId)
    clearTimeout(entry.timer)
    clearTimeout(entry.parkTimer)
    const clean = (Array.isArray(answers) ? answers : [])
      .map((item) => ({
        id: typeof item?.id === 'string' ? item.id : String(item?.id ?? ''),
        selected: Array.isArray(item?.selected) ? item.selected.map((value) => String(value)) : [],
        ...(typeof item?.custom === 'string' && item.custom.length > 0 ? { custom: item.custom } : {}),
      }))
      .filter((item) => item.id.length > 0)
    entry.settle({ kind: 'answered', answers: { answers: clean } })
    return { settled: true, delivered: true, deferred: false }
  }

  /** 放弃在 App 上回答 → 交回电脑端界面（延后项则只是销账）。 */
  function declineQuestion(questionId) {
    const entry = pendingQuestions.get(questionId)
    if (entry === undefined) {
      if (deferredQuestions.delete(questionId)) {
        return { settled: true, delivered: false, deferred: true }
      }
      return { settled: false, delivered: false, deferred: false }
    }
    pendingQuestions.delete(questionId)
    clearTimeout(entry.timer)
    clearTimeout(entry.parkTimer)
    entry.settle({ kind: 'handoff' })
    return { settled: true, delivered: true, deferred: false }
  }

  /** 待答清单（桥接脚本轮询用；这次轮询同时表示「App 侧在线」）。 */
  function questionsPayload() {
    pruneDeferred()
    return {
      status: 'success',
      questions: [
        ...[...pendingQuestions.values()].map((entry) => ({
          questionId: entry.questionId,
          sessionId: entry.sessionId,
          createdAt: entry.createdAt,
          questions: entry.questions,
          // pending: 刚问不久 ｜ waiting: 等超过 5 分钟但**仍在等**（本轮不会交给模型）
          // orphaned: 挂满 24h 已中止本轮，答复要走续跑
          state: entry.stale === true ? 'waiting' : 'pending',
          deferred: false,
        })),
        // 已中止的延后项：本轮结束了，但答案仍想要（App 侧答复时走续跑）
        ...[...deferredQuestions.values()].map((entry) => ({
          questionId: entry.questionId,
          sessionId: entry.sessionId,
          createdAt: entry.createdAt,
          questions: entry.questions,
          state: 'orphaned',
          deferred: true,
          deferredAt: entry.deferredAt,
        })),
      ],
    }
  }

  /**
   * 待审批清单（桥接脚本轮询用，与选择框同一套机制）。
   *
   * 带 `reason`：文件沙箱升级这类审批的理由（"写入工作区之外"等）是用户判断
   * 该不该放行的关键信息，只给工具名等于让人盲签。这次轮询同时充当
   * 「App 侧在线」的心跳（见 APPROVAL_ARM_MS）。
   */
  function approvalsPayload() {
    pruneDeferred()
    return {
      status: 'success',
      approvals: [
        ...[...pendingApprovals.entries()].map(([approvalId, entry]) => ({
          approvalId,
          sessionId: entry.sessionId,
          tool: entry.tool,
          reason: entry.reason ?? '',
          createdAt: entry.createdAt,
          state: entry.stale === true ? 'waiting' : 'pending',
          deferred: false,
        })),
        // 已中止的延后项：那一轮结束了，晚点批准会以续跑方式重试该操作
        ...[...deferredApprovals.values()].map((entry) => ({
          approvalId: entry.approvalId,
          sessionId: entry.sessionId,
          tool: entry.tool,
          reason: entry.reason ?? '',
          createdAt: entry.createdAt,
          state: 'orphaned',
          deferred: true,
          deferredAt: entry.deferredAt,
        })),
      ],
    }
  }
  //#endregion

  //#region 路由注册（node:http 原生路由 + Fetch 形态适配）

  /** 读原始 body 文本（上限 8MB）。 */
  function readRaw(req) {
    return new Promise((resolve, reject) => {
      const chunks = []
      let size = 0
      req.on('data', (chunk) => {
        size += chunk.length
        if (size > 8 * 1024 * 1024) {
          reject(new Error('请求体过大'))
          req.destroy()
          return
        }
        chunks.push(chunk)
      })
      req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
      req.on('error', reject)
    })
  }

  /** 把 Fetch 形态的 Response 写回 node 响应（支持流式）。 */
  async function writeResponse(res, response) {
    const headers = {}
    for (const [key, value] of response.headers) headers[key] = value
    res.writeHead(response.status, headers)
    if (response.body === null) {
      res.end()
      return
    }
    const reader = response.body.getReader()
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      // 背压：缓冲区满了就等排空，避免长回答把内存吃光
      if (!res.write(Buffer.from(value))) await new Promise((resolve) => res.once('drain', resolve))
    }
    res.end()
  }

  /**
   * 注册一条路由。kind 为 exact（如 /health）或 prefix（如 /v1）。
   * handler 仍然收 Fetch 的 Request、返回 Fetch 的 Response —— 便于按 bridge 的契约书写。
   */
  function page(kind, path, handler) {
    ctx.effect(() => webServer.register({
      kind,
      path,
      handler: async (req, res) => {
        try {
          if (req.method === 'OPTIONS') {
            res.writeHead(204, CORS_HEADERS)
            res.end()
            return
          }
          // 官方同款信任栅栏：Host/Origin 不合法直接 403（防 DNS rebinding）
          const rejection = ctx.get('connection')?.requestRejection?.(req)
          if (rejection !== undefined) {
            res.writeHead(rejection, CORS_HEADERS)
            res.end(rejection === 401 ? 'unauthorized' : 'forbidden')
            return
          }
          const raw = req.method === 'GET' || req.method === 'HEAD' ? undefined : await readRaw(req)
          const request = new Request(new URL(req.url ?? '/', `http://${req.headers.host ?? '127.0.0.1'}`), {
            method: req.method,
            headers: req.headers,
            ...(raw === undefined || raw.length === 0 ? {} : { body: raw }),
          })
          const response = await handler(request)
          await writeResponse(res, response)
        } catch (error) {
          ctx.logger?.warn?.(`[app-bridge] ${path} 处理失败: ${String(error?.message ?? error)}`)
          if (!res.headersSent) {
            const text = JSON.stringify({ status: 'error', error: { code: 'bridge-error', message: String(error?.message ?? error) } })
            res.writeHead(500, { 'content-type': 'application/json; charset=utf-8', ...CORS_HEADERS })
            res.end(text)
          } else {
            res.end()
          }
        }
      },
    }), `app-bridge: ${path}`)
  }

  /** 读 JSON body（宽容：空体当 {}）。 */
  async function body(request) {
    try {
      const text = await request.text()
      if (text.trim().length === 0) return {}
      return JSON.parse(text)
    } catch {
      return {}
    }
  }

  //#endregion

  //#region 路由

  page('exact', '/health', async () => json(200, {
    status: 'ok',
    service: 'dsh-app-bridge',
    harness: 'deepseek-harness',
    version: '0.1.0',
    endpoints: [
      'GET /health',
      'GET /v1/models',
      'GET /v1/sessions',
      'POST /v1/sessions',
      'PATCH /v1/sessions/:id',
      'DELETE /v1/sessions/:id',
      'POST /v1/sessions/:id/abort',
      'POST /v1/sessions/:id/approve',
      'POST /v1/agent/prompt',
      'POST /v1/agent/prompt/stream',
      'POST /v1/agent/abort',
      'POST /v1/agent/approve',
      'GET /v1/plugins',
      'GET /v1/user-questions/pending',
      'POST /v1/user-questions/answer',
      'POST /v1/user-questions/decline',
    ],
  }))

  page('prefix', '/v1', async (request) => {
    const pathname = new URL(request.url).pathname
    const method = request.method

    if (pathname === '/v1/models' && method === 'GET') return json(200, await modelsPayload())
    if (pathname === '/v1/plugins' && method === 'GET') return pluginsPayload()
    if (pathname === '/v1/sessions' && method === 'GET') return json(200, await sessionsPayload())
    if (pathname === '/v1/sessions' && method === 'POST') return createSession(await body(request))

    if (pathname === '/v1/agent/abort' && method === 'POST') {
      const input = await body(request)
      const sessionId = readSessionId(input.sessionId)
      if (sessionId === undefined) return json(400, { status: 'error', error: { code: 'bad-id', message: '缺少 sessionId' } })
      await sessions().cancel({ sessionId }, turnSignal())
      return json(200, { status: 'success', sessionId, aborted: true })
    }

    if (pathname === '/v1/agent/approve' && method === 'POST') {
      const input = await body(request)
      const approvalId = typeof input.approvalId === 'string' ? input.approvalId : ''
      const result = answerApproval(approvalId, input.action ?? 'allow')
      return json(200, {
        status: 'success',
        approvalId,
        action: input.action ?? 'allow',
        settled: result.settled,
        // delivered=false + deferred=true：那一轮早已结束，App 应改为"续跑"重试该操作
        delivered: result.delivered,
        deferred: result.deferred,
      })
    }

    // ── 选择框（ask_user_question）→ 手机 App ────────────────────
    //
    // 桥接脚本每 1s 拉一次待答清单：既拿到新问题，也顺带告诉本插件
    // "App 侧在线，可以把问题交给它"（见上面的 answerer）。
    if (pathname === '/v1/user-questions/pending' && method === 'GET') {
      lastQuestionPollAt = Date.now()
      return json(200, questionsPayload())
    }

    // 审批待办清单：与选择框完全对称的一条链路，桥接 1s 轮询一次。
    // 有了它，审批不再依赖"手机发起的那一轮 SSE 流还连着" ——
    // DSH 网页端跑的任务、文件沙箱越权升级产生的审批都能推到 App 卡片上。
    if (pathname === '/v1/agent/approvals/pending' && method === 'GET') {
      lastApprovalPollAt = Date.now()
      return json(200, approvalsPayload())
    }

    if (pathname === '/v1/user-questions/answer' && method === 'POST') {
      const input = await body(request)
      const questionId = typeof input.questionId === 'string' && input.questionId.length > 0
        ? input.questionId
        : (typeof input.id === 'string' ? input.id : '')
      if (questionId.length === 0) {
        return json(400, { status: 'error', error: { code: 'bad-id', message: '缺少 questionId' } })
      }
      const result = answerQuestion(questionId, input.answers)
      if (!result.settled) {
        return json(404, {
          status: 'error',
          error: { code: 'not-found', message: '该选择框已不在等待中（已超时，或已在电脑端答复）' },
        })
      }
      return json(200, {
        status: 'success',
        questionId,
        answered: true,
        delivered: result.delivered,
        deferred: result.deferred,
      })
    }

    if (pathname === '/v1/user-questions/decline' && method === 'POST') {
      const input = await body(request)
      const questionId = typeof input.questionId === 'string' && input.questionId.length > 0
        ? input.questionId
        : (typeof input.id === 'string' ? input.id : '')
      if (questionId.length === 0) {
        return json(400, { status: 'error', error: { code: 'bad-id', message: '缺少 questionId' } })
      }
      const result = declineQuestion(questionId)
      return json(result.settled ? 200 : 404, result.settled
        ? { status: 'success', questionId, declined: true, delivered: result.delivered, deferred: result.deferred }
        : { status: 'error', error: { code: 'not-found', message: '该选择框已不在等待中' } })
    }

    if (pathname === '/v1/agent/prompt' && method === 'POST') return promptSync(await body(request))
    if (pathname === '/v1/agent/prompt/stream' && method === 'POST') return promptStream(await body(request))

    // ── 权限预设：列出 + 立即切换 ───────────────────────────────
    //
    // 为什么需要专门的接口：原先"切权限"只是把 /permission <值> 塞进下一轮对话，
    // 而且值一旦不是真实预设，DSH 会回 unknown preset 并被静默吞掉 ——
    // App 上改了看着像生效，其实什么都没发生（旧版 App 填的 ask/auto_allow/
    // read_only 全都不是合法预设名）。这里把可用预设列出来，并在切换时**立即**
    // 下发、把失败原因如实带回 App。
    if (pathname === '/v1/permission-presets' && method === 'GET') {
      const service = ctx.get('permissionPresets')
      const names = Array.isArray(service?.names) ? service.names : []
      return json(200, {
        status: 'success',
        presets: names.map((id) => ({
          id,
          name: service?.presets?.[id]?.name ?? id,
          description: service?.presets?.[id]?.description ?? '',
          sandbox: service?.presets?.[id]?.sandbox,
          approval: service?.presets?.[id]?.approval,
        })),
      })
    }

    // 读：当前会话真正生效的权限预设（App 用它显示真值，别再靠"下发成功"猜）
    if (pathname === '/v1/session/permission' && method === 'GET') {
      const query = new URL(request.url).searchParams
      const sessionId = readSessionId(query.get('sessionId'))
      if (sessionId === undefined) return json(400, { status: 'error', error: { code: 'bad-id', message: '缺少 sessionId' } })
      const service = ctx.get('permissionPresets')
      const names = Array.isArray(service?.names) ? service.names : []
      const session = await resolveSessionObject(sessionId)
      if (session === undefined) {
        return json(404, { status: 'error', error: { code: 'session-not-found', message: `会话 ${sessionId} 不在活动列表里` } })
      }
      const current = typeof service?.current === 'function' ? service.current(session) : undefined
      return json(200, { status: 'success', sessionId, preset: current, available: names })
    }

    // 读：某个会话**真实生效**的模型档位 + 权限预设（App 切会话 / 桥接上线时精准刷一次）
    if (pathname === '/v1/session/state' && method === 'GET') {
      const query = new URL(request.url).searchParams
      const sessionId = readSessionId(query.get('sessionId'))
      if (sessionId === undefined) {
        return json(400, { status: 'error', error: { code: 'bad-id', message: '缺少 sessionId' } })
      }
      if (sessions() === undefined) {
        return json(503, { status: 'error', error: { code: 'unavailable', message: 'sessionController 服务缺失' } })
      }
      // 与 /v1/sessions 读同一份投影（同源同形），避免两处各读一套、界面互相打架
      let state = {}
      try {
        const value = await sessions().list({}, turnSignal())
        const item = (value?.items ?? []).find((entry) => entry.sessionId === sessionId)
        if (item !== undefined) state = sessionStateFields(item)
      } catch (error) {
        ctx.logger?.warn?.(`[app-bridge] session/state 读投影失败: ${String(error?.message ?? error)}`)
      }
      // 权限兜底：投影里没有时问 permissionPresets.current（与切换走的是同一条真值来源）
      if (state.permission === undefined) {
        const service = ctx.get('permissionPresets')
        const session = await resolveSessionObject(sessionId)
        if (session !== undefined && typeof service?.current === 'function') {
          try {
            const current = service.current(session)
            if (typeof current === 'string' && current.length > 0) state.permission = current
          } catch {
            /* 读不到就不给这个键：App 保持原值，不用空值覆盖 */
          }
        }
      }
      return json(200, { status: 'success', sessionId, ...state })
    }

    if (pathname === '/v1/session/permission' && method === 'POST') {
      const input = await body(request)
      const sessionId = readSessionId(input.sessionId)
      if (sessionId === undefined) return json(400, { status: 'error', error: { code: 'bad-id', message: '缺少 sessionId' } })
      const preset = typeof input.preset === 'string' ? input.preset.trim() : ''
      const service = ctx.get('permissionPresets')
      const names = Array.isArray(service?.names) ? service.names : []
      if (preset.length === 0) return json(400, { status: 'error', error: { code: 'bad-preset', message: '缺少 preset' } })
      if (names.length > 0 && !names.includes(preset)) {
        return json(400, {
          status: 'error',
          error: { code: 'unknown-preset', message: `未知权限预设 "${preset}"（可用：${names.join(', ')}）` },
        })
      }
      if (typeof service?.apply !== 'function') {
        return json(503, {
          status: 'error',
          error: { code: 'unsupported', message: 'permissionPresets.apply 不可用：DSH 版本过旧或插件未加载' },
        })
      }
      // 真正的切换：与 DSH 内置 /permission 命令完全同一条路径（写 permission/preset
      // 会话事实 + 改沙箱模式 + 改审批策略）。具体实现见 switchSessionPermission，
      // 它与"每轮任务开头下发权限"共用同一段逻辑，避免两处再分叉。
      const switched = await switchSessionPermission(sessionId, preset)
      if (!switched.ok) {
        const notFound = (switched.reason ?? '').includes('不在活动列表')
        return json(notFound ? 404 : 400, {
          status: 'error',
          error: {
            code: notFound ? 'session-not-found' : 'apply-failed',
            message: switched.reason ?? `DSH 未应用该预设（当前 ${switched.current ?? '未知'}）`,
          },
        })
      }
      return json(200, {
        status: 'success',
        sessionId,
        preset,
        current: switched.current,
        applied: true,
        live: switched.live === true,
      })
    }

    // ── 思考深度：立即切换（不必等下一轮对话才生效）─────────────
    if (pathname === '/v1/session/model' && method === 'POST') {
      const input = await body(request)
      const sessionId = readSessionId(input.sessionId)
      if (sessionId === undefined) return json(400, { status: 'error', error: { code: 'bad-id', message: '缺少 sessionId' } })
      if (sessions() === undefined) return json(503, { status: 'error', error: { code: 'unavailable', message: 'sessions() 缺失' } })
      const effort = input.reasoningEffort ?? input.reasoning_effort
      const model = typeof input.model === 'string' && input.model.length > 0 ? input.model : undefined
      // DSH 的 selectModel 必须知道具体模型：只给档位会报
      // "invalid exact model metadata for provider ... model undefined"。
      if (model === undefined) {
        return json(400, {
          status: 'error',
          error: { code: 'model-required', message: '必须同时指定 model（DSH 的 selectModel 不接受只给档位）' },
        })
      }
      // 档位必须是该模型声明的档位之一，否则 DSH 侧会抛错并被静默忽略
      if (typeof effort === 'string' && effort.length > 0 && effort !== 'default') {
        const catalogValue = await catalog().catch(() => undefined)
        const declared = []
        for (const group of catalogValue?.groups ?? []) {
          for (const item of group.models ?? []) {
            if (item.id === model) {
              for (const e of item.reasoning?.efforts ?? []) declared.push(e.id)
            }
          }
        }
        if (declared.length > 0 && !declared.includes(effort)) {
          return json(400, {
            status: 'error',
            error: {
              code: 'unknown-effort',
              message: `模型 ${model} 不支持档位 "${effort}"（可用：${declared.join(', ')}）`,
            },
          })
        }
      }
      const provider = typeof input.provider === 'string' && input.provider.length > 0
        ? input.provider
        : await providerOf(model)
      try {
        const selected = await sessions().selectModel({
          sessionId,
          ...(provider === undefined ? {} : { provider }),
          model,
          ...(typeof effort === 'string' && effort.length > 0 && effort !== 'default' ? { reasoningEffort: effort } : {}),
        })
        return json(200, { status: 'success', sessionId, selected })
      } catch (error) {
        // 这里不再 swallow：把真实原因带回 App，用户才知道为什么没切过去
        return json(400, {
          status: 'error',
          error: { code: 'select-model-failed', message: String(error?.message ?? error) },
        })
      }
    }

    // /v1/sessions/<id>[/abort|/approve]
    if (pathname.startsWith('/v1/sessions/')) {
      const rest = pathname.slice('/v1/sessions/'.length)
      const [rawId, action] = rest.split('/')
      const sessionId = readSessionId(decodeURIComponent(rawId ?? ''))
      if (sessionId === undefined) return json(400, { status: 'error', error: { code: 'bad-id', message: '缺少会话 id' } })

      if (action === undefined && method === 'PATCH') {
        const input = await body(request)
        const title = typeof input.title === 'string' ? input.title : ''
        if (title.length === 0) return json(400, { status: 'error', error: { code: 'bad-title', message: '缺少 title' } })
        const value = await sessions().rename({ sessionId, title })
        titleCache.set(sessionId, value?.title ?? title)
        return json(200, { status: 'success', sessionId, title: value?.title ?? title })
      }

      if (action === undefined && method === 'DELETE') {
        if (workspaces() === undefined) return json(503, { status: 'error', error: { code: 'unavailable', message: 'workspaces() 缺失' } })
        await workspaces().archiveSession({ sessionId })
        return json(200, { status: 'success', sessionId, archived: true })
      }

      if (action === 'abort' && method === 'POST') {
        await sessions().cancel({ sessionId }, turnSignal())
        return json(200, { status: 'success', sessionId, aborted: true })
      }

      if (action === 'approve' && method === 'POST') {
        const input = await body(request)
        const approvalId = typeof input.approvalId === 'string' ? input.approvalId : ''
        const result = answerApproval(approvalId, input.action ?? 'allow')
        return json(200, {
          status: 'success',
          sessionId,
          approvalId,
          action: input.action ?? 'allow',
          settled: result.settled,
          delivered: result.delivered,
          deferred: result.deferred,
        })
      }
    }

    return json(404, { status: 'error', error: { code: 'not-found', message: `${method} ${pathname}` } })
  })

  /** GET /v1/plugins：已装插件清单。 */
  function pluginsPayload() {
    const rows = []
    for (const entry of loader.entries()) {
      if (entry.options?.group) continue
      rows.push({
        id: entry.id,
        name: entry.options.name,
        enabled: !entry.disabled,
        phase: entry.fiber === undefined ? null : ['pending', 'loading', 'active', 'failed', null, 'unloading'][entry.fiber.state] ?? null,
      })
    }
    return json(200, { status: 'success', count: rows.length, plugins: rows, data: rows })
  }

  /** POST /v1/sessions：新建会话（可带 workspace / title）。 */
  async function createSession(input) {
    if (sessions() === undefined) return json(503, { status: 'error', error: { code: 'unavailable', message: 'sessions() 缺失' } })
    const cwd = await resolveCwd(input.workspace)
    const created = await sessions().create(cwd === undefined ? {} : { cwd })
    const sessionId = created?.sessionId
    if (typeof sessionId !== 'string') return json(500, { status: 'error', error: { code: 'create-failed', message: '未拿到 sessionId' } })
    if (typeof input.title === 'string' && input.title.length > 0) {
      try {
        await sessions().rename({ sessionId, title: input.title })
        titleCache.set(sessionId, input.title)
      } catch {
        /* 重命名失败不影响建会话 */
      }
    }
    return json(200, { status: 'success', sessionId, id: sessionId, title: input.title ?? (await titleOf(sessionId)) })
  }

  /** POST /v1/agent/prompt：同步版，收完一轮再一次性返回。 */
  async function promptSync(input) {
    const started = await startTurn(input)
    const collected = await collectTurn(started)
    if (collected.error !== undefined) {
      return json(200, { status: 'error', error: { code: 'agent-error', message: collected.error }, choices: [] })
    }
    return json(200, {
      status: 'success',
      sessionId: started.sessionId,
      content: collected.content,
      reasoning: collected.reasoning,
      steps: collected.steps,
      choices: [{ index: 0, message: { role: 'assistant', content: collected.content }, finish_reason: 'stop' }],
    })
  }

  /** POST /v1/agent/prompt/stream：SSE 流式版（App 主用）。 */
  async function promptStream(input) {
    let started
    try {
      started = await startTurn(input)
    } catch (error) {
      return json(200, {
        status: 'error',
        error: {
          code: 'start-failed',
          message: String(error?.message ?? error),
          // 只留第一行堆栈位置，便于定位又不泄露路径细节
          where: String(error?.stack ?? '').split('\n')[1]?.trim() ?? '',
        },
        choices: [],
      })
    }
    const stream = new ReadableStream({
      start(controller) {
        void pumpSse(controller, started.sessionId, started.sinceSeq)
      },
    })
    return new Response(stream, {
      status: 200,
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-store',
        connection: 'keep-alive',
        'x-accel-buffering': 'no',
        ...CORS_HEADERS,
      },
    })
  }

  //#endregion

  /** 收完一轮（同步接口用）：复用 SSE 事件流，聚合成文本。 */
  async function collectTurn(started) {
    const result = { content: '', reasoning: '', steps: [], error: undefined }
    const stream = new ReadableStream({
      start(controller) {
        void pumpSse(controller, started.sessionId, started.sinceSeq)
      },
    })
    const reader = stream.getReader()
    const decoder = new TextDecoder()
    let buffer = ''
    const deadline = Date.now() + TURN_TIMEOUT_MS
    try {
      for (;;) {
        if (Date.now() > deadline) { result.error = 'timeout'; break }
        const { done, value } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        let index
        while ((index = buffer.indexOf('\n\n')) >= 0) {
          const chunk = buffer.slice(0, index)
          buffer = buffer.slice(index + 2)
          let eventName = 'message'
          let dataLine = ''
          for (const line of chunk.split('\n')) {
            if (line.startsWith('event:')) eventName = line.slice(6).trim()
            else if (line.startsWith('data:')) dataLine += line.slice(5).trim()
          }
          if (dataLine.length === 0) continue
          let payload
          try { payload = JSON.parse(dataLine) } catch { continue }
          if (eventName === 'content') result.content += payload.content ?? ''
          else if (eventName === 'reasoning') result.reasoning += payload.content ?? ''
          else if (eventName === 'tool_start' || eventName === 'tool_end') result.steps.push({ event: eventName, ...payload })
          else if (eventName === 'error') result.error = payload.message
          else if (eventName === 'done') { return result }
        }
      }
    } finally {
      reader.releaseLock()
    }
    return result
  }

  ctx.logger?.info?.('[app-bridge] 已挂载 /v1/* 与 /health（手机 App 桥接接口）')
}
