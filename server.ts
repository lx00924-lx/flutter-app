import "dotenv/config";
import express from "express";
import bcrypt from "bcryptjs";
import { randomBytes } from "crypto";
import FormData from "form-data";
import { createServer } from "http";
import { Server } from "socket.io";
import { WebSocketServer, WebSocket as WSWebSocket } from "ws";
import { EventEmitter } from "events";
import path from "path";
import fs from "fs/promises";
import fsSync from "node:fs";
import multer from "multer";
import { createServer as createViteServer } from "vite";
import cors from "cors";

// ==================== 控制台日志时间戳 ====================
// 需求：排查「手机点了重置 Token 之后到底发生了什么」这类顺序问题时，
// 日志必须能看出先后（谁先踢谁、指令何时排队、电脑端何时取走）。
//
// 做法：入口处把 console 的四个输出方法包一层，统一加本地时间前缀。
// 相比逐个改写 90 多处调用点：不会漏、不会改错参数、以后新增日志自动生效。
// 多行内容（如异常堆栈）后续行按同样宽度缩进对齐，避免"第二行没有时间戳"。
const LOG_TZ_OFFSET_MIN = -new Date().getTimezoneOffset();
const LOG_TZ_LABEL = (() => {
  const sign = LOG_TZ_OFFSET_MIN >= 0 ? "+" : "-";
  const abs = Math.abs(LOG_TZ_OFFSET_MIN);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `UTC${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
})();

/** 生成本地时间前缀，形如 `2026-02-14 18:27:03.123 +08:00`。 */
function logTimestamp(date: Date = new Date()): string {
  const pad = (n: number, width = 2) => String(n).padStart(width, "0");
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.` +
    `${pad(date.getMilliseconds(), 3)} ${LOG_TZ_LABEL}`
  );
}

(() => {
  const prefix = () => `[${logTimestamp()}]`;
  const wrap =
    (write: (...args: any[]) => void) =>
    (...args: any[]) => {
      const head = prefix();
      const indent = " ".repeat(head.length + 1);
      const formatted = args.map((arg) =>
        typeof arg === "string" && arg.includes("\n")
          ? arg
              .split("\n")
              .map((line, i) => (i === 0 ? line : indent + line))
              .join("\n")
          : arg,
      );
      write(head, ...formatted);
    };
  console.log = wrap(console.log.bind(console));
  console.info = wrap(console.info.bind(console));
  console.warn = wrap(console.warn.bind(console));
  console.error = wrap(console.error.bind(console));
})();

const generationEvents = new EventEmitter();
generationEvents.setMaxListeners(500);

// 监听端口：默认 3000，可用环境变量 PORT 覆盖（便于本地起隔离实例做安全回归测试）
const PORT = Number(process.env.PORT) || 3000;
/** Agent 任务正常超时（300 秒）：这段时间内本地没回结果就认为它不行了。 */
const AGENT_TASK_TIMEOUT_MS = 300000;
/**
 * 若该用户此刻有挂起的选择框/审批（= Agent 正在等用户拍板），超时不是"失败"而是
 * "在等人"，顺延到这段时间再判死。顺延期间**不会**拿主模型替用户作答。
 */
const AGENT_TASK_PENDING_GRACE_MS = 30 * 60 * 1000;
/**
 * 本次中继进程的启动标识。
 *
 * 为什么需要：桥接脚本从中继掉线时会退到 HTTP 长轮询，而**旧实现再也不切回**
 * WebSocket —— 中继重启后桥接就一直挂在轮询模式（会话列表不再同步、能力降级）。
 * 桥接把这里下发的 bootId 记下来，一旦发现变了（= 中继重启过）就主动切回 WS。
 */
const SERVER_BOOT_ID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
const DATA_DIR = path.join(process.cwd(), "messages_data");
const MESSAGES_FILE = path.join(DATA_DIR, "messages_v2.json"); // Use v2 to avoid conflicts
const USERS_FILE = path.join(DATA_DIR, "users.json");
const SETTINGS_FILE = path.join(DATA_DIR, "settings.json");
const ACTIVE_SESSIONS_FILE = path.join(DATA_DIR, "active_sessions.json");
const MODEL_LIMITS_FILE = path.join(DATA_DIR, "model_limits.json");
const MODEL_LIMITS_EXAMPLE = path.join(process.cwd(), "model_limits.example.json");
const UPLOADS_DIR = path.join(process.cwd(), "messages_media");

// 中继服务器对外地址（用于生成 Bridge 启动命令 / 一键 bat 脚本）。
// 自建部署无需改代码：设置环境变量 SERVER_BASE_URL，或写入 .env 文件。
const SERVER_BASE_URL =
  (process.env.SERVER_BASE_URL || "").trim().replace(/\/+$/, "") || "https://www.lx00924ai.top";

// ==================== Agent Token 工具（顶层，供生成流程与路由共用） ====================
// 历史问题：客户端设置的字段名是 harnessToken，服务端曾误读 agentToken，
// 导致永远读不到 token、全部落进 default_agent_token（公共秘密＝无鉴权）。
// 参考：https://github.com/lx00924-lx/flutter-app 多租户安全整改

// ==================== 密码哈希（bcrypt） ====================
// 历史问题：用户密码以明文落盘于 messages_data/users.json，比对也是明文相等判断。
// 一旦服务器文件被读取，所有账号口令直接泄露（且用户往往复用口令）。
// 现改为 bcrypt 哈希存储；存量明文账号在下次登录成功时自动升级为哈希。

/** bcrypt 计算强度（12 ≈ 250ms/次，兼顾安全与登录体验） */
const BCRYPT_ROUNDS = 12;
/** bcrypt 只取前 72 字节，超长口令需显式截断，避免"不同长口令被判相同" */
const MAX_PASSWORD_BYTES = 72;
const isBcryptHash = (value: string): boolean =>
  /^\$2[aby]?\$\d{2}\$/.test((value || "").trim());

/** 生成密码哈希（超长部分按 72 字节截断，与 bcrypt 内部行为保持一致） */
const hashPassword = async (plain: string): Promise<string> =>
  bcrypt.hash((plain || "").slice(0, MAX_PASSWORD_BYTES), BCRYPT_ROUNDS);

/**
 * 校验密码。
 * - 已哈希（$2a$/$2b$/$2y$ 开头）→ bcrypt 比对
 * - 尚未升级的明文（含历史数据里以 "hash:" 前缀标记的情况）→ 明文比对
 * @returns matched 是否正确；needsRehash 表示这次应当把明文升级为哈希
 */
const verifyPassword = async (
  plain: string,
  stored: string
): Promise<{ matched: boolean; needsRehash: boolean }> => {
  const record = (stored || "").trim();
  const candidate = (plain || "").slice(0, MAX_PASSWORD_BYTES);
  if (!record) return { matched: false, needsRehash: false };
  if (isBcryptHash(record)) {
    return { matched: await bcrypt.compare(candidate, record), needsRehash: false };
  }
  return { matched: record === candidate, needsRehash: true };
};

/** 明显非法的 token（空值、历史默认值、占位符）一律不接受。 */
const isPlausibleAgentToken = (token: string): boolean => {
  const t = (token || "").trim();
  if (!t) return false;
  const lower = t.toLowerCase();
  if (lower === "default_agent_token") return false;
  if (lower === "agent_default") return false;
  if (lower.includes("your_token") || lower.includes("你的token")) return false;
  return t.length >= 16;
};

/**
 * 从用户设置里读取 Agent Token。
 * 兼容两种字段：App 端为 harnessToken，早期服务端字段为 agentToken。
 */
const readUserAgentToken = (record: any): string => {
  if (!record || typeof record !== "object") return "";
  const candidate = record.harnessToken ?? record.agentToken ?? "";
  return isPlausibleAgentToken(String(candidate)) ? String(candidate).trim() : "";
};

interface DeviceSession {
  clientSessionId: string;
  deviceType: 'mobile' | 'desktop';
  loginTime: number;
  lastActive: number;
}

/**
 * 待下发的「桥接控制指令」队列：userId -> { command, createdAt }。
 *
 * 用途：手机端点「启动 / 停止 / 重启」时无法直接操作电脑上的脚本，
 * 因此把指令排队，由该用户的电脑端 App 在每 4 秒一次的会话轮询中取走并本地执行。
 * 复用既有轮询通道，无需新建长连接。
 *
 * 【只发给电脑端】手机与电脑轮询的是同一个 userId，若手机自己的轮询也去取这条
 * 队列，它会抢在电脑前面把指令取走并删除 —— 电脑端永远收不到，表现就是
 * "手机点重置 Token 后，还得在电脑上手动停止-重置-启动才恢复"。因此取件方
 * 必须是 deviceType === "desktop"，且取到才删。
 *
 * 【超时丢弃】电脑端可能压根没开（指令无人执行）。指令保留 2 分钟，
 * 过期即作废，避免用户几天后打开电脑 App 时被一条陈旧指令意外启停桥接。
 */
const BRIDGE_COMMAND_TTL_MS = 2 * 60 * 1000;
const pendingBridgeCommands = new Map<string, { command: string; createdAt: number }>();

/**
 * 账号级「桥接状态切换中」标记：userId -> 切换信息。
 *
 * 为什么必须放在服务端：手机点「启动」只是把指令排队，电脑端 App 要等下一次
 * 轮询（≤4 秒）才真正执行，这段时间电脑界面还显示"未运行"，用户很可能在电脑上
 * 又点一次「启动/停止」，两条相反指令打架，桥接被反复启停。
 * 服务端是两端唯一共同的真相，因此：
 *   · 任一端发起 启停 / 重置，都在这里登记一条切换标记；
 *   · 每次会话轮询把标记下发给**所有**设备，两端据此统一置灰按钮；
 *   · 观察到 agentOnline 达到期望终态（且中途确实偏离过）才清除；
 *   · 超时兜底清除，避免按钮永久卡住。
 */
interface BridgeTransition {
  command: string;
  target: boolean;
  by: string;
  startedAt: number;
}
const bridgeTransitions = new Map<string, BridgeTransition>();
/** 兜底时限：超过就作废，防止异常情况下两端按钮永久置灰。 */
const BRIDGE_TRANSITION_TTL_MS = 20 * 1000;

const armBridgeTransition = (userId: string, command: string, target: boolean, by: string): void => {
  bridgeTransitions.set(userId, {
    command,
    target,
    by: by || "unknown",
    startedAt: Date.now(),
  });
};

const describeBridgeTransition = (t: BridgeTransition) => ({
  command: t.command,
  target: t.target,
  by: t.by,
  since: t.startedAt,
});

/** 仍在切换中的标记（未超时）。 */
const activeBridgeTransition = (userId: string): BridgeTransition | null => {
  const t = bridgeTransitions.get(userId);
  if (!t) return null;
  if (Date.now() - t.startedAt > BRIDGE_TRANSITION_TTL_MS) {
    bridgeTransitions.delete(userId);
    return null;
  }
  return t;
};

/**
 * 结算切换标记：agentOnline 达到期望终态（或超时）就清除，
 * 返回仍需下发给设备的标记；null 表示切换已完成/无切换。
 *
 * 判据刻意只认「在线状态是否等于期望终态」，不依赖"有没有观察到中途偏离"：
 * 后者要靠轮询采样，桥接上线很快时可能一次都没采到，标记就会一直挂到超时，
 * 表现为按钮白灰 20 秒。
 */
const resolveBridgeTransition = (userId: string, agentOnline: boolean) => {
  const t = activeBridgeTransition(userId);
  if (!t) return null;
  if (agentOnline === t.target) {
    bridgeTransitions.delete(userId);
    return null;
  }
  return describeBridgeTransition(t);
};

/** 某个 Agent Token 当前是否在线（WS 活着，或轮询模式心跳未超时）。 */
const isAgentOnlineByToken = (token: string): boolean => {
  if (!token) return false;
  const agent = connectedAgents.get(token);
  if (!agent) return false;
  return (
    (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) ||
    Date.now() - agent.lastPing < 45000
  );
};

/**
 * 用户设置的最后写入时间与来源设备：userId -> { at, bySessionId }。
 *
 * 场景：手机改了「开屏启动页」等个性化设置，电脑上**已经打开**的 App 完全不知道 ——
 * 客户端既没有 socket.io 连接，`pullCloudSettings()` 又只在冷启动/登录时调用一次，
 * 所以设置变更实际上只在"重启 App"时才同步。服务端广播的 settings_updated
 * 没有任何客户端在听。
 *
 * 现在把版本号挂在 4 秒一次的会话轮询里下发：客户端发现版本变了、且不是自己写的，
 * 就主动拉一次云端设置。放在内存里即可 —— 服务重启后客户端最多多拉一次。
 */
const settingsRevision = new Map<string, { at: number; bySessionId: string }>();

const bumpSettingsRevision = (userId: string, bySessionId: string): void => {
  if (!userId || userId === "guest") return;
  settingsRevision.set(userId, { at: Date.now(), bySessionId: bySessionId || "" });
};

// File lock mechanism to prevent race conditions during concurrent JSON writes
const fileLocks: Map<string, Promise<any>> = new Map();

async function withFileLock<T>(filePath: string, fn: () => Promise<T>): Promise<T> {
  const currentLock = fileLocks.get(filePath) || Promise.resolve();
  let release: () => void = () => {};
  const nextLock = new Promise<void>((resolve) => { release = resolve; });
  fileLocks.set(filePath, currentLock.then(() => nextLock));

  try {
    await currentLock;
    return await fn();
  } finally {
    release();
  }
}

// Atomic file write using a temporary file and rename
async function safeWriteJSON(filePath: string, data: any): Promise<void> {
  const dir = path.dirname(filePath);
  await fs.mkdir(dir, { recursive: true }).catch(() => {});
  const tempPath = `${filePath}.tmp.${Math.random().toString(36).substring(2, 9)}`;
  const content = JSON.stringify(data, null, 2);
  await fs.writeFile(tempPath, content, "utf-8");
  await fs.rename(tempPath, filePath);
}

// Robust JSON reader with auto-recovery for corrupted JSON files
async function safeReadJSON<T>(filePath: string, fallback: T): Promise<T> {
  try {
    const raw = await fs.readFile(filePath, "utf-8");
    const trimmed = raw.trim();
    if (!trimmed) return fallback;
    return JSON.parse(trimmed) as T;
  } catch (error: any) {
    // If the file simply doesn't exist yet (ENOENT), return fallback gracefully without spamming error logs
    if (error && (error.code === 'ENOENT' || error.errno === -4058 || error.errno === -2)) {
      return fallback;
    }

    console.error(`[JSON Read Error] Failed to parse ${filePath}:`, error);
    try {
      const raw = await fs.readFile(filePath, "utf-8");
      const firstBrace = raw.indexOf('{');
      const lastBrace = raw.lastIndexOf('}');
      const firstBracket = raw.indexOf('[');
      const lastBracket = raw.lastIndexOf(']');

      let candidate = '';
      if (firstBracket !== -1 && lastBracket > firstBracket) {
        candidate = raw.substring(firstBracket, lastBracket + 1);
      } else if (firstBrace !== -1 && lastBrace > firstBrace) {
        candidate = raw.substring(firstBrace, lastBrace + 1);
      }

      if (candidate) {
        const parsed = JSON.parse(candidate);
        console.log(`[JSON Recovery] Recovered clean JSON for ${filePath}`);
        await safeWriteJSON(filePath, parsed);
        return parsed as T;
      }
    } catch (recoveryErr) {
      console.error(`[JSON Recovery Failed] Backing up corrupted file ${filePath}`);
      try {
        await fs.writeFile(`${filePath}.corrupted.${Date.now()}`, await fs.readFile(filePath));
        await safeWriteJSON(filePath, fallback);
      } catch (e) {
        console.error("Failed to write fallback file:", e);
      }
    }
    return fallback;
  }
}

// Helper to normalize and sanitize custom OpenAI-compatible API endpoints
function normalizeApiBaseUrl(rawEndpoint: string): string {
  if (!rawEndpoint) return '';
  let endpoint = rawEndpoint.trim();
  
  if (!endpoint.startsWith('http://') && !endpoint.startsWith('https://')) {
    if (
      endpoint.startsWith('localhost') || 
      endpoint.startsWith('127.0.0.1') || 
      endpoint.startsWith('192.168.') || 
      endpoint.startsWith('10.')
    ) {
      endpoint = `http://${endpoint}`;
    } else {
      endpoint = `https://${endpoint}`;
    }
  }

  endpoint = endpoint.replace(/\/+$/, '');

  endpoint = endpoint
    .replace(/\/chat\/completions\/?$/i, '')
    .replace(/\/completions\/?$/i, '')
    .replace(/\/models\/?$/i, '')
    .replace(/\/responses\/?$/i, '')
    .replace(/\/embeddings\/?$/i, '')
    .replace(/\/+$/, '');

  if (endpoint.includes('dashscope.aliyuncs.com')) {
    if (!endpoint.includes('/compatible-mode/v1')) {
      endpoint = endpoint.replace(/\/+$/, '');
      if (endpoint.endsWith('/v1')) {
        endpoint = endpoint.replace(/\/v1$/, '/compatible-mode/v1');
      } else {
        endpoint = `${endpoint}/compatible-mode/v1`;
      }
    }
    return endpoint;
  }

  if (endpoint.includes('generativelanguage.googleapis.com')) {
    if (endpoint.endsWith('/openai')) {
      return endpoint;
    } else if (endpoint.endsWith('/v1beta')) {
      return `${endpoint}/openai`;
    } else if (!endpoint.includes('/v1beta/openai')) {
      return `${endpoint}/v1beta/openai`;
    }
    return endpoint;
  }

  if (endpoint.includes('open.bigmodel.cn')) {
    if (!endpoint.includes('/api/paas/v4')) {
      endpoint = endpoint.replace(/\/+$/, '');
      if (endpoint.endsWith('/v1') || endpoint.endsWith('/v4')) {
        endpoint = endpoint.replace(/\/(v1|v4)$/, '/api/paas/v4');
      } else {
        endpoint = `${endpoint}/api/paas/v4`;
      }
    }
    return endpoint;
  }

  if (endpoint.includes('volces.com') || endpoint.includes('volcengine.com')) {
    if (!endpoint.includes('/api/v3') && !endpoint.includes('/api/')) {
      endpoint = `${endpoint}/api/v3`;
    }
    return endpoint;
  }

  if (endpoint.includes('qianfan.baidubce.com')) {
    if (!endpoint.includes('/v2') && !endpoint.includes('/v1')) {
      endpoint = `${endpoint}/v2`;
    }
    return endpoint;
  }

  const hasVersionPath = /\/(v\d+|api\/v\d+|compatible-mode\/v\d+|api\/paas\/v\d+)$/i.test(endpoint) || /\/v\d+\//i.test(endpoint) || /\/api\//i.test(endpoint);
  if (!hasVersionPath) {
    endpoint = `${endpoint}/v1`;
  }

  return endpoint;
}

function getChatCompletionsUrl(endpoint: string): string {
  const base = normalizeApiBaseUrl(endpoint);
  return `${base}/chat/completions`;
}

// Ensure model_limits.json exists in messages_data/ (initialized from template if absent, NEVER overwriting existing local edits)
async function ensureModelLimitsInitialized(): Promise<void> {
  try {
    const exists = await fs.stat(MODEL_LIMITS_FILE).then(() => true).catch(() => false);
    if (!exists) {
      let initialData: Record<string, number> = {};
      try {
        const exampleContent = await fs.readFile(MODEL_LIMITS_EXAMPLE, "utf-8");
        initialData = JSON.parse(exampleContent);
      } catch {
        initialData = {
          "deepseek-chat": 64000,
          "deepseek-reasoner": 64000,
          "gpt-4o": 128000,
          "gpt-4o-mini": 128000,
          "claude-3-7-sonnet": 200000,
          "gemini-2.0-flash": 1000000,
          "qwen-max": 128000
        };
      }
      await safeWriteJSON(MODEL_LIMITS_FILE, initialData);
      console.log(`[Model Limits] Initialized ${MODEL_LIMITS_FILE} from template.`);
    }
  } catch (err) {
    console.error("[Model Limits] Failed to initialize model limits file:", err);
  }
}

// Get maximum allowed context length for a given model from local server table (supports exact & fuzzy wildcard matches)
async function getEffectiveModelContextLimit(modelName?: string): Promise<number | null> {
  if (!modelName || !modelName.trim()) return null;
  const rawModel = modelName.trim().toLowerCase();
  try {
    const limits = await safeReadJSON<Record<string, number>>(MODEL_LIMITS_FILE, {});
    // 1. Exact match
    if (typeof limits[rawModel] === 'number') {
      return limits[rawModel];
    }
    // 2. Exact match on raw lowercase keys
    for (const [pattern, limit] of Object.entries(limits)) {
      if (typeof limit === 'number' && pattern.toLowerCase() === rawModel) {
        return limit;
      }
    }
    // 3. Substring / Prefix fuzzy match (e.g., "deepseek" matches "deepseek-chat" or vice versa)
    for (const [pattern, limit] of Object.entries(limits)) {
      if (typeof limit === 'number') {
        const p = pattern.toLowerCase();
        if (rawModel.includes(p) || p.includes(rawModel)) {
          return limit;
        }
      }
    }
  } catch (e) {
    console.error("[Model Limits] Error reading limits:", e);
  }
  return null;
}

interface ActiveGeneration {
  userId: string;
  assistantMessageId: string;
  /** 这一轮属于哪个会话：插话/排队要按会话定位当前在跑的轮次 */
  sessionId?: string;
  content: string;
  status: 'generating' | 'completed' | 'error' | 'cancelled';
  error?: string;
  startedAt: number;
  abortController: AbortController;
  /** 用户主动插话/停止：收尾时保留已生成的部分并标记"已打断"，不当成错误 */
  cancelledByUser?: boolean;
  /** 当前处于哪个阶段：DSH 执行中 / 思考 API 润色中 */
  phase?: 'executing' | 'polishing';
}

const activeGenerations = new Map<string, ActiveGeneration>();

/**
 * 挂起中的「选择框」（DSH 的 ask_user_question）。
 *
 * 为什么中继也要存一份：选择框是**没有任务归属**的 —— DSH 侧插件排队等答复，
 * 桥接脚本轮询取走再推上来，此刻可能压根没有正在跑的任务（比如用户在电脑网页
 * 里发起的一轮）。App 断线重连后也要能补拉，所以按 questionId 落在这里。
 */
const pendingQuestions = new Map<string, {
  questionId: string;
  sessionId?: string;
  questions: any[];
  token?: string;
  userId?: string;
  at: number;
  /**
   * `pending` 刚问不久 ｜ `waiting` 等超过 5 分钟但**仍在等**（DSH 那一轮没有交给
   * 模型，所以不会出现"AI 自己把问题答了"）｜ `orphaned` 挂满 24h 已中止本轮，
   * 用户答复时 App 走「续跑」。
   */
  state?: 'pending' | 'waiting' | 'orphaned';
  /** true = state 为 orphaned（兼容旧字段）。 */
  deferred?: boolean;
}>();

