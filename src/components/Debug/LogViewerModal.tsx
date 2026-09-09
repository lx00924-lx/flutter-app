/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useState, useEffect, useRef } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  getLogs,
  clearLogs,
  subscribeLogs,
  copyLogsToClipboard,
  LogEntry,
  LogLevel,
} from '../../lib/logger';
import {
  Copy,
  Trash2,
  Search,
  X,
  Bug,
  Filter,
  Check,
  ChevronDown,
  ChevronRight,
  ArrowDown,
  RefreshCw,
  Terminal,
} from 'lucide-react';
import { cn } from '../../lib/utils';

interface LogViewerModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export const LogViewerModal: React.FC<LogViewerModalProps> = ({
  open,
  onOpenChange,
}) => {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [filterLevel, setFilterLevel] = useState<LogLevel | 'all'>('all');
  const [searchQuery, setSearchQuery] = useState('');
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const [autoScroll, setAutoScroll] = useState(true);
  const [copied, setCopied] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (open) {
      setLogs(getLogs());
      const unsubscribe = subscribeLogs(() => {
        setLogs(getLogs());
      });
      return () => unsubscribe();
    }
  }, [open]);

  useEffect(() => {
    if (open && autoScroll && listRef.current) {
      listRef.current.scrollTop = listRef.current.scrollHeight;
    }
  }, [logs, open, autoScroll]);

  const handleCopy = async () => {
    const success = await copyLogsToClipboard();
    if (success) {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    }
  };

  const handleClear = () => {
    clearLogs();
    setLogs([]);
  };

  const toggleExpand = (id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  };

  const filteredLogs = logs.filter((log) => {
    if (filterLevel !== 'all' && log.level !== filterLevel) {
      return false;
    }
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase();
      return (
        log.formattedText.toLowerCase().includes(q) ||
        log.timestamp.includes(q) ||
        log.level.toLowerCase().includes(q)
      );
    }
    return true;
  });

  const getLevelBadgeClass = (level: LogLevel) => {
    switch (level) {
      case 'error':
        return 'bg-red-500/15 text-red-600 dark:text-red-400 border-red-500/30';
      case 'warn':
        return 'bg-amber-500/15 text-amber-600 dark:text-amber-400 border-amber-500/30';
      case 'info':
        return 'bg-blue-500/15 text-blue-600 dark:text-blue-400 border-blue-500/30';
      case 'log':
      default:
        return 'bg-muted text-muted-foreground border-border';
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-4xl w-[95vw] h-[90vh] max-h-[850px] p-0 gap-0 bg-background border-border text-foreground flex flex-col overflow-hidden rounded-xl shadow-2xl">
        {/* Modal Header */}
        <DialogHeader className="p-3.5 sm:p-4 pr-10 border-b border-border bg-muted/30 flex flex-row items-center justify-between space-y-0">
          <div className="flex items-center gap-2 min-w-0">
            <div className="p-1.5 rounded-lg bg-emerald-500/10 border border-emerald-500/20 text-emerald-600 dark:text-emerald-400 shrink-0">
              <Terminal className="w-4 h-4 sm:w-5 sm:h-5" />
            </div>
            <DialogTitle className="text-base sm:text-lg font-mono font-semibold text-foreground flex items-center gap-2 whitespace-nowrap">
              APP 检修调试日志
              <span className="text-xs px-2 py-0.5 rounded-full bg-muted text-muted-foreground font-normal">
                {filteredLogs.length} / {logs.length} 条
              </span>
            </DialogTitle>
          </div>
        </DialogHeader>

        {/* Toolbar: Search and Filters */}
        <div className="p-2.5 sm:p-3 border-b border-border bg-muted/20 flex flex-wrap items-center gap-2 text-xs">
          {/* Search Input */}
          <div className="relative flex-1 min-w-[160px]">
            <Search className="w-3.5 h-3.5 absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="搜索日志关键字 / 状态码 / 接口..."
              className="pl-8 h-8 text-xs bg-background border-border text-foreground placeholder:text-muted-foreground focus:border-primary"
            />
            {searchQuery && (
              <button
                onClick={() => setSearchQuery('')}
                className="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
              >
                <X className="w-3.5 h-3.5" />
              </button>
            )}
          </div>

          {/* Level Filter Buttons */}
          <div className="flex items-center bg-muted/60 p-0.5 rounded-lg border border-border">
            {(['all', 'error', 'warn', 'info', 'log'] as const).map((lvl) => (
              <button
                key={lvl}
                onClick={() => setFilterLevel(lvl)}
                className={cn(
                  'px-2.5 py-1 rounded-md transition-all font-mono capitalize text-[11px]',
                  filterLevel === lvl
                    ? 'bg-background text-foreground font-semibold shadow-sm'
                    : 'text-muted-foreground hover:text-foreground'
                )}
              >
                {lvl}
              </button>
            ))}
          </div>

          {/* Auto scroll toggle */}
          <button
            onClick={() => setAutoScroll(!autoScroll)}
            className={cn(
              'h-8 px-2.5 rounded-lg border flex items-center gap-1.5 transition-colors text-[11px]',
              autoScroll
                ? 'bg-emerald-500/10 border-emerald-500/30 text-emerald-600 dark:text-emerald-400 font-medium'
                : 'bg-background border-border text-muted-foreground hover:text-foreground'
            )}
            title="新日志产生时自动滚动到底部"
          >
            <ArrowDown className="w-3 h-3" />
            <span>自动滚动</span>
          </button>

          {/* Actions: Copy and Clear */}
          <div className="flex items-center gap-1.5 ml-auto sm:ml-0">
            <Button
              variant="outline"
              size="sm"
              onClick={handleCopy}
              className="h-8 px-2.5 text-xs bg-background hover:bg-muted border-border text-foreground gap-1.5"
            >
              {copied ? (
                <>
                  <Check className="w-3.5 h-3.5 text-emerald-500" />
                  <span className="text-emerald-500 font-medium">已复制</span>
                </>
              ) : (
                <>
                  <Copy className="w-3.5 h-3.5" />
                  <span>复制全部</span>
                </>
              )}
            </Button>

            <Button
              variant="outline"
              size="sm"
              onClick={handleClear}
              className="h-8 px-2.5 text-xs bg-background hover:bg-destructive/10 border-border hover:border-destructive/30 text-foreground hover:text-destructive gap-1.5"
            >
              <Trash2 className="w-3.5 h-3.5" />
              <span>清空</span>
            </Button>
          </div>
        </div>

        {/* Logs List Console */}
        <div
          ref={listRef}
          className="flex-1 overflow-y-auto p-3 font-mono text-xs space-y-1.5 bg-background scrollbar-thin"
        >
          {filteredLogs.length === 0 ? (
            <div className="h-full min-h-[200px] flex flex-col items-center justify-center text-muted-foreground gap-2">
              <Bug className="w-8 h-8 opacity-40" />
              <p>暂无符合条件的运行日志</p>
            </div>
          ) : (
            filteredLogs.map((log) => {
              const isExpanded = expandedIds.has(log.id);
              return (
                <div
                  key={log.id}
                  className={cn(
                    'group rounded-lg border p-2 transition-all',
                    log.level === 'error'
                      ? 'bg-red-500/10 dark:bg-red-950/20 border-red-500/30 text-red-900 dark:text-red-200 hover:bg-red-500/15'
                      : log.level === 'warn'
                      ? 'bg-amber-500/10 dark:bg-amber-950/20 border-amber-500/30 text-amber-900 dark:text-amber-200 hover:bg-amber-500/15'
                      : 'bg-card border-border text-card-foreground hover:bg-muted/50'
                  )}
                >
                  <div
                    onClick={() => toggleExpand(log.id)}
                    className="flex items-start gap-2 cursor-pointer select-text"
                  >
                    <button className="mt-0.5 text-muted-foreground group-hover:text-foreground transition-colors">
                      {isExpanded ? (
                        <ChevronDown className="w-3.5 h-3.5" />
                      ) : (
                        <ChevronRight className="w-3.5 h-3.5" />
                      )}
                    </button>

                    <span className="text-muted-foreground shrink-0 text-[11px] font-sans">
                      {log.timestamp}
                    </span>

                    <span
                      className={cn(
                        'px-1.5 py-0.2 rounded border text-[10px] uppercase font-bold shrink-0',
                        getLevelBadgeClass(log.level)
                      )}
                    >
                      {log.level}
                    </span>

                    <div className="flex-1 min-w-0 break-all whitespace-pre-wrap leading-relaxed">
                      {log.formattedText}
                    </div>
                  </div>

                  {/* Expanded Detail View */}
                  {isExpanded && (
                    <div className="mt-2 pt-2 border-t border-border text-[11px] space-y-2 text-muted-foreground pl-6">
                      {log.args.length > 0 && (
                        <div>
                          <div className="text-muted-foreground mb-1 font-sans text-[10px] uppercase tracking-wider">
                            原始参数 (Args count: {log.args.length})
                          </div>
                          {log.args.map((arg, idx) => (
                            <pre
                              key={idx}
                              className="p-2 rounded bg-muted/80 border border-border overflow-x-auto text-foreground text-[10px] mb-1.5"
                            >
                              {typeof arg === 'object'
                                ? JSON.stringify(arg, null, 2)
                                : String(arg)}
                            </pre>
                          ))}
                        </div>
                      )}

                      {log.stack && (
                        <div>
                          <div className="text-red-500/80 dark:text-red-400/80 mb-1 font-sans text-[10px] uppercase tracking-wider">
                            调用堆栈 (Stack Trace)
                          </div>
                          <pre className="p-2 rounded bg-red-500/10 dark:bg-red-950/30 border border-red-500/20 dark:border-red-900/40 overflow-x-auto text-red-700 dark:text-red-300 text-[10px] leading-normal">
                            {log.stack}
                          </pre>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              );
            })
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
};

export const DebugFloatButton: React.FC<{ onClick: () => void }> = ({
  onClick,
}) => {
  return (
    <button
      onClick={onClick}
      className="fixed bottom-20 right-4 z-50 p-2.5 rounded-full bg-card/90 hover:bg-muted border border-border text-emerald-600 dark:text-emerald-400 shadow-xl backdrop-blur active:scale-95 transition-all flex items-center gap-1.5 group"
      title="点击打开 APP 检修调试日志"
    >
      <Bug className="w-4 h-4 text-emerald-600 dark:text-emerald-400 group-hover:rotate-12 transition-transform" />
      <span className="text-[11px] font-mono font-medium pr-1 text-foreground">
        日志
      </span>
    </button>
  );
};
