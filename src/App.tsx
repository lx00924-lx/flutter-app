/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useState, useEffect, useCallback } from 'react';
import {
  Server,
  Smartphone,
  Laptop,
  QrCode,
  Copy,
  Check,
  RefreshCw,
  Activity,
  Terminal,
  Database,
  Wifi,
  WifiOff,
  Sun,
  Moon,
  ExternalLink,
  ShieldCheck,
  Zap,
} from 'lucide-react';
import QRCode from 'qrcode';
import socket from './lib/socket';

interface AgentStatus {
  online: boolean;
  token: string;
  clientName: string;
  workspaces?: string[];
  sessions?: any[];
  models?: any[];
}

interface EventLog {
  id: string;
  time: string;
  type: string;
  payload: any;
}

export default function App() {
  // Theme state
  const [isDarkMode, setIsDarkMode] = useState<boolean>(() => {
    if (typeof window !== 'undefined') {
      const saved = localStorage.getItem('app_theme');
      if (saved) return saved === 'dark';
      return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    return true;
  });

  // Server & Relay status
  const [serverOnline, setServerOnline] = useState(true);
  const [socketConnected, setSocketConnected] = useState(socket.connected);
  const [serverBaseUrl, setServerBaseUrl] = useState('https://www.lx00924ai.top');
  const [qrCodeDataUrl, setQrCodeDataUrl] = useState('');
  const [copiedUrl, setCopiedUrl] = useState(false);
  const [copiedCmd, setCopiedCmd] = useState(false);

  // Agent Hub status
  const generateOpenAiKey = () => {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let rand = '';
    for (let i = 0; i < 48; i++) {
      rand += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return `sk-${rand}`;
  };

  const [agentToken, setAgentToken] = useState('sk-agent030efheg0z78491abcdef0123456789abcdef0123456789');
  const [agentStatus, setAgentStatus] = useState<AgentStatus>({
    online: false,
    token: 'sk-agent030efheg0z78491abcdef0123456789abcdef0123456789',
    clientName: 'DeepSeek-Bridge-Local',
    workspaces: ['deepseek-agent'],
    sessions: [],
  });

  // Diagnostics & Stats
  const [pingLatency, setPingLatency] = useState<number | null>(null);
  const [diagnosticResult, setDiagnosticResult] = useState<string | null>(null);
  const [isDiagnosing, setIsDiagnosing] = useState(false);
  const [logs, setLogs] = useState<EventLog[]>([]);

  // Apply Theme
  useEffect(() => {
    if (isDarkMode) {
      document.documentElement.classList.add('dark');
      localStorage.setItem('app_theme', 'dark');
    } else {
      document.documentElement.classList.remove('dark');
      localStorage.setItem('app_theme', 'light');
    }
  }, [isDarkMode]);

  // Generate QR Code whenever serverBaseUrl or theme changes
  useEffect(() => {
    const targetUrl = serverBaseUrl || 'https://www.lx00924ai.top';
    QRCode.toDataURL(targetUrl, {
      margin: 2,
      width: 200,
      color: {
        dark: isDarkMode ? '#F8FAFC' : '#0F172A',
        light: isDarkMode ? '#1E293B' : '#FFFFFF',
      },
    })
      .then((url) => setQrCodeDataUrl(url))
      .catch((err) => console.error('Failed to generate QR code', err));
  }, [serverBaseUrl, isDarkMode]);

  // Append Event Log
  const addLog = useCallback((type: string, payload: any) => {
    const now = new Date();
    const time = `${now.getHours().toString().padStart(2, '0')}:${now
      .getMinutes()
      .toString()
      .padStart(2, '0')}:${now.getSeconds().toString().padStart(2, '0')}.${now
      .getMilliseconds()
      .toString()
      .padStart(3, '0')}`;
    setLogs((prev) => [
      { id: `${Date.now()}_${Math.random().toString(36).substring(2, 6)}`, time, type, payload },
      ...prev.slice(0, 50),
    ]);
  }, []);

  // Socket.IO event listeners
  useEffect(() => {
    const onConnect = () => {
      setSocketConnected(true);
      addLog('socket_connect', { id: socket.id });
      // Check current agent status
      socket.emit('check_agent_status', { token: agentToken });
    };

    const onDisconnect = () => {
      setSocketConnected(false);
      addLog('socket_disconnect', {});
    };

    const onAgentStatusChange = (data: { token: string; online: boolean; clientName?: string }) => {
      if (!agentToken || data.token === agentToken) {
        setAgentStatus((prev) => ({
          ...prev,
          online: data.online,
          clientName: data.clientName || prev.clientName,
        }));
        addLog('agent_status_change', data);
      }
    };

    const onAgentStatusResponse = (data: { token: string; online: boolean; clientName?: string }) => {
      setAgentStatus((prev) => ({
        ...prev,
        online: data.online,
        clientName: data.clientName || prev.clientName,
      }));
    };

    const onAgentSessionsUpdated = (data: any) => {
      if (!agentToken || data.token === agentToken) {
        setAgentStatus((prev) => ({
          ...prev,
          workspaces: data.workspaces || prev.workspaces,
          sessions: data.sessions || prev.sessions,
          models: data.models || prev.models,
        }));
        addLog('agent_sessions_synced', { count: data.sessions?.length || 0 });
      }
    };

    const onSettingsUpdated = (data: any) => {
      addLog('cloud_settings_updated', data);
    };

    const onMessagesUpdated = (data: any) => {
      addLog('cloud_messages_updated', { count: Array.isArray(data) ? data.length : 1 });
    };

    socket.on('connect', onConnect);
    socket.on('disconnect', onDisconnect);
    socket.on('agent_status_change', onAgentStatusChange);
    socket.on('agent_status_response', onAgentStatusResponse);
    socket.on('agent_sessions_updated', onAgentSessionsUpdated);
    socket.on('settings_updated', onSettingsUpdated);
    socket.on('messages_updated', onMessagesUpdated);

    // Initial check
    if (socket.connected) {
      setSocketConnected(true);
      socket.emit('check_agent_status', { token: agentToken });
    }

    return () => {
      socket.off('connect', onConnect);
      socket.off('disconnect', onDisconnect);
      socket.off('agent_status_change', onAgentStatusChange);
      socket.off('agent_status_response', onAgentStatusResponse);
      socket.off('agent_sessions_updated', onAgentSessionsUpdated);
      socket.off('settings_updated', onSettingsUpdated);
      socket.off('messages_updated', onMessagesUpdated);
    };
  }, [agentToken, addLog]);

  // Run Health & API Diagnostics
  const runDiagnostics = async () => {
    setIsDiagnosing(true);
    const start = performance.now();
    try {
      const resp = await fetch('/api/health');
      const data = await resp.json();
      const end = performance.now();
      const latency = Math.round(end - start);
      setPingLatency(latency);
      setServerOnline(true);
      setDiagnosticResult(`服务正常 (${latency}ms) - 响应: ${JSON.stringify(data)}`);
      addLog('health_check', { latency, status: resp.status });
    } catch (err: any) {
      setServerOnline(false);
      setDiagnosticResult(`健康探测失败: ${err.message || String(err)}`);
      addLog('health_check_failed', { error: String(err) });
    } finally {
      setIsDiagnosing(false);
    }
  };

  const copyUrl = () => {
    navigator.clipboard.writeText(serverBaseUrl);
    setCopiedUrl(true);
    setTimeout(() => setCopiedUrl(false), 2000);
  };

  const bridgeCommand = `python deepseek_bridge.py --url ${serverBaseUrl} --token ${agentToken || 'sk-agent030efheg0z78491abcdef0123456789abcdef0123456789'}`;
  const copyCmd = () => {
    navigator.clipboard.writeText(bridgeCommand);
    setCopiedCmd(true);
    setTimeout(() => setCopiedCmd(false), 2000);
  };

  return (
    <div className="min-h-screen bg-slate-50 dark:bg-slate-950 text-slate-900 dark:text-slate-100 transition-colors">
      {/* Top Navbar */}
      <header className="border-b border-slate-200 dark:border-slate-800 bg-white/80 dark:bg-slate-900/80 backdrop-blur sticky top-0 z-30 px-4 sm:px-8 py-3.5">
        <div className="max-w-7xl mx-auto flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-xl bg-gradient-to-tr from-sky-500 to-indigo-600 flex items-center justify-center text-white shadow-md shadow-indigo-500/20">
              <Zap className="w-5 h-5" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h1 className="text-lg font-bold tracking-tight">Aether-X Hub</h1>
                <span className="text-[11px] font-semibold px-2 py-0.5 rounded-full bg-indigo-100 text-indigo-700 dark:bg-indigo-950/80 dark:text-indigo-300 border border-indigo-200 dark:border-indigo-800">
                  Relay Console
                </span>
              </div>
              <p className="text-xs text-slate-500 dark:text-slate-400">
                云端中继 · 本地 Agent 反向穿透 · Flutter 原生端服务中枢
              </p>
            </div>
          </div>

          <div className="flex items-center gap-3">
            <div className="hidden sm:flex items-center gap-2 text-xs px-3 py-1.5 rounded-lg border border-slate-200 dark:border-slate-800 bg-slate-100/70 dark:bg-slate-800/70">
              <span
                className={`w-2 h-2 rounded-full ${
                  socketConnected ? 'bg-emerald-500 animate-pulse' : 'bg-rose-500'
                }`}
              />
              <span className="font-medium text-slate-600 dark:text-slate-300">
                {socketConnected ? '中继信道在线' : '信道连接中'}
              </span>
            </div>

            <button
              onClick={() => setIsDarkMode(!isDarkMode)}
              className="p-2 rounded-lg border border-slate-200 dark:border-slate-800 hover:bg-slate-100 dark:hover:bg-slate-800 transition"
              title="切换主题"
            >
              {isDarkMode ? <Sun className="w-4 h-4 text-amber-400" /> : <Moon className="w-4 h-4 text-slate-600" />}
            </button>
          </div>
        </div>
      </header>

      {/* Main Content Dashboard */}
      <main className="max-w-7xl mx-auto px-4 sm:px-8 py-6 space-y-6">
        {/* Top Status Banner */}
        <div className="p-4 rounded-2xl bg-gradient-to-r from-blue-600/10 via-indigo-600/10 to-purple-600/10 border border-indigo-200/50 dark:border-indigo-800/40 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
          <div className="flex items-center gap-3.5">
            <div className="p-2.5 rounded-xl bg-indigo-500 text-white shadow-sm">
              <ShieldCheck className="w-5 h-5" />
            </div>
            <div>
              <h2 className="text-sm font-semibold text-slate-800 dark:text-slate-200">
                纯原生 Flutter App 架构运行中
              </h2>
              <p className="text-xs text-slate-500 dark:text-slate-400">
                旧版 Web 套壳依赖已成功清理。服务端由 Express 高性能反向中继驱动，所有消息、多端互斥及设置云端漫游均已接通。
              </p>
            </div>
          </div>

          <button
            onClick={runDiagnostics}
            disabled={isDiagnosing}
            className="flex items-center gap-2 px-3.5 py-1.5 text-xs font-medium rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white transition disabled:opacity-50 whitespace-nowrap"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${isDiagnosing ? 'animate-spin' : ''}`} />
            服务连通性自检
          </button>
        </div>

        {/* 4 Core Cards Grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-5">
          {/* Card 1: Flutter App 扫码连接 */}
          <div className="p-5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-sm flex flex-col justify-between">
            <div>
              <div className="flex items-center justify-between mb-3">
                <span className="p-2 rounded-xl bg-sky-50 dark:bg-sky-950/60 text-sky-600 dark:text-sky-400 border border-sky-100 dark:border-sky-900">
                  <Smartphone className="w-5 h-5" />
                </span>
                <span className="text-[11px] font-medium text-emerald-600 dark:text-emerald-400 flex items-center gap-1">
                  <span className="w-1.5 h-1.5 rounded-full bg-emerald-500" />
                  已就绪
                </span>
              </div>
              <h3 className="font-semibold text-sm mb-1">Flutter App 扫码绑定</h3>
              <p className="text-xs text-slate-500 dark:text-slate-400 mb-4">
                手机 Flutter 客户端可通过扫码或填写此服务器地址一键连接中继。
              </p>

              {/* QR Code */}
              <div className="flex justify-center p-3 bg-slate-50 dark:bg-slate-800/60 rounded-xl border border-slate-100 dark:border-slate-800 mb-3">
                {qrCodeDataUrl ? (
                  <img src={qrCodeDataUrl} alt="Server QR Code" className="w-36 h-36 rounded-lg" />
                ) : (
                  <div className="w-36 h-36 flex items-center justify-center text-xs text-slate-400">
                    生成二维码中...
                  </div>
                )}
              </div>
            </div>

            <div className="space-y-2">
              <div className="text-[11px] font-mono text-slate-500 dark:text-slate-400 truncate bg-slate-100 dark:bg-slate-800 px-2.5 py-1.5 rounded-lg border border-slate-200 dark:border-slate-700/60">
                {serverBaseUrl}
              </div>
              <button
                onClick={copyUrl}
                className="w-full flex items-center justify-center gap-1.5 py-1.5 text-xs font-medium rounded-lg bg-slate-100 hover:bg-slate-200 dark:bg-slate-800 dark:hover:bg-slate-700 text-slate-700 dark:text-slate-200 transition"
              >
                {copiedUrl ? <Check className="w-3.5 h-3.5 text-emerald-500" /> : <Copy className="w-3.5 h-3.5" />}
                {copiedUrl ? '已复制服务器地址' : '复制服务器地址'}
              </button>
            </div>
          </div>

          {/* Card 2: 电脑端 Agent 反向穿透 */}
          <div className="p-5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-sm flex flex-col justify-between">
            <div>
              <div className="flex items-center justify-between mb-3">
                <span className="p-2 rounded-xl bg-violet-50 dark:bg-violet-950/60 text-violet-600 dark:text-violet-400 border border-violet-100 dark:border-violet-900">
                  <Laptop className="w-5 h-5" />
                </span>
                <span
                  className={`text-[11px] font-medium flex items-center gap-1.5 ${
                    agentStatus.online
                      ? 'text-emerald-600 dark:text-emerald-400'
                      : 'text-amber-600 dark:text-amber-400'
                  }`}
                >
                  <span
                    className={`w-2 h-2 rounded-full ${
                      agentStatus.online ? 'bg-emerald-500 animate-pulse' : 'bg-amber-500'
                    }`}
                  />
                  {agentStatus.online ? '电脑 Agent 在线' : '等待电脑端桥接'}
                </span>
              </div>
              <h3 className="font-semibold text-sm mb-1">电脑端 Agent 穿透状态</h3>
              <p className="text-xs text-slate-500 dark:text-slate-400 mb-3">
                内网电脑运行 <code className="text-indigo-600 dark:text-indigo-400">deepseek_bridge.py</code> 即可反向接入云端中继。
              </p>

              <div className="p-3 bg-slate-50 dark:bg-slate-800/60 rounded-xl border border-slate-100 dark:border-slate-800 space-y-2 mb-3">
                <div className="flex items-center justify-between text-xs gap-2">
                  <span className="text-slate-500 shrink-0">配对 Token:</span>
                  <div className="flex items-center gap-1.5 min-w-0">
                    <span className="font-mono text-[11px] font-medium text-slate-800 dark:text-slate-200 truncate max-w-[170px]" title={agentToken}>
                      {agentToken}
                    </span>
                    <button
                      onClick={() => setAgentToken(generateOpenAiKey())}
                      className="p-1 rounded hover:bg-slate-200 dark:hover:bg-slate-700 text-slate-500 hover:text-slate-700 dark:hover:text-slate-300 transition"
                      title="随机生成 OpenAI 风格长字符 Token"
                    >
                      <RefreshCw className="w-3 h-3" />
                    </button>
                  </div>
                </div>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500">客户端标识:</span>
                  <span className="text-slate-700 dark:text-slate-300 truncate max-w-[120px]">
                    {agentStatus.clientName}
                  </span>
                </div>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500">已同步会话:</span>
                  <span className="font-semibold text-indigo-600 dark:text-indigo-400">
                    {agentStatus.sessions?.length || 0} 个
                  </span>
                </div>
              </div>
            </div>

            <div className="space-y-2">
              <div className="text-[10px] font-mono text-slate-500 dark:text-slate-400 truncate bg-slate-100 dark:bg-slate-800 px-2 py-1 rounded border border-slate-200 dark:border-slate-700">
                {bridgeCommand}
              </div>
              <button
                onClick={copyCmd}
                className="w-full flex items-center justify-center gap-1.5 py-1.5 text-xs font-medium rounded-lg bg-slate-100 hover:bg-slate-200 dark:bg-slate-800 dark:hover:bg-slate-700 text-slate-700 dark:text-slate-200 transition"
              >
                {copiedCmd ? <Check className="w-3.5 h-3.5 text-emerald-500" /> : <Terminal className="w-3.5 h-3.5" />}
                {copiedCmd ? '已复制启动指令' : '复制 Bridge 启动命令'}
              </button>
            </div>
          </div>

          {/* Card 3: 云端数据漫游与设置同步 */}
          <div className="p-5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-sm flex flex-col justify-between">
            <div>
              <div className="flex items-center justify-between mb-3">
                <span className="p-2 rounded-xl bg-amber-50 dark:bg-amber-950/60 text-amber-600 dark:text-amber-400 border border-amber-100 dark:border-amber-900">
                  <Database className="w-5 h-5" />
                </span>
                <span className="text-[11px] font-medium text-emerald-600 dark:text-emerald-400 flex items-center gap-1">
                  <span className="w-1.5 h-1.5 rounded-full bg-emerald-500" />
                  双向实时
                </span>
              </div>
              <h3 className="font-semibold text-sm mb-1">云端设置与历史漫游</h3>
              <p className="text-xs text-slate-500 dark:text-slate-400 mb-3">
                全新加入的云端设置同步功能已生效，Flutter 端所有自定义配置自动同步保存。
              </p>

              <div className="p-3 bg-slate-50 dark:bg-slate-800/60 rounded-xl border border-slate-100 dark:border-slate-800 space-y-2 mb-3">
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500">同步模式:</span>
                  <span className="font-medium text-emerald-600 dark:text-emerald-400">增量防抖推送</span>
                </div>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500">API 卡片 & Key:</span>
                  <span className="text-slate-700 dark:text-slate-300">云端持久化已接通</span>
                </div>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500">单点登录管控:</span>
                  <span className="text-slate-700 dark:text-slate-300">1手机 + 1电脑互斥</span>
                </div>
              </div>
            </div>

            <div className="text-[11px] text-slate-500 dark:text-slate-400 bg-slate-50 dark:bg-slate-800/40 p-2.5 rounded-lg border border-slate-100 dark:border-slate-800">
              💡 换机或清除缓存后，只需在 Flutter App 登录即可无缝恢复所有会话和个性化设置。
            </div>
          </div>

          {/* Card 4: 服务中继与健康度 */}
          <div className="p-5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-sm flex flex-col justify-between">
            <div>
              <div className="flex items-center justify-between mb-3">
                <span className="p-2 rounded-xl bg-emerald-50 dark:bg-emerald-950/60 text-emerald-600 dark:text-emerald-400 border border-emerald-100 dark:border-emerald-900">
                  <Activity className="w-5 h-5" />
                </span>
                <span className="text-[11px] font-mono text-slate-500">Port 3000</span>
              </div>
              <h3 className="font-semibold text-sm mb-1">中继节点运行状态</h3>
              <p className="text-xs text-slate-500 dark:text-slate-400 mb-3">
                负责处理 Flutter 客户端请求分发、模型流式中转与 FunASR 语音代理。
              </p>

              <div className="p-3 bg-slate-50 dark:bg-slate-800/60 rounded-xl border border-slate-100 dark:border-slate-800 space-y-2 mb-3">
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500">服务响应延迟:</span>
                  <span className="font-mono font-medium text-emerald-600 dark:text-emerald-400">
                    {pingLatency !== null ? `${pingLatency} ms` : '未测试'}
                  </span>
                </div>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500">WebSocket 信道:</span>
                  <span className="text-slate-700 dark:text-slate-300">
                    {socketConnected ? '已连接 (在线)' : '连接中'}
                  </span>
                </div>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500">语音转写 (ASR):</span>
                  <span className="text-slate-700 dark:text-slate-300">FunASR 代理可用</span>
                </div>
              </div>
            </div>

            <div className="text-[11px] text-slate-500 dark:text-slate-400 truncate">
              {diagnosticResult || '点击右上角「自检」可查看即时延迟'}
            </div>
          </div>
        </div>

        {/* Real-time Event Stream / Log Console */}
        <div className="p-5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-sm">
          <div className="flex items-center justify-between mb-3">
            <div className="flex items-center gap-2">
              <Terminal className="w-4 h-4 text-indigo-500" />
              <h3 className="font-semibold text-sm">云端中继实时通信流 (Event Stream)</h3>
              <span className="text-xs text-slate-400">({logs.length} 条记录)</span>
            </div>
            <button
              onClick={() => setLogs([])}
              className="text-xs text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 transition"
            >
              清空日志
            </button>
          </div>

          <div className="font-mono text-xs bg-slate-950 text-slate-300 rounded-xl p-3.5 h-48 overflow-y-auto space-y-1.5 border border-slate-800">
            {logs.length === 0 ? (
              <div className="text-slate-500 italic">等待实时网络事件中... (连接中继、Flutter 消息、Agent 握手等)</div>
            ) : (
              logs.map((log) => (
                <div key={log.id} className="flex items-start gap-2">
                  <span className="text-slate-500 select-none">[{log.time}]</span>
                  <span className="font-semibold text-indigo-400">{log.type}:</span>
                  <span className="text-slate-300 break-all">{JSON.stringify(log.payload)}</span>
                </div>
              ))
            )}
          </div>
        </div>
      </main>
    </div>
  );
}