/**
 * 待办保留时长：24 小时。
 *
 * 为什么从 10 分钟提到 24 小时（用户场景：发完指令人就走了，隔天才回来）：
 * DSH 的提问自己没有任何超时，人不在时那一轮会一直挂着（插件到 24h 才中止本轮）；
 * 卡片必须还在，否则用户回来什么都没有，只能重新发一遍指令。
 */
const QUESTION_TTL_MS = 24 * 60 * 60 * 1000;
const prunePendingQuestions = () => {
  const now = Date.now();
  for (const [id, item] of pendingQuestions) {
    if (now - item.at > QUESTION_TTL_MS) pendingQuestions.delete(id);
  }
};

/**
 * 该用户此刻是否正卡在"等用户答复"的选择框上。
 *
 * 用途：Agent 任务超时判定要区分"它挂了"和"它在等人" —— 正在等答复的那一轮
 * 绝不能判失败并转去让主模型回答（用户实测抱怨的"超时后主聊天模型还是回答了"
 * 就是这么来的：Agent Execution Failed (300s) → Server Background Gen）。
 */
const pendingQuestionCountForUser = (userId: string): number => {
  const now = Date.now();
  let count = 0;
  for (const item of pendingQuestions.values()) {
    if (item.userId && userId && item.userId !== userId) continue;
    if (now - item.at > QUESTION_TTL_MS) continue;
    count++;
  }
  return count;
};

/** 按「用户+会话」找到当前在跑的那一轮（插话时需要）。 */
const findActiveGenerationBySession = (userId: string, sessionId: string): ActiveGeneration | undefined => {
  if (!userId || !sessionId) return undefined;
  let latest: ActiveGeneration | undefined;
  for (const gen of activeGenerations.values()) {
    if (gen.userId !== userId || gen.sessionId !== sessionId) continue;
    if (gen.status !== 'generating') continue;
    if (!latest || gen.startedAt > latest.startedAt) latest = gen;
  }
  return latest;
};

interface DshSessionInfo {
  id: string;
  sessionId?: string;
  title: string;
  workspace?: string;
  updatedAt?: string | number;
  model?: string;
}

// Agent Hub state for reverse WebSocket and HTTP Long-Polling connections
interface ConnectedAgent {
  ws?: WSWebSocket;
  token: string;
  /** 该 Agent 归属的用户 ID（用于 App 侧越权校验；未认领时为 undefined） */
  ownerUserId?: string;
  clientName: string;
  connectedAt: number;
  lastPing: number;
  mode: 'ws' | 'polling';
  pendingPollResolvers?: Array<(taskMsg: any) => void>;
  queuedTasks?: any[];
  workspaces?: string[];
  sessions?: DshSessionInfo[];
  models?: any[];
  activeUserSessions?: Map<string, string>;
}

const connectedAgents = new Map<string, ConnectedAgent>();
const pendingAgentTasks = new Map<string, {
  resolve: (value: { success: boolean; output: string; steps: string[] }) => void;
  reject: (reason: any) => void;
  timeoutId: NodeJS.Timeout;
  token: string;
  userId: string;
  assistantMessageId: string;
}>();

async function upsertMessage(userId: string, message: any) {
  if (!userId || userId === 'guest') return;
  await withFileLock(MESSAGES_FILE, async () => {
    const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
    if (!allMessages[userId]) allMessages[userId] = [];
    const idx = allMessages[userId].findIndex((m: any) => m.id === message.id);
    if (idx !== -1) {
      allMessages[userId][idx] = { ...allMessages[userId][idx], ...message };
    } else {
      allMessages[userId].push(message);
    }
    await safeWriteJSON(MESSAGES_FILE, allMessages);
  });
}

/** 按消息 id 读取云端已存的那条（用于"不要用更短的内容覆盖更长内容"）。 */
async function findMessageById(userId: string, messageId: string): Promise<any | undefined> {
  if (!userId || userId === 'guest' || !messageId) return undefined;
  try {
    const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
    return (allMessages[userId] || []).find((m: any) => m?.id === messageId);
  } catch {
    return undefined;
  }
}

async function runServerSideGeneration({
  userId,
  assistantMessageId,
  messages,
  settings,
  io
}: {
  userId: string;
  assistantMessageId: string;
  messages: any[];
  settings: any;
  io: Server;
}) {
  const genKey = `${userId}_${assistantMessageId}`;
  if (activeGenerations.has(genKey)) {
    return;
  }

  // Safely extract and resolve target sessionId
  const resolvedSessionId = (
    settings?.sessionId ||
    (messages && messages.length > 0 ? (messages[messages.length - 1]?.sessionId || messages[0]?.sessionId) : "") ||
    ""
  ).toString().trim();

  const abortController = new AbortController();
  const genState: ActiveGeneration = {
    userId,
    assistantMessageId,
    sessionId: resolvedSessionId,
    content: "",
    status: 'generating',
    startedAt: Date.now(),
    abortController,
    phase: settings?.agentMode === true ? 'executing' : 'polishing',
  };
  activeGenerations.set(genKey, genState);

  // Initial placeholder save in DB
  const initialAssistantMessage = {
    id: assistantMessageId,
    sessionId: resolvedSessionId,
    role: 'assistant',
    content: '',
    timestamp: new Date().toISOString(),
    type: 'text',
    status: 'generating',
  };
  // 不要用这个空占位覆盖云端已有的同 id 消息：那条可能已经有内容
  // （例如客户端在插话前已经把半句推上来过），覆盖掉就会出现"这端有、那端空"。
  const existingBeforeStart = await findMessageById(userId, assistantMessageId);
  if (!existingBeforeStart || (existingBeforeStart.content ?? '').toString().trim().isEmpty) {
    await upsertMessage(userId, initialAssistantMessage);
  }

  // 这三个变量提到 try 外面：catch 里的"被用户打断"分支也要用它们
  // （保留已生成的内容与执行结果），放在 try 内会取不到作用域。
  const isAgentMode = settings?.agentMode === true;
  let agentExecutionResult: { status: 'completed' | 'failed'; steps: string[]; rawOutput?: string; timestamp?: string } | null = null;
  /** Agent 阶段是否失败：失败时**不进入润色阶段**（绝不能拿主模型替 Agent 作答）。 */
  let agentStageFailed = false;
  let accumulatedContent = "";
  let accumulatedReasoning = "";

  try {
    // 修复：客户端字段是 harnessToken，此前误读 agentToken 导致永远取空 → 全落默认 token
    const agentToken = readUserAgentToken(settings);

    const onChunk = (chunk: string, reasoningChunk?: string) => {
      if (chunk) accumulatedContent += chunk;
      if (reasoningChunk) accumulatedReasoning += reasoningChunk;
      genState.content = accumulatedContent;
      io.to(`user_${userId}`).emit("chat_chunk", {
        messageId: assistantMessageId,
        chunk,
        reasoningChunk: reasoningChunk || "",
        fullContent: accumulatedContent,
        fullReasoning: accumulatedReasoning,
      });
      generationEvents.emit(`chunk_${assistantMessageId}`, {
        messageId: assistantMessageId,
        chunk,
        reasoningChunk: reasoningChunk || "",
        fullContent: accumulatedContent,
        fullReasoning: accumulatedReasoning,
      });
    };

    let workingMessages = [...messages];
    const lastUserMsg = workingMessages[workingMessages.length - 1] || { role: 'user', content: ' ' };
    const rawUserPrompt = typeof lastUserMsg.content === 'string' ? lastUserMsg.content : (lastUserMsg.content?.[0]?.text || '');

    if (isAgentMode) {
      const agent = connectedAgents.get(agentToken);
      const isAgentOnline = agent && (
        (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) ||
        (Date.now() - agent.lastPing < 45000)
      );

      if (!isAgentOnline) {
        // Agent is offline
        const offlineNotice = `> ⚠️ **【本地 Agent 模式提示】**\n> 检测到您已开启 **Agent 模式**，但未检测到本地 DeepSeek Harness 桥接连接。\n>\n> **快速解决**：\n> 1. 打开应用右上角 **设置 ➔ 🤖 本地 Agent**；\n> 2. 复制启动命令并在本地终端运行：\`python deepseek_bridge.py --token "${agentToken}" --server "${SERVER_BASE_URL}" --harness-url "http://127.0.0.1:3080"\`；\n> 3. 或在聊天输入框左侧一键切换回 **「💬 普通模式」**。`;
        
        onChunk(offlineNotice);
        genState.status = 'completed';
        genState.content = offlineNotice;
        const offlineMsg = {
          id: assistantMessageId,
          sessionId: resolvedSessionId,
          role: 'assistant',
          content: offlineNotice,
          timestamp: new Date().toISOString(),
          type: 'text',
          status: 'completed',
          isAgentMode: true,
          agentExecution: {
            status: 'failed',
            steps: ['尝试连接本地 Agent: 失败 (本地未启动桥接程序或离线)'],
            rawOutput: 'Agent Offline',
            timestamp: new Date().toISOString(),
          }
        };
        await upsertMessage(userId, offlineMsg);
        io.to(`user_${userId}`).emit("chat_completed", {
          messageId: assistantMessageId,
          content: offlineNotice,
          isAgentMode: true,
          agentExecution: offlineMsg.agentExecution
        });
        return;
      }

      // Agent is online -> dispatch task
      const taskId = `task_${Date.now()}_${Math.random().toString(36).substring(2, 7)}`;
      console.log(`[Agent Hub] Dispatching task ${taskId} to agent for token [${agentToken}] (mode: ${agent.mode || 'ws'})`);

      io.to(`user_${userId}`).emit("agent_task_started", {
        messageId: assistantMessageId,
        taskId,
        initialStep: "已将需求派发至本地 DeepSeek Harness 智能体..."
      });
      generationEvents.emit(`task_started_${assistantMessageId}`, {
        messageId: assistantMessageId,
        taskId,
        initialStep: "已将需求派发至本地 DeepSeek Harness 智能体..."
      });

      try {
        const taskPromise = new Promise<{ success: boolean; output: string; steps: string[] }>((resolve, reject) => {
          /**
           * 任务超时：**正在等用户确认时不算超时**。
           *
           * 为什么必须这样：Agent 那一轮可能正卡在 `ask_user_question`（或审批）上等用户
           * 答复，这是"正常在工作"，不是"死了"。旧逻辑 300 秒一到就判失败，接着进入润色
           * 阶段拿**主模型**把这轮"回答"了 —— 用户实测看到的就是
           * 「超时后主聊天模型还是回答了」（中继日志：Agent Execution Failed (300s) →
           * Server Background Gen Calling ... completions）。
           */
          let timeoutId: NodeJS.Timeout;
          const armTimeout = (graceForPendingDecision: boolean) => {
            timeoutId = setTimeout(() => {
              const waiting = pendingQuestionCountForUser(userId);
              if (!graceForPendingDecision && waiting > 0) {
                console.log(
                  `[Agent Hub] 任务 ${taskId} 仍在等待用户处理（${waiting} 条待答），超时顺延 ${Math.round(AGENT_TASK_PENDING_GRACE_MS / 60000)} 分钟`,
                );
                armTimeout(true);
                return;
              }
              pendingAgentTasks.delete(taskId);
              reject(new Error(`本地 DeepSeek 智能体执行超时 (${graceForPendingDecision ? '等待用户确认超时' : '300秒'})`));
            }, graceForPendingDecision ? AGENT_TASK_PENDING_GRACE_MS : AGENT_TASK_TIMEOUT_MS);
          };
          armTimeout(false);

          pendingAgentTasks.set(taskId, {
            resolve,
            reject,
            get timeoutId() { return timeoutId; },
            token: agentToken,
            userId,
            assistantMessageId,
          } as any);
        });

        const selectedSessionId = (settings?.agentSessionId || "").trim();
        // 不再回退到 'deepseek-agent'：本地没有这个工作区，回退过去只会让
        // 本地 DSH 找不到目录、任务卡住直到超时。留空 = 用电脑端默认工作区。
        const selectedWorkspace = (settings?.agentWorkspace || "").trim();
        
        // 自动绑定对话会话：若设置未指定特定会话，按用户维度维持一个稳定的活跃会话标识
        let sessionId = selectedSessionId;
        if (!sessionId) {
          if (!agent.activeUserSessions) agent.activeUserSessions = new Map<string, string>();
          let userAssignedSid = agent.activeUserSessions.get(userId);
          if (!userAssignedSid) {
            userAssignedSid = `session_${Date.now()}_${Math.random().toString(36).substring(2, 7)}`;
            agent.activeUserSessions.set(userId, userAssignedSid);
          }
          sessionId = userAssignedSid;
        }

        const taskPayload = {
          type: "run_agent",
          taskId,
          sessionId,
          agentSessionId: sessionId,
          agentWorkspace: selectedWorkspace,
          prompt: rawUserPrompt,
          messages: workingMessages.slice(-5),
          harnessUrl: settings?.agentHarnessUrl || "http://127.0.0.1:3080",
          model: settings?.agentModel || "deepseek-v4-flash",
          reasoningEffort: settings?.agentReasoningEffort || "high",
          reasoning_effort: settings?.agentReasoningEffort || "high",
          permission: settings?.agentPermission || "workspace-write",
          apiEndpoint: settings?.apiEndpoint || "",
          apiKey: settings?.apiKey || "",
          chatModel: settings?.modelName || ""
        };

        // Dispatch via WS if available, otherwise deliver to pending long-polling or task queue
        if (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) {
          agent.ws.send(JSON.stringify(taskPayload));
        } else if (agent.pendingPollResolvers && agent.pendingPollResolvers.length > 0) {
          const resolver = agent.pendingPollResolvers.shift();
          if (resolver) resolver(taskPayload);
        } else {
          if (!agent.queuedTasks) agent.queuedTasks = [];
          agent.queuedTasks.push(taskPayload);
        }

        const taskResult = await taskPromise;
        agentExecutionResult = {
          status: taskResult.success ? 'completed' : 'failed',
          steps: taskResult.steps && taskResult.steps.length > 0 ? taskResult.steps : ['本地执行完成'],
          rawOutput: taskResult.output,
          timestamp: new Date().toISOString()
        };

        io.to(`user_${userId}`).emit("agent_task_finished", {
          messageId: assistantMessageId,
          taskId,
          result: agentExecutionResult
        });
        generationEvents.emit(`task_finished_${assistantMessageId}`, {
          messageId: assistantMessageId,
          taskId,
          result: agentExecutionResult
        });

        // Construct Stage 2 augmented prompt for the App's target model
        const augmentedPrompt = `用户提出的需求：\n${rawUserPrompt}\n\n====================\n【本地 DeepSeek Harness 智能体执行产出的真实数据与环境结果】：\n${taskResult.output}\n====================\n\n【任务要求】：\n本地智能体已在用户本地环境执行完毕并返回了上述数据。请你结合用户的原始问题与上述本地执行结果，进行条理清晰、严谨专业的总结与深度回答。`;
        
        workingMessages = [
          ...workingMessages.slice(0, -1),
          { ...lastUserMsg, content: augmentedPrompt }
        ];

      } catch (agentErr: any) {
        console.error("[Agent Execution Failed]:", agentErr);
        agentStageFailed = true;
        agentExecutionResult = {
          status: 'failed',
          steps: [`执行出错: ${agentErr.message || '本地响应超时'}`],
          rawOutput: String(agentErr),
          timestamp: new Date().toISOString()
        };
        io.to(`user_${userId}`).emit("agent_task_finished", {
          messageId: assistantMessageId,
          taskId,
          result: agentExecutionResult
        });
      }
    }

    // Agent 阶段失败时**不进入润色阶段**（也就是不拿主模型来"回答"）。
    //
    // 为什么：润色阶段的意义是"把本地执行结果总结给用户"。执行都失败了，再调主模型
    // 只会让它凭空编一段回答 —— 用户实测看到的现象就是「超时后主聊天模型还是回答了」
    // （中继日志：Agent Execution Failed (300s) → Server Background Gen Calling completions）。
    // 这里改为写一条如实的失败说明，用户答复/重试后那一轮会继续。
    if (isAgentMode && agentStageFailed) {
      const waiting = pendingQuestionCountForUser(userId);
      const notice = waiting > 0
        ? '本地 Agent 正在等你确认（选择框 / 授权卡片），这一轮会一直等你的答复，不会自己继续。'
        : `本地 Agent 这一轮没有拿到结果（${agentExecutionResult?.steps?.[0] ?? '执行失败'}）。如果你那边还有等待确认的卡片，它就是在等你答复；否则可以重发一次。`;
      const failedMessage = {
        id: assistantMessageId,
        sessionId: resolvedSessionId,
        role: 'assistant',
        content: notice,
        timestamp: new Date().toISOString(),
        type: 'text',
        status: 'completed',
        isAgentMode: true,
        agentExecution: agentExecutionResult,
      };
      await upsertMessage(userId, failedMessage);
      io.to(`user_${userId}`).emit("chat_completed", {
        messageId: assistantMessageId,
        content: notice,
        isAgentMode: true,
        agentExecution: agentExecutionResult,
      });
      generationEvents.emit(`completed_${assistantMessageId}`, {
        messageId: assistantMessageId,
        content: notice,
        isAgentMode: true,
        agentExecution: agentExecutionResult,
      });
      genState.status = 'completed';
      genState.content = notice;
      return;
    }

    // 本地执行结束（成功或失败）→ 进入"润色"阶段。
    // 客户端据此判断此刻插话是否安全：执行阶段插话会丢掉正在跑的任务，
    // 润色阶段插话只是掐断一段便宜的文本生成。
    if (isAgentMode) {
      genState.phase = 'polishing';
      generationEvents.emit(`phase_${assistantMessageId}`, { phase: 'polishing' });
    }

    const apiEndpoint = settings?.apiEndpoint?.trim();
    const apiKey = settings?.apiKey || process.env.GEMINI_API_KEY || "";
    const modelName = settings?.modelName;
    const systemInstruction = settings?.systemInstruction;
    let contextLength = settings?.contextLength || 30000;
    const sessionSummary = settings?.sessionSummary;

    // 自动结合服务端维护的 model_limits.json 校验与修正上限，若用户填写的数值超过限制则自动更正
    const serverModelLimit = await getEffectiveModelContextLimit(modelName);
    if (serverModelLimit && serverModelLimit > 0 && contextLength > serverModelLimit) {
      console.log(`[Server Context Safe Guard] Context length ${contextLength} exceeds model limit ${serverModelLimit} for ${modelName}. Auto-corrected to ${serverModelLimit}.`);
      contextLength = serverModelLimit;
    }

    if (apiEndpoint) {
      // OpenAI compatible flow
      const url = getChatCompletionsUrl(apiEndpoint);
      console.log(`[Server Background Gen] Calling OpenAI compatible API: ${url} (model: ${modelName || 'default'})`);
      
      const systemMessage: any[] = [];
      if (systemInstruction) {
        systemMessage.push({ role: 'system', content: systemInstruction });
      }
      if (sessionSummary && typeof sessionSummary === 'string' && sessionSummary.trim()) {
        systemMessage.push({ role: 'system', content: `【📜 前文对话核心背景摘要】:\n${sessionSummary.trim()}` });
      }

      const mapMessageToContent = (msg: any) => {
        let text = msg.content || '';
        // 自动清洗历史消息中的错误提示占位符，避免污染大模型上下文
        text = text.replace(/\n*\*\s*\(请求异常[^\)]*\)\s*\*/g, '').trim();
        if (!text) {
          const hasAudio = (Array.isArray(msg.attachments) && msg.attachments.some((a: any) => typeof a === 'string' && a.startsWith('data:audio/'))) || msg.type === 'voice';
          if (hasAudio) {
            text = '[用户发送了一条语音消息。提示：当前客户端未配置 ASR 语音识别转写服务，大模型接收到的是音频条。请直接回复已收到语音消息，并提醒用户在 App「设置 ➔ 语音识别与合成」中配置 ASR 识别服务即可直接与 AI 进行语音文本交互。]';
          } else if (msg.type === 'image' || (Array.isArray(msg.attachments) && msg.attachments.some((a: any) => typeof a === 'string' && a.startsWith('data:image/')))) {
            text = '[图片]';
          } else {
            text = ' ';
          }
        }
        if (msg.quote) {
          text = `引用消息: "${msg.quote.content}"\n\n回复上面的消息: ${text}`;
        }
        if (msg.type === 'image' && msg.mediaUrl) {
          return [
            { type: 'text', text: text || ' ' },
            { type: 'image_url', image_url: { url: msg.mediaUrl } }
          ];
        }
        return text || ' ';
      };

      let currentTokens = 0;
      const recentHistory: any[] = [];
      const historyMessages = workingMessages.slice(0, -1).reverse();
      for (const msg of historyMessages) {
        const msgTokens = Math.ceil((msg.content || "").length * 1.5);
        if (currentTokens + msgTokens > contextLength) break;
        currentTokens += msgTokens;
        recentHistory.unshift(msg);
      }

      const formattedHistory = recentHistory.map((m: any) => ({
        role: m.role === 'assistant' ? 'assistant' : 'user',
        content: mapMessageToContent(m),
      }));

      const finalLastMsg = workingMessages[workingMessages.length - 1] || { role: 'user', content: ' ' };
      const formattedLast = {
        role: 'user',
        content: mapMessageToContent(finalLastMsg),
      };

      const requestBody = {
        model: modelName || "local-model",
        messages: [
          ...systemMessage,
          ...formattedHistory,
          formattedLast,
        ],
        stream: true,
      };

      console.log(`[Server Background Gen] Request Body:`, JSON.stringify(requestBody).substring(0, 200));

      const resp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json, text/event-stream",
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AetherX/1.0",
          "Authorization": `Bearer ${apiKey || "lm-studio"}`,
        },
        body: JSON.stringify(requestBody),
        signal: abortController.signal,
      });

      if (!resp.ok) {
        const errBody = await resp.text().catch(() => "");
        throw new Error(`API 返回错误 ${resp.status}: ${errBody.substring(0, 300)}`);
      }

      if (resp.body) {
        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";

          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || !trimmed.startsWith("data:")) continue;
            const dataStr = trimmed.slice(5).trim();
            if (dataStr === "[DONE]") continue;
            try {
              const json = JSON.parse(dataStr);
              const deltaContent = json.choices?.[0]?.delta?.content || json.choices?.[0]?.text || "";
              const deltaReasoning = json.choices?.[0]?.delta?.reasoning_content || json.choices?.[0]?.delta?.reasoning || "";
              if (deltaContent || deltaReasoning) {
                onChunk(deltaContent, deltaReasoning);
              }
            } catch (_) {}
          }
        }
      } else {
        const json: any = await resp.json();
        const full = json.choices?.[0]?.message?.content || "";
        if (full) onChunk(full);
      }

    } else {
      // Google Gemini SDK flow
      const { GoogleGenAI } = await import("@google/genai");
      const ai = new GoogleGenAI({ apiKey: apiKey || process.env.GEMINI_API_KEY || "" });
      const targetModel = modelName || "gemini-2.5-flash";

      const mapToGeminiParts = (msg: any) => {
        let text = msg.content;
        if (!text) {
          if (msg.type === 'image') text = '[图片]';
          else if (msg.type === 'voice') text = '[语音]';
          else text = ' ';
        }
        if (msg.quote) {
          text = `引用消息: "${msg.quote.content}"\n\n回复上面的消息: ${text}`;
        }
        const parts: any[] = [{ text: text || ' ' }];
        if ((msg.type === 'image' || msg.type === 'voice') && msg.mediaUrl) {
          try {
            const commaIndex = msg.mediaUrl.indexOf(',');
            if (commaIndex !== -1) {
              const base64Data = msg.mediaUrl.substring(commaIndex + 1);
              const metaPart = msg.mediaUrl.substring(0, commaIndex);
              const mimeMatch = metaPart.match(/data:([a-zA-Z0-9-]+\/[a-zA-Z0-9-.+]+)/);
              const mimeType = mimeMatch ? mimeMatch[1] : (msg.type === 'voice' ? 'audio/wav' : 'image/jpeg');
              parts.push({
                inlineData: {
                  data: base64Data,
                  mimeType,
                }
              });
            }
          } catch (e) {
            console.error("Error parsing media URL in server gen:", e);
          }
        }
        return parts;
      };

      let currentTokens = 0;
      const recentHistory: any[] = [];
      const historyMessages = workingMessages.slice(0, -1).reverse();
      for (const msg of historyMessages) {
        const msgTokens = Math.ceil((msg.content || "").length * 1.5);
        if (currentTokens + msgTokens > contextLength) break;
        currentTokens += msgTokens;
        recentHistory.unshift(msg);
      }

      const formattedHistory = recentHistory.map((m: any) => ({
        role: m.role === 'assistant' ? 'model' : 'user',
        parts: mapToGeminiParts(m),
      }));

      const finalLastMsg = workingMessages[workingMessages.length - 1] || { role: 'user', content: ' ' };
      const lastParts = mapToGeminiParts(finalLastMsg);

      const responseStream = await ai.models.generateContentStream({
        model: targetModel,
        contents: [
          ...formattedHistory,
          { role: 'user', parts: lastParts },
        ],
        config: {
          ...(systemInstruction ? { systemInstruction } : {}),
          tools: [{ googleSearch: {} }] as any,
        }
      });

      for await (const chunk of responseStream) {
        if (chunk.text) {
          onChunk(chunk.text);
        }
      }
    }

    genState.status = 'completed';
    genState.content = accumulatedContent;
    const finalAssistantMessage = {
      id: assistantMessageId,
      sessionId: resolvedSessionId,
      role: 'assistant',
      content: accumulatedContent,
      reasoningContent: accumulatedReasoning,
      thought: accumulatedReasoning,
      timestamp: new Date().toISOString(),
      type: 'text',
      status: 'completed',
      isAgentMode: isAgentMode || false,
      ...(agentExecutionResult ? { agentExecution: agentExecutionResult } : {})
    };
    await upsertMessage(userId, finalAssistantMessage);

    io.to(`user_${userId}`).emit("chat_completed", {
      messageId: assistantMessageId,
      content: accumulatedContent,
      reasoningContent: accumulatedReasoning,
      isAgentMode: isAgentMode || false,
      agentExecution: agentExecutionResult
    });
    generationEvents.emit(`completed_${assistantMessageId}`, {
      messageId: assistantMessageId,
      content: accumulatedContent,
      reasoningContent: accumulatedReasoning,
      isAgentMode: isAgentMode || false,
      agentExecution: agentExecutionResult
    });
    console.log(`[Server Background Gen] Completed for msg ${assistantMessageId} (${accumulatedContent.length} chars)`);

  } catch (err: any) {
    // 用户主动插话/停止：保留已经生成的部分，标成"已打断"，不当成错误
    if (genState.cancelledByUser) {
      genState.status = 'cancelled';
      const partial = (genState.content || '').trim();
      // 关键：不要用服务端这份（可能更短的）内容覆盖客户端已经推到云端的版本。
      // 插话时手机本地气泡里往往已经有半句，而服务端这一轮可能一个字都没攒下，
      // 直接 upsert 会把对方的半句清空 —— 表现为"手机有内容、电脑是空气泡"。
      const existing = await findMessageById(userId, assistantMessageId);
      const existingContent = (existing?.content ?? '').toString();
      const keepContent = existingContent.length > partial.length ? existingContent : partial;
      const interruptedMessage = {
        id: assistantMessageId,
        sessionId: resolvedSessionId,
        role: 'assistant',
        content: keepContent,
        reasoningContent: accumulatedReasoning || (existing?.reasoningContent ?? ''),
        timestamp: new Date().toISOString(),
        type: 'text',
        status: 'cancelled',
        isAgentMode: isAgentMode || false,
        ...(agentExecutionResult ? { agentExecution: agentExecutionResult } : {})
      };
      await upsertMessage(userId, interruptedMessage);
      io.to(`user_${userId}`).emit("chat_completed", {
        messageId: assistantMessageId,
        content: keepContent,
        reasoningContent: interruptedMessage.reasoningContent,
        interrupted: true,
        isAgentMode: isAgentMode || false,
        agentExecution: agentExecutionResult
      });
      generationEvents.emit(`completed_${assistantMessageId}`, {
        messageId: assistantMessageId,
        content: keepContent,
        reasoningContent: interruptedMessage.reasoningContent,
        interrupted: true,
        isAgentMode: isAgentMode || false,
        agentExecution: agentExecutionResult
      });
      console.log(`[Server Background Gen] 已被用户打断，保留内容 ${keepContent.length} 字 (${assistantMessageId})`);
      return;
    }
    console.error(`[Server Background Gen] Error for msg ${assistantMessageId}:`, err);
    genState.status = 'error';
    genState.error = err.message || "生成失败";

    const errorAssistantMessage = {
      id: assistantMessageId,
      sessionId: resolvedSessionId,
      role: 'assistant',
      content: genState.content || `[生成失败: ${err.message || '网络中断'}]`,
      timestamp: new Date().toISOString(),
      type: 'text',
      status: 'error',
    };
    await upsertMessage(userId, errorAssistantMessage);

    io.to(`user_${userId}`).emit("chat_error", {
      messageId: assistantMessageId,
      error: err.message || "生成失败",
    });
    generationEvents.emit(`error_${assistantMessageId}`, {
      messageId: assistantMessageId,
      error: err.message || "生成失败",
    });
  } finally {
    setTimeout(() => {
      activeGenerations.delete(genKey);
    }, 10 * 60 * 1000);
  }
}

