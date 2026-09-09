/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

export type LogLevel = 'log' | 'info' | 'warn' | 'error';

export interface LogEntry {
  id: string;
  timestamp: string;
  timeMs: number;
  level: LogLevel;
  args: any[];
  formattedText: string;
  stack?: string;
}

const MAX_LOGS = 600;
let logs: LogEntry[] = [];
let listeners: Set<() => void> = new Set();
let isInitialized = false;

function formatArg(arg: any): string {
  if (arg === null) return 'null';
  if (arg === undefined) return 'undefined';
  if (typeof arg === 'string') return arg;
  if (arg instanceof Error) return `${arg.name}: ${arg.message}\n${arg.stack || ''}`;
  try {
    return JSON.stringify(arg, null, 2);
  } catch (e) {
    return String(arg);
  }
}

function notifyListeners() {
  listeners.forEach((fn) => {
    try {
      fn();
    } catch (e) {
      // ignore listener error
    }
  });
}

export function addLog(level: LogLevel, args: any[], stack?: string) {
  const now = new Date();
  const timeStr = now.toTimeString().split(' ')[0] + '.' + String(now.getMilliseconds()).padStart(3, '0');
  const formattedText = args.map(formatArg).join(' ');

  const entry: LogEntry = {
    id: `${Date.now()}_${Math.random().toString(36).substring(2, 7)}`,
    timestamp: timeStr,
    timeMs: Date.now(),
    level,
    args,
    formattedText,
    stack,
  };

  logs.push(entry);
  if (logs.length > MAX_LOGS) {
    logs.shift();
  }

  notifyListeners();
}

export function initLogger() {
  if (isInitialized || typeof window === 'undefined') return;
  isInitialized = true;

  const originalLog = console.log;
  const originalInfo = console.info;
  const originalWarn = console.warn;
  const originalError = console.error;

  console.log = (...args: any[]) => {
    originalLog.apply(console, args);
    addLog('log', args);
  };

  console.info = (...args: any[]) => {
    originalInfo.apply(console, args);
    addLog('info', args);
  };

  console.warn = (...args: any[]) => {
    originalWarn.apply(console, args);
    addLog('warn', args);
  };

  console.error = (...args: any[]) => {
    originalError.apply(console, args);
    let stack: string | undefined = undefined;
    for (const arg of args) {
      if (arg instanceof Error && arg.stack) {
        stack = arg.stack;
        break;
      }
    }
    addLog('error', args, stack);
  };

  window.addEventListener('error', (event) => {
    addLog(
      'error',
      [`[Uncaught Error] ${event.message} at ${event.filename}:${event.lineno}:${event.colno}`, event.error],
      event.error?.stack
    );
  });

  window.addEventListener('unhandledrejection', (event) => {
    addLog(
      'error',
      [`[Unhandled Rejection] ${event.reason}`, event.reason],
      event.reason instanceof Error ? event.reason.stack : undefined
    );
  });

  console.info('[System Logger] 日志拦截器初始化完成，准备录入 APP 日志');
}

export function getLogs(): LogEntry[] {
  return [...logs];
}

export function clearLogs() {
  logs = [];
  notifyListeners();
}

export function subscribeLogs(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export async function copyLogsToClipboard(): Promise<boolean> {
  const text = logs
    .map((l) => `[${l.timestamp}] [${l.level.toUpperCase()}] ${l.formattedText}${l.stack ? '\n' + l.stack : ''}`)
    .join('\n\n----------------------------------------\n\n');

  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
    }
    return true;
  } catch (err) {
    console.error('Failed to copy logs:', err);
    return false;
  }
}
