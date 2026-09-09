/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React from 'react';
import ReactMarkdown from 'react-markdown';
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter';
import { oneDark } from 'react-syntax-highlighter/dist/esm/styles/prism';
import { Message, AppSettings } from '../../types';
import { cn, formatMessageDate } from '../../lib/utils';
import { Avatar, AvatarFallback, AvatarImage } from '../ui/avatar';
import { motion, AnimatePresence } from 'motion/react';
import { Bot, User, Mic, CheckCircle2, Circle, Play, Pause, Copy, Quote, Languages, RefreshCcw, Target, Trash2, ChevronDown, Square, AlertCircle } from 'lucide-react';
import { API_BASE_URL } from '../../config';
import { Clipboard } from '@capacitor/clipboard';
import { Toast } from '@capacitor/toast';

interface VoiceMessagePlayerProps {
  url: string;
  onReplay?: (play: () => void) => void;
}

const VoiceMessagePlayer: React.FC<VoiceMessagePlayerProps> = ({ url, onReplay }) => {
  const audioRef = React.useRef<HTMLAudioElement>(null);
  const [isPlaying, setIsPlaying] = React.useState(false);
  const [duration, setDuration] = React.useState<number | null>(null);
  const [currentTime, setCurrentTime] = React.useState(0);

  React.useEffect(() => {
    if (onReplay && audioRef.current) {
      onReplay(() => {
        if (audioRef.current) {
          audioRef.current.currentTime = 0;
          audioRef.current.play();
        }
      });
    }
  }, [onReplay]);

  const formatTime = (time: number) => {
    const minutes = Math.floor(time / 60);
    const seconds = Math.floor(time % 60);
    return `${minutes}:${seconds.toString().padStart(2, '0')}`;
  };

  React.useEffect(() => {
    let interval: number;
    if (isPlaying) {
      interval = window.setInterval(() => {
        if (audioRef.current) {
          setCurrentTime(audioRef.current.currentTime);
        }
      }, 1000 / 240); // 240 FPS Target (approx 4.16ms)
    }
    return () => {
      if (interval) clearInterval(interval);
    };
  }, [isPlaying]);

  const togglePlay = (e: React.MouseEvent) => {
    e.stopPropagation();
    if (audioRef.current) {
      if (audioRef.current.paused) {
        audioRef.current.play();
      } else {
        audioRef.current.pause();
      }
    }
  };

  const onLoadedMetadata = () => {
    if (audioRef.current) {
      setDuration(audioRef.current.duration);
    }
  };

  const onEnded = () => {
    setIsPlaying(false);
    setCurrentTime(0);
  };

  const progress = duration ? (currentTime / duration) * 100 : 0;

  return (
    <div 
      className="flex items-center gap-3 py-1 cursor-pointer group/voice"
      onClick={togglePlay}
    >
      <div className="w-9 h-9 rounded-full bg-primary/10 flex items-center justify-center group-active/voice:scale-90 transition-transform">
        {isPlaying ? (
          <Pause size={16} className="text-primary fill-primary/20" />
        ) : (
          <Play size={16} className="text-primary translate-x-0.5 fill-primary/20" />
        )}
      </div>
      <div className="flex flex-col gap-1 min-w-32">
        <div className="relative flex items-center h-4 w-full">
          <div className="absolute inset-0 flex items-center justify-between pointer-events-none overflow-hidden">
            {[...Array(18)].map((_, i) => (
              <div 
                key={i} 
                className={cn(
                  "w-0.5 rounded-full transition-colors",
                  progress >= (i / 17) * 100 ? "bg-primary" : "bg-primary/20"
                )}
                style={{ 
                  height: `${4 + (Math.sin(i * 0.8) + 1) * 5}px`,
                }} 
              />
            ))}
          </div>
          
          {/* Moving progress bar */}
          <div 
            className="absolute top-0 bottom-0 w-[1.5px] bg-primary shadow-[0_0_8px_#00D2FF] z-10"
            style={{ 
              left: `${progress}%`,
              transform: 'translateX(-50%)',
              transition: 'none'
            }}
          />
        </div>
        <div className="flex justify-end items-center px-0.5">
          <span className="text-[10px] font-medium text-muted-foreground/60">
            {duration ? formatTime(duration) : '--:--'}
          </span>
        </div>
      </div>
      <audio 
        ref={audioRef}
        src={url} 
        onPlay={() => setIsPlaying(true)}
        onPause={() => setIsPlaying(false)}
        onEnded={onEnded}
        onLoadedMetadata={onLoadedMetadata}
        className="hidden" 
      />
    </div>
  );
};