// Ensure directories and files exist & sanitize orphan messages
async function ensureDirs() {
  try {
    await fs.mkdir(path.dirname(MESSAGES_FILE), { recursive: true });
    await fs.mkdir(UPLOADS_DIR, { recursive: true });
    
    const checkFile = async (filePath: string, defaultContent: any) => {
      await safeReadJSON(filePath, defaultContent);
    };

    await checkFile(MESSAGES_FILE, {}); // Map of userId -> messages[]
    await checkFile(USERS_FILE, []); // Simple user list
    await checkFile(SETTINGS_FILE, {}); // Map of userId -> settings

    // Clean any orphan messages (messages with empty or missing sessionId)
    await withFileLock(MESSAGES_FILE, async () => {
      const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
      let changed = false;
      for (const uid of Object.keys(allMessages)) {
        const msgs = allMessages[uid];
        if (Array.isArray(msgs)) {
          const cleaned = msgs.filter((m: any) => m && m.id && m.sessionId && m.sessionId.toString().trim() !== '');
          if (cleaned.length !== msgs.length) {
            allMessages[uid] = cleaned;
            changed = true;
          }
        }
      }
      if (changed) {
        await safeWriteJSON(MESSAGES_FILE, allMessages);
        console.log(`[Data Sanitizer] Purged orphan messages without valid sessionId from server storage.`);
      }
    });
  } catch (error) {
    console.error("Error creating directories:", error);
  }
}

const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    cb(null, UPLOADS_DIR);
  },
  filename: (req, file, cb) => {
    const uniqueSuffix = Date.now() + "-" + Math.round(Math.random() * 1e9);
    cb(null, uniqueSuffix + path.extname(file.originalname));
  },
});

const upload = multer({ 
  storage,
  limits: { fileSize: 100 * 1024 * 1024 } // 100MB limit for ultra-high-res photos (up to 9248x6930)
});

