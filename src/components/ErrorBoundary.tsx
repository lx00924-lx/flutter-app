/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { Component, ErrorInfo, ReactNode } from 'react';
import { RotateCcw, AlertTriangle, RefreshCw, Copy, Check, Sparkles } from 'lucide-react';
import { Button } from '@/components/ui/button';

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
  errorInfo: ErrorInfo | null;
  copied: boolean;
}

export class ErrorBoundary extends Component<Props, State> {
  public state: State = {
    hasError: false,
    error: null,
    errorInfo: null,
    copied: false
  };

  public static getDerivedStateFromError(error: Error): Partial<State> {
    return { hasError: true, error };
  }

  public componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error("Uncaught error in React Component Tree:", error, errorInfo);
    this.setState({ error, errorInfo });
  }

  private handleReload = () => {
    window.location.reload();
  };

  private handleSelfHealAndReset = () => {
    try {
      // 清除可能损坏的会话与状态缓存
      const keysToClean = [
        'app_user',
        'gemini_settings',
        'guest_messages',
        'app_theme'
      ];
      keysToClean.forEach(k => {
        try { localStorage.removeItem(k); } catch (_) {}
      });
      // 遍历清除所有包含 chat_messages_ 的旧键
      try {
        for (let i = 0; i < localStorage.length; i++) {
          const key = localStorage.key(i);
          if (key && (key.startsWith('chat_messages_') || key.startsWith('gemini_settings_'))) {
            localStorage.removeItem(key);
          }
        }
      } catch (_) {}
    } catch (e) {
      console.warn('Failed to clean localStorage in error boundary:', e);
    }
    
    // 强制刷新并重置 URL 参数
    window.location.href = window.location.origin + window.location.pathname;
  };

  private handleCopyError = async () => {
    const errorText = `[Error Details]\nMessage: ${this.state.error?.message || 'Unknown error'}\n\nStack:\n${this.state.error?.stack || 'No stack'}\n\nComponent Stack:\n${this.state.errorInfo?.componentStack || 'No component stack'}`;
    try {
      await navigator.clipboard.writeText(errorText);
      this.setState({ copied: true });
      setTimeout(() => this.setState({ copied: false }), 2000);
    } catch (e) {
      console.error('Failed to copy error to clipboard:', e);
    }
  };

  public render() {
    if (this.state.hasError) {
      return (
        <div className="min-h-screen min-h-[100dvh] w-full bg-background text-foreground flex items-center justify-center p-4 sm:p-6 select-text">
          <div className="w-full max-w-lg bg-card border border-border rounded-3xl p-6 sm:p-8 shadow-2xl flex flex-col items-center text-center space-y-5">
            <div className="w-16 h-16 rounded-2xl bg-destructive/10 text-destructive flex items-center justify-center border border-destructive/20 shadow-lg shadow-destructive/10 animate-pulse">
              <AlertTriangle size={32} />
            </div>

            <div className="space-y-1.5">
              <h1 className="text-xl sm:text-2xl font-bold tracking-tight">应用遇到异常</h1>
              <p className="text-sm text-muted-foreground">
                检测到页面初始化或渲染出现异常，已启动自动防护机制。
              </p>
            </div>

            {this.state.error && (
              <div className="w-full text-left bg-muted/60 border border-border/80 rounded-2xl p-3.5 max-h-36 overflow-y-auto text-xs font-mono text-muted-foreground whitespace-pre-wrap break-all">
                <span className="text-destructive font-semibold">
                  {this.state.error.name}: {this.state.error.message}
                </span>
                {this.state.error.stack && (
                  <div className="mt-1 opacity-70 text-[10px]">
                    {this.state.error.stack.split('\n').slice(1, 4).join('\n')}
                  </div>
                )}
              </div>
            )}

            <div className="w-full flex flex-col sm:flex-row gap-2.5 pt-2">
              <Button
                variant="outline"
                className="flex-1 h-11 rounded-xl gap-2 font-medium"
                onClick={this.handleReload}
              >
                <RefreshCw size={16} />
                刷新页面
              </Button>
              <Button
                variant="default"
                className="flex-1 h-11 rounded-xl gap-2 font-semibold shadow-lg shadow-primary/20"
                onClick={this.handleSelfHealAndReset}
              >
                <RotateCcw size={16} />
                一键自愈并重置
              </Button>
            </div>

            <div className="flex items-center gap-4 text-xs text-muted-foreground pt-1">
              <button
                type="button"
                onClick={this.handleCopyError}
                className="hover:text-primary transition-colors flex items-center gap-1.5"
              >
                {this.state.copied ? (
                  <>
                    <Check size={13} className="text-emerald-500" />
                    <span className="text-emerald-500">已复制错误日志</span>
                  </>
                ) : (
                  <>
                    <Copy size={13} />
                    <span>复制错误日志</span>
                  </>
                )}
              </button>
            </div>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}
