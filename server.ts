import "dotenv/config";
import express from "express";
import bcrypt from "bcryptjs";
import FormData from "form-data";
import { createServer } from "http";
import { Server } from "socket.io";
import { WebSocketServer, WebSocket as WSWebSocket } from "ws";
import { EventEmitter } from "events";
import path from "path";
import fs from "fs/promises";
import multer from "multer";
import { createServer as createViteServer } from "vite";
import cors from "cors";

const generationEvents = new EventEmitter();
generationEvents.setMaxListeners(500);

// 监听端口：默认 3000，可用环境变量 PORT 覆盖（便于本地起隔离实例做安全回归测试）
const PORT = Number(process.env.PORT) || 3000;
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
  content: string;
  status: 'generating' | 'completed' | 'error';
  error?: string;
  startedAt: number;
  abortController: AbortController;
}

const activeGenerations = new Map<string, ActiveGeneration>();

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
    content: "",
    status: 'generating',
    startedAt: Date.now(),
    abortController,
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
  await upsertMessage(userId, initialAssistantMessage);

  try {
    const isAgentMode = settings?.agentMode === true;
    // 修复：客户端字段是 harnessToken，此前误读 agentToken 导致永远取空 → 全落默认 token
    const agentToken = readUserAgentToken(settings);
    let agentExecutionResult: { status: 'completed' | 'failed'; steps: string[]; rawOutput?: string; timestamp?: string } | null = null;

    let accumulatedContent = "";
    let accumulatedReasoning = "";
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
          const timeoutId = setTimeout(() => {
            pendingAgentTasks.delete(taskId);
            reject(new Error("本地 DeepSeek 智能体执行超时 (300秒)"));
          }, 300000);

          pendingAgentTasks.set(taskId, {
            resolve,
            reject,
            timeoutId,
            token: agentToken,
            userId,
            assistantMessageId,
          });
        });

        const selectedSessionId = (settings?.agentSessionId || "").trim();
        const selectedWorkspace = (settings?.agentWorkspace || "deepseek-agent").trim();
        
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
      res.json({ valid: true });
    } catch (e) {
      res.json({ valid: true });
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
      generationEvents.off(`chunk_${assistantMessageId}`, chunkHandler);
      generationEvents.off(`step_${assistantMessageId}`, stepHandler);
      generationEvents.off(`task_started_${assistantMessageId}`, taskStartedHandler);
      generationEvents.off(`task_finished_${assistantMessageId}`, taskFinishedHandler);
      generationEvents.off(`completed_${assistantMessageId}`, completedHandler);
      generationEvents.off(`error_${assistantMessageId}`, errorHandler);
    };

    req.on("close", () => {
      isClosed = true;
      cleanup();
    });

    generationEvents.on(`chunk_${assistantMessageId}`, chunkHandler);
    generationEvents.on(`step_${assistantMessageId}`, stepHandler);
    generationEvents.on(`task_started_${assistantMessageId}`, taskStartedHandler);
    generationEvents.on(`task_finished_${assistantMessageId}`, taskFinishedHandler);
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
      io.to(`user_${cleanUserId}`).emit("settings_updated", cleanSettings);
      res.json({ success: true });
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
      if (!isPlausibleAgentToken(token)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      // 不再回退到 default_agent_token：默认值 = 公共秘密，等于没有鉴权
      if (!isPlausibleAgentToken(token)) {
        console.warn("[Security] 拒绝注册：非法或默认 Agent Token");
        return res.status(401).json({ error: "无效的 Agent Token，请在 App 中生成配对口令后重试" });
      }
      const clientInfo = req.body?.clientInfo || {};
      const clientName = clientInfo.name || "DeepSeek-Harness-Local";

      console.log(`\x1b[32m[Agent Hub] Agent registered via HTTP [${token}] (${clientName}, mode: ${clientInfo.mode || 'polling'})\x1b[0m`);

      // 绑定归属（若该 token 已在某用户设置中登记）
      const ownerUserId = await resolveTokenOwnerUserId(token);
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
          res.json({ type: "noop", timestamp: Date.now() });
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
    res.json({ success: true, timestamp: Date.now() });
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
        workspaces: agent?.workspaces || ["deepseek-agent"],
        sessions: agent?.sessions || [],
        clientName: agent?.clientName || "DeepSeek-Harness-Local"
      });
    } catch (err: any) {
      res.json({
        online: false,
        workspaces: ["deepseek-agent"],
        sessions: [],
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

  // Create new session in local DeepSeek Harness via bridge
  app.post("/api/agent/create-session", async (req, res) => {
    try {
      const { token, workspace, title, model } = req.body || {};
      const targetToken = (token || "").trim() || "";
      if (!isPlausibleAgentToken(targetToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }
      const agent = connectedAgents.get(targetToken);
      const targetWs = (workspace || "").trim() || "deepseek-agent";
      const sessionTitle = (title || "").trim() || `新对话 ${new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}`;

      if (!agent) {
        const fallbackSessionId = `session_${Date.now()}_${Math.random().toString(36).substring(2, 7)}`;
        const fallbackSession = {
          id: fallbackSessionId,
          sessionId: fallbackSessionId,
          title: sessionTitle,
          workspace: targetWs,
          updatedAt: Date.now(),
          model: model || "deepseek-chat"
        };
        return res.json({
          success: true,
          sessionId: fallbackSessionId,
          session: fallbackSession,
          sessions: [fallbackSession],
          workspaces: [targetWs],
          notice: "本地尚未连接，已预置会话标识"
        });
      }

      if (agent.ws && agent.ws.readyState === WSWebSocket.OPEN) {
        const createTaskId = `create_session_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`;
        
        const createPromise = new Promise<any>((resolve) => {
          const timeout = setTimeout(() => {
            const fallbackSessionId = `session_${Date.now()}_${Math.random().toString(36).substring(2, 7)}`;
            const fbSession = {
              id: fallbackSessionId,
              sessionId: fallbackSessionId,
              title: sessionTitle,
              workspace: targetWs,
              updatedAt: Date.now(),
              model: model || "deepseek-chat"
            };
            resolve({
              type: "create_session_result",
              success: true,
              sessionId: fallbackSessionId,
              session: fbSession,
              sessions: [fbSession, ...(agent.sessions || [])]
            });
          }, 3500);

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
        if (result.workspaces && Array.isArray(result.workspaces)) agent.workspaces = result.workspaces;
        if (result.sessions && Array.isArray(result.sessions)) {
          agent.sessions = result.sessions;
        } else if (result.session) {
          const sid = result.sessionId || result.session.id;
          agent.sessions = [result.session, ...(agent.sessions || []).filter(s => (s.sessionId || s.id) !== sid)];
        }

        io.emit("agent_sessions_updated", {
          token: targetToken,
          workspaces: agent.workspaces || ["deepseek-agent"],
          sessions: agent.sessions || []
        });

        return res.json({
          success: true,
          sessionId: result.sessionId || result.session?.id || result.session?.sessionId,
          session: result.session,
          sessions: agent.sessions,
          workspaces: agent.workspaces
        });
      }

      // Polling mode or ws not open
      const newSid = `session_${Date.now()}_${Math.random().toString(36).substring(2, 7)}`;
      const newSession = {
        id: newSid,
        sessionId: newSid,
        title: sessionTitle,
        workspace: targetWs,
        updatedAt: Date.now(),
        model: model || "deepseek-chat"
      };
      agent.sessions = [newSession, ...(agent.sessions || []).filter(s => (s.sessionId || s.id) !== newSid)];
      io.emit("agent_sessions_updated", {
        token: targetToken,
        workspaces: agent.workspaces || [targetWs],
        sessions: agent.sessions
      });
      return res.json({
        success: true,
        sessionId: newSid,
        session: newSession,
        sessions: agent.sessions,
        workspaces: agent.workspaces || [targetWs]
      });
    } catch (err: any) {
      console.error("[Create Session API Error]", err);
      const fallbackId = `session_${Date.now()}`;
      res.json({
        success: true,
        sessionId: fallbackId,
        session: { id: fallbackId, sessionId: fallbackId, title: "新会话", workspace: "deepseek-agent" },
        sessions: [],
        workspaces: ["deepseek-agent"]
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
          workspaces: agent.workspaces || ["deepseek-agent"],
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
  }
  const bridgeAuthSessions = new Map<string, BridgeAuthSession>();

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
  app.post("/api/bridge/auth-confirm", (req, res) => {
    try {
      const { sessionCode, token, account } = req.body || {};
      const cleanCode = (sessionCode || "").toString().trim().toUpperCase();
      const cleanToken = (token || "").toString().trim();
      if (!isPlausibleAgentToken(cleanToken)) {
        return res.status(401).json({ error: "无效或缺失的 Agent Token" });
      }

      if (!cleanCode || !cleanToken) {
        return res.status(400).json({ success: false, error: "缺少配对码或授权 Token" });
      }

      const sess = bridgeAuthSessions.get(cleanCode);
      if (!sess) {
        return res.status(404).json({ success: false, error: "配对码不存在或已失效，请重新生成" });
      }

      if (Date.now() > sess.expiresAt) {
        sess.status = "expired";
        return res.status(410).json({ success: false, error: "配对码已过期，请在电脑端重新生成二维码" });
      }

      // 授权成功，关联 Token
      sess.status = "confirmed";
      sess.authorizedToken = cleanToken;
      sess.authorizedAccount = (account || "").toString().trim();

      console.log(`[Bridge Auth] Session ${cleanCode} confirmed by user: ${sess.authorizedAccount || 'anonymous'}`);
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
      }
    } catch (err) {
      console.error("[WS Upgrade Error]", err);
    }
  });

  // Handle Local Agent WebSocket Connections
  agentWss.on("connection", (clientWs, request) => {
    try {
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
            } else {
              io.emit("agent_waiting_approval", {
                taskId: msg.taskId,
                approval: msg.approval
              });
            }
          } else if (msg.type === "sync_sessions" || msg.type === "sessions_result") {
            agentInfo.workspaces = msg.workspaces || ["deepseek-agent"];
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