async function startServer() {
  await ensureDirs();

  const app = express();
  app.use(cors());
  const httpServer = createServer(app);
  const io = new Server(httpServer, {
    cors: { origin: "*" },
    maxHttpBufferSize: 1e8,
  });

  app.use(express.json({ limit: "100mb" }));
  app.use(express.urlencoded({ limit: "100mb", extended: true }));
  app.use("/uploads", express.static(UPLOADS_DIR));

  // User Auth API
  app.post("/api/register", async (req, res) => {
    const { username, password } = req.body;
    console.log(`Registration attempt for username: ${username}`);
    try {
      let registeredUser: any = null;
      let errorMsg = "";

      // 先把口令哈希算好再进锁，避免在文件锁内做 250ms 的 CPU 计算
      const passwordHash = await hashPassword(password || "");

      await withFileLock(USERS_FILE, async () => {
        const users = await safeReadJSON<any[]>(USERS_FILE, []);
        if (users.find((u: any) => u.username === username)) {
          errorMsg = "User already exists";
          return;
        }
        // 只存哈希，不存明文
        const newUser = { id: Date.now().toString(), username, passwordHash };
        users.push(newUser);
        await safeWriteJSON(USERS_FILE, users);
        registeredUser = newUser;
      });

      if (errorMsg) {
        console.log(`Registration failed: ${errorMsg} for ${username}`);
        return res.status(400).json({ error: errorMsg });
      }

      console.log(`Registration successful for username: ${username}`);
      res.json({ user: { id: registeredUser.id, username: registeredUser.username } });
    } catch (e) {
      console.error(`Registration error for ${username}:`, e);
      res.status(500).json({ error: "Registration failed" });
    }
  });

  app.post("/api/login", async (req, res) => {
    if (!req.body || typeof req.body !== 'object') {
      return res.status(400).json({ error: "Invalid request body" });
    }
    const { username, password, deviceType, clientSessionId } = req.body;
    console.log(`Login attempt for username: ${username}, deviceType: ${deviceType}, clientSessionId: ${clientSessionId}`);
    try {
      const users = await safeReadJSON<any[]>(USERS_FILE, []);
      const user = users.find((u: any) => u.username === username);
      
      if (!user) {
        console.log(`Login failed for username: ${username}. User not found.`);
        return res.status(401).json({ error: "账号不存在" });
      }
      
      // 兼容存量：老数据是明文 password 字段，新数据是 passwordHash
      const storedSecret = (user.passwordHash ?? user.password ?? "").toString();
      const { matched, needsRehash } = await verifyPassword(password || "", storedSecret);
      if (!matched) {
        console.log(`Login failed for username: ${username}. Incorrect password.`);
        return res.status(401).json({ error: "密码错误" });
      }

      // 存量明文账号：登录成功即升级为 bcrypt 哈希，并清除明文
      if (needsRehash) {
        try {
          const upgradedHash = await hashPassword(password || "");
          await withFileLock(USERS_FILE, async () => {
            const all = await safeReadJSON<any[]>(USERS_FILE, []);
            const idx = all.findIndex((u: any) => u.username === username);
            if (idx !== -1) {
              all[idx].passwordHash = upgradedHash;
              delete all[idx].password;
              await safeWriteJSON(USERS_FILE, all);
            }
          });
          console.log(`[Security] 已将账号 ${username} 的明文口令升级为 bcrypt 哈希`);
        } catch (upgradeError) {
          // 升级失败不应影响本次登录，下次登录会重试
          console.error(`[Security] 口令哈希升级失败 (${username}):`, upgradeError);
        }
      }

      const cleanDeviceType: 'mobile' | 'desktop' = (deviceType === 'mobile') ? 'mobile' : 'desktop';
      const sessionId = (clientSessionId || `sess_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`).toString();

      await withFileLock(ACTIVE_SESSIONS_FILE, async () => {
        const sessions = await safeReadJSON<Record<string, Record<string, DeviceSession>>>(ACTIVE_SESSIONS_FILE, {});
        if (!sessions[username]) sessions[username] = {};

        const existingSession = sessions[username][cleanDeviceType];
        if (existingSession && existingSession.clientSessionId && existingSession.clientSessionId !== sessionId) {
          const reason = `您的账号已在另一台${cleanDeviceType === 'mobile' ? '手机' : '电脑'}上登录，当前设备已被下线。`;
          console.log(`[Kick] User ${username} logged in on new ${cleanDeviceType}, kicking previous session ${existingSession.clientSessionId}`);
          
          io.to(`session_${existingSession.clientSessionId}`).emit("force_logout", {
            reason,
            deviceType: cleanDeviceType,
            kickedSessionId: existingSession.clientSessionId,
          });
          io.to(`user_${username}_${cleanDeviceType}`).emit("force_logout", {
            reason,
            deviceType: cleanDeviceType,
            kickedSessionId: existingSession.clientSessionId,
          });
          io.to(`user_${username}`).emit("force_logout", {
            reason,
            deviceType: cleanDeviceType,
            kickedSessionId: existingSession.clientSessionId,
          });
        }

        sessions[username][cleanDeviceType] = {
          clientSessionId: sessionId,
          deviceType: cleanDeviceType,
          loginTime: Date.now(),
          lastActive: Date.now(),
        };
        await safeWriteJSON(ACTIVE_SESSIONS_FILE, sessions);
      });

      console.log(`Login successful for username: ${username} on ${cleanDeviceType}`);
      res.json({
        user: { id: user.id, username: user.username },
        deviceType: cleanDeviceType,
        clientSessionId: sessionId,
      });
    } catch (e) {
      console.error(`Login error for ${username}:`, e);
      res.status(500).json({ error: "Login failed" });
    }
  });

  app.get("/api/health", (req, res) => {
    res.json({ status: "ok", service: "aether-x-relay", timestamp: Date.now() });
  });

  app.get("/api/check-session", async (req, res) => {
    const userId = (req.query.userId || req.query.username || "").toString().trim();
    const deviceType: 'mobile' | 'desktop' = (req.query.deviceType || "").toString() === "mobile" ? "mobile" : "desktop";
    const clientSessionId = (req.query.clientSessionId || "").toString().trim();

    if (!userId || !clientSessionId || userId === 'guest' || userId === 'default_user') {
      return res.json({ valid: true });
    }

    // 顺带下发当前有效的 Agent Token：这个接口每 4 秒被轮询一次，
    // 是最合适的"token 变更通知"通道（服务端换发后各端无需重登即可收敛）。
    const currentAgentToken = await (async () => {
      try {
        const allSettings = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
        return readUserAgentToken(allSettings[userId]);
      } catch {
        return "";
      }
    })();

    // 顺带下发 Agent 在线状态：手机上点击启动/停止后，界面需要自动反映真实状态，
    // 而手机端无法本地探测电脑进程。挂在这次轮询里，两端都能在 ≤4 秒内自动更新，
    // 不必再手动点"刷新"。
    const agentOnline = isAgentOnlineByToken(currentAgentToken);

    // 「桥接状态切换中」标记：任一端发起启停/重置后登记，两端据此统一置灰按钮，
    // 直到状态真的切换到位才解除。这里是结算点（能拿到最新 agentOnline）。
    const bridgeTransition = resolveBridgeTransition(userId, agentOnline);

    // 设置版本号：任一端写过设置后这里会变，客户端据此决定要不要重新拉云端设置。
    // bySessionId 用于让写入方自己跳过（避免自己拉自己刚推的内容）。
    const revision = settingsRevision.get(userId);

    // 下发并消费"桥接控制指令"：手机点启停/重置时排队，电脑端 App 在下一次轮询
    // （≤4 秒）取到并本地执行 —— 复用已有的会话轮询通道，无需新建长连接。
    //
    // 关键：只有电脑端才允许取件。手机端与电脑端轮询的是同一个 userId，
    // 早先的实现两端都取，手机常常抢先把指令取走删掉，导致电脑端收不到指令、
    // 用户只能跑到电脑前手动"停止-重置-启动"。指令必须先到电脑端手里。
    let pendingCommand: string | undefined;
    if (deviceType === "desktop") {
      const queued = pendingBridgeCommands.get(userId);
      if (queued) {
        if (Date.now() - queued.createdAt > BRIDGE_COMMAND_TTL_MS) {
          pendingBridgeCommands.delete(userId);
          console.log(`[Bridge Cmd] 指令 ${queued.command} 已过期作废（电脑端未在 2 分钟内取走）`);
        } else {
          pendingBridgeCommands.delete(userId);
          pendingCommand = queued.command;
          console.log(`[Bridge Cmd] 指令 ${queued.command} 已下发给电脑端 App 执行`);
        }
      }
    }

    try {
      const sessions = await safeReadJSON<Record<string, Record<string, DeviceSession>>>(ACTIVE_SESSIONS_FILE, {});
      const active = sessions[userId]?.[deviceType];

      if (active && active.clientSessionId && active.clientSessionId !== clientSessionId) {
        return res.status(401).json({
          valid: false,
          error: "FORCE_LOGOUT",
          reason: `您的账号已在另一台${deviceType === 'mobile' ? '手机' : '电脑'}上登录，当前设备已被下线。`,
          kickedSessionId: clientSessionId,
        });
      }

      if (active && active.clientSessionId === clientSessionId) {
        active.lastActive = Date.now();
      }
      res.json({
        valid: true,
        agentOnline,
        ...(currentAgentToken ? { harnessToken: currentAgentToken } : {}),
        ...(pendingCommand ? { bridgeCommand: pendingCommand } : {}),
        ...(bridgeTransition ? { bridgeTransition } : {}),
        ...(revision
          ? { settingsUpdatedAt: revision.at, settingsBySessionId: revision.bySessionId }
          : {}),
      });
    } catch (e) {
      res.json({
        valid: true,
        agentOnline,
        ...(currentAgentToken ? { harnessToken: currentAgentToken } : {}),
        ...(pendingCommand ? { bridgeCommand: pendingCommand } : {}),
        ...(bridgeTransition ? { bridgeTransition } : {}),
        ...(revision
          ? { settingsUpdatedAt: revision.at, settingsBySessionId: revision.bySessionId }
          : {}),
      });
    }
  });

  /**
   * 手机端下发桥接控制指令。
   * 电脑端 App 在会话轮询中取走并本地执行（启动/停止/重启本机的 bridge 脚本）。
   */
  app.post("/api/agent/bridge-command", async (req, res) => {
    try {
      const userId = ((req.body?.userId as string) || "").trim();
      const command = ((req.body?.command as string) || "").trim().toLowerCase();
      const allowed = ["start", "stop", "restart"];
      if (!userId || userId === "guest") {
        return res.status(401).json({ error: "缺少 userId，无法下发指令" });
      }
      if (!allowed.includes(command)) {
        return res.status(400).json({ error: `不支持的指令：${command}，可选 ${allowed.join(" / ")}` });
      }

      // 账号级互斥：任一端正在切换状态时，另一端（含发起端自己连点）一律拒绝，
      // 否则 start/stop 会互相打架，桥接被反复启停。
      const occupied = activeBridgeTransition(userId);
      if (occupied) {
        return res.status(409).json({
          error: "桥接状态正在切换中，请等这次切换完成后再操作",
          code: "BRIDGE_BUSY",
          bridgeTransition: describeBridgeTransition(occupied),
        });
      }

      const device = ((req.body?.device as string) || "unknown").trim();
      pendingBridgeCommands.set(userId, { command, createdAt: Date.now() });
      armBridgeTransition(userId, command, command === "stop" ? false : true, device);
      console.log(
        `[Bridge Cmd] 已为用户 ${userId} 排队指令: ${command}（发起端 ${device}，等待电脑端 App 轮询取走）` +
          `；账号已锁定，切换到位前两端按钮都会置灰`,
      );
      res.json({ success: true, command, note: "电脑端将在数秒内执行" });
    } catch (err: any) {
      res.status(500).json({ error: err.message || "Failed to queue bridge command" });
    }
  });

  /**
   * 电脑端**本地**启停前先来登记一次「状态切换中」。
   *
   * 电脑端在自己机器上直接启停不经过指令队列，若不登记，手机端在状态回传前
   * 仍可点击并下发相反指令。登记后两端都会在轮询里拿到标记并置灰按钮。
   */
  app.post("/api/agent/bridge-transition", async (req, res) => {
    try {
      const userId = ((req.body?.userId as string) || "").trim();
      const command = ((req.body?.command as string) || "").trim().toLowerCase();
      const device = ((req.body?.device as string) || "unknown").trim();
      const allowed = ["start", "stop", "restart"];
      if (!userId || userId === "guest") {
        return res.status(401).json({ error: "缺少 userId，无法登记状态切换" });
      }
      if (!allowed.includes(command)) {
        return res.status(400).json({ error: `不支持的指令：${command}，可选 ${allowed.join(" / ")}` });
      }
      const occupied = activeBridgeTransition(userId);
      if (occupied) {
        return res.status(409).json({
          error: "另一台设备正在切换桥接状态，请稍候",
          code: "BRIDGE_BUSY",
          bridgeTransition: describeBridgeTransition(occupied),
        });
      }
      const target = command === "stop" ? false : true;
      armBridgeTransition(userId, command, target, device);
      console.log(`[Bridge Cmd] ${device} 端在本地发起 ${command}，已锁定账号切换状态`);
      res.json({ success: true, command, target, note: "已登记，两端界面将在数秒内同步为切换中" });
    } catch (err: any) {
      res.status(500).json({ error: err.message || "Failed to register bridge transition" });
    }
  });

  /**
   * 撤销「状态切换中」标记。
   *
   * 电脑端本地启停失败（例如没装 Python）时用得上：登记已经发生，但状态永远
   * 不会变成期望值，若不撤销，两端按钮要白等 20 秒兜底才恢复。
   */
  app.post("/api/agent/bridge-transition/cancel", async (req, res) => {
    try {
      const userId = ((req.body?.userId as string) || "").trim();
      if (!userId || userId === "guest") {
        return res.status(401).json({ error: "缺少 userId" });
      }
      const existed = bridgeTransitions.delete(userId);
      if (existed) {
        console.log(`[Bridge Cmd] 用户 ${userId} 的切换标记已撤销，两端按钮立即恢复`);
      }
      res.json({ success: true, cancelled: existed });
    } catch (err: any) {
      res.status(500).json({ error: err.message || "Failed to cancel bridge transition" });
    }
  });

  app.post("/api/logout", async (req, res) => {
    const { username, userId, deviceType, clientSessionId } = req.body || {};
    const targetUser = (username || userId || "").toString().trim();
    const cleanDeviceType = deviceType === "mobile" ? "mobile" : "desktop";

    if (targetUser) {
      try {
        await withFileLock(ACTIVE_SESSIONS_FILE, async () => {
          const sessions = await safeReadJSON<Record<string, Record<string, DeviceSession>>>(ACTIVE_SESSIONS_FILE, {});
          if (sessions[targetUser]?.[cleanDeviceType]?.clientSessionId === clientSessionId) {
            delete sessions[targetUser][cleanDeviceType];
            await safeWriteJSON(ACTIVE_SESSIONS_FILE, sessions);
          }
        });
      } catch (e) {
        console.error("Logout error:", e);
      }
    }
    res.json({ success: true });
  });

  // REST API for messages (Per user)
  app.get("/api/messages/:userId", async (req, res) => {
    try {
      const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
      const userMsgs = (allMessages[req.params.userId] || []).filter(
        (m: any) => m && m.id && m.sessionId && m.sessionId.toString().trim() !== ''
      );
      res.json(userMsgs);
    } catch (error) {
      res.status(500).json({ error: "Failed to load messages" });
    }
  });

  app.post("/api/sync-messages", async (req, res) => {
    const { userId, messages } = req.body;
    try {
      await withFileLock(MESSAGES_FILE, async () => {
        const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
        if (!allMessages[userId]) allMessages[userId] = [];
        // Only accept messages with a valid sessionId
        const validIncoming = (messages || []).filter(
          (m: any) => m && m.id && m.sessionId && m.sessionId.toString().trim() !== ''
        );
        const newMessages = [...allMessages[userId], ...validIncoming];
        const uniqueMessages = Array.from(new Map(newMessages.map(m => [m.id, m])).values())
          .filter((m: any) => m && m.id && m.sessionId && m.sessionId.toString().trim() !== '');
        allMessages[userId] = uniqueMessages;
        await safeWriteJSON(MESSAGES_FILE, allMessages);
      });
      res.json({ success: true });
    } catch (error) {
      console.error("Sync messages error:", error);
      res.status(500).json({ error: "Failed to sync messages" });
    }
  });

  app.post("/api/delete-message", async (req, res) => {
    const { userId, messageId } = req.body;
    if (!userId || !messageId) {
      return res.status(400).json({ error: "Missing userId or messageId" });
    }
    try {
      await withFileLock(MESSAGES_FILE, async () => {
        const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
        if (allMessages[userId]) {
          allMessages[userId] = allMessages[userId].filter((m: any) => m.id !== messageId);
          await safeWriteJSON(MESSAGES_FILE, allMessages);
        }
      });
      io.to(`user_${userId}`).emit("message_deleted", messageId);
      res.json({ success: true });
    } catch (error) {
      console.error("Delete message error:", error);
      res.status(500).json({ error: "Failed to delete message" });
    }
  });

  app.post("/api/delete-session", async (req, res) => {
    const { userId, sessionId } = req.body;
    const cleanSessionId = (sessionId || "").toString().trim();
    if (!userId || !cleanSessionId) {
      return res.status(400).json({ error: "Missing userId or sessionId" });
    }
    try {
      await withFileLock(MESSAGES_FILE, async () => {
        const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
        if (allMessages[userId]) {
          allMessages[userId] = allMessages[userId].filter(
            (m: any) => m && m.sessionId && m.sessionId.toString().trim() !== cleanSessionId
          );
          await safeWriteJSON(MESSAGES_FILE, allMessages);
        }
      });
      // Broadcast session deletion to all connected devices of this user
      io.to(`user_${userId}`).emit("session_deleted", { sessionId: cleanSessionId });
      io.emit("session_deleted", { userId, sessionId: cleanSessionId });
      res.json({ success: true });
    } catch (error) {
      console.error("Delete session error:", error);
      res.status(500).json({ error: "Failed to delete session" });
    }
  });

  // REST API for active session IDs of a user
  app.get("/api/active-sessions/:userId", async (req, res) => {
    try {
      const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
      const userMessages = allMessages[req.params.userId] || [];
      const sessionIds = Array.from(new Set(userMessages.map((m: any) => m.sessionId).filter(Boolean)));
      res.json({ sessionIds });
    } catch (error) {
      res.status(500).json({ error: "Failed to load active sessions" });
    }
  });

  // Server-side Background Chat Generation (Persists even if client is closed/killed)
  app.post("/api/chat/generate", async (req, res) => {
    const { userId, assistantMessageId, messages, settings } = req.body;
    if (!assistantMessageId || !Array.isArray(messages)) {
      return res.status(400).json({ error: "Invalid parameters" });
    }
    
    // Start asynchronous generation in the background
    runServerSideGeneration({
      userId: userId || "guest",
      assistantMessageId,
      messages,
      settings: settings || {},
      io
    }).catch(err => {
      console.error("[Background Gen Worker] Uncaught error:", err);
    });

    res.json({ success: true, messageId: assistantMessageId, status: "generating" });
  });

  /**
   * 打断 / 停止当前这一轮生成。
   *
   * 插话发送与"停止生成"都走这里。要点：
   * · 掐断思考 API 的流（abortController）；
   * · 若这一轮还在等本地 Agent 执行，同时把 DSH 那一轮也中止 ——
   *   此前 App 的"停止"只断开了自己的 SSE，电脑上的 DSH 还在继续跑，
   *   跑完的结果过一会儿又同步回来（"诈尸"）；
   * · 标记 cancelledByUser，让收尾逻辑保留已生成的部分并标成"已打断"。
   */
  app.post("/api/chat/cancel", async (req, res) => {
    try {
      const userId = ((req.body?.userId as string) || "").trim();
      const assistantMessageId = ((req.body?.assistantMessageId as string) || "").trim();
      const sessionId = ((req.body?.sessionId as string) || "").trim();
      if (!userId || userId === "guest") {
        return res.status(401).json({ success: false, error: "缺少 userId" });
      }

      let gen: ActiveGeneration | undefined;
      if (assistantMessageId) gen = activeGenerations.get(`${userId}_${assistantMessageId}`);
      if (!gen && sessionId) gen = findActiveGenerationBySession(userId, sessionId);
      if (!gen) {
        return res.json({ success: true, cancelled: false, note: "当前没有进行中的生成" });
      }

      gen.cancelledByUser = true;
      gen.status = 'cancelled';
      try {
        gen.abortController.abort();
      } catch {}

      // 同时中止本地 Agent 那一轮（如果还在执行阶段）
      let agentCancelled = false;
      for (const [taskId, pending] of pendingAgentTasks.entries()) {
        if (pending.assistantMessageId !== gen.assistantMessageId) continue;
        const targetToken = pending.token;
        const agent = targetToken ? connectedAgents.get(targetToken) : undefined;
        if (agent?.ws && agent.ws.readyState === 1) {
          try {
            agent.ws.send(JSON.stringify({ type: "cancel_task", taskId }));
            agentCancelled = true;
          } catch {}
        }
        clearTimeout(pending.timeoutId);
        pendingAgentTasks.delete(taskId);
        pending.resolve({ success: false, output: "任务已被用户打断。", steps: ["⏹ 已打断本地执行"] });
      }

      console.log(
        `[Chat] 用户打断生成 ${gen.assistantMessageId}（阶段 ${gen.phase ?? "unknown"}）` +
          (agentCancelled ? "，并已通知本地 DSH 中止执行" : ""),
      );
      io.to(`user_${userId}`).emit("chat_cancelled", { messageId: gen.assistantMessageId });
      res.json({ success: true, cancelled: true, agentCancelled, phase: gen.phase ?? null });
    } catch (err: any) {
      res.status(500).json({ success: false, error: err?.message || "打断失败" });
    }
  });

  // Server-side SSE Chat Stream (Streams Agent Execution & Final LLM Tokens in Realtime)
  app.post("/api/chat/stream", async (req, res) => {
    const { userId = "guest", assistantMessageId, messages, settings } = req.body;
    if (!assistantMessageId || !Array.isArray(messages)) {
      return res.status(400).json({ error: "Invalid parameters" });
    }

    res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
    res.setHeader("Cache-Control", "no-cache, no-transform");
    res.setHeader("Connection", "keep-alive");
    res.setHeader("X-Accel-Buffering", "no");
    res.flushHeaders?.();

    let isClosed = false;
    const sendEvent = (event: string, data: any) => {
      if (isClosed) return;
      try {
        res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
        (res as any).flush?.();
      } catch {}
    };

    // SSE 心跳：Agent 任务在电脑上可能要跑几十秒到几分钟，期间可能长时间没有
    // 任何事件。客户端 Dio 的 receiveTimeout、以及中间的 Nginx/Cloudflare 都会
    // 把"静默"的连接掐断 —— 手机上报的「The request took longer than 0:00:15
    // to receive data」正是这么来的。每 10 秒发一个 SSE 注释行保活。
    const heartbeat = setInterval(() => {
      if (isClosed) return;
      try {
        res.write(`: ping ${Date.now()}\n\n`);
        (res as any).flush?.();
      } catch {}
    }, 10000);

    const chunkHandler = (data: any) => {
      if (data.messageId === assistantMessageId) {
        sendEvent("chunk", {
          content: data.chunk,
          reasoning: data.reasoningChunk,
          fullContent: data.fullContent,
          fullReasoning: data.fullReasoning,
        });
      }
    };

    const stepHandler = (data: any) => {
      sendEvent("step", { step: data.step, taskId: data.taskId });
    };

    const taskStartedHandler = (data: any) => {
      if (data.messageId === assistantMessageId) {
        sendEvent("agent_started", { initialStep: data.initialStep, taskId: data.taskId });
      }
    };

    const phaseHandler = (data: any) => {
      sendEvent("phase", { phase: data.phase });
    };

    // DSH 在本地执行时可能要用户拍板（越权操作确认等）。服务端把它通过 SSE
    // 送到 App，用户在 App 上点了之后走 /api/agent/approve 回传 —— 之前这条
    // 通知只走 socket.io，而 App 没有 socket.io 客户端，所以只有 DSH 自己弹窗。
    const approvalHandler = (data: any) => {
      sendEvent("approval", {
        taskId: data.taskId,
        approval: data.approval,
      });
    };

    // 选择框（ask_user_question）：同样走 SSE 送一份，App 在流式接收时能立刻弹卡片
    const questionHandler = (data: any) => {
      sendEvent("question", {
        questionId: data.questionId,
        questions: data.questions,
      });
    };

    const taskFinishedHandler = (data: any) => {
      if (data.messageId === assistantMessageId) {
        sendEvent("agent_finished", { result: data.result, taskId: data.taskId });
      }
    };

    const completedHandler = (data: any) => {
      if (data.messageId === assistantMessageId) {
        sendEvent("done", {
          fullContent: data.content,
          fullReasoning: data.reasoningContent,
          agentExecution: data.agentExecution,
          // 被用户插话/停止打断时告知客户端：保留已生成的部分，不要当成失败
          interrupted: data.interrupted === true,
        });
        cleanup();
        if (!isClosed) {
          isClosed = true;
          res.end();
        }
      }
    };

    const errorHandler = (data: any) => {
      if (data.messageId === assistantMessageId) {
        sendEvent("error", { error: data.error });
        cleanup();
        if (!isClosed) {
          isClosed = true;
          res.end();
        }
      }
    };

    const cleanup = () => {
      clearInterval(heartbeat);
      generationEvents.off(`chunk_${assistantMessageId}`, chunkHandler);
      generationEvents.off(`step_${assistantMessageId}`, stepHandler);
      generationEvents.off(`task_started_${assistantMessageId}`, taskStartedHandler);
      generationEvents.off(`task_finished_${assistantMessageId}`, taskFinishedHandler);
      generationEvents.off(`phase_${assistantMessageId}`, phaseHandler);
      generationEvents.off(`approval_${assistantMessageId}`, approvalHandler);
      generationEvents.off(`question_${assistantMessageId}`, questionHandler);
      generationEvents.off(`completed_${assistantMessageId}`, completedHandler);
      generationEvents.off(`error_${assistantMessageId}`, errorHandler);
    };

    // 客户端断开要监听 **res** 而不是 req：
    // Node 14+ 的流在 'end' 之后会自动销毁并触发 'close'，而请求体被 body-parser
    // 读完就会 'end'。也就是说 req.on('close') 在这次请求刚开始就会被触发，
    // isClosed 立刻变 true，之后所有 sendEvent/心跳全部被静默丢弃 ——
    // 表现就是"SSE 一个字节都收不到"，手机端一直等到 Dio 的 receive timeout。
    res.on("close", () => {
      isClosed = true;
      cleanup();
    });

    generationEvents.on(`chunk_${assistantMessageId}`, chunkHandler);
    generationEvents.on(`step_${assistantMessageId}`, stepHandler);
    generationEvents.on(`task_started_${assistantMessageId}`, taskStartedHandler);
    generationEvents.on(`task_finished_${assistantMessageId}`, taskFinishedHandler);
    generationEvents.on(`phase_${assistantMessageId}`, phaseHandler);
    generationEvents.on(`approval_${assistantMessageId}`, approvalHandler);
    generationEvents.on(`question_${assistantMessageId}`, questionHandler);
    generationEvents.on(`completed_${assistantMessageId}`, completedHandler);
    generationEvents.on(`error_${assistantMessageId}`, errorHandler);

    // Trigger or connect to background generation
    runServerSideGeneration({
      userId,
      assistantMessageId,
      messages,
      settings: settings || {},
      io,
    }).catch((err) => {
      sendEvent("error", { error: err.message });
      cleanup();
      if (!isClosed) {
        isClosed = true;
        res.end();
      }
    });
  });

  // Settings API
  // ==================== Agent Token 归属校验（多租户安全） ====================
  // 历史问题：agent 接口只按 token 查表、且多处回退到 "default_agent_token"，
  // 导致「知道任意 token 即可控制他人电脑」。以下工具用于堵死该通道：
  // 1) 客户端字段名是 harnessToken，服务端曾误读 agentToken → 永远读空 → 全落默认 token；
  // 2) token 必须能归属到某个真实用户，否则拒绝；
  // 3) 所有带 token 的 App 侧请求都必须自报 userId 并通过归属校验。

  /**
   * 反查 token 归属者：优先取注册时记录的 owner，
   * 否则回落到用户设置反查并回填（兼容升级前已配对的存量用户）。
   */
  const resolveTokenOwnerUserId = async (token: string): Promise<string | undefined> => {
    const clean = (token || "").trim();
    if (!isPlausibleAgentToken(clean)) return undefined;

    const existing = connectedAgents.get(clean);
    if (existing?.ownerUserId) return existing.ownerUserId;

    try {
      const allSettings = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
      for (const [userId, record] of Object.entries(allSettings || {})) {
        if (readUserAgentToken(record) === clean) {
          const agent = connectedAgents.get(clean);
          if (agent && !agent.ownerUserId) {
            agent.ownerUserId = userId;
            console.log(`\x1b[36m[Agent Hub] 已回填 token 归属: user=${userId}\x1b[0m`);
          }
          return userId;
        }
      }
    } catch (e) {
      console.error("[Agent Hub] 反查 token 归属失败:", e);
    }
    return undefined;
  };

  /**
   * App（人）侧接口的归属校验：必须自报 userId，且该 token 确实属于他。
   * 返回 undefined 表示通过；否则为应回给客户端的错误。
   */
  const verifyAgentOwnership = async (
    token: string,
    claimedUserId: string
  ): Promise<{ status: number; error: string } | undefined> => {
    const clean = (token || "").trim();
    const claimed = (claimedUserId || "").trim();

    if (!isPlausibleAgentToken(clean)) {
      return { status: 401, error: "无效的 Agent Token（不得为空或使用默认值）" };
    }
    if (!claimed) {
      return { status: 401, error: "缺少 userId，无法校验 Agent 归属" };
    }

    const owner = await resolveTokenOwnerUserId(clean);
    if (owner && owner !== claimed) {
      console.warn(`\x1b[31m[Security] 越权访问被拒绝: user=${claimed} 试图访问 owner=${owner} 的 Agent\x1b[0m`);
      return { status: 403, error: "该 Agent 不属于当前账号" };
    }
    if (!owner) {
      // 严格模式：token 必须能归属到某个真实用户。
      // 此前这里直接放行，导致任意"格式合法"的字符串都能注册成 Agent，
      // 而 App 拿着本账号真正的 token 永远查不到它（表现为"桥接已连接但手机显示离线"）。
      return { status: 403, error: "该 Agent Token 未绑定任何账号，请在 App 中重新配对" };
    }
    return undefined;
  };

  const sanitizeSettings = (settings: any) => {
    if (!settings || typeof settings !== "object") return settings;
    const sanitized = { ...settings };
    if ("apiKey" in sanitized) sanitized.apiKey = "";
    if ("asrApiKey" in sanitized) sanitized.asrApiKey = "";
    if ("accountPassword" in sanitized) sanitized.accountPassword = "";
    if ("password" in sanitized) sanitized.password = "";
    if (Array.isArray(sanitized.apiEndpoints)) {
      sanitized.apiEndpoints = sanitized.apiEndpoints.map((ep: any) => {
        if (ep && typeof ep === "object") {
          return { ...ep, apiKey: "" };
        }
        return ep;
      });
    }
    return sanitized;
  };

  app.get("/api/settings/:userId", async (req, res) => {
    try {
      const allSettings = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
      res.json(sanitizeSettings(allSettings[req.params.userId] || {}));
    } catch (error) {
      res.status(500).json({ error: "Failed to load settings" });
    }
  });

  app.post("/api/settings/:userId", async (req, res) => {
    const userId = (req.params.userId || "").trim();
    if (!userId || userId === 'guest') {
      return res.json({ success: true, message: "Guest settings ignored" });
    }
    const newSettings = sanitizeSettings(req.body || {});
    try {
      await withFileLock(SETTINGS_FILE, async () => {
        const allSettings = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
        allSettings[userId] = { ...(allSettings[userId] || {}), ...newSettings };
        await safeWriteJSON(SETTINGS_FILE, allSettings);
      });
      io.to(`user_${userId}`).emit("settings_updated", newSettings);
      // 记下版本：其他设备的会话轮询拿到后会主动拉一次，实现运行中的双端同步
      bumpSettingsRevision(userId, (req.headers["x-client-session-id"] as string) || "");
      res.json({ success: true, data: newSettings });
    } catch (error) {
      console.error("Failed to save user settings:", error);
      res.status(500).json({ error: "Failed to save settings" });
    }
  });

  app.post("/api/sync-settings", async (req, res) => {
    const { userId, settings } = req.body || {};
    const cleanUserId = (userId || "").trim();
    if (!cleanUserId || cleanUserId === 'guest') {
      return res.json({ success: true, message: "Guest settings ignored" });
    }
    const cleanSettings = sanitizeSettings(settings || {});
    try {
      await withFileLock(SETTINGS_FILE, async () => {
        const allSettings = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
        allSettings[cleanUserId] = { ...(allSettings[cleanUserId] || {}), ...cleanSettings };
        await safeWriteJSON(SETTINGS_FILE, allSettings);
      });

      // 确保该用户有一条服务端签发的 Agent Token（token 唯一真源）。
      // 兼容顺序：设置里已有 → 复用；本次同步带来了 → 采纳；都没有 → 生成。
      const issuedToken = await resolveOrCreateUserAgentToken(
        cleanUserId,
        readUserAgentToken(cleanSettings)
      );

      io.to(`user_${cleanUserId}`).emit("settings_updated", cleanSettings);
      bumpSettingsRevision(cleanUserId, (req.headers["x-client-session-id"] as string) || "");
      res.json({ success: true, ...(issuedToken ? { harnessToken: issuedToken } : {}) });
    } catch (error) {
      console.error("Failed to sync settings:", error);
      res.status(500).json({ error: "Failed to sync settings" });
    }
  });

  // 获取服务端维护的全部模型上下文上限列表
  app.get("/api/model-limits", async (req, res) => {
    try {
      await ensureModelLimitsInitialized();
      const limits = await safeReadJSON<Record<string, number>>(MODEL_LIMITS_FILE, {});
      res.json({ success: true, limits });
    } catch (error) {
      console.error("Failed to read model limits:", error);
      res.status(500).json({ error: "Failed to read model limits", limits: {} });
    }
  });

  // 更新/维护服务端模型上下文上限列表 (支持在线直接修改或后台写入)
  app.post("/api/model-limits", async (req, res) => {
    try {
      const { limits } = req.body || {};
      if (limits && typeof limits === 'object') {
        await withFileLock(MODEL_LIMITS_FILE, async () => {
          await safeWriteJSON(MODEL_LIMITS_FILE, limits);
        });
        return res.json({ success: true, message: "Model limits updated successfully" });
      }
      res.status(400).json({ error: "Invalid limits object" });
    } catch (error) {
      console.error("Failed to write model limits:", error);
      res.status(500).json({ error: "Failed to write model limits" });
    }
  });

  app.post("/api/change-password", async (req, res) => {
    const { userId, oldPassword, newPassword } = req.body;
    if (!newPassword || String(newPassword).length < 6) {
      return res.status(400).json({ error: "新密码长度至少 6 位" });
    }
    try {
      // bcrypt 比对是异步的，不能放进同步的文件锁回调里，
      // 因此先读取校验，再在锁内落盘（并在锁内复查用户仍存在）。
      const snapshot = await safeReadJSON<any[]>(USERS_FILE, []);
      const snapshotUser = snapshot.find((u: any) => u.id === userId);
      if (!snapshotUser) {
        return res.status(401).json({ error: "原密码错误" });
      }
      const storedSecret = (snapshotUser.passwordHash ?? snapshotUser.password ?? "").toString();
      const { matched } = await verifyPassword(oldPassword || "", storedSecret);
      if (!matched) {
        return res.status(401).json({ error: "原密码错误" });
      }

      const newHash = await hashPassword(newPassword || "");
      let success = false;
      await withFileLock(USERS_FILE, async () => {
        const users = await safeReadJSON<any[]>(USERS_FILE, []);
        const userIndex = users.findIndex((u: any) => u.id === userId);
        if (userIndex === -1) {
          return;
        }
        users[userIndex].passwordHash = newHash;
        delete users[userIndex].password; // 清除可能残留的明文字段
        await safeWriteJSON(USERS_FILE, users);
        success = true;
      });

      if (!success) {
        return res.status(401).json({ error: "用户不存在" });
      }
      res.json({ success: true });
    } catch (e) {
      res.status(500).json({ error: "服务器错误" });
    }
  });

  app.post("/api/upload-chunk", upload.single("chunk"), async (req, res) => {
    try {
      const { filename, chunkIndex, totalChunks } = req.body;
      const chunkDir = path.join(UPLOADS_DIR, `temp_${filename}`);
      await fs.mkdir(chunkDir, { recursive: true });
      await fs.rename(req.file!.path, path.join(chunkDir, chunkIndex));
      
      const files = await fs.readdir(chunkDir);
      if (files.length === parseInt(totalChunks)) {
        // Assemble
        const finalPath = path.join(UPLOADS_DIR, filename);
        const writeStream = require('fs').createWriteStream(finalPath);
        for (let i = 0; i < files.length; i++) {
          const chunkPath = path.join(chunkDir, i.toString());
          const chunkData = await fs.readFile(chunkPath);
          writeStream.write(chunkData);
          await fs.unlink(chunkPath);
        }
        writeStream.end();
        await fs.rmdir(chunkDir);
        res.json({ url: `/uploads/${filename}`, completed: true });
      } else {
        res.json({ completed: false });
      }
    } catch (e) {
      console.error(e);
      res.status(500).json({ error: "Chunk upload failed" });
    }
  });
  
  app.post("/api/upload", upload.single("image"), (req, res) => {
    if (!req.file) return res.status(400).json({ error: "No file uploaded" });
    res.json({ url: `/uploads/${req.file.filename}` });
  });

  // Universal Proxy route for Voice Transcription (FunASR, SenseVoice & OpenAI/Whisper compatible APIs)
  app.post(["/api/funasr-transcribe", "/api/asr/transcribe", "/api/asr/speech-to-text"], upload.any(), async (req, res) => {
    let file: any = null;
    try {
      file = (req.files as any)?.[0] || req.file;
      const rawEndpoint = (req.query.endpoint as string) || (req.query.target as string) || (req.body?.endpoint as string) || (req.body?.target as string) || "";
      if (!rawEndpoint) {
        return res.status(400).json({ error: "Missing endpoint/target parameter" });
      }
      if (!file) {
        return res.status(400).json({ error: "No file uploaded" });
      }

      const apiKey = (req.headers["x-asr-api-key"] as string) || 
                     (req.headers["x-api-key"] as string) || 
                     (req.headers["authorization"]?.replace(/^Bearer\s+/i, "")) || 
                     (req.query.apiKey as string) || 
                     (req.body?.apiKey as string) || "";

      let model = (req.query.model as string) || (req.headers["x-asr-model"] as string) || (req.body?.model as string) || "";

      let sanitized = rawEndpoint.trim();
      if (sanitized.startsWith('ws://')) {
        sanitized = sanitized.replace('ws://', 'http://');
      } else if (sanitized.startsWith('wss://')) {
        sanitized = sanitized.replace('wss://', 'https://');
      } else if (!sanitized.startsWith('http://') && !sanitized.startsWith('https://')) {
        if (
          sanitized.startsWith('localhost') || 
          sanitized.startsWith('127.0.0.1') || 
          sanitized.startsWith('192.168.') || 
          sanitized.startsWith('10.') || 
          sanitized.startsWith('172.') ||
          /^(\d{1,3}\.){3}\d{1,3}/.test(sanitized)
        ) {
          sanitized = `http://${sanitized}`;
        } else {
          sanitized = `https://${sanitized}`;
        }
      }

      // Check if this is an OpenAI/Whisper compatible endpoint
      const isOpenAiCompatible = 
        sanitized.includes('/audio/transcriptions') ||
        sanitized.includes('openai.com') ||
        sanitized.includes('groq.com') ||
        sanitized.includes('siliconflow.cn') ||
        sanitized.includes('dashscope.aliyuncs.com') ||
        sanitized.endsWith('/v1') ||
        sanitized.endsWith('/v1/') ||
        !!model;

      // Auto-append /audio/transcriptions if user provided a base URL for an OpenAI compatible provider, 
      // but only if it's not already there.
      const alreadyHasPath = sanitized.includes('/audio/transcriptions');
      if (isOpenAiCompatible && !alreadyHasPath) {
        sanitized = sanitized.replace(/\/+$/, '');
        if (sanitized.includes('dashscope.aliyuncs.com')) {
          if (!sanitized.includes('/compatible-mode/v1')) {
            sanitized = `${sanitized}/compatible-mode/v1/audio/transcriptions`;
          } else {
            sanitized = `${sanitized}/audio/transcriptions`;
          }
        } else if (sanitized.includes('groq.com')) {
          if (!sanitized.includes('/openai/v1') && !sanitized.includes('/v1')) {
            sanitized = `${sanitized}/openai/v1/audio/transcriptions`;
          } else {
            sanitized = `${sanitized}/audio/transcriptions`;
          }
        } else if (sanitized.endsWith('/v1')) {
          sanitized = `${sanitized}/audio/transcriptions`;
        } else if (!sanitized.includes('/v1/')) {
          sanitized = `${sanitized}/v1/audio/transcriptions`;
        } else {
          sanitized = `${sanitized}/audio/transcriptions`;
        }
      }

      const fileBuffer = await fs.readFile(file.path);
      const fileName = file.originalname || "audio.wav";
      const mimeType = file.mimetype || "audio/wav";

      const headers: Record<string, string> = {};
      if (apiKey) {
        headers["Authorization"] = `Bearer ${apiKey}`;
      }
      
      var response: Response;

      if (isOpenAiCompatible) {
        if (!model) {
          if (sanitized.includes('siliconflow')) {
            model = 'FunAudioLLM/SenseVoiceSmall';
          } else if (sanitized.includes('groq')) {
            model = 'whisper-large-v3';
          } else if (sanitized.includes('dashscope')) {
            model = 'sensevoice-v1';
          } else {
            model = 'whisper-1';
          }
        }

        const form = new FormData();
        form.append('model', model);
        form.append('file', fileBuffer, {
          filename: fileName,
          contentType: mimeType,
          knownLength: fileBuffer.length
        });

        const formHeaders = form.getHeaders();
        const formBuffer = form.getBuffer();

        response = await fetch(sanitized, {
          method: 'POST',
          headers: { 
            ...headers, 
            ...formHeaders,
            'Content-Length': formBuffer.length.toString()
          },
          body: formBuffer,
        });
      } else {
        // Fallback for non-OpenAI compatible endpoints (FunASR C++ / Python server)
        const form = new FormData();
        form.append("audio_in", fileBuffer, { filename: fileName, contentType: mimeType });
        form.append("file", fileBuffer, { filename: fileName, contentType: mimeType });
        form.append("wav_name", fileName);
        form.append("wav_format", "wav");
        form.append("is_itn", "1");
        
        const formHeaders = form.getHeaders();
        const formBuffer = form.getBuffer();

        response = await fetch(sanitized, {
          method: "POST",
          headers: { 
            ...headers, 
            ...formHeaders,
            'Content-Length': formBuffer.length.toString()
          },
          body: formBuffer,
        });
      }

      // Clean up local temp file
      try {
        if (file && file.path) {
          await fs.unlink(file.path);
        }
      } catch (err) {
        console.error("Failed to delete temp proxy file:", err);
      }

      if (!response.ok) {
        const errorText = await response.text();
        console.error(`[ASR Proxy] Error from target server: ${response.status} - ${errorText}`);
        return res.status(response.status).json({ 
          error: `转写服务返回状态码 ${response.status}: ${errorText.substring(0, 300)}` 
        });
      }

      const responseText = await response.text();
      try {
        const data = JSON.parse(responseText);
        res.json(data);
      } catch {
        res.json({ text: responseText });
      }
    } catch (error: any) {
      console.error("[ASR Proxy] Exception:", error);
      if (file && file.path) {
        try {
          await fs.unlink(file.path);
        } catch (_) {}
      }
      res.status(500).json({ error: error.message || "Failed to proxy ASR request" });
    }
  });

  // Agent Status & Bridge APIs (Dual-Channel: HTTP Long-Polling + WebSocket)
  app.post("/api/agent/register", async (req, res) => {
    try {
      const token = ((req.body?.token as string) || "").trim();
      // 不再回退到 default_agent_token：默认值 = 公共秘密，等于没有鉴权
      if (!isPlausibleAgentToken(token)) {
        console.warn("[Security] 拒绝注册：非法或默认 Agent Token");
        return res.status(401).json({ error: "无效的 Agent Token，请在 App 中生成配对口令后重试" });
      }
      const clientInfo = req.body?.clientInfo || {};
      const clientName = clientInfo.name || "DeepSeek-Harness-Local";

      console.log(`\x1b[32m[Agent Hub] Agent registered via HTTP [${token}] (${clientName}, mode: ${clientInfo.mode || 'polling'})\x1b[0m`);

      // 绑定归属；未能归属任何账号的 token 一律拒绝注册，
      // 避免"孤儿 bridge 显示已连接、但手机端永远查不到"的假在线
      const ownerUserId = await resolveTokenOwnerUserId(token);
      if (!ownerUserId) {
        console.warn("[Security] 拒绝注册：该 Token 未绑定任何账号");
        return res.status(403).json({
          error: "该 Agent Token 未绑定任何账号，请在 App 中重新扫码配对或使用 App 显示的 Token",
        });
      }
      let agent = connectedAgents.get(token);
      if (!agent) {
        agent = {
          token,
          ownerUserId,
          clientName,
          connectedAt: Date.now(),
          lastPing: Date.now(),
          mode: clientInfo.mode || 'polling',
          pendingPollResolvers: [],
          queuedTasks: []
        };
        connectedAgents.set(token, agent);
      } else {
        agent.clientName = clientName;
        agent.lastPing = Date.now();
        agent.mode = clientInfo.mode || agent.mode || 'polling';
      }

      io.emit("agent_status_change", { token, online: true, clientName });
      res.json({ success: true, token, registeredAt: agent.connectedAt });
    } catch (err: any) {
      res.status(500).json({ error: err.message || "Failed to register agent" });
    }
  });

  // Long-polling endpoint for local Python bridge agent
  app.get("/api/agent/poll", (req, res) => {
    try {
      const token = ((req.query.token as string) || "").trim() || "";
      if (!isPlausibleAgentToken(token)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const timeoutSec = Math.min(60, Math.max(5, parseInt((req.query.timeout as string) || "25", 10)));

      let agent = connectedAgents.get(token);
      if (!agent) {
        agent = {
          token,
          clientName: "DeepSeek-Harness-Local",
          connectedAt: Date.now(),
          lastPing: Date.now(),
          mode: 'polling',
          pendingPollResolvers: [],
          queuedTasks: []
        };
        connectedAgents.set(token, agent);
        io.emit("agent_status_change", { token, online: true, clientName: agent.clientName });
      } else {
        agent.lastPing = Date.now();
      }

      // Check if there is already a task waiting in queue
      if (agent.queuedTasks && agent.queuedTasks.length > 0) {
        const task = agent.queuedTasks.shift();
        return res.json(task);
      }

      // Otherwise, hold connection open for long-polling
      let isResolved = false;
      const pollTimer = setTimeout(() => {
        if (!isResolved) {
          isResolved = true;
          if (agent?.pendingPollResolvers) {
            const idx = agent.pendingPollResolvers.indexOf(deliverTask);
            if (idx !== -1) agent.pendingPollResolvers.splice(idx, 1);
          }
          res.json({ type: "noop", timestamp: Date.now(), bootId: SERVER_BOOT_ID });
        }
      }, timeoutSec * 1000);

      const deliverTask = (taskPayload: any) => {
        if (!isResolved) {
          isResolved = true;
          clearTimeout(pollTimer);
          res.json(taskPayload);
        }
      };

      if (!agent.pendingPollResolvers) agent.pendingPollResolvers = [];
      agent.pendingPollResolvers.push(deliverTask);

      req.on("close", () => {
        if (!isResolved) {
          isResolved = true;
          clearTimeout(pollTimer);
          if (agent?.pendingPollResolvers) {
            const idx = agent.pendingPollResolvers.indexOf(deliverTask);
            if (idx !== -1) agent.pendingPollResolvers.splice(idx, 1);
          }
        }
      });
    } catch (err: any) {
      res.status(500).json({ error: err.message || "Failed to poll agent tasks" });
    }
  });

  // Agent task step update
  app.post("/api/agent/step", (req, res) => {
    try {
      const { taskId, step, token } = req.body;
      if (token && connectedAgents.has(token)) {
        connectedAgents.get(token)!.lastPing = Date.now();
      }
      if (taskId && step) {
        io.emit("agent_task_step", { taskId, step });
      }
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // Agent task result report
  app.post("/api/agent/result", (req, res) => {
    try {
      const { taskId, success, steps, output, token } = req.body;
      if (token && connectedAgents.has(token)) {
        connectedAgents.get(token)!.lastPing = Date.now();
      }
      const pending = pendingAgentTasks.get(taskId);
      if (pending) {
        clearTimeout(pending.timeoutId);
        pendingAgentTasks.delete(taskId);
        pending.resolve({
          success: success !== false,
          output: output || "",
          steps: steps || []
        });
      }
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // Agent heartbeat ping
  app.post("/api/agent/heartbeat", (req, res) => {
    const token = ((req.body?.token as string) || "").trim() || "";
    if (!isPlausibleAgentToken(token)) {
      return res.status(401).json({ error: "无效或缺失的 Agent Token" });
    }
    let agent = connectedAgents.get(token);
    if (agent) {
      agent.lastPing = Date.now();
    } else {
      agent = {
        token,
        clientName: "DeepSeek-Harness-Local",
        connectedAt: Date.now(),
        lastPing: Date.now(),
        mode: 'polling',
        pendingPollResolvers: [],
        queuedTasks: []
      };
      connectedAgents.set(token, agent);
      io.emit("agent_status_change", { token, online: true, clientName: agent.clientName });
    }
    res.json({ success: true, timestamp: Date.now(), bootId: SERVER_BOOT_ID });
  });

  app.get("/deepseek_bridge.py", async (req, res) => {
    try {
      const scriptPath = path.resolve(process.cwd(), "deepseek_bridge.py");
      const content = await fs.readFile(scriptPath, "utf-8");
      res.setHeader("Content-Type", "application/octet-stream");
      res.setHeader("Content-Disposition", 'attachment; filename="deepseek_bridge.py"');
      res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
      res.send(content);
    } catch (err: any) {
      res.status(404).send("File not found");
    }
  });

  // Dedicated API download route for Python Bridge with attachment headers
  app.get(["/api/download/deepseek_bridge.py", "/api/download/bridge.py"], async (req, res) => {
    try {
      const scriptPath = path.resolve(process.cwd(), "deepseek_bridge.py");
      const content = await fs.readFile(scriptPath, "utf-8");
      res.setHeader("Content-Type", "application/octet-stream");
      res.setHeader("Content-Disposition", 'attachment; filename="deepseek_bridge.py"');
      res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
      res.send(content);
    } catch (err: any) {
      res.status(404).send("File not found");
    }
  });

  // Dedicated API download route for Windows 1-Click .bat package
  app.get(["/api/download/run_bridge.bat", "/api/download/start.bat"], (req, res) => {
    const token = ((req.query.token as string) || "").trim();
    if (!isPlausibleAgentToken(token)) {
      return res.status(401).json({ error: "无效或缺失的 Agent Token" });
    }
    const harnessUrl = ((req.query.harnessUrl as string) || "http://127.0.0.1:3080").trim();
    
    // Determine host URL
    const protocol = req.headers["x-forwarded-proto"] || req.protocol || "http";
    const host = req.headers["x-forwarded-host"] || req.headers.host || "localhost:3000";
    const serverUrl = `${protocol}://${host}`;

    const batContent = `@echo off
chcp 65001 >nul
title DeepSeek Bridge 本地智能体桥接服务
echo ======================================================================
echo    DeepSeek Bridge 一键启动脚本 (会话自动管理增强版)
echo    服务器地址: ${serverUrl}
echo    本地 Harness: ${harnessUrl}
echo ======================================================================
echo.

where python >nul 2>nul
if %errorlevel% neq 0 (
    echo [错误] 未检测到 Python 环境，请先安装 Python 3.8+ 并勾选 Add to PATH！
    pause
    exit /b 1
)

echo [1/3] 正在检查依赖库 (websockets, aiohttp, urllib3)...
python -m pip install websockets aiohttp urllib3 -q --disable-pip-version-check 2>nul

echo [2/3] 正在同步下载最新的 deepseek_bridge.py 桥接程序...
python -c "import urllib.request; urllib.request.urlretrieve('${serverUrl}/api/download/deepseek_bridge.py', 'deepseek_bridge.py')" 2>nul

if not exist "deepseek_bridge.py" (
    echo [警告] 自动下载失败，将尝试使用本地已有的 deepseek_bridge.py...
)

echo [3/3] 正在启动桥接服务并连接调度中心...
echo.
python deepseek_bridge.py --server "${serverUrl}" --token "${token}" --harness-url "${harnessUrl}"
if %errorlevel% neq 0 (
    echo.
    echo 桥接服务异常退出，请检查上方日志。
    pause
)
`;
    res.setHeader("Content-Type", "application/octet-stream");
    res.setHeader("Content-Disposition", 'attachment; filename="run_bridge.bat"');
    res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
    res.send(batContent);
  });

  app.get("/api/agent/status", async (req, res) => {
    const token = ((req.query.token as string) || "").trim() || "";
    if (!isPlausibleAgentToken(token)) {
      return res.status(401).json({ error: "无效或缺失的 Agent Token" });
    }
    // 越权校验：App 需自报 userId，token 不属于该用户时一律拒绝
    const ownershipError = await verifyAgentOwnership(token, (req.query.userId as string) || "");
    if (ownershipError) {
      return res.status(ownershipError.status).json({ error: ownershipError.error, online: false });
    }

    const agent = connectedAgents.get(token);
    const isOnline = agent && (
      (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) ||
      (Date.now() - agent.lastPing < 45000)
    );

    if (isOnline) {
      res.json({
        online: true,
        clientName: agent.clientName,
        connectedAt: agent.connectedAt,
        mode: agent.mode,
        // 不再用假值兜底：取不到真实工作区就返回空数组，交由客户端提示“未取到”
        workspaces: agent.workspaces ?? [],
        sessions: agent.sessions ?? []
      });
    } else {
      res.json({ online: false, workspaces: [], sessions: [] });
    }
  });

  // Get agent workspaces and active session list
  app.get("/api/agent/sessions", async (req, res) => {
    try {
      const token = ((req.query.token as string) || "").trim() || "";
      if (!isPlausibleAgentToken(token)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      // 越权校验：token 必须属于自报的 userId
      const ownershipError = await verifyAgentOwnership(token, (req.query.userId as string) || "");
      if (ownershipError) {
        return res.status(ownershipError.status).json({ error: ownershipError.error, online: false, workspaces: [], sessions: [] });
      }
      const agent = connectedAgents.get(token);
      const isOnline = agent && (
        (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) ||
        (Date.now() - agent.lastPing < 60000)
      );

      if (agent && agent.ws && agent.ws.readyState === WSWebSocket.OPEN) {
        try {
          const reqId = `sess_req_${Date.now()}`;
          const p = new Promise<any>((resolve) => {
            const timer = setTimeout(() => resolve(null), 2500);
            const l = (raw: any) => {
              try {
                const msg = JSON.parse(raw.toString());
                if (msg.type === "sessions_result") {
                  clearTimeout(timer);
                  agent.ws?.off("message", l);
                  resolve(msg);
                }
              } catch {}
            };
            agent.ws?.on("message", l);
          });
          agent.ws.send(JSON.stringify({ type: "get_sessions", reqId }));
          const result = await p;
          if (result) {
            if (result.workspaces && Array.isArray(result.workspaces)) agent.workspaces = result.workspaces;
            if (result.sessions && Array.isArray(result.sessions)) agent.sessions = result.sessions;
          }
        } catch {}
      }

      res.json({
        online: !!isOnline,
        workspaces: agent?.workspaces || [],
        sessions: agent?.sessions || [],
        // 模型也一并下发：App 的「智能体调度模型」下拉此前列的是 deepseek-chat /
        // deepseek-reasoner 这类本地 DSH 根本不存在的模型，选中后 selectModel
        // 必然失败。以电脑端目录为准，App 才有真选项可选。
        models: agent?.models || [],
        clientName: agent?.clientName || "DeepSeek-Harness-Local"
      });
    } catch (err: any) {
      res.json({
        online: false,
        // 取不到就返回空数组：客户端据此显示空白框，而不是显示一个假的工作区
        workspaces: [],
        sessions: [],
        models: [],
        clientName: "DeepSeek-Harness-Local",
        error: err.message
      });
    }
  });

  // Reset user active session
  app.post("/api/agent/reset-session", (req, res) => {
    const { userId, token } = req.body || {};
    const targetToken = (token || "").trim() || "";
    if (!isPlausibleAgentToken(targetToken)) {
      return res.status(401).json({ error: "无效或缺失的 Agent Token" });
    }
    const agent = connectedAgents.get(targetToken);
    if (agent && agent.activeUserSessions && userId) {
      agent.activeUserSessions.delete(userId);
    }
    res.json({ success: true });
  });

  /**
   * 通过中继把「立即切换权限预设 / 思考深度」转发给本地桥接，并把结果原样带回。
   *
   * 为什么要单独做：以前这两项只在"下一轮对话开始时"由桥接顺手带给 DSH，
   * 而且失败会被静默吞掉 —— App 上点了看着像生效，实际没变。现在按需即时下发，
   * 成功/失败都能回到界面。
   */
  app.post("/api/agent/session-option", async (req, res) => {
    try {
      const { token, userId, kind, sessionId, permission, reasoningEffort, model } = req.body || {};
      const targetToken = (token || "").trim();
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const ownerId = await resolveTokenOwnerUserId(targetToken);
      if (!ownerId || (userId && String(userId).trim() && String(userId).trim() !== ownerId)) {
        return res.status(403).json({ error: "该 Token 不属于当前账号" });
      }
      const agent = connectedAgents.get(targetToken);
      if (!agent || !agent.ws || agent.ws.readyState !== WSWebSocket.OPEN) {
        return res.status(503).json({ success: false, error: "电脑端桥接未在线，无法即时切换" });
      }
      const sid = (sessionId || "").toString().trim();
      if (!sid) {
        return res.status(400).json({ success: false, error: "缺少 sessionId：请先选择或新建会话" });
      }

      let wantType: string;
      let payload: Record<string, any>;
      let wantResult: string;
      if (kind === "permission") {
        wantType = "apply_session_permission";
        wantResult = "apply_session_permission_result";
        payload = { permission: (permission || "").toString().trim() };
      } else if (kind === "model") {
        wantType = "apply_session_model";
        wantResult = "apply_session_model_result";
        payload = {
          model: (model || "").toString().trim(),
          reasoningEffort: (reasoningEffort || "").toString().trim(),
        };
      } else {
        return res.status(400).json({ success: false, error: `不支持的 kind：${kind}（可选 permission / model）` });
      }

      const taskId = `apply_${kind}_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`;
      const resultPromise = new Promise<any>((resolve) => {
        const timeout = setTimeout(() => {
          agent.ws?.off("message", listener);
          resolve({ success: false, message: "电脑端响应超时" });
        }, 8000);
        const listener = (raw: any) => {
          try {
            const msg = JSON.parse(raw.toString());
            if (msg.type === wantResult && (msg.taskId === taskId || !msg.taskId)) {
              clearTimeout(timeout);
              agent.ws?.off("message", listener);
              resolve(msg);
            }
          } catch {}
        };
        agent.ws?.on("message", listener);
      });

      agent.ws.send(JSON.stringify({
        type: wantType,
        taskId,
        sessionId: sid,
        harnessUrl: (req.body?.harnessUrl || "http://127.0.0.1:3080").toString(),
        ...payload,
      }));

      const result = await resultPromise;
      console.log(
        `[Agent Hub] 即时切换 ${kind}（会话 ${sid}）→ ${result.success ? "成功" : "失败"}：${result.message ?? ""}`,
      );
      if (!result.success) {
        return res.status(502).json({ success: false, error: result.message || "本地 DSH 未接受该设置" });
      }
      return res.json({ success: true, kind, sessionId: sid, message: result.message ?? "" });
    } catch (err: any) {
      res.status(500).json({ success: false, error: err?.message || "切换失败" });
    }
  });

  /**
   * 读取电脑端真实可用的权限预设列表（由本地 DSH 的 permissionPresets 提供）。
   * App 据此显示真实可选项，避免再出现"填了一个 DSH 不认识的值"。
   */
  app.get("/api/agent/permission-presets", async (req, res) => {
    try {
      const targetToken = ((req.query.token || "") as string).trim();
      const userId = ((req.query.userId || "") as string).trim();
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const ownerId = await resolveTokenOwnerUserId(targetToken);
      if (!ownerId || (userId && userId !== ownerId)) {
        return res.status(403).json({ error: "该 Token 不属于当前账号" });
      }
      const agent = connectedAgents.get(targetToken);
      if (!agent || !agent.ws || agent.ws.readyState !== WSWebSocket.OPEN) {
        return res.json({ success: false, online: false, presets: [] });
      }
      const taskId = `presets_${Date.now()}`;
      const resultPromise = new Promise<any>((resolve) => {
        const timeout = setTimeout(() => {
          agent.ws?.off("message", listener);
          resolve({ success: false, presets: [] });
        }, 6000);
        const listener = (raw: any) => {
          try {
            const msg = JSON.parse(raw.toString());
            if (msg.type === "permission_presets_result" && (msg.taskId === taskId || !msg.taskId)) {
              clearTimeout(timeout);
              agent.ws?.off("message", listener);
              resolve(msg);
            }
          } catch {}
        };
        agent.ws?.on("message", listener);
      });
      agent.ws.send(JSON.stringify({
        type: "get_permission_presets",
        taskId,
        harnessUrl: "http://127.0.0.1:3080",
      }));
      const result = await resultPromise;
      res.json({
        success: result.success === true,
        online: true,
        presets: Array.isArray(result.presets) ? result.presets : [],
      });
    } catch (err: any) {
      res.status(500).json({ error: err?.message || "读取权限预设失败" });
    }
  });

  // Create new session in local DeepSeek Harness via bridge
  app.post("/api/agent/create-session", async (req, res) => {
    try {
      const { token, workspace, title, model } = req.body || {};
      const targetToken = (token || "").trim() || "";
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const agent = connectedAgents.get(targetToken);
      // 不再回退到 'deepseek-agent' 这个并不存在的预设工作区：
      // 传空表示"用电脑端 DSH 的默认工作区"，由桥接决定。
      const targetWs = (workspace || "").trim();
      const sessionTitle = (title || "").trim() || `新对话 ${new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}`;

      if (!agent) {
        // 桥接不在线时不伪造会话 id：伪造出来的 id 后面发消息必然失败，
        // 而且用户根本看不出问题出在哪。
        return res.status(503).json({
          success: false,
          online: false,
          error: "电脑端桥接未在线，无法新建会话"
        });
      }

      if (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) {
        const createTaskId = `create_session_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`;

        const createPromise = new Promise<any>((resolve) => {
          // 超时不再伪造会话 id：假 id 拿回去发消息必然失败，
          // 不如如实告诉用户"创建没成功，请稍后再试"。
          const timeout = setTimeout(() => {
            agent.ws?.off("message", listener);
            resolve({ type: "create_session_result", success: false, error: "电脑端创建会话超时（8 秒）" });
          }, 8000);

          const listener = (raw: any) => {
            try {
              const msg = JSON.parse(raw.toString());
              if ((msg.type === "create_session_result" || msg.type === "create_session_ack") && (msg.taskId === createTaskId || !msg.taskId)) {
                clearTimeout(timeout);
                agent.ws?.off("message", listener);
                resolve(msg);
              }
            } catch {}
          };
          agent.ws?.on("message", listener);
        });

        agent.ws.send(JSON.stringify({
          type: "create_session",
          taskId: createTaskId,
          workspace: targetWs,
          title: sessionTitle,
          model: model || "deepseek-chat"
        }));

        const result = await createPromise;
        const createdId = result?.sessionId || result?.session?.id || result?.session?.sessionId;
        if (result?.success === false || !createdId) {
          console.warn(
            `[Agent Hub] 新建会话失败: ${result?.error || "桥接未返回会话 id"}`,
          );
          return res.status(502).json({
            success: false,
            error: result?.error || "电脑端未能创建会话，请确认本地 DSH 正常",
          });
        }
        if (result.workspaces && Array.isArray(result.workspaces)) agent.workspaces = result.workspaces;
        if (result.sessions && Array.isArray(result.sessions)) {
          agent.sessions = result.sessions;
        } else if (result.session) {
          const sid = result.sessionId || result.session.id;
          agent.sessions = [result.session, ...(agent.sessions || []).filter(s => (s.sessionId || s.id) !== sid)];
        }

        io.emit("agent_sessions_updated", {
          token: targetToken,
          workspaces: agent.workspaces || [],
          sessions: agent.sessions || []
        });

        console.log(`[Agent Hub] 已为工作区 ${targetWs || "(默认)"} 新建会话 ${createdId}`);
        return res.json({
          success: true,
          online: true,
          sessionId: createdId,
          session: result.session,
          sessions: agent.sessions,
          workspaces: agent.workspaces
        });
      }

      // 长轮询模式：桥接不在 WS 上时无法即时创建，如实返回失败
      return res.status(503).json({
        success: false,
        online: false,
        error: "电脑端桥接当前不在实时通道上，无法新建会话"
      });
    } catch (err: any) {
      console.error("[Create Session API Error]", err);
      // 异常时同样不伪造会话 id 与假工作区
      res.status(500).json({
        success: false,
        error: err?.message || "新建会话失败",
      });
    }
  });

  // Sync sessions report from agent
  app.post("/api/agent/sync-sessions", (req, res) => {
    try {
      const { token, workspaces, sessions, models } = req.body;
      const targetToken = (token || "").trim() || "";
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const agent = connectedAgents.get(targetToken);
      if (agent) {
        if (workspaces) agent.workspaces = workspaces;
        if (sessions) agent.sessions = sessions;
        if (models) agent.models = models;
        agent.lastPing = Date.now();
        io.emit("agent_sessions_updated", {
          token: targetToken,
          workspaces: agent.workspaces || [],
          sessions: agent.sessions || [],
          models: agent.models || []
        });
      }
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // Get agent models and reasoning levels
  app.get("/api/agent/models", (req, res) => {
    try {
      const token = (req.query.token as string || "").trim() || "";
      if (!isPlausibleAgentToken(token)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const agent = connectedAgents.get(token);
      if (agent && agent.models && agent.models.length > 0) {
        return res.json({ models: agent.models });
      }
      // Return fallback models if not populated yet
      res.json({
        models: [
          { id: "deepseek-v4-flash", name: "DeepSeek-V4-Flash", reasoningEfforts: ["off", "low", "high", "max"], defaultEffort: "high" },
          { id: "deepseek-v4-pro", name: "DeepSeek-V4-Pro", reasoningEfforts: ["off", "low", "high", "max"], defaultEffort: "high" },
          { id: "deepseek-v4-flash-vision-exp", name: "视觉实验版 (Flash Vision)", reasoningEfforts: ["off", "low", "high", "max"], defaultEffort: "high" },
          { id: "ep-20260824185630-nkdc7", name: "Doubao (豆包)", reasoningEfforts: [] }
        ]
      });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // Agent waiting approval notification from polling bridge
  app.post("/api/agent/waiting-approval", (req, res) => {
    try {
      const { taskId, token, approval } = req.body;
      const pending = pendingAgentTasks.get(taskId);
      if (pending) {
        io.to(`user_${pending.userId}`).emit("agent_waiting_approval", {
          taskId,
          messageId: pending.assistantMessageId,
          approval
        });
      } else {
        io.emit("agent_waiting_approval", { taskId, approval });
      }
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // ── 选择框（DSH 的 ask_user_question）→ App ─────────────────────
  //
  // 背景：ask_user_question 走的是 DSH 的「客户端 UI」能力（ctx.userQuestions），
  // 只有连到 DSH 的界面能应答；桥接脚本吃的是任务事件流，里面没有 question 事件，
  // 所以 App 在结构上永远收不到选择框。现在由 DSH 侧插件排队 + 桥接轮询转发，
  // 中继这里负责转投给 App 并把答复送回去。

  /**
   * 把一个挂起的选择框投递给该用户的所有在线端（手机/电脑 App）。
   *
   * 走 `io.to(user_x).emit` —— 推送通道的包装层会把它同时复制到 /ws/app，
   * 所以新事件不用再手写一份推送逻辑；同时按 questionId 存一份，供 App 重连补拉。
   */
  const deliverQuestionToUser = async (qToken: string, question: {
    questionId: string;
    sessionId?: string;
    questions: any[];
    state?: 'pending' | 'waiting' | 'orphaned';
    deferred?: boolean;
  }) => {
    prunePendingQuestions();
    const agent = connectedAgents.get(qToken);
    let userId = "";
    if (agent?.activeUserSessions && agent.activeUserSessions.size > 0) {
      userId = Array.from(agent.activeUserSessions.keys())[0] || "";
    }
    if (!userId) {
      try {
        userId = (await resolveTokenOwnerUserId(qToken)) || "";
      } catch {
        userId = "";
      }
    }
    const payload = {
      questionId: question.questionId,
      sessionId: question.sessionId || "",
      questions: question.questions || [],
      state: question.state ?? (question.deferred === true ? 'orphaned' : 'pending'),
      deferred: (question.state ?? (question.deferred === true ? 'orphaned' : 'pending')) === 'orphaned',
      at: Date.now(),
    };
    pendingQuestions.set(question.questionId, { ...payload, token: qToken, userId: userId || undefined });
    savePendingDecisions();
    if (userId) io.to(`user_${userId}`).emit("agent_question", payload);
    else io.emit("agent_question", payload);
    // 正在流式接收的那一轮也顺手带一份（推送通道没连上时 SSE 是唯一活路）
    for (const gen of activeGenerations.values()) {
      if (userId && gen.userId !== userId) continue;
      generationEvents.emit(`question_${gen.assistantMessageId}`, payload);
    }
  };

  app.post("/api/agent/waiting-question", (req, res) => {
    try {
      const { token, questionId, sessionId, questions, deferred, state } = req.body || {};
      const qid = (questionId || "").toString().trim();
      if (!qid) return res.status(400).json({ error: "缺少 questionId" });
      const qToken = (token || "").toString().trim();
      void deliverQuestionToUser(qToken, {
        questionId: qid,
        sessionId,
        questions: Array.isArray(questions) ? questions : [],
        state,
        deferred: deferred === true,
      });
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // App 启动/重连时补拉：推送通道断线期间挂起的选择框不会丢
  app.get("/api/agent/pending-questions", (req, res) => {
    try {
      prunePendingQuestions();
      const userId = ((req.query.userId as string) || "").trim();
      const token = ((req.query.token as string) || "").trim();
      const questions = [...pendingQuestions.values()].filter((item) => {
        if (token && item.token && item.token !== token) return false;
        if (userId && item.userId && item.userId !== userId) return false;
        return true;
      });
      res.json({ success: true, questions });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // App 上的答复 / 「在电脑上回答」→ 送回桥接 → 本地 DSH 插件
  app.post("/api/agent/answer-question", (req, res) => {
    try {
      const { token, questionId, answers, decline } = req.body || {};
      const qid = (questionId || "").toString().trim();
      if (!qid) return res.status(400).json({ error: "缺少 questionId" });
      const pending = pendingQuestions.get(qid);
      const targetToken = ((token || pending?.token || "") as string).trim();
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const agent = connectedAgents.get(targetToken);
      if (!agent) {
        return res.status(404).json({ error: "Agent not connected or offline" });
      }

      const isDecline = decline === true;
      const payload = {
        type: isDecline ? "decline_question" : "answer_question",
        questionId: qid,
        answers: Array.isArray(answers) ? answers : [],
      };

      if (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) {
        agent.ws.send(JSON.stringify(payload));
      } else if (agent.pendingPollResolvers && agent.pendingPollResolvers.length > 0) {
        const resolver = agent.pendingPollResolvers.shift();
        if (resolver) resolver(payload);
      } else {
        if (!agent.queuedTasks) agent.queuedTasks = [];
        agent.queuedTasks.push(payload);
      }

      pendingQuestions.delete(qid);
      savePendingDecisions();
      io.emit("agent_question_resolved", {
        questionId: qid,
        reason: isDecline ? "declined" : "answered",
      });
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // ── 审批（含文件沙箱升级）→ App ────────────────────────────────
  //
  // 与选择框完全对称的一条链路：DSH 插件排队 → 桥接 1s 轮询 → 中继转投 App。
  //
  // 为什么必须补这条：审批原先只出现在"手机发起那一轮的 SSE 流"里，于是
  // DSH 网页端自己跑的任务、以及文件沙箱越权升级（sandbox_permissions）产生的
  // 审批，手机侧永远收不到 —— 而插件侧会一直挂着等，电脑前的人只看到卡死。

  /** 挂起中的审批：approvalId → 载荷（重连补拉用，带 TTL 清理）。 */
  const pendingApprovals = new Map<string, {
    approvalId: string;
    sessionId?: string;
    tool: string;
    reason?: string;
    at: number;
    token?: string;
    userId?: string;
    /** 与选择框同一套状态机（pending / waiting / orphaned）。 */
    state?: 'pending' | 'waiting' | 'orphaned';
    /** true = state 为 orphaned（兼容旧字段）。 */
    deferred?: boolean;
  }>();
  /** 审批缓存有效期：与选择框一致 24 小时（人隔天回来还能看到并批准）。 */
  const PENDING_APPROVAL_TTL_MS = 24 * 60 * 60 * 1000;

  const prunePendingApprovals = () => {
    const now = Date.now();
    for (const [id, item] of pendingApprovals) {
      if (now - item.at > PENDING_APPROVAL_TTL_MS) pendingApprovals.delete(id);
    }
  };

  // ── 待办落盘 ─────────────────────────────────────────────────
  //
  // 为什么必须落盘：中继每次部署/重启都会清空内存里的待办，而这些东西代表
  // "电脑端还在等人拍板"。用户隔天回来时若什么都没了，只能重新发一遍指令。
  // 文件：messages_data/pending-decisions.json（与其它持久化数据同目录）。
  const PENDING_STORE_FILE = path.join(DATA_DIR, "pending-decisions.json");
  let pendingStoreTimer: NodeJS.Timeout | null = null;

  const writePendingDecisions = () => {
    try {
      fsSync.mkdirSync(DATA_DIR, { recursive: true });
      fsSync.writeFileSync(PENDING_STORE_FILE, JSON.stringify({
        version: 1,
        savedAt: Date.now(),
        questions: [...pendingQuestions.values()],
        approvals: [...pendingApprovals.values()],
      }), "utf-8");
    } catch (err: any) {
      console.error("[Pending] 待办落盘失败:", err?.message ?? err);
    }
  };

  /** 落盘（默认 500ms 防抖；immediate=true 立刻写）。 */
  const savePendingDecisions = (immediate = false) => {
    if (immediate) {
      if (pendingStoreTimer) { clearTimeout(pendingStoreTimer); pendingStoreTimer = null; }
      writePendingDecisions();
      return;
    }
    if (pendingStoreTimer) return;
    pendingStoreTimer = setTimeout(() => { pendingStoreTimer = null; writePendingDecisions(); }, 500);
  };

  /** 启动时恢复上次没处理完的待办。 */
  const loadPendingDecisions = () => {
    try {
      if (!fsSync.existsSync(PENDING_STORE_FILE)) return;
      const raw = JSON.parse(fsSync.readFileSync(PENDING_STORE_FILE, "utf-8"));
      for (const item of raw?.questions ?? []) {
        if (item?.questionId) pendingQuestions.set(item.questionId, item);
      }
      for (const item of raw?.approvals ?? []) {
        if (item?.approvalId) pendingApprovals.set(item.approvalId, item);
      }
      prunePendingQuestions();
      prunePendingApprovals();
      if (pendingQuestions.size > 0 || pendingApprovals.size > 0) {
        console.log(`[Pending] 已恢复待办：选择框 ${pendingQuestions.size} 个 / 审批 ${pendingApprovals.size} 个`);
      }
    } catch (err: any) {
      console.error("[Pending] 读取待办落盘文件失败:", err?.message ?? err);
    }
  };

  loadPendingDecisions();

  /** 把一个挂起的审批投递给该用户的所有在线端，并缓存供补拉。 */
  const deliverApprovalToUser = async (aToken: string, approval: {
    approvalId: string;
    sessionId?: string;
    tool?: string;
    reason?: string;
    state?: 'pending' | 'waiting' | 'orphaned';
    deferred?: boolean;
  }) => {
    prunePendingApprovals();
    const agent = connectedAgents.get(aToken);
    let userId = "";
    if (agent?.activeUserSessions && agent.activeUserSessions.size > 0) {
      userId = Array.from(agent.activeUserSessions.keys())[0] || "";
    }
    if (!userId) {
      try {
        userId = (await resolveTokenOwnerUserId(aToken)) || "";
      } catch {
        userId = "";
      }
    }
    const payload = {
      approvalId: approval.approvalId,
      sessionId: approval.sessionId || "",
      tool: approval.tool || "tool",
      reason: approval.reason || "",
      state: approval.state ?? (approval.deferred === true ? 'orphaned' : 'pending'),
      deferred: (approval.state ?? (approval.deferred === true ? 'orphaned' : 'pending')) === 'orphaned',
      at: Date.now(),
    };
    pendingApprovals.set(approval.approvalId, { ...payload, token: aToken, userId: userId || undefined });
    savePendingDecisions();
    // App 的 ChatProvider 已经在处理 agent_waiting_approval（原先走 socket.io，
    // 推送通道的包装层会把它同时复制到 /ws/app），这里直接复用同一个事件名。
    if (userId) io.to(`user_${userId}`).emit("agent_waiting_approval", { approval: payload });
    else io.emit("agent_waiting_approval", { approval: payload });
    for (const gen of activeGenerations.values()) {
      if (userId && gen.userId !== userId) continue;
      generationEvents.emit(`approval_${gen.assistantMessageId}`, { approval: payload });
    }
  };

  // 桥接轮询通道的审批事件入口（WS 通道见 agent hub 的 approval_requested 分支）
  app.post("/api/agent/approval-event", (req, res) => {
    try {
      const { token, type, approvalId, sessionId, tool, reason, deferred, state } = req.body || {};
      const aid = (approvalId || "").toString().trim();
      if (!aid) return res.status(400).json({ error: "缺少 approvalId" });
      const aToken = (token || "").toString().trim();
      if (type === "approval_closed") {
        pendingApprovals.delete(aid);
        savePendingDecisions();
        io.emit("agent_approval_resolved", { approvalId: aid, outcome: "resolved" });
        return res.json({ success: true });
      }
      void deliverApprovalToUser(aToken, { approvalId: aid, sessionId, tool, reason, state, deferred: deferred === true });
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // App 启动/重连时补拉：断线期间挂起的审批不会丢
  app.get("/api/agent/pending-approvals", (req, res) => {
    try {
      prunePendingApprovals();
      const userId = ((req.query.userId as string) || "").trim();
      const token = ((req.query.token as string) || "").trim();
      const approvals = [...pendingApprovals.values()].filter((item) => {
        if (token && item.token && item.token !== token) return false;
        if (userId && item.userId && item.userId !== userId) return false;
        return true;
      });
      res.json({ success: true, approvals });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // User decision for approval (allow / deny)
  app.post("/api/agent/approve", (req, res) => {
    try {
      const { taskId, approvalId, action, token } = req.body;
      const pending = pendingAgentTasks.get(taskId);
      const targetToken = (token || pending?.token || "").trim();
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const agent = connectedAgents.get(targetToken);
      if (!agent) {
        return res.status(404).json({ error: "Agent not connected or offline" });
      }

      const approvePayload = {
        type: "agent_approve",
        taskId,
        approvalId,
        action: action || "allow"
      };

      if (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) {
        agent.ws.send(JSON.stringify(approvePayload));
      } else if (agent.pendingPollResolvers && agent.pendingPollResolvers.length > 0) {
        const resolver = agent.pendingPollResolvers.shift();
        if (resolver) resolver(approvePayload);
      } else {
        if (!agent.queuedTasks) agent.queuedTasks = [];
        agent.queuedTasks.push(approvePayload);
      }

      // 已裁决：从补拉缓存里去掉，并广播给各端收起卡片
      // （桥接侧随后也会报 approval_closed，这里先一步，避免另一端还挂着旧卡片）
      if (approvalId) {
        pendingApprovals.delete(approvalId.toString());
        savePendingDecisions();
        io.emit("agent_approval_resolved", {
          approvalId: approvalId.toString(),
          outcome: (action || "allow") === "allow" ? "allowed-once" : "rejected",
        });
      }

      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // Session rename
  app.patch("/api/agent/rename-session", (req, res) => {
    try {
      const { sessionId, title, token } = req.body;
      const targetToken = (token || "").trim() || "";
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const agent = connectedAgents.get(targetToken);
      if (agent) {
        const renamePayload = { type: "rename_session", sessionId, title };
        if (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) {
          agent.ws.send(JSON.stringify(renamePayload));
        } else if (agent.pendingPollResolvers && agent.pendingPollResolvers.length > 0) {
          const resolver = agent.pendingPollResolvers.shift();
          if (resolver) resolver(renamePayload);
        } else {
          if (!agent.queuedTasks) agent.queuedTasks = [];
          agent.queuedTasks.push(renamePayload);
        }
      }
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  // Session archive
  app.delete("/api/agent/archive-session", (req, res) => {
    try {
      const { sessionId, token } = req.body;
      const targetToken = (token || "").trim() || "";
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const agent = connectedAgents.get(targetToken);
      if (agent) {
        const archPayload = { type: "archive_session", sessionId };
        if (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) {
          agent.ws.send(JSON.stringify(archPayload));
        } else if (agent.pendingPollResolvers && agent.pendingPollResolvers.length > 0) {
          const resolver = agent.pendingPollResolvers.shift();
          if (resolver) resolver(archPayload);
        } else {
          if (!agent.queuedTasks) agent.queuedTasks = [];
          agent.queuedTasks.push(archPayload);
        }
      }
      res.json({ success: true });
    } catch (err: any) {
      res.status(500).json({ error: err.message });
    }
  });

  app.post("/api/agent/cancel-task", (req, res) => {
    try {
      const { taskId, token } = req.body;
      if (!taskId) {
        return res.status(400).json({ error: "Missing taskId" });
      }
      
      const pending = pendingAgentTasks.get(taskId);
      if (pending) {
        clearTimeout(pending.timeoutId);
        pendingAgentTasks.delete(taskId);

        // Notify local bridge to cancel execution
        const targetToken = token || pending.token;
        if (!isPlausibleAgentToken(targetToken)) {
          return res.status(401).json({ error: "无效或缺失的 Agent Token" });
        }
        const agent = connectedAgents.get(targetToken);
        if (agent && agent.ws && agent.ws.readyState === 1) {
          try {
            agent.ws.send(JSON.stringify({ type: "cancel_task", taskId }));
          } catch {}
        }

        pending.resolve({
          success: false,
          output: "任务已由用户手动中止。",
          steps: ["⏹ 任务已被用户手动中止"]
        });

        io.to(`user_${pending.userId}`).emit("agent_task_finished", {
          messageId: pending.assistantMessageId,
          taskId,
          result: {
            status: "cancelled",
            steps: ["⏹ 任务已被用户手动中止"],
            rawOutput: "任务已由用户手动中止",
            timestamp: new Date().toISOString()
          }
        });
      }

      res.json({ success: true, message: "Task cancelled successfully" });
    } catch (err: any) {
      res.status(500).json({ error: err.message || "Failed to cancel task" });
    }
  });

  app.post("/api/agent/revoke-token", (req, res) => {
    try {
      const { oldToken } = req.body;
      if (oldToken && connectedAgents.has(oldToken)) {
        const agent = connectedAgents.get(oldToken);
        if (agent) {
          try {
            if (agent.ws && agent.ws.readyState === 1) {
              agent.ws.send(JSON.stringify({ type: "token_revoked", reason: "Token revoked by user in App settings" }));
              agent.ws.close(1000, "Token Revoked");
            }
          } catch {}
          connectedAgents.delete(oldToken);
          io.emit("agent_status_change", { token: oldToken, online: false });
        }
      }
      res.json({ success: true, message: "Old token revoked successfully" });
    } catch (err: any) {
      res.status(500).json({ error: err.message || "Failed to revoke token" });
    }
  });

  /**
   * 换发该用户的 Agent 配对 Token。
   *
   * token 的真源在服务端，因此"重新生成"必须走这里，而不是客户端本地随机一个：
   * 1) 生成新 token 并写入该用户设置
   * 2) 踢掉旧 token 上的 Agent 连接，避免旧凭证继续可用
   * 3) 广播 settings_updated，使该用户所有在线设备（手机/电脑）立即拿到同一枚新 token
   */
  app.post("/api/agent/rotate-token", async (req, res) => {
    try {
      const userId = ((req.body?.userId as string) || "").trim();
      const oldToken = ((req.body?.oldToken as string) || "").trim();
      if (!userId || userId === "guest") {
        return res.status(401).json({ error: "缺少 userId，无法换发配对凭证" });
      }

      // 校验账号真实存在，避免为任意字符串凭空造 token
      const allUsers = await safeReadJSON<any[]>(USERS_FILE, []);
      const user = allUsers.find((u: any) => u.username === userId || u.id === userId);
      if (!user) {
        return res.status(401).json({ error: "账号无效，请重新登录" });
      }
      const ownerUserId = (user.username || user.id).toString();

      // 账号级互斥：切换中不允许再重置，避免两端连点把 Token 连换几次、
      // 桥接被反复踢下线又拉起。
      const occupied = activeBridgeTransition(ownerUserId);
      if (occupied) {
        return res.status(409).json({
          error: "桥接状态正在切换中，请等这次切换完成后再重置 Token",
          code: "BRIDGE_BUSY",
          bridgeTransition: describeBridgeTransition(occupied),
        });
      }

      const device = ((req.body?.device as string) || "unknown").trim();

      // 重置前先看桥接是否在线：在线的话换发后必然要被踢掉再拉回来，
      // 期间两端都该置灰；本来就不在线则无需锁定。
      const settingsBefore = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
      const wasOnline = isAgentOnlineByToken(readUserAgentToken(settingsBefore[ownerUserId]));

      // 先断开旧 token 上的 Agent 连接
      let kickedAgent = false;
      if (oldToken && connectedAgents.has(oldToken)) {
        const agent = connectedAgents.get(oldToken);
        try {
          if (agent?.ws && agent.ws.readyState === 1) {
            agent.ws.send(JSON.stringify({ type: "token_revoked", reason: "Token rotated by user" }));
            agent.ws.close(1000, "Token Rotated");
            kickedAgent = true;
          }
        } catch {}
        connectedAgents.delete(oldToken);
        io.emit("agent_status_change", { token: oldToken, online: false });
      }

      const newToken = generateServerAgentToken();
      await withFileLock(SETTINGS_FILE, async () => {
        const current = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
        current[ownerUserId] = { ...(current[ownerUserId] || {}), harnessToken: newToken };
        await safeWriteJSON(SETTINGS_FILE, current);
      });

      // 广播给该用户所有设备，使手机与电脑立刻收敛到同一枚 token
      io.to(`user_${ownerUserId}`).emit("settings_updated", { harnessToken: newToken });

      // 换发后桥接要带着新 Token 重新上线：登记切换标记，两端按钮置灰，
      // 直到 agentOnline 回到 true（或超时兜底）才解除。
      if (wasOnline) {
        armBridgeTransition(ownerUserId, "restart", true, device);
      }

      console.log(
        `[Agent Hub] 用户 ${ownerUserId} 重置了配对 Token（发起端 ${device}）` +
          (kickedAgent
            ? "：已向旧 Token 上的电脑端桥接下发 token_revoked 并断开（脚本会自行退出，等待电脑端 App 用新 Token 拉起）"
            : "：旧 Token 上没有在线桥接连接，无需踢线") +
          (wasOnline ? "；已锁定账号，切换到位前两端按钮置灰" : "；桥接本来不在线，无需锁定"),
      );

      res.json({ success: true, token: newToken });
    } catch (err: any) {
      console.error("rotate-token failed:", err);
      res.status(500).json({ error: err.message || "Failed to rotate token" });
    }
  });

  // ==================== 设备凭证（bridge 自愈取回 token） ====================
  // 场景：服务端换发 token 后，正在运行的 bridge 仍持有旧 token，会被拒绝注册，
  // 表现为"手机端显示桥接离线"，而用户必须手动重新扫码。
  // 方案：bridge 首次配对后领取一枚长期【设备凭证】，之后启动时用它向服务端
  // 换取当前有效的 Agent Token，从而在 token 换发后自动跟上。

  const DEVICE_TOKENS_FILE = path.join(DATA_DIR, "device_tokens.json");

  const generateDeviceToken = (): string => {
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const bytes = randomBytes(32);
    let out = "dev_";
    for (let i = 0; i < 32; i++) out += charset[bytes[i] % charset.length];
    return out;
  };

  /** 校验 Agent Token 并换取该用户的设备凭证（同一 token 重复调用返回同一枚）。 */
  app.post("/api/bridge/bootstrap-device", async (req, res) => {
    try {
      const agentToken = ((req.body?.token as string) || "").trim();
      if (!isPlausibleAgentToken(agentToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const ownerUserId = await resolveTokenOwnerUserId(agentToken);
      if (!ownerUserId) {
        return res.status(403).json({ error: "该 Agent Token 未绑定任何账号，请先在 App 中完成配对" });
      }

      let deviceToken: string | undefined;
      await withFileLock(DEVICE_TOKENS_FILE, async () => {
        const store = await safeReadJSON<Record<string, any>>(DEVICE_TOKENS_FILE, {});
        for (const [dt, rec] of Object.entries(store)) {
          if (rec?.userId === ownerUserId && rec?.agentToken === agentToken) {
            deviceToken = dt;
            return;
          }
        }
        deviceToken = generateDeviceToken();
        store[deviceToken] = {
          userId: ownerUserId,
          agentToken,
          createdAt: Date.now(),
          lastSeenAt: Date.now(),
        };
        await safeWriteJSON(DEVICE_TOKENS_FILE, store);
      });

      console.log(`[Device] 已为用户 ${ownerUserId} 签发设备凭证`);
      res.json({ success: true, deviceToken, userId: ownerUserId });
    } catch (err: any) {
      console.error("bootstrap-device failed:", err);
      res.status(500).json({ error: err.message || "Failed to bootstrap device" });
    }
  });

  /** 用设备凭证换取该用户当前有效的 Agent Token（token 换发后 bridge 靠它自愈）。 */
  app.post("/api/bridge/current-token", async (req, res) => {
    try {
      const deviceToken = ((req.body?.deviceToken as string) || "").trim();
      if (!deviceToken) {
        return res.status(401).json({ error: "缺少设备凭证" });
      }
      const store = await safeReadJSON<Record<string, any>>(DEVICE_TOKENS_FILE, {});
      const record = store[deviceToken];
      if (!record?.userId) {
        return res.status(401).json({ error: "设备凭证无效或已被撤销" });
      }

      const allSettings = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
      let currentToken = readUserAgentToken(allSettings[record.userId]);
      if (!currentToken) {
        currentToken = await resolveOrCreateUserAgentToken(record.userId);
      }
      if (!currentToken) {
        return res.status(500).json({ error: "服务端未能提供有效 Token" });
      }

      // 凭证所记录的 token 已过期时同步刷新，便于后续按 token 反查
      await withFileLock(DEVICE_TOKENS_FILE, async () => {
        const latest = await safeReadJSON<Record<string, any>>(DEVICE_TOKENS_FILE, {});
        if (latest[deviceToken]) {
          latest[deviceToken].agentToken = currentToken;
          latest[deviceToken].lastSeenAt = Date.now();
          await safeWriteJSON(DEVICE_TOKENS_FILE, latest);
        }
      });

      res.json({ success: true, token: currentToken, userId: record.userId });
    } catch (err: any) {
      console.error("current-token failed:", err);
      res.status(500).json({ error: err.message || "Failed to resolve current token" });
    }
  });

  app.get("/api/agent/download-bat", (req, res) => {
    try {
      const token = (req.query.token as string)?.trim() || "";
      if (!isPlausibleAgentToken(token)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const serverUrl = (req.query.server as string)?.trim() || SERVER_BASE_URL;
      const harnessUrl = (req.query.harness as string)?.trim() || "http://127.0.0.1:3080";
      const batContent = `@echo off
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
title DeepSeek Harness 本地安全桥接 (v3.5 高可用版)
echo ========================================================
echo   DeepSeek Harness 本地安全反向桥接启动器 (v3.5)
echo ========================================================
echo.
echo [1/3] 正在探测 Python 执行环境...

set PYTHON_CMD=
py -3 --version >nul 2>&1 && set PYTHON_CMD=py -3
if not defined PYTHON_CMD (
    python --version >nul 2>&1 && set PYTHON_CMD=python
)
if not defined PYTHON_CMD (
    python3 --version >nul 2>&1 && set PYTHON_CMD=python3
)

if not defined PYTHON_CMD (
    echo.
    echo ❌ [错误] 未在系统 PATH 中找到 Python！
    echo 💡 解决方式:
    echo    1. 请前往 https://www.python.org 下载安装 Python 3.8+;
    echo    2. 安装时请务必勾选 "Add Python to PATH" (添加至环境变量).
    echo.
    pause
    exit /b 1
)

echo [✓] 找到可用 Python: %PYTHON_CMD%
echo.
echo [2/3] 正在检查并自动安装依赖库 (requests)...
%PYTHON_CMD% -m pip install --quiet --upgrade requests

echo.
echo [3/3] 启动安全长连接调度...
echo • 配对 Token   : ${token}
echo • 服务器地址   : ${serverUrl}
echo • 本地 Harness : ${harnessUrl}/v1
echo.
%PYTHON_CMD% deepseek_bridge.py --token "${token}" --server "${serverUrl}" --harness-url "${harnessUrl}"

if %errorlevel% neq 0 (
    echo.
    echo ⚠️ [提示] 桥接程序退出或发生异常。
    pause
)
`;
      res.setHeader("Content-Type", "application/x-bat; charset=utf-8");
      res.setHeader("Content-Disposition", 'attachment; filename="start_bridge.bat"');
      res.send(batContent);
    } catch (err: any) {
      res.status(500).json({ error: "Failed to generate bat script" });
    }
  });

  // =========================================================================
  // Bridge 扫码动态授权握手核心接口 (OAuth 2.0 Device Flow 扫码模型)
  // =========================================================================
  interface BridgeAuthSession {
    sessionCode: string;
    createdAt: number;
    expiresAt: number;
    status: "pending" | "confirmed" | "expired";
    authorizedToken?: string;
    authorizedAccount?: string;
    /** 发起配对的用户 ID（扫码者身份校验通过后写入） */
    authorizedUserId?: string;
  }
  const bridgeAuthSessions = new Map<string, BridgeAuthSession>();

  /**
   * 取（必要时创建）某用户的 Agent 配对 Token，并落盘。
   *
   * 这是 token 的**唯一真源**：服务端生成、服务端存储，各端只读取。
   * 兼容策略（顺序很重要，避免升级时把用户正在用的 token 换掉导致 bridge 断连）：
   *   1) 用户设置里已有合法 token  → 直接复用
   *   2) 设置里没有但请求方带来了合法 token（首次同步）→ **采纳并落盘**
   *   3) 都没有 → 生成一个新的
   */
  const resolveOrCreateUserAgentToken = async (
    userId: string,
    adoptToken?: string
  ): Promise<string | undefined> => {
    const cleanUserId = (userId || "").trim();
    if (!cleanUserId || cleanUserId === "guest") return undefined;

    const allSettings = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
    const record = allSettings[cleanUserId] || {};
    const existing = readUserAgentToken(record);
    if (existing) return existing;

    const adopted = (adoptToken || "").trim();
    const token = isPlausibleAgentToken(adopted) ? adopted : generateServerAgentToken();

    await withFileLock(SETTINGS_FILE, async () => {
      const current = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
      const currentRecord = current[cleanUserId] || {};
      // 双检：避免并发下覆盖别人刚写入的值
      if (!readUserAgentToken(currentRecord)) {
        current[cleanUserId] = { ...currentRecord, harnessToken: token };
        await safeWriteJSON(SETTINGS_FILE, current);
      }
    });

    // 让该用户的所有在线设备立即拿到新 token
    io.to(`user_${cleanUserId}`).emit("settings_updated", { harnessToken: token });
    return token;
  };

  /**
   * 生成服务端 Agent Token（格式：`lx-` + 43 位随机字符，共 46 字符）。
   *
   * 前缀从 `sk-agent` 改为 `lx-`：旧前缀恒定不变，界面脱敏后永远显示成
   * `sk-agent************`，用户根本看不出 Token 到底换没换（错觉的来源）。
   * 随机部分仍是 43 位密码学安全随机字符，强度不变。
   * 老 Token（`sk-agent…`）继续有效 —— 校验只看长度与占位符，不看前缀。
   */
  const generateServerAgentToken = (): string => {
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const bytes = randomBytes(43);
    let out = "lx-";
    for (let i = 0; i < 43; i++) {
      out += charset[bytes[i] % charset.length];
    }
    return out;
  };

  // 定期清理过期扫码授权会话 (超过 3 分钟自动销毁)
  setInterval(() => {
    const now = Date.now();
    for (const [code, sess] of bridgeAuthSessions.entries()) {
      if (now > sess.expiresAt + 60000) {
        bridgeAuthSessions.delete(code);
      }
    }
  }, 30000);

  // 1. 电脑端申请一次性扫码临时配对码
  app.post("/api/bridge/auth-session", (req, res) => {
    try {
      // 生成 8 位高强度随机大写临时码
      const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
      let code = "AUTH_";
      for (let i = 0; i < 6; i++) {
        code += chars.charAt(Math.floor(Math.random() * chars.length));
      }
      const now = Date.now();
      const expiresAt = now + 120 * 1000; // 有效期 2 分钟

      bridgeAuthSessions.set(code, {
        sessionCode: code,
        createdAt: now,
        expiresAt,
        status: "pending",
      });

      res.json({
        success: true,
        sessionCode: code,
        expiresIn: 120,
        expiresAt,
      });
    } catch (err: any) {
      res.status(500).json({ success: false, error: err.message });
    }
  });

  // 2. 手机端 App 扫码成功后，确认授权并将当前用户的 agentToken 与该临时码绑定
  app.post("/api/bridge/auth-confirm", async (req, res) => {
    try {
      // 兼容两种字段名：新客户端用 sessionCode，旧客户端曾用 authCode
      const body = req.body || {};
      const rawCode = body.sessionCode ?? body.authCode ?? body.code ?? "";
      const cleanCode = rawCode.toString().trim().toUpperCase();
      // 扫码者身份：必须自报已登录账号（服务端据此校验并绑定 token 归属）
      const scannerUserId = (body.userId ?? body.account ?? "").toString().trim();
      const legacyToken = (body.token || "").toString().trim();

      if (!cleanCode) {
        return res.status(400).json({ success: false, error: "缺少配对码" });
      }
      if (!scannerUserId) {
        return res.status(401).json({ success: false, error: "请先登录后再扫码配对" });
      }
      // 校验账号真实存在，防止伪造 userId 把二维码绑到他人账号
      const allUsers = await safeReadJSON<any[]>(USERS_FILE, []);
      const scanner = allUsers.find((u: any) => u.username === scannerUserId || u.id === scannerUserId);
      if (!scanner) {
        return res.status(401).json({ success: false, error: "扫码账号无效，请重新登录" });
      }
      const ownerUserId = (scanner.username || scanner.id).toString();

      const sess = bridgeAuthSessions.get(cleanCode);
      if (!sess) {
        return res.status(404).json({ success: false, error: "配对码不存在或已失效，请重新生成" });
      }
      if (Date.now() > sess.expiresAt) {
        sess.status = "expired";
        return res.status(410).json({ success: false, error: "配对码已过期，请在电脑端重新生成二维码" });
      }

      // token 由服务端产生并存储（唯一真源）；兼容旧客户端带来的 token 时予以采纳
      const issuedToken = await resolveOrCreateUserAgentToken(ownerUserId, legacyToken);
      if (!issuedToken) {
        return res.status(500).json({ success: false, error: "服务端未能签发配对凭证" });
      }

      // 授权成功：绑定归属，供 auth-poll 下发给电脑端
      sess.status = "confirmed";
      sess.authorizedToken = issuedToken;
      sess.authorizedAccount = ownerUserId;
      sess.authorizedUserId = ownerUserId;

      console.log(`[Bridge Auth] 配对码 ${cleanCode} 已由用户 ${ownerUserId} 确认授权`);

      // 注意：不把 token 回给手机端——手机端本就持有同一枚 token（服务端真源），
      // 而电脑端会通过 auth-poll 领取，避免 token 在更多位置留存。
      res.json({
        success: true,
        message: "授权成功！电脑端正在自动完成握手并上线...",
      });
    } catch (err: any) {
      res.status(500).json({ success: false, error: err.message });
    }
  });

  // 3. 电脑端 Python 脚本轮询探测扫码状态
  app.get("/api/bridge/auth-poll", (req, res) => {
    try {
      const cleanCode = ((req.query.sessionCode as string) || "").trim().toUpperCase();
      if (!cleanCode) {
        return res.status(400).json({ success: false, error: "缺少 sessionCode 参数" });
      }

      const sess = bridgeAuthSessions.get(cleanCode);
      if (!sess) {
        return res.json({ status: "expired", message: "配对码不存在或已销毁" });
      }

      if (Date.now() > sess.expiresAt) {
        sess.status = "expired";
        return res.json({ status: "expired", message: "配对码已过期" });
      }

      if (sess.status === "confirmed" && sess.authorizedToken) {
        const token = sess.authorizedToken;
        if (!isPlausibleAgentToken(token)) {
          return res.status(401).json({ error: "无效或缺失的 Agent Token" });
        }
        const account = sess.authorizedAccount;
        // 安全考虑：获取一次后立即标记销毁，防止重放盗用
        bridgeAuthSessions.delete(cleanCode);

        return res.json({
          status: "confirmed",
          token,
          account,
          message: "授权成功！已下发凭证。",
        });
      }

      // 仍在等待扫码
      res.json({
        status: "pending",
        remainingSeconds: Math.max(0, Math.floor((sess.expiresAt - Date.now()) / 1000)),
      });
    } catch (err: any) {
      res.status(500).json({ success: false, error: err.message });
    }
  });

  // WebSocket Proxy for Real-time Streaming FunASR
  const wss = new WebSocketServer({ noServer: true });
  // WebSocket Server for Local DeepSeek Agent Hub
  const agentWss = new WebSocketServer({ noServer: true });
  // App 端推送通道（手机/电脑客户端）：把服务端已经在广播的事件真正送到端上，
  // 而不是让客户端靠 4 秒 / 12 秒轮询去"猜"有没有变化。
  const appWss = new WebSocketServer({ noServer: true });

  httpServer.on("upgrade", (request, socket, head) => {
    try {
      const requestUrl = new URL(request.url || "", `http://${request.headers.host || "localhost"}`);
      if (requestUrl.pathname === "/api/funasr-ws") {
        wss.handleUpgrade(request, socket, head, (ws) => {
          wss.emit("connection", ws, request);
        });
      } else if (requestUrl.pathname === "/ws/agent") {
        agentWss.handleUpgrade(request, socket, head, (ws) => {
          agentWss.emit("connection", ws, request);
        });
      } else if (requestUrl.pathname === "/ws/app") {
        appWss.handleUpgrade(request, socket, head, (ws) => {
          appWss.emit("connection", ws, request);
        });
      }
    } catch (err) {
      console.error("[WS Upgrade Error]", err);
    }
  });

  /**
   * App 端推送通道：把服务端原本只走 socket.io 的事件，真正推给手机/电脑客户端。
   *
   * 背景：服务端一直在广播 17 种事件（设置变更、上下线、审批、任务进度、消息等），
   * 但 Flutter 端从来没有 socket.io 客户端 —— 没人听。于是只能靠：
   *   · 4 秒一次的会话轮询（在线状态/令牌/桥接指令/切换锁/设置版本号）
   *   · 12 秒一次的消息漫游拉取
   * 这些轮询每天每台设备要发近 3 万次请求，而且审批这类"只在某一轮次里才有通道"
   * 的事件一旦错过就彻底收不到。这里补一条双向通道，轮询降级为兜底。
   */
  interface AppSocket {
    ws: WSWebSocket;
    userId: string;
    clientSessionId: string;
    deviceType: string;
    lastPing: number;
  }
  const appSockets = new Map<string, AppSocket>();

  const pushToUser = (userId: string, event: string, payload: any) => {
    if (!userId) return;
    for (const conn of appSockets.values()) {
      if (conn.userId !== userId) continue;
      if (conn.ws.readyState !== WSWebSocket.OPEN) continue;
      try {
        conn.ws.send(JSON.stringify({ event, data: payload ?? null, at: Date.now() }));
      } catch {}
    }
  };

  const pushToAll = (event: string, payload: any) => {
    for (const conn of appSockets.values()) {
      if (conn.ws.readyState !== WSWebSocket.OPEN) continue;
      try {
        conn.ws.send(JSON.stringify({ event, data: payload ?? null, at: Date.now() }));
      } catch {}
    }
  };

  // 把既有的 socket.io 广播"顺带"复制一份到 App 推送通道：
  // 全项目 17 处 io.emit / io.to(room).emit 不用逐个改写，新加的事件也自动覆盖。
  const originalIoEmit = io.emit.bind(io);
  (io as any).emit = (event: string, ...args: any[]) => {
    try {
      pushToAll(event, args[0]);
    } catch {}
    return (originalIoEmit as any)(event, ...args);
  };
  const originalIoTo = io.to.bind(io);
  (io as any).to = (room: string) => {
    const target: any = (originalIoTo as any)(room);
    const originalTargetEmit = target.emit.bind(target);
    target.emit = (event: string, ...args: any[]) => {
      try {
        // room 形如 user_<userId>：只推给该用户自己的设备
        const userId = typeof room === "string" && room.startsWith("user_") ? room.slice(5) : "";
        if (userId) pushToUser(userId, event, args[0]);
        else pushToAll(event, args[0]);
      } catch {}
      return originalTargetEmit(event, ...args);
    };
    return target;
  };

  appWss.on("connection", async (clientWs, request) => {
    let conn: AppSocket | null = null;
    try {
      const requestUrl = new URL(request.url || "", `http://${request.headers.host || "localhost"}`);
      const userId = (requestUrl.searchParams.get("userId") || "").trim();
      const clientSessionId = (requestUrl.searchParams.get("clientSessionId") || "").trim();
      const deviceType = (requestUrl.searchParams.get("deviceType") || "mobile").trim();

      if (!userId || userId === "guest" || !clientSessionId) {
        clientWs.send(JSON.stringify({ event: "auth_error", data: { message: "缺少 userId 或 clientSessionId" } }));
        clientWs.close(4001, "bad params");
        return;
      }

      // 与 check-session 同一套单点互斥校验：被顶下线的设备不允许再挂长连接
      const sessions = await safeReadJSON<Record<string, Record<string, DeviceSession>>>(ACTIVE_SESSIONS_FILE, {});
      const active = sessions[userId]?.[deviceType === "mobile" ? "mobile" : "desktop"];
      if (active && active.clientSessionId && active.clientSessionId !== clientSessionId) {
        clientWs.send(JSON.stringify({
          event: "force_logout",
          data: { reason: `您的账号已在另一台${deviceType === "mobile" ? "手机" : "电脑"}上登录，当前设备已被下线。` },
        }));
        clientWs.close(4002, "kicked");
        return;
      }

      conn = { ws: clientWs, userId, clientSessionId, deviceType, lastPing: Date.now() };
      appSockets.set(clientSessionId, conn);
      console.log(`[App WS] ${deviceType} 端已连接推送通道（user=${userId}）`);

      clientWs.send(JSON.stringify({ event: "ready", data: { userId, deviceType, at: Date.now() } }));

      clientWs.on("message", (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (!conn) return;
          conn.lastPing = Date.now();
          if (msg.type === "ping") {
            clientWs.send(JSON.stringify({ event: "pong", data: { at: Date.now() } }));
          }
        } catch {}
      });

      clientWs.on("close", () => {
        if (conn && appSockets.get(conn.clientSessionId)?.ws === clientWs) {
          appSockets.delete(conn.clientSessionId);
        }
        console.log(`[App WS] ${deviceType} 端推送通道已断开（user=${userId}）`);
      });

      const pingTimer = setInterval(() => {
        if (clientWs.readyState !== WSWebSocket.OPEN) {
          clearInterval(pingTimer);
          return;
        }
        // 空闲判定：180 秒没收到任何消息（含协议层 pong）才认为这条连接已死。
        //
        // 为什么从 45 秒放宽到 180 秒：手机切后台后，系统会把 Dart 定时器冻结
        // （Doze / 应用待机），几十秒内一条消息都发不出来 —— 服务端却据此判死并
        // close(4003)，用户回到 App 就看到"连接中断"。而 TCP 连接本身往往还活着，
        // 真正的死连接由下面的 pong 超时兜底。
        if (conn && Date.now() - conn.lastPing > 180000) {
          try { clientWs.close(4003, "idle timeout"); } catch {}
          clearInterval(pingTimer);
          return;
        }
        try {
          clientWs.send(JSON.stringify({ event: "ping", data: { at: Date.now() } }));
        } catch {}
      }, 20000);
      clientWs.on("close", () => clearInterval(pingTimer));
      // 协议层 pong 同样算"活着"：dart:io 的 WebSocket 会自动回 pong，
      // 即使 Dart 侧定时器被系统冻结也能证明链路仍然可用。
      clientWs.on("pong", () => {
        if (conn) conn.lastPing = Date.now();
      });
    } catch (err) {
      console.error("[App WS] 连接处理异常:", err);
      try { clientWs.close(1011, "server error"); } catch {}
    }
  });

  // Handle Local Agent WebSocket Connections
  agentWss.on("connection", (clientWs, request) => {    try {
      const requestUrl = new URL(request.url || "", `http://${request.headers.host || "localhost"}`);
      let token = requestUrl.searchParams.get("token")?.trim() || "";
      let clientName = requestUrl.searchParams.get("clientName")?.trim() || "DeepSeek-Harness-Local";

      if (!token || token === "YOUR_AGENT_TOKEN_HERE" || token === "<YOUR_AGENT_TOKEN>") {
        console.warn(`[Agent Hub] Rejected agent connection: missing or placeholder token`);
        clientWs.send(JSON.stringify({
          type: "auth_error",
          message: "未配置有效的 App 配对密钥 (Token)，请在 App 设置中查看专属配对 Token 并携带 --token 重新运行"
        }));
        setTimeout(() => clientWs.close(4001, "Token required"), 500);
        return;
      }

      console.log(`\x1b[32m[Agent Hub] Local Agent connected with token [${token}] (${clientName})\x1b[0m`);
      const agentInfo: ConnectedAgent = {
        ws: clientWs,
        token,
        clientName,
        connectedAt: Date.now(),
        lastPing: Date.now(),
        mode: 'ws',
        pendingPollResolvers: [],
        queuedTasks: [],
      };
      connectedAgents.set(token, agentInfo);

      // Notify all connected frontend sockets
      io.emit("agent_status_change", { token, online: true, clientName });

      clientWs.on("message", (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (msg.type === "register") {
            const updatedToken = (msg.token || token).trim();
            agentInfo.token = updatedToken;
            if (msg.clientInfo?.name) agentInfo.clientName = msg.clientInfo.name;
            connectedAgents.set(updatedToken, agentInfo);
            console.log(`[Agent Hub] Agent registered with token [${updatedToken}]`);
            io.emit("agent_status_change", { token: updatedToken, online: true, clientName: agentInfo.clientName });
          } else if (msg.type === "agent_step") {
            console.log(`[Agent Hub] Agent step for task ${msg.taskId}: ${msg.step}`);
            io.emit("agent_task_step", {
              taskId: msg.taskId,
              step: msg.step,
            });
            const pending = pendingAgentTasks.get(msg.taskId);
            if (pending) {
              generationEvents.emit(`step_${pending.assistantMessageId}`, {
                taskId: msg.taskId,
                step: msg.step,
              });
            }
          } else if (msg.type === "agent_result") {
            console.log(`[Agent Hub] Agent task completed: ${msg.taskId} (success: ${msg.success})`);
            const pending = pendingAgentTasks.get(msg.taskId);
            if (pending) {
              clearTimeout(pending.timeoutId);
              pendingAgentTasks.delete(msg.taskId);
              pending.resolve({
                success: msg.success !== false,
                output: msg.output || "",
                steps: msg.steps || [],
              });
            }
          } else if (msg.type === "waiting_approval") {
            console.log(`[Agent Hub] Agent waiting approval for task ${msg.taskId}`);
            const pending = pendingAgentTasks.get(msg.taskId);
            if (pending) {
              io.to(`user_${pending.userId}`).emit("agent_waiting_approval", {
                taskId: msg.taskId,
                messageId: pending.assistantMessageId,
                approval: msg.approval
              });
              // App 没有 socket.io 客户端，只有 SSE 通道 —— 必须在这里也推一份，
              // 否则"DSH 弹选项等用户点"这件事 App 永远看不到。
              generationEvents.emit(`approval_${pending.assistantMessageId}`, {
                messageId: pending.assistantMessageId,
                taskId: msg.taskId,
                approval: msg.approval,
              });
            } else {
              io.emit("agent_waiting_approval", {
                taskId: msg.taskId,
                approval: msg.approval
              });
            }
          } else if (msg.type === "approval_resolved") {
            // DSH 侧已给出结论（用户点了/超时），同步给所有在等的界面
            const resolved = msg.approvalId ? { approvalId: msg.approvalId, outcome: msg.outcome } : msg;
            io.emit("agent_approval_resolved", resolved);
            generationEvents.emit('approval_resolved_broadcast', resolved);
          } else if (msg.type === "waiting_question") {
            // DSH 的 ask_user_question 挂起了：桥接轮询到就推上来，转给 App 弹卡片。
            // 注意这里**不依赖 taskId**：用户在电脑网页里发起的一轮同样可能有提问。
            // deferred=true 表示那一轮已结束（超过阻塞窗口），答复要走续跑。
            const qToken = (msg.token || token || "").trim();
            console.log(`[Agent Hub] Agent waiting user question ${msg.questionId} (session ${msg.sessionId || '-'}, state=${msg.state || (msg.deferred === true ? 'orphaned' : 'pending')})`);
            void deliverQuestionToUser(qToken, {
              questionId: String(msg.questionId || ""),
              sessionId: msg.sessionId,
              questions: Array.isArray(msg.questions) ? msg.questions : [],
              state: msg.state,
              deferred: msg.deferred === true,
            });
          } else if (msg.type === "question_resolved") {
            // 问题已经被答复（在 App 上或在电脑端网页上）→ 让各端把卡片收起来
            const qid = String(msg.questionId || "");
            if (qid) pendingQuestions.delete(qid);
            savePendingDecisions();
            io.emit("agent_question_resolved", { questionId: qid, reason: msg.reason || "closed" });
          } else if (msg.type === "approval_requested") {
            // DSH 挂起了授权请求（工具审批 / 文件沙箱越权升级）→ 转给 App 卡片。
            // 同样**不依赖 taskId**：网页端发起的一轮、或后台升级产生的审批都会走到这里。
            const aToken = (msg.token || token || "").trim();
            console.log(`[Agent Hub] Agent waiting approval ${msg.approvalId} (tool ${msg.tool || '-'}, state=${msg.state || (msg.deferred === true ? 'orphaned' : 'pending')})`);
            void deliverApprovalToUser(aToken, {
              approvalId: String(msg.approvalId || ""),
              sessionId: msg.sessionId,
              tool: msg.tool,
              reason: msg.reason,
              state: msg.state,
              deferred: msg.deferred === true,
            });
          } else if (msg.type === "approval_closed") {
            // 审批已被裁决（App 上、或电脑端网页上）→ 各端收起卡片
            const aid = String(msg.approvalId || "");
            if (aid) pendingApprovals.delete(aid);
            savePendingDecisions();
            io.emit("agent_approval_resolved", { approvalId: aid, outcome: "resolved" });
          } else if (msg.type === "sync_sessions" || msg.type === "sessions_result") {
            agentInfo.workspaces = msg.workspaces || [];
            agentInfo.sessions = msg.sessions || [];
            if (msg.models) agentInfo.models = msg.models;
            console.log(`[Agent Hub] Synced ${agentInfo.sessions.length} sessions and ${agentInfo.models?.length || 0} models for agent [${token}]`);
            io.emit("agent_sessions_updated", {
              token,
              workspaces: agentInfo.workspaces,
              sessions: agentInfo.sessions,
              models: agentInfo.models || []
            });
          } else if (msg.type === "pong" || msg.type === "app_pong") {
            agentInfo.lastPing = Date.now();
          }
        } catch (err) {
          console.error("[Agent Hub] Error parsing agent message:", err);
        }
      });

      clientWs.on("close", () => {
        console.log(`\x1b[33m[Agent Hub] Local Agent disconnected for token [${token}]\x1b[0m`);
        if (connectedAgents.get(token)?.ws === clientWs) {
          connectedAgents.delete(token);
          io.emit("agent_status_change", { token, online: false });
        }

        // Fail-fast any pending tasks that were waiting for this disconnected agent
        for (const [taskId, taskInfo] of pendingAgentTasks.entries()) {
          if (taskInfo.token === token) {
            clearTimeout(taskInfo.timeoutId);
            pendingAgentTasks.delete(taskId);
            taskInfo.reject(new Error("本地 DeepSeek Agent 桥接连接已中断，任务已中止。"));
            io.to(`user_${taskInfo.userId}`).emit("agent_task_finished", {
              messageId: taskInfo.assistantMessageId,
              taskId,
              result: {
                status: "failed",
                steps: ["⚠️ 本地 Agent 桥接已断开连接"],
                rawOutput: "Agent Disconnected",
                timestamp: new Date().toISOString()
              }
            });
          }
        }
      });

      clientWs.on("error", (err) => {
        console.error("[Agent Hub] Agent WS error:", err);
      });
    } catch (err) {
      console.error("[Agent Hub] Setup error:", err);
    }
  });

  wss.on("connection", (clientWs, request) => {
    try {
      const requestUrl = new URL(request.url || "", `http://${request.headers.host || "localhost"}`);
      let targetEndpoint = requestUrl.searchParams.get("endpoint");

      if (!targetEndpoint) {
        console.error("[FunASR WS Proxy] Missing target endpoint");
        clientWs.close(1008, "Missing endpoint parameter");
        return;
      }

      targetEndpoint = targetEndpoint.trim();
      if (targetEndpoint.startsWith("http://")) {
        targetEndpoint = targetEndpoint.replace("http://", "ws://");
      } else if (targetEndpoint.startsWith("https://")) {
        targetEndpoint = targetEndpoint.replace("https://", "wss://");
      } else if (!targetEndpoint.startsWith("ws://") && !targetEndpoint.startsWith("wss://")) {
        if (targetEndpoint.includes('.') && !targetEndpoint.startsWith('127.') && !targetEndpoint.startsWith('192.168.') && !targetEndpoint.startsWith('10.') && !targetEndpoint.startsWith('localhost')) {
          targetEndpoint = `wss://${targetEndpoint}`;
        } else {
          targetEndpoint = `ws://${targetEndpoint}`;
        }
      }

      console.log(`[FunASR WS Proxy] Proxying WebSocket connection to target: ${targetEndpoint}`);

      const rawSubprotocol = request.headers['sec-websocket-protocol'];
      let protocols: string[] = ['binary'];
      if (rawSubprotocol) {
        const parsed = rawSubprotocol.split(',').map((s) => s.trim()).filter(Boolean);
        if (parsed.length > 0) {
          protocols = parsed;
        }
      }

      console.log(`[FunASR WS Proxy] Connecting to target WS: ${targetEndpoint} with protocols:`, protocols);
      
      const wsOptions: WSWebSocket.ClientOptions = {
        rejectUnauthorized: false,
        headers: {
          'User-Agent': (request.headers['user-agent'] as string) || 'Mozilla/5.0',
        },
      };

      const targetWs = new WSWebSocket(targetEndpoint, protocols, wsOptions);
      const pendingBuffer: any[] = [];

      targetWs.on("open", () => {
        console.log(`[FunASR WS Proxy] Connected to target FunASR WS: ${targetEndpoint}`);
        while (pendingBuffer.length > 0 && targetWs.readyState === WSWebSocket.OPEN) {
          const msg = pendingBuffer.shift();
          if (msg !== undefined) targetWs.send(msg);
        }
      });

      targetWs.on("message", (data, isBinary) => {
        if (clientWs.readyState === WSWebSocket.OPEN) {
          clientWs.send(data, { binary: isBinary });
        }
      });

      targetWs.on("error", (err) => {
        console.error("[FunASR WS Proxy] Target WS error:", err.message);
        if (clientWs.readyState === WSWebSocket.OPEN) {
          clientWs.close(1011, `Target error: ${err.message}`);
        }
      });

      // 每 45 秒发送 ping 帧，防止 Cloudflare / 代理层超时断开
      const heartbeatInterval = setInterval(() => {
        if (clientWs.readyState === WSWebSocket.OPEN) {
          try {
            clientWs.ping();
          } catch (pingErr) {
            console.error("[FunASR WS Proxy] Client ping error:", pingErr);
          }
        }
        if (targetWs.readyState === WSWebSocket.OPEN) {
          try {
            targetWs.ping();
          } catch (pingErr) {
            console.error("[FunASR WS Proxy] Target ping error:", pingErr);
          }
        }
      }, 45000);

      const cleanupProxy = () => {
        clearInterval(heartbeatInterval);
      };

      targetWs.on("close", (code, reason) => {
        console.log(`[FunASR WS Proxy] Target WS closed: ${code}`);
        cleanupProxy();
        if (clientWs.readyState === WSWebSocket.OPEN) {
          clientWs.close(code, reason);
        }
      });

      clientWs.on("message", (data, isBinary) => {
        if (targetWs.readyState === WSWebSocket.OPEN) {
          targetWs.send(data, { binary: isBinary });
        } else if (targetWs.readyState === WSWebSocket.CONNECTING) {
          pendingBuffer.push(data);
        }
      });

      clientWs.on("error", (err) => {
        console.error("[FunASR WS Proxy] Client WS error:", err.message);
        cleanupProxy();
        if (targetWs.readyState === WSWebSocket.OPEN || targetWs.readyState === WSWebSocket.CONNECTING) {
          targetWs.close();
        }
      });

      clientWs.on("close", () => {
        console.log("[FunASR WS Proxy] Client WS connection closed");
        cleanupProxy();
        if (targetWs.readyState === WSWebSocket.OPEN || targetWs.readyState === WSWebSocket.CONNECTING) {
          targetWs.close();
        }
      });
    } catch (err: any) {
      console.error("[FunASR WS Proxy] Setup exception:", err);
      clientWs.close(1011, err?.message || "Proxy setup failed");
    }
  });

  // Socket.io for Real-time Sync
  io.on("connection", (socket) => {
    console.log("Client connected:", socket.id);

    // Join a room based on userId to keep data separate
    socket.on("join_user_room", (payload) => {
      let userId = "";
      let deviceType: 'mobile' | 'desktop' = "desktop";
      let clientSessionId = "";

      if (typeof payload === "object" && payload !== null) {
        userId = payload.userId || "";
        deviceType = payload.deviceType === "mobile" ? "mobile" : "desktop";
        clientSessionId = payload.clientSessionId || "";
      } else {
        userId = String(payload || "");
      }

      socket.join(`user_${userId}`);
      socket.join(`user_${userId}_${deviceType}`);
      if (clientSessionId) {
        socket.join(`session_${clientSessionId}`);
      }
      console.log(`Socket ${socket.id} joined user_${userId}, user_${userId}_${deviceType}${clientSessionId ? ', session_' + clientSessionId : ''}`);
    });

    socket.on("send_message", async ({ userId, message }) => {
      try {
        if (userId !== "guest") { // Only store for non-guests
          await withFileLock(MESSAGES_FILE, async () => {
            const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
            if (!allMessages[userId]) allMessages[userId] = [];
            allMessages[userId].push(message);
            await safeWriteJSON(MESSAGES_FILE, allMessages);
          });
        }
        
        // Still broadcast for real-time
        io.to(`user_${userId}`).emit("receive_message", message);
      } catch (error) {
        console.error("Socket error saving message:", error);
      }
    });

    socket.on("start_generation", async ({ userId, assistantMessageId, messages, settings }) => {
      console.log(`[Socket] Received start_generation for user ${userId}, messageId ${assistantMessageId}`);
      try {
        console.log(`[Socket] Starting server-side generation for ${assistantMessageId}`);
        runServerSideGeneration({
          userId: userId || "guest",
          assistantMessageId,
          messages,
          settings: settings || {},
          io
        }).catch(err => {
          console.error("[Socket Background Gen Worker] Error:", err);
        });
      } catch (error) {
        console.error("Socket error initiating generation:", error);
      }
    });

    socket.on("delete_message", async ({ userId, messageId }) => {
      try {
        await withFileLock(MESSAGES_FILE, async () => {
          const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
          if (allMessages[userId]) {
            allMessages[userId] = allMessages[userId].filter((m: any) => m.id !== messageId);
            await safeWriteJSON(MESSAGES_FILE, allMessages);
          }
        });
        io.to(`user_${userId}`).emit("message_deleted", messageId);
      } catch (error) {
        console.error("Socket error deleting message:", error);
      }
    });

    socket.on("delete_messages_range", async ({ userId, range }) => {
      console.log(`[Socket] Received delete_messages_range for userId: ${userId}, range: ${range}`);
      try {
        let updatedUserMessages: any[] = [];
        await withFileLock(MESSAGES_FILE, async () => {
          const allMessages = await safeReadJSON<Record<string, any[]>>(MESSAGES_FILE, {});
          if (!allMessages[userId]) {
            console.log(`[Socket] No messages found for user: ${userId}`);
            return;
          }

          // Logic for filtering
          let messages = allMessages[userId];
          const firstMessage = messages[0];
          
          if (range === 'all') {
            console.log(`[Socket] Deleting all messages for user: ${userId}`);
            allMessages[userId] = firstMessage?.role === 'assistant' ? [firstMessage] : [];
          } else {
            const days = range as number;
            console.log(`[Socket] Deleting messages older than ${days} days for user: ${userId}`);
            const cutoff = new Date();
            cutoff.setDate(cutoff.getDate() - days);
            cutoff.setHours(0, 0, 0, 0);
            
            allMessages[userId] = messages.filter((m: any, index: number) => {
              if (index === 0 && m.role === 'assistant') return true;
              return new Date(m.timestamp) >= cutoff; // Keeps messages within the range
            });
          }
          
          await safeWriteJSON(MESSAGES_FILE, allMessages);
          updatedUserMessages = allMessages[userId];
        });

        console.log(`[Socket] Messages updated for user: ${userId}`);
        io.to(`user_${userId}`).emit("messages_updated", updatedUserMessages);
      } catch (error) {
        console.error("Socket error deleting messages range:", error);
      }
    });

    socket.on("update_settings", async ({ userId, settings }) => {
      try {
        await withFileLock(SETTINGS_FILE, async () => {
          const allSettings = await safeReadJSON<Record<string, any>>(SETTINGS_FILE, {});
          allSettings[userId] = settings;
          await safeWriteJSON(SETTINGS_FILE, allSettings);
        });
        io.to(`user_${userId}`).emit("settings_updated", settings);
      } catch (error) {
        console.error("Socket error saving settings:", error);
      }
    });

    socket.on("check_agent_status", ({ token }) => {
      const cleanToken = (token || "").trim() || "";
      // Socket 上下文没有 res，改用事件回错
      if (!isPlausibleAgentToken(cleanToken)) {
        socket.emit("agent_status_response", {
          token: cleanToken,
          online: false,
          error: "invalid_token",
        });
        return;
      }
      const agent = connectedAgents.get(cleanToken);
      const isOnline = !!(agent && agent.ws.readyState === WSWebSocket.OPEN);
      socket.emit("agent_status_response", {
        token: cleanToken,
        online: isOnline,
        clientName: agent?.clientName,
        connectedAt: agent?.connectedAt,
      });
    });

    socket.on("disconnect", () => {
      console.log("Client disconnected:", socket.id);
    });
  });

  // Vite integration
  if (process.env.NODE_ENV !== "production") {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: "spa",
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.join(process.cwd(), "dist");
    app.use(express.static(distPath));
    app.get("*", (req, res) => {
      res.sendFile(path.join(distPath, "index.html"));
    });
  }

  // Ensure essential directories exist on startup
  await fs.mkdir(DATA_DIR, { recursive: true }).catch(() => {});
  await fs.mkdir(UPLOADS_DIR, { recursive: true }).catch(() => {});

  // Initialize model limits file on startup
  await ensureModelLimitsInitialized();

  httpServer.listen(PORT, "0.0.0.0", () => {
    console.log(`Server running at http://0.0.0.0:${PORT}`);
  });
}

startServer();