const QuoteDisplay: React.FC<{ quote: Message['quote']; onLocate?: (id: string) => void }> = ({ quote, onLocate }) => {
  if (!quote) return null;
  return (
    <div className="mb-2 p-2 rounded-lg bg-black/5 dark:bg-white/5 border-l-2 border-primary/50 text-xs text-muted-foreground italic relative group/quote">
      <div className="flex items-center justify-between mb-0.5">
        <span className="font-semibold not-italic text-primary/70">{quote.userName}</span>
        <div className="flex items-center gap-2">
           <span className="text-[10px] opacity-60 not-italic font-normal">{formatMessageDate(quote.timestamp)}</span>
           <button 
             onClick={(e) => {
               e.stopPropagation();
               onLocate?.(quote.id);
             }}
             className="p-1 rounded-md hover:bg-primary/20 text-primary opacity-0 group-hover/quote:opacity-100 transition-opacity"
             title="点击定位到引用消息"
           >
             <Target size={12} />
           </button>
        </div>
      </div>
      <div className="line-clamp-2">
        {quote.content}
      </div>
    </div>
  );
};

const HighlightedText: React.FC<{ text: string; query: string; isActive?: boolean }> = ({ text, query, isActive }) => {
  if (!query.trim()) return <>{text}</>;
  
  const parts = text.split(new RegExp(`(${query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'gi'));
  
  return (
    <>
      {parts.map((part, i) => 
        part.toLowerCase() === query.toLowerCase() 
          ? <span 
              key={i} 
              className={cn(
                "rounded-sm px-0.5 leading-none inline-block transition-colors duration-200",
                isActive 
                  ? "bg-orange-500/30 text-orange-600 font-black border-b border-orange-500/60 ring-1 ring-orange-500/20" 
                  : "bg-primary/20 text-primary font-bold border-b border-primary/40"
              )}
            >
              {part}
            </span> 
          : part
      )}
    </>
  );
};

interface MessageListProps {
  messages: Message[];
  isLoading: boolean;
  settings: AppSettings;
  isSelectionMode: boolean;
  isSearching: boolean;
  searchQuery?: string;
  activeSearchMatchId?: string;
  selectedIds: string[];
  onToggleSelection: (id: string) => void;
  onEnterSelectionMode: (id: string) => void;
  onQuote?: (message: Message) => void;
  onTranscribe?: (message: Message) => void;
  onDelete?: (id: string) => void;
  onResendMessage?: (id: string) => void;
}

const MessageItem: React.FC<{
  message: Message;
  isSelected: boolean;
  isSelectionMode: boolean;
  isSearching: boolean;
  searchQuery: string;
  activeSearchMatchId?: string;
  highlightMessageId: string | null;
  contextMenuId?: string;
  settings: AppSettings;
  onMouseDown: (e: React.MouseEvent, id: string) => void;
  onMouseUp: () => void;
  onMouseEnter: (id: string) => void;
  onTouchStart: (e: React.TouchEvent, id: string) => void;
  onTouchEnd: () => void;
  onClick: (id: string) => void;
  scrollToMessage: (id: string) => void;
  messageRef?: (el: HTMLDivElement | null) => void;
  onRegisterReplay?: (id: string, play: () => void) => void;
  onResendMessage?: (id: string) => void;
}> = ({
  message,
  isSelected,
  isSelectionMode,
  isSearching,
  searchQuery,
  activeSearchMatchId,
  highlightMessageId,
  contextMenuId,
  settings,
  onMouseDown,
  onMouseUp,
  onMouseEnter,
  onTouchStart,
  onTouchEnd,
  onClick,
  scrollToMessage,
  messageRef,
  onRegisterReplay,
  onResendMessage
}) => {
  // 动态字号样式映射
  const fontSizeClasses = {
    sm: "text-[13px] leading-relaxed",
    base: "text-[14px] sm:text-[15px] leading-relaxed",
    lg: "text-[15px] sm:text-[16px] leading-relaxed",
    xl: "text-[17px] sm:text-[18px] leading-relaxed",
  };
  const activeFontSizeClass = fontSizeClasses[settings.chatFontSize || 'base'] || fontSizeClasses.base;

  return (
    <motion.div
      key={message.id}
      ref={messageRef}
      data-message-id={message.id}
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      onMouseDown={(e) => onMouseDown(e, message.id)}
      onMouseUp={onMouseUp}
      onMouseEnter={() => onMouseEnter(message.id)}
      onTouchStart={(e) => onTouchStart(e, message.id)}
      onTouchEnd={onTouchEnd}
      onClick={() => onClick(message.id)}
      className={cn(
        "flex w-full gap-2.5 sm:gap-3 transition-all duration-300 rounded-xl px-1 py-0.5 relative",
        message.role === 'user' ? "flex-row-reverse" : "flex-row",
        isSelectionMode && "cursor-pointer active:scale-[0.98]",
        isSelected && "opacity-100 scale-[1.02]",
        highlightMessageId === message.id && "animate-pulse-highlight",
        contextMenuId === message.id && "z-[65]"
      )}
    >
      {isSelectionMode && (
        <div className="flex items-center justify-center px-2">
          {isSelected ? (
            <CheckCircle2 className="text-primary size-5 fill-primary/10" />
          ) : (
            <Circle className="text-muted-foreground/30 size-5" />
          )}
        </div>
      )}

      {message.role === 'assistant' && (
        <Avatar className="w-8 h-8 border border-border shrink-0 mt-0.5">
          {settings.aiAvatar && <AvatarImage src={settings.aiAvatar} />}
          <AvatarFallback><Bot size={16} /></AvatarFallback>
        </Avatar>
      )}

      {message.role === 'user' && (
        <Avatar className="w-8 h-8 border border-border shrink-0 mt-0.5">
          {settings.userAvatar && <AvatarImage src={settings.userAvatar} />}
          <AvatarFallback><User size={16} /></AvatarFallback>
        </Avatar>
      )}

      <div className={cn(
        "flex flex-col max-w-[90%] sm:max-w-[85%] md:max-w-[78%] transition-opacity",
        message.role === 'user' ? "items-end" : "items-start",
        isSelectionMode && !isSelected && "opacity-50"
      )}>
        <div className="flex items-center gap-2 mb-0.5 px-1">
          <span className="text-[10px] font-medium text-muted-foreground tracking-wider select-none">
            {message.role === 'assistant' ? settings.aiName : settings.userName}
          </span>
        </div>
        <div className={cn(
          "px-3.5 py-2.5 sm:px-4 sm:py-3 rounded-[16px] sm:rounded-[18px] transition-all relative overflow-hidden select-text break-words",
          activeFontSizeClass,
          message.role === 'user' 
            ? "bg-white dark:bg-card border border-border text-black dark:text-foreground" 
            : "bg-white dark:bg-card border border-border text-black dark:text-foreground",
          isSelected && "ring-2 ring-primary/50 border-primary/50 shadow-lg shadow-primary/10",
          contextMenuId === message.id && "ring-2 ring-primary/30 scale-[0.99]"
        )}>
          <QuoteDisplay quote={message.quote} onLocate={scrollToMessage} />

          {message.type === 'image' && message.mediaUrl && (
            <div className="relative group/image overflow-hidden rounded-lg mb-2 bg-muted/20">
              <img 
                src={message.mediaUrl} 
                alt="Uploaded" 
                className="rounded-lg max-w-full h-auto cursor-zoom-in transition-transform group-hover/image:scale-[1.01] active:scale-95"
                referrerPolicy="no-referrer"
                loading="lazy"
                onClick={() => window.open(message.mediaUrl, '_blank')}
                onError={(e) => {
                  const target = e.target as HTMLImageElement;
                  if (!target.dataset.retried) {
                    target.dataset.retried = 'true';
                    target.src = `${message.mediaUrl}?t=${Date.now()}`;
                  } else {
                    target.style.display = 'none';
                    console.error("Image render error");
                  }
                }}
              />
              <div className="absolute bottom-2 right-2 opacity-0 group-hover/image:opacity-100 transition-opacity bg-black/50 backdrop-blur-md text-[10px] text-white px-2 py-1 rounded-md pointer-events-none">
                查看原图 (4K+)
              </div>
            </div>
          )}
          
          {message.type === 'voice' && message.mediaUrl && (
            <>
              <VoiceMessagePlayer 
                url={message.mediaUrl} 
                onReplay={(play) => onRegisterReplay?.(message.id, play)}
              />
              {message.transcribedText && (
                <div className="mt-3 pt-3 border-t border-border/30 text-xs italic text-muted-foreground/80 leading-relaxed font-mono">
                   <Languages size={10} className="inline mr-1 opacity-50" />
                   {message.transcribedText}
                </div>
              )}
            </>
          )}

          {/* Agent Mode Execution Details */}
          {message.role === 'assistant' && (message.isAgentMode || message.agentExecution) && (
            <div className="mb-2.5 w-full">
              <div className="flex items-center gap-1.5 text-[11px] font-semibold text-primary mb-1 select-none">
                <Bot size={13} className={cn(message.agentExecution?.status === 'running' && "animate-pulse")} />
                <span>DeepSeek Harness 本地智能体协同</span>
                {message.agentExecution?.status === 'running' && (
                  <span className="text-[10px] text-primary bg-primary/10 px-1.5 py-0.5 rounded-full font-normal flex items-center gap-1 animate-pulse">
                    执行中
                  </span>
                )}
                {message.agentExecution?.status === 'waiting_approval' && (
                  <span className="text-[10px] text-amber-500 bg-amber-500/15 border border-amber-500/30 px-1.5 py-0.5 rounded-full font-medium flex items-center gap-1 animate-pulse">
                    ⚠️ 等待您的审批
                  </span>
                )}
                {message.agentExecution?.status === 'completed' && (
                  <span className="text-[10px] text-emerald-500 bg-emerald-500/10 px-1.5 py-0.5 rounded-full font-normal">已完成</span>
                )}
                {message.agentExecution?.status === 'failed' && (
                  <span className="text-[10px] text-amber-500 bg-amber-500/10 px-1.5 py-0.5 rounded-full font-normal">异常提示</span>
                )}

                {(message.agentExecution?.status === 'running' || message.agentExecution?.status === 'waiting_approval') && message.agentExecution.taskId && (
                  <button
                    type="button"
                    onClick={async (e) => {
                      e.stopPropagation();
                      try {
                        await fetch(`${API_BASE_URL}/api/agent/cancel-task`, {
                          method: 'POST',
                          headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({ taskId: message.agentExecution!.taskId, token: settings.agentToken })
                        });
                        Toast.show({ text: '已向本地 DSH 发起中止指令' });
                      } catch (err) {
                        console.error('Failed to cancel task:', err);
                      }
                    }}
                    className="ml-auto text-[10px] text-destructive hover:bg-destructive/10 border border-destructive/30 px-1.5 py-0.5 rounded flex items-center gap-1 font-medium transition-colors cursor-pointer"
                    title="中止当前本地智能体执行 (POST /v1/sessions/:id/abort)"
                  >
                    <Square size={8} className="fill-destructive" />
                    中止任务
                  </button>
                )}
              </div>

              {/* Waiting Approval Card */}
              {message.agentExecution?.waitingApproval && (
                <div className="my-2 p-3 bg-amber-500/10 dark:bg-amber-950/30 border border-amber-500/40 rounded-xl text-xs space-y-2 shadow-sm animate-in fade-in duration-200">
                  <div className="flex items-center gap-1.5 font-semibold text-amber-600 dark:text-amber-400">
                    <AlertCircle size={14} className="shrink-0" />
                    <span>本地敏感操作审批请求</span>
                  </div>
                  <div className="text-foreground/90 text-[11px] leading-relaxed bg-background/50 p-2 rounded-lg border border-amber-500/20 font-mono">
                    <div className="font-semibold text-amber-700 dark:text-amber-300 mb-0.5">
                      操作: {message.agentExecution.waitingApproval.actionType}
                    </div>
                    <div>{message.agentExecution.waitingApproval.description}</div>
                  </div>
                  <div className="flex items-center justify-end gap-2 pt-1">
                    <button
                      type="button"
                      onClick={async () => {
                        try {
                          await fetch(`${API_BASE_URL}/api/agent/approve`, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({
                              taskId: message.agentExecution!.taskId,
                              approvalId: message.agentExecution!.waitingApproval!.approvalId,
                              action: 'deny',
                              token: settings.agentToken
                            })
                          });
                          Toast.show({ text: '已拒绝该操作' });
                        } catch (e) {
                          console.error(e);
                        }
                      }}
                      className="px-2.5 py-1 text-[11px] font-medium rounded-lg border border-border bg-background hover:bg-muted text-foreground/80 hover:text-foreground transition-colors cursor-pointer"
                    >
                      拒绝操作
                    </button>
                    <button
                      type="button"
                      onClick={async () => {
                        try {
                          await fetch(`${API_BASE_URL}/api/agent/approve`, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({
                              taskId: message.agentExecution!.taskId,
                              approvalId: message.agentExecution!.waitingApproval!.approvalId,
                              action: 'allow',
                              token: settings.agentToken
                            })
                          });
                          Toast.show({ text: '已批准执行' });
                        } catch (e) {
                          console.error(e);
                        }
                      }}
                      className="px-3 py-1 text-[11px] font-medium rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white shadow-sm transition-colors cursor-pointer"
                    >
                      批准执行
                    </button>
                  </div>
                </div>
              )}
              {message.agentExecution?.steps && message.agentExecution.steps.length > 0 && (
                <details className="group/agent border border-primary/25 bg-primary/5 rounded-xl text-xs overflow-hidden my-1 shadow-sm">
                  <summary className="px-2.5 py-1.5 flex items-center justify-between cursor-pointer select-none text-[11px] font-medium text-foreground/90 hover:bg-primary/10 transition-colors">
                    <span className="flex items-center gap-1.5">
                      <span className="w-1.5 h-1.5 rounded-full bg-primary" />
                      本地智能体执行链路 ({message.agentExecution.steps.length} 步操作)
                    </span>
                    <ChevronDown size={12} className="transition-transform group-open/agent:rotate-180 text-muted-foreground" />
                  </summary>
                  <div className="p-2.5 pt-1.5 space-y-1 border-t border-primary/15 text-[11px] font-mono text-muted-foreground bg-background/60">
                    {message.agentExecution.steps.map((st, i) => (
                      <div key={i} className="flex items-start gap-1.5">
                        <span className="text-primary select-none shrink-0 font-bold">›</span>
                        <span className="break-all text-foreground/80">{st}</span>
                      </div>
                    ))}
                    {message.agentExecution.rawOutput && (() => {
                      const rawOutputText = typeof message.agentExecution.rawOutput === 'string'
                        ? message.agentExecution.rawOutput
                        : JSON.stringify(message.agentExecution.rawOutput, null, 2);
                      return (
                        <div className="mt-2 pt-2 border-t border-border/50 text-[10px]">
                          <div className="text-muted-foreground font-semibold mb-1">本地 Harness 产出摘要:</div>
                          <div className="max-h-32 overflow-y-auto whitespace-pre-wrap bg-muted/50 p-2 rounded-lg text-foreground/90 font-mono select-text border border-border/40">
                            {rawOutputText.slice(0, 600)}
                            {rawOutputText.length > 600 ? '...' : ''}
                          </div>
                        </div>
                      );
                    })()}
                  </div>
                </details>
              )}
            </div>
          )}

              {message.content && (
                <div className={cn(
                  "prose prose-sm dark:prose-invert max-w-none",
                  (message.type === 'image' || message.type === 'voice') && "mt-2 pt-2 border-t border-border/50"
                )}>
                  {isSearching ? (
                    <div className="whitespace-pre-wrap">
                      <HighlightedText 
                        text={message.content} 
                        query={searchQuery} 
                        isActive={message.id === activeSearchMatchId}
                      />
                    </div>
                  ) : (
                    <ReactMarkdown
                      components={{
                        code({ node, inline, className, children, ...props }: any) {
                          const match = /language-(\w+)/.exec(className || '');
                          return !inline && match ? (
                            <SyntaxHighlighter
                              style={oneDark}
                              language={match[1]}
                              PreTag="div"
                              {...props}
                            >
                              {String(children).replace(/\n$/, '')}
                            </SyntaxHighlighter>
                          ) : (
                            <code className={className} {...props}>
                              {children}
                            </code>
                          );
                        },
                      }}
                    >
                      {message.content}
                    </ReactMarkdown>
                  )}
                </div>
              )}
        </div>
        <span className="text-[10px] text-muted-foreground mt-1 px-1 select-none">
          {formatMessageDate(message.timestamp)}
        </span>
      </div>

      {message.role === 'user' && message.status === 'error' && (
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            onResendMessage?.(message.id);
          }}
          className="self-center p-1.5 text-red-500 hover:text-red-600 hover:bg-red-50 dark:hover:bg-red-950/30 rounded-full transition-colors cursor-pointer"
          title="发送失败，点击重新发送"
        >
          <AlertCircle className="w-5 h-5 text-red-500 animate-pulse" />
        </button>
      )}
    </motion.div>
  );
};

export const MessageList: React.FC<MessageListProps> = ({ 
  messages, 
  isLoading, 
  settings,
  isSelectionMode,
  isSearching,
  searchQuery = '',
  activeSearchMatchId,
  selectedIds,
  onToggleSelection,
  onEnterSelectionMode,
  onQuote,
  onTranscribe,
  onDelete,
  onResendMessage
}) => {
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const longPressTimer = React.useRef<NodeJS.Timeout | null>(null);
  const [isDragging, setIsDragging] = React.useState(false);
  const [contextMenu, setContextMenu] = React.useState<{ id: string; x: number; y: number } | null>(null);
  const contextMenuRef = React.useRef<{ id: string; x: number; y: number } | null>(null);
  const [highlightMessageId, setHighlightMessageId] = React.useState<string | null>(null);
  const messageRefs = React.useRef<{ [key: string]: HTMLDivElement | null }>({});
  const replayRefs = React.useRef<{ [key: string]: () => void }>({});
  const lastSelectedId = React.useRef<string | null>(null);
  const touchStartPos = React.useRef<{ x: number; y: number } | null>(null);

  React.useEffect(() => {
    const handleSelectionChange = () => {
      const selection = window.getSelection();
      if (!selection) return;
      
      const hasSelection = selection.type === 'Range' && selection.toString().length > 0;

      if (hasSelection) {
        setContextMenu(null);
      } else {
        // Selection is cancelled or no text selected
        setContextMenu(null);
        contextMenuRef.current = null;
      }
    };
    
    const handleRelease = () => {
       // On release, if a selection exists, restore menu
       const selection = window.getSelection();
       if (selection && selection.toString().length > 0 && contextMenuRef.current && !contextMenu) {
           setContextMenu(contextMenuRef.current);
       }
    };
    
    document.addEventListener('selectionchange', handleSelectionChange);
    window.addEventListener('mouseup', handleRelease);
    window.addEventListener('touchend', handleRelease);
    
    return () => {
        document.removeEventListener('selectionchange', handleSelectionChange);
        window.removeEventListener('mouseup', handleRelease);
        window.removeEventListener('touchend', handleRelease);
    }
  }, [contextMenu]);

  const scrollToMessage = (id: string) => {
    const element = messageRefs.current[id];
    if (element) {
      element.scrollIntoView({ behavior: 'smooth', block: 'center' });
      setHighlightMessageId(id);
      setTimeout(() => setHighlightMessageId(null), 2000);
    } else {
      Toast.show({ text: '找不到原消息' });
    }
  };

  const selectAllText = (id: string) => {
    const el = messageRefs.current[id];
    if (el) {
       // 查找消息内容容器以便精确定位
       const contentEl = el.querySelector('.prose');
       if (contentEl) {
         const selection = window.getSelection();
         // 增加检查：如果已经有文本被选中，不强制全选
         if (selection && selection.toString().length > 0) return;
         
         const range = document.createRange();
         range.selectNodeContents(contentEl);
         selection?.removeAllRanges();
         selection?.addRange(range);
       }
    }
  };

  const handleCopy = async (text: string) => {
    await Clipboard.write({ string: text });
    await Toast.show({ text: '已复制到剪贴板' });
    setContextMenu(null);
  };

  const handleQuoteClick = (message: Message) => {
    onQuote?.(message);
    setContextMenu(null);
  };

  const handleTranscribeClick = (message: Message) => {
    onTranscribe?.(message);
    setContextMenu(null);
  };

  const handleReplayClick = (id: string) => {
    replayRefs.current[id]?.();
    setContextMenu(null);
  };

  const handleDeleteClick = (id: string) => {
    onDelete?.(id);
    setContextMenu(null);
  };

  const handleMouseDown = (e: React.MouseEvent, id: string) => {
    if (isSelectionMode) {
      if (isSearching) {
        setIsDragging(true);
      }
      lastSelectedId.current = id;
      onToggleSelection(id);
      return;
    }
    
    // Check if text is currently selected
    if (window.getSelection()?.toString()) {
        return;
    }

    const x = e.clientX;
    const y = e.clientY;
    touchStartPos.current = { x, y };

    longPressTimer.current = setTimeout(() => {
        // Automatically select text and show menu
        selectAllText(id);
        
        if (isSearching) {
          onEnterSelectionMode(id);
          setIsDragging(true);
          lastSelectedId.current = id;
        } else {
          const menuData = { id, x, y };
          setContextMenu(menuData);
          contextMenuRef.current = menuData;
        }
        touchStartPos.current = null;
    }, 600);
  };

  const handleTouchStart = (e: React.TouchEvent, id: string) => {
    if (isSelectionMode) return;
    
    // Check if text is currently selected
    if (window.getSelection()?.toString()) {
        return;
    }
    
    const touch = e.touches[0];
    const x = touch.clientX;
    const y = touch.clientY;
    touchStartPos.current = { x, y };

    longPressTimer.current = setTimeout(() => {
        // Automatically select text and show menu
        selectAllText(id);
        
        if (isSearching) {
          onEnterSelectionMode(id);
          setIsDragging(true);
          lastSelectedId.current = id;
        } else {
          const menuData = { id, x, y };
          setContextMenu(menuData);
          contextMenuRef.current = menuData;
        }
        touchStartPos.current = null;
    }, 600);
  };

  const handleTouchEnd = () => {
    if (longPressTimer.current) {
      clearTimeout(longPressTimer.current);
      longPressTimer.current = null;
    }
    touchStartPos.current = null;
    setIsDragging(false);
    lastSelectedId.current = null;
  };

  const handleClick = (id: string) => {
    if (isSelectionMode) {
      onToggleSelection(id);
    }
  };

  const handleMouseEnter = (id: string) => {
    if (isDragging && isSelectionMode && lastSelectedId.current !== id) {
      onToggleSelection(id);
      lastSelectedId.current = id;
    }
  };

  const handleTouchMove = (e: React.TouchEvent) => {
    if (longPressTimer.current && touchStartPos.current) {
      const touch = e.touches[0];
      const dx = Math.abs(touch.clientX - touchStartPos.current.x);
      const dy = Math.abs(touch.clientY - touchStartPos.current.y);
      if (dx > 10 || dy > 10) {
        clearTimeout(longPressTimer.current);
        longPressTimer.current = null;
        touchStartPos.current = null;
      }
    }

    if (!isDragging || !isSelectionMode) return;
    
    const touch = e.touches[0];
    const element = document.elementFromPoint(touch.clientX, touch.clientY);
    const messageElement = element?.closest('[data-message-id]');
    
    if (messageElement) {
      const id = messageElement.getAttribute('data-message-id');
      if (id && lastSelectedId.current !== id) {
        onToggleSelection(id);
        lastSelectedId.current = id;
      }
    }
  };

  React.useEffect(() => {
    const handleGlobalMouseUp = () => {
      setIsDragging(false);
      lastSelectedId.current = null;
    };
    window.addEventListener('mouseup', handleGlobalMouseUp);
    return () => window.removeEventListener('mouseup', handleGlobalMouseUp);
  }, []);

  const isFirstScroll = React.useRef(true);
  const isNavigatingSearchMatch = React.useRef(false);
  const prevIsSearching = React.useRef(isSearching);

  React.useEffect(() => {
    const searchStatusChanged = prevIsSearching.current !== isSearching;
    const searchCancelled = prevIsSearching.current && !isSearching;
    const isFirst = isFirstScroll.current;
    
    // Update the ref for next render
    prevIsSearching.current = isSearching;

    const scrollToBottom = () => {
      if (scrollRef.current && !isSelectionMode && !isNavigatingSearchMatch.current) {
        // Use instant scroll if it's the first scroll OR if search status just changed (on/off)
        const shouldBeInstant = isFirst || searchStatusChanged;
        
        scrollRef.current.scrollTo({
          top: scrollRef.current.scrollHeight,
          behavior: shouldBeInstant ? 'auto' : 'smooth'
        });
        
        if (isFirst) isFirstScroll.current = false;
      }
    };
    
    // Use a slightly longer delay if search cancelled to ensure DOM is fully updated
    const timeoutId = setTimeout(scrollToBottom, (isFirst || searchStatusChanged) ? 0 : 100);
    return () => clearTimeout(timeoutId);
  }, [messages, isLoading, isSelectionMode, isSearching]);

  // Scroll to search match
  React.useEffect(() => {
    if (isSearching && activeSearchMatchId) {
      isNavigatingSearchMatch.current = true;
      const element = messageRefs.current[activeSearchMatchId];
      if (element) {
        element.scrollIntoView({ behavior: 'smooth', block: 'center' });
        setHighlightMessageId(activeSearchMatchId);
        
        // Allow auto-scroll again after a delay
        const timer = setTimeout(() => {
          isNavigatingSearchMatch.current = false;
          setHighlightMessageId(null);
        }, 1500);
        return () => clearTimeout(timer);
      } else {
        isNavigatingSearchMatch.current = false;
      }
    } else {
      isNavigatingSearchMatch.current = false;
    }
  }, [activeSearchMatchId, isSearching]);

  return (
    <div 
      ref={scrollRef} 
        className="flex-1 overflow-y-auto px-2.5 py-2.5 sm:px-4 sm:py-3 space-y-2 sm:space-y-2.5 pb-20 sm:pb-24 overscroll-contain"
        onTouchMove={handleTouchMove}
      >
        {messages.map((message) => (
          <MessageItem
            key={message.id}
            message={message}
            isSelected={selectedIds.includes(message.id)}
            isSelectionMode={isSelectionMode}
            isSearching={isSearching}
            searchQuery={searchQuery}
            activeSearchMatchId={activeSearchMatchId}
            highlightMessageId={highlightMessageId}
            contextMenuId={contextMenu?.id}
            settings={settings}
            onMouseDown={handleMouseDown}
            onMouseUp={handleTouchEnd}
            onMouseEnter={handleMouseEnter}
            onTouchStart={handleTouchStart}
            onTouchEnd={handleTouchEnd}
            onClick={handleClick}
            scrollToMessage={scrollToMessage}
            messageRef={(el) => { messageRefs.current[message.id] = el; }}
            onRegisterReplay={(id, play) => { replayRefs.current[id] = play; }}
            onResendMessage={onResendMessage}
          />
        ))}
        
        {isLoading && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className="flex gap-3"
        >
          <Avatar className="w-8 h-8 border animate-pulse">
            {settings.aiAvatar && <AvatarImage src={settings.aiAvatar} />}
            <AvatarFallback><Bot size={16} /></AvatarFallback>
          </Avatar>
          <div className="bg-white dark:bg-muted border border-border dark:border-none px-4 py-3 rounded-2xl shadow-sm dark:shadow-none">
            <div className="flex gap-1">
              <span className="w-1.5 h-1.5 bg-foreground/30 rounded-full animate-bounce" style={{ animationDelay: '0ms' }} />
              <span className="w-1.5 h-1.5 bg-foreground/30 rounded-full animate-bounce" style={{ animationDelay: '150ms' }} />
              <span className="w-1.5 h-1.5 bg-foreground/30 rounded-full animate-bounce" style={{ animationDelay: '300ms' }} />
            </div>
          </div>
        </motion.div>
      )}

      {/* Context Menu Overlay */}
      <AnimatePresence>
        {contextMenu && (
          <>
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="fixed inset-0 z-[60] bg-transparent"
              onClick={() => setContextMenu(null)}
              onContextMenu={(e) => {
                e.preventDefault();
                setContextMenu(null);
              }}
            />
            <motion.div
              initial={{ opacity: 0, scale: 0.9, y: 10 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.9, y: 10 }}
              className="fixed z-[70] bg-popover border border-border rounded-2xl shadow-2xl overflow-hidden min-w-[140px] p-1.5 backdrop-blur-md"
              style={{ 
                left: Math.min(window.innerWidth - 160, Math.max(20, contextMenu.x - 70)),
                top: contextMenu.y > window.innerHeight - 200 
                  ? contextMenu.y - 210 // Pop up if near bottom
                  : contextMenu.y + 10  // Pop down normally
              }}
            >
              <div className="flex flex-col gap-0.5">
                {(() => {
                  const message = messages.find(m => m.id === contextMenu.id);
                  if (!message) return null;

                  return (
                    <>
                      {message.type !== 'voice' && (
                        <button 
                          className="flex items-center gap-3 w-full px-3 py-2.5 text-sm hover:bg-muted rounded-xl transition-colors active:bg-muted/80"
                          onClick={() => handleCopy(message.content)}
                        >
                          <Copy size={16} className="text-muted-foreground" />
                          <span>复制文本</span>
                        </button>
                      )}
                      <button 
                        className="flex items-center gap-3 w-full px-3 py-2.5 text-sm hover:bg-muted rounded-xl transition-colors active:bg-muted/80"
                        onClick={() => handleQuoteClick(message)}
                      >
                        <Quote size={16} className="text-muted-foreground" />
                        <span>引用消息</span>
                      </button>
                      {message.type === 'voice' && (
                        <>
                          <button 
                            className="flex items-center gap-3 w-full px-3 py-2.5 text-sm hover:bg-muted rounded-xl transition-colors active:bg-muted/80"
                            onClick={() => handleTranscribeClick(message)}
                          >
                            <Languages size={16} className="text-muted-foreground" />
                            <span>转为文本</span>
                          </button>
                          <button 
                            className="flex items-center gap-3 w-full px-3 py-2.5 text-sm hover:bg-muted rounded-xl transition-colors active:bg-muted/80"
                            onClick={() => handleReplayClick(message.id)}
                          >
                            <RefreshCcw size={16} className="text-muted-foreground" />
                            <span>重新播放</span>
                          </button>
                        </>
                      )}

                      <div className="h-px bg-border/50 my-1 mx-1" />
                      
                      <button 
                        className="flex items-center gap-3 w-full px-3 py-2.5 text-sm hover:bg-destructive/10 text-destructive rounded-xl transition-colors active:bg-destructive/20"
                        onClick={() => handleDeleteClick(message.id)}
                      >
                        <Trash2 size={16} />
                        <span>删除消息</span>
                      </button>
                    </>
                  );
                })()}
              </div>
            </motion.div>
          </>
        )}
      </AnimatePresence>
    </div>
  );
};
