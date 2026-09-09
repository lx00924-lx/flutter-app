/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useState, useRef, useEffect } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Send, Mic, Camera, X, Square, Image as ImageIcon, Quote, Plus, Phone, Bot, Sparkles, AlertCircle, QrCode, Brain, Shield, ChevronDown, Check, Settings2 } from 'lucide-react';
import { useVoiceRecorder } from '../../hooks/useVoiceRecorder';
import { motion, AnimatePresence } from 'motion/react';
import { cn, formatMessageDate } from '../../lib/utils';
import { Camera as CapCamera, CameraResultType, CameraSource } from '@capacitor/camera';
import { Toast } from '@capacitor/toast';
import { API_BASE_URL } from '../../config';
import { generateThumbnail, cacheFullImage } from '../../lib/imageHandler';
import { CameraScannerModal } from './CameraScannerModal';

interface ChatInputProps {
  onSendMessage: (text: string, type: 'text' | 'voice' | 'image', mediaUrl?: string) => void;
  disabled?: boolean;
  quotedMessage?: any;
  onCancelQuote?: () => void;
  onStartCall?: () => void;
  isAgentMode?: boolean;
  onToggleAgentMode?: () => void;
  agentOnline?: boolean;
  onOpenAgentSettings?: () => void;
  onScanToken?: (token: string) => void;
  agentModel?: string;
  agentReasoningEffort?: 'off' | 'low' | 'high' | 'max';
  agentPermission?: 'read-only' | 'workspace-write' | 'danger-full-access';
  agentToken?: string;
  agentSessionId?: string;
  onUpdateAgentConfig?: (config: {
    agentModel?: string;
    agentReasoningEffort?: 'off' | 'low' | 'high' | 'max';
    agentPermission?: 'read-only' | 'workspace-write' | 'danger-full-access';
  }) => void;
}

export const ChatInput: React.FC<ChatInputProps> = ({ 
  onSendMessage, 
  quotedMessage, 
  onCancelQuote, 
  onStartCall,
  isAgentMode = false,
  onToggleAgentMode,
  agentOnline = false,
  onOpenAgentSettings,
  onScanToken,
  agentModel = 'deepseek-v4-flash',
  agentReasoningEffort = 'high',
  agentPermission = 'workspace-write',
  agentToken = '',
  agentSessionId,
  onUpdateAgentConfig
}) => {
  const [text, setText] = useState('');
  const [previewImage, setPreviewImage] = useState<string | null>(null);
  const [fullImageUrl, setFullImageUrl] = useState<string | null>(null); // For local cache
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  const [isCameraModalOpen, setIsCameraModalOpen] = useState(false);
  const [cameraModalMode, setCameraModalMode] = useState<'camera' | 'scanner'>('camera');
  const containerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const longPressTimer = useRef<NodeJS.Timeout | null>(null);
  const isLongPress = useRef(false);
  const { isRecording, audioUrl, duration, maxDuration, startRecording, stopRecording, setAudioUrl } = useVoiceRecorder();
  const micLongPressTimer = useRef<NodeJS.Timeout | null>(null);
  const isMicLongPress = useRef(false);

  // Agent model list & control state
  const [dshModels, setDshModels] = useState<Array<{ id: string; name: string; reasoningEfforts?: string[]; reasoning_effort?: string[]; defaultEffort?: string; default_reasoning?: string }>>([
    { id: "deepseek-v4-flash", name: "DeepSeek-V4-Flash", reasoningEfforts: ["off", "low", "high", "max"], defaultEffort: "high" },
    { id: "deepseek-v4-pro", name: "DeepSeek-V4-Pro", reasoningEfforts: ["off", "low", "high", "max"], defaultEffort: "high" },
    { id: "deepseek-v4-flash-vision-exp", name: "视觉实验版 (Flash Vision)", reasoningEfforts: ["off", "low", "high", "max"], defaultEffort: "high" },
    { id: "ep-20260824185630-nkdc7", name: "Doubao (豆包)", reasoningEfforts: [] }
  ]);
  const [isModelSelectorOpen, setIsModelSelectorOpen] = useState(false);
  const modelMenuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (isAgentMode) {
      fetch(`${API_BASE_URL}/api/agent/models?token=${encodeURIComponent(agentToken)}`)
        .then(res => res.json())
        .then(data => {
          if (data && Array.isArray(data.models) && data.models.length > 0) {
            setDshModels(data.models);
          }
        })
        .catch(() => {});
    }
  }, [isAgentMode, agentToken]);

  // Click outside to close model selector
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (modelMenuRef.current && !modelMenuRef.current.contains(e.target as Node)) {
        setIsModelSelectorOpen(false);
      }
    };
    if (isModelSelectorOpen) {
      document.addEventListener('mousedown', handleClickOutside);
    }
    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
    };
  }, [isModelSelectorOpen]);

  // Auto-focus when isRecording becomes false
  useEffect(() => {
    if (!isRecording) {
      const timer = setTimeout(() => {
        inputRef.current?.focus();
      }, 100);
      return () => clearTimeout(timer);
    }
  }, [isRecording]);

  // Auto-send when audioUrl is set
  useEffect(() => {
    if (audioUrl) {
      onSendMessage('', 'voice', audioUrl);
      setAudioUrl(null);
    }
  }, [audioUrl, onSendMessage, setAudioUrl]);

  const handleSend = async () => {
    if (text.trim() || previewImage) {
      if (previewImage) {
        try {
          const blob = await (await fetch(previewImage)).blob();
          const file = new File([blob], 'upload.jpg', { type: 'image/jpeg' });
          
          // Generate thumbnail for preview (already done, just need to use)
          // For now, let's just implement the chunked upload for the full image
          
          const CHUNK_SIZE = 1024 * 1024 * 1; // 1MB chunks
          const totalChunks = Math.ceil(file.size / CHUNK_SIZE);
          const filename = `${Date.now()}_${file.name}`;
          let imageUrl = '';

          for (let i = 0; i < totalChunks; i++) {
            const start = i * CHUNK_SIZE;
            const end = Math.min(start + CHUNK_SIZE, file.size);
            const chunk = file.slice(start, end);
            
            const formData = new FormData();
            formData.append('chunk', chunk);
            formData.append('chunkIndex', i.toString());
            formData.append('totalChunks', totalChunks.toString());
            formData.append('filename', filename);

            const res = await fetch(`${API_BASE_URL}/api/upload-chunk`, {
              method: 'POST',
              body: formData
            });
            const data = await res.json();
            if (data.completed) {
              imageUrl = data.url;
              break;
            }
          }
          
          // Cache locally
          await cacheFullImage(file, filename);
          
          onSendMessage(text, 'image', imageUrl.startsWith('http') ? imageUrl : `${API_BASE_URL}${imageUrl}`);
          setPreviewImage(null);
        } catch (error) {
          console.error("Upload failed:", error);
          await Toast.show({ text: '图片发送失败，请重试' });
        }
      } else {
        onSendMessage(text, 'text');
      }
      setText('');
      
      // Explicitly focus after a short delay to ensure DOM update
      setTimeout(() => {
        inputRef.current?.focus();
      }, 50);
    }
  };

  const openCamera = (initialMode: 'camera' | 'scanner' = 'camera') => {
    setIsMenuOpen(false);
    setCameraModalMode(initialMode);
    setIsCameraModalOpen(true);
  };

  const takePhoto = async () => {
    openCamera('camera');
  };

  const pickImage = async () => {
    openCamera('camera');
  };

  const handleCameraStart = () => {
    isLongPress.current = false;
    longPressTimer.current = setTimeout(() => {
      isLongPress.current = true;
      openCamera('scanner');
    }, 600);
  };

  const handleCameraEnd = () => {
    if (longPressTimer.current) {
      clearTimeout(longPressTimer.current);
      longPressTimer.current = null;
    }
  };

  const handleCameraClick = () => {
    if (!isLongPress.current) {
      openCamera('camera');
    }
  };

  const handleMicDown = () => {
    isMicLongPress.current = false;
    micLongPressTimer.current = setTimeout(() => {
      isMicLongPress.current = true;
      if (!isRecording) {
        startRecording();
      }
    }, 400);
  };

  const handleMicUp = () => {
    if (micLongPressTimer.current) {
      clearTimeout(micLongPressTimer.current);
    }
    
    if (isMicLongPress.current) {
      if (isRecording) {
        stopRecording();
      }
      isMicLongPress.current = false;
    } else {
      // It was a click
      if (isRecording) {
        stopRecording();
      } else {
        startRecording();
      }
    }
  };

  const handleImageUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      const reader = new FileReader();
      reader.onloadend = () => {
        setPreviewImage(reader.result as string);
        if (e.target) e.target.value = '';
      };
      reader.onerror = () => {
        console.error('FileReader error');
        Toast.show({ text: '图片读取失败，请尝试其他文件。' });
      };
      reader.readAsDataURL(file);
    }
  };

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(event.target as Node)) {
        setIsMenuOpen(false);
      }
    };

    if (isMenuOpen) {
      document.addEventListener('mousedown', handleClickOutside);
    } else {
      document.removeEventListener('mousedown', handleClickOutside);
    }

    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
    };
  }, [isMenuOpen]);

  return (
    <div className="w-full" ref={containerRef}>
      <div className="max-w-2xl mx-auto space-y-4">
        <AnimatePresence>
          {previewImage && (
            <motion.div 
              initial={{ opacity: 0, scale: 0.9, y: 20 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.9, y: 20 }}
              className="relative flex flex-col gap-3 p-3 bg-card border border-primary/20 rounded-[32px] shadow-2xl max-w-sm w-full mx-auto"
            >
              <div className="relative rounded-[24px] overflow-hidden aspect-video bg-muted border border-border/50">
                <img src={previewImage} alt="Preview" className="w-full h-full object-cover" />
                <div className="absolute top-3 left-3 px-2 py-1 bg-black/60 backdrop-blur-md rounded-lg text-[10px] text-white font-mono uppercase tracking-[0.2em] border border-white/10">
                  Captured
                </div>
              </div>
              
              <div className="flex gap-3">
                <Button 
                  type="button"
                  variant="outline" 
                  className="flex-1 h-12 rounded-2xl border-muted-foreground/20 text-muted-foreground hover:text-foreground hover:bg-muted transition-all active:scale-95"
                  onClick={() => {
                    setPreviewImage(null);
                    // Small delay to allow state update before opening camera
                    setTimeout(() => takePhoto(), 100);
                  }}
                >
                  重拍
                </Button>
                <Button 
                  type="button"
                  className="flex-1 h-12 rounded-2xl bg-primary text-primary-foreground shadow-lg shadow-primary/20 hover:bg-primary/90 transition-all active:scale-95 font-medium"
                  onClick={handleSend}
                >
                  发送
                </Button>
              </div>
              
              <button 
                type="button"
                onClick={() => setPreviewImage(null)}
                className="absolute -top-2 -right-2 bg-destructive text-destructive-foreground rounded-full p-2 shadow-xl hover:scale-110 active:scale-90 transition-all border-2 border-background"
              >
                <X size={16} />
              </button>
            </motion.div>
          )}
        </AnimatePresence>

        <AnimatePresence>
          {quotedMessage && (
            <motion.div
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: 10 }}
              className="px-4 py-3 bg-muted/50 border border-border/50 rounded-2xl flex items-center justify-between gap-3 shadow-sm"
            >
              <div className="flex-1 min-w-0">
                <div className="flex items-center justify-between mb-0.5">
                  <div className="flex items-center gap-2">
                    <Quote size={12} className="text-primary" />
                    <span className="text-[10px] font-bold text-primary uppercase tracking-wider">{quotedMessage.role === 'assistant' ? 'AI' : '我'}</span>
                  </div>
                  <span className="text-[9px] text-muted-foreground/60">{formatMessageDate(quotedMessage.timestamp)}</span>
                </div>
                <p className="text-xs text-muted-foreground line-clamp-1 italic">
                  {quotedMessage.content || (quotedMessage.type === 'voice' ? '[语音消息]' : '[图片消息]')}
                </p>
              </div>
              <Button
                variant="ghost"
                size="icon"
                className="w-8 h-8 rounded-full hover:bg-muted"
                onClick={onCancelQuote}
              >
                <X size={14} />
              </Button>
            </motion.div>
          )}
        </AnimatePresence>

        <AnimatePresence>
          {isMenuOpen && (
            <motion.div
              initial={{ opacity: 0, scale: 0.95, y: 10 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.95, y: 10 }}
              className="flex gap-3 sm:gap-4 p-3 sm:p-4 bg-white dark:bg-black border border-border rounded-[24px] shadow-lg mb-2 overflow-x-auto"
            >
              <div className="flex flex-col items-center gap-1.5 shrink-0">
                <Button 
                  type="button"
                  variant="ghost" 
                  size="icon" 
                  className="w-13 h-13 sm:w-14 sm:h-14 rounded-2xl bg-muted/30 border border-border/50 select-none active:scale-95 transition-all hover:bg-primary/10 hover:text-primary"
                  onClick={() => openCamera('camera')}
                  disabled={isRecording}
                >
                  <Camera size={22} className="sm:size-6" />
                </Button>
                <span className="text-[10px] text-muted-foreground font-medium">拍照</span>
              </div>
              <div className="flex flex-col items-center gap-1.5 shrink-0">
                <Button 
                  type="button"
                  variant="ghost" 
                  size="icon" 
                  className="w-13 h-13 sm:w-14 sm:h-14 rounded-2xl bg-muted/30 border border-border/50 select-none active:scale-95 transition-all hover:bg-primary/10 hover:text-primary"
                  onClick={() => fileInputRef.current?.click()}
                  disabled={isRecording}
                >
                  <Plus size={22} className="sm:size-6" />
                </Button>
                <span className="text-[10px] text-muted-foreground font-medium">选文件</span>
                <input
                    type="file"
                    ref={fileInputRef}
                    className="hidden"
                    onChange={handleImageUpload}
                    accept="image/*"
                />
              </div>
              <div className="flex flex-col items-center gap-1.5 shrink-0">
                <Button 
                  type="button"
                  variant="ghost" 
                  size="icon" 
                  className="w-13 h-13 sm:w-14 sm:h-14 rounded-2xl bg-muted/30 border border-border/50 select-none active:scale-95 transition-all hover:bg-primary/10 hover:text-primary"
                  onClick={() => {
                    setIsMenuOpen(false);
                    onStartCall?.();
                  }}
                  disabled={isRecording}
                >
                  <Phone size={20} className="sm:size-[22px] text-primary animate-pulse" />
                </Button>
                <span className="text-[10px] text-muted-foreground font-medium">语音通话</span>
              </div>
            </motion.div>
          )}
        </AnimatePresence>

        {/* Agent Mode Controls Strip (Model, Reasoning Effort, Permission) */}
        {isAgentMode && (
          <div className="flex items-center justify-between gap-1.5 mb-1.5 px-1 overflow-x-auto no-scrollbar select-none text-[11px]">
            <div className="flex items-center gap-1.5 shrink-0 relative" ref={modelMenuRef}>
              {/* Model Selector Button */}
              <button
                type="button"
                onClick={() => setIsModelSelectorOpen(!isModelSelectorOpen)}
                className="flex items-center gap-1 px-2 py-0.5 rounded-md bg-muted/70 hover:bg-muted text-foreground/80 hover:text-foreground border border-border/60 transition-colors cursor-pointer"
                title="选择 DSH 本地模型"
              >
                <Bot size={11} className="text-primary shrink-0" />
                <span className="font-mono text-[10.5px] max-w-[110px] truncate">{agentModel}</span>
                <ChevronDown size={10} className={cn("text-muted-foreground transition-transform", isModelSelectorOpen && "rotate-180")} />
              </button>

              {/* Model Dropdown Menu */}
              {isModelSelectorOpen && (
                <div className="absolute bottom-full left-0 mb-1 z-50 min-w-[180px] bg-popover/95 backdrop-blur-md border border-border rounded-lg shadow-lg p-1 text-xs space-y-0.5">
                  <div className="px-2 py-1 text-[10px] font-semibold text-muted-foreground border-b border-border/50">
                    DSH 3080 可用模型
                  </div>
                  {dshModels.map((m) => (
                    <button
                      key={m.id}
                      type="button"
                      onClick={() => {
                        const newEfforts = m.reasoningEfforts || m.reasoning_effort || [];
                        let nextEffort: 'off' | 'low' | 'high' | 'max' = agentReasoningEffort;
                        if (newEfforts.length === 0) {
                          nextEffort = 'off';
                        } else if (!newEfforts.includes(agentReasoningEffort)) {
                          nextEffort = (m.defaultEffort || m.default_reasoning || newEfforts[0] || 'high') as any;
                        }
                        onUpdateAgentConfig?.({
                          agentModel: m.id,
                          agentReasoningEffort: nextEffort
                        });
                        setIsModelSelectorOpen(false);
                      }}
                      className={cn(
                        "w-full flex items-center justify-between px-2 py-1.5 rounded text-left text-[11px] transition-colors hover:bg-accent hover:text-accent-foreground",
                        agentModel === m.id && "bg-primary/10 text-primary font-medium"
                      )}
                    >
                      <span className="truncate">{m.name || m.id}</span>
                      {agentModel === m.id && <Check size={12} className="text-primary shrink-0 ml-1" />}
                    </button>
                  ))}
                </div>
              )}

              {/* Reasoning Effort (Thinking Depth) Button - Dynamic from model metadata */}
              {(() => {
                const currentModelObj = dshModels.find(m => m.id === agentModel);
                const supportedEfforts = (currentModelObj?.reasoningEfforts || currentModelObj?.reasoning_effort || ['off', 'low', 'high', 'max']) as Array<'off' | 'low' | 'high' | 'max'>;
                const hasReasoning = supportedEfforts.length > 0;

                const getEffortLabel = (effort: string) => {
                  switch (effort) {
                    case 'high': return '深度思考 (High)';
                    case 'max': return '极限思考 (Max)';
                    case 'low': return '快速推理 (Low)';
                    case 'off': return '关闭思考 (Off)';
                    default: return effort;
                  }
                };

                const getShortLabel = (effort: string) => {
                  switch (effort) {
                    case 'high': return '深度思考';
                    case 'max': return '极限思考';
                    case 'low': return '快速推理';
                    case 'off': return '关闭思考';
                    default: return effort;
                  }
                };

                return (
                  <button
                    type="button"
                    onClick={() => {
                      if (!hasReasoning) {
                        Toast.show({ text: '当前模型为通用模型，不支持设置思考深度' });
                        return;
                      }
                      // Preferred rotation: high -> max -> low -> off
                      const defaultOrder: Array<'off' | 'low' | 'high' | 'max'> = ['high', 'max', 'low', 'off'];
                      const activeList = defaultOrder.filter(item => supportedEfforts.includes(item));
                      const currentIdx = activeList.indexOf(agentReasoningEffort);
                      const nextEffort = activeList[(currentIdx + 1) % activeList.length] || 'high';
                      onUpdateAgentConfig?.({ agentReasoningEffort: nextEffort });
                      Toast.show({ text: `已将推理思考深度切换为: ${getEffortLabel(nextEffort)}` });
                    }}
                    className={cn(
                      "flex items-center gap-1 px-2 py-0.5 rounded-md border text-[10.5px] font-medium transition-colors cursor-pointer",
                      !hasReasoning
                        ? "bg-muted/40 text-muted-foreground/60 border-border/40 opacity-70 cursor-not-allowed"
                        : agentReasoningEffort === 'high' 
                          ? "bg-purple-500/10 text-purple-600 dark:text-purple-400 border-purple-500/30" 
                          : agentReasoningEffort === 'max'
                            ? "bg-indigo-500/15 text-indigo-600 dark:text-indigo-400 border-indigo-500/40 font-semibold"
                            : agentReasoningEffort === 'low' 
                              ? "bg-blue-500/10 text-blue-600 dark:text-blue-400 border-blue-500/30" 
                              : "bg-muted/70 text-muted-foreground border-border/60"
                    )}
                    title={hasReasoning ? "切换模型思考深度 (Reasoning Effort: high/max/low/off)" : "当前模型无思考深度选项"}
                  >
                    <Brain size={11} className="shrink-0" />
                    <span>
                      {!hasReasoning ? '无思考档位' : getShortLabel(agentReasoningEffort)}
                    </span>
                  </button>
                );
              })()}

              {/* Permission Level Button (3-Tier DSH Standard: workspace-write / read-only / danger-full-access) */}
              <button
                type="button"
                onClick={() => {
                  const permCycle: Array<'workspace-write' | 'read-only' | 'danger-full-access'> = ['workspace-write', 'read-only', 'danger-full-access'];
                  const nextPermIdx = (permCycle.indexOf(agentPermission) + 1) % permCycle.length;
                  const nextPermVal = permCycle[nextPermIdx];
                  onUpdateAgentConfig?.({ agentPermission: nextPermVal });
                  Toast.show({ 
                    text: `执行权限级别: ${
                      nextPermVal === 'workspace-write' ? '工作区写 (Workspace Write)' : 
                      nextPermVal === 'read-only' ? '只读安全模式 (Read Only)' : 
                      '完全控制 (Danger Full Access)'
                    }` 
                  });
                }}
                className={cn(
                  "flex items-center gap-1 px-2 py-0.5 rounded-md border text-[10.5px] font-medium transition-colors cursor-pointer",
                  agentPermission === 'danger-full-access'
                    ? "bg-amber-500/10 text-amber-600 dark:text-amber-400 border-amber-500/30"
                    : agentPermission === 'workspace-write'
                      ? "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border-emerald-500/30"
                      : "bg-muted/70 text-muted-foreground border-border/60"
                )}
                title="权限等级 (Permission Level: workspace-write / read-only / danger-full-access)"
              >
                <Shield size={11} className="shrink-0" />
                <span>
                  {agentPermission === 'workspace-write' ? '工作区写' : agentPermission === 'read-only' ? '只读模式' : '完全控制'}
                </span>
              </button>
            </div>

            <div className="flex items-center gap-1 shrink-0">
              <button
                type="button"
                onClick={onOpenAgentSettings}
                className="p-1 text-muted-foreground hover:text-foreground rounded hover:bg-muted/60 transition-colors"
                title="打开 Agent 详细配置"
              >
                <Settings2 size={12} />
              </button>
            </div>
          </div>
        )}

        <div className="flex items-center gap-2 sm:gap-3 bg-white dark:bg-black border border-border rounded-[20px] sm:rounded-[24px] p-1.5 sm:p-2 h-14 sm:h-20 shadow-sm dark:shadow-none">
          {/* Agent Mode Toggle Pill */}
          <button
            type="button"
            onClick={onToggleAgentMode}
            title={
              isAgentMode 
                ? (agentOnline ? "当前处于 Agent 模式（本地 Harness 已连接），点击切换为普通模式" : "当前处于 Agent 模式（本地未连接），点击切换为普通模式") 
                : "当前处于普通模式，点击切换为 DeepSeek Agent 模式"
            }
            className={cn(
              "flex items-center gap-1.5 px-2 sm:px-2.5 py-1 sm:py-1.5 rounded-full text-xs font-medium transition-all shrink-0 select-none cursor-pointer active:scale-95",
              isAgentMode
                ? "bg-primary/15 text-primary border border-primary/30 shadow-[0_0_12px_rgba(0,210,255,0.15)]"
                : "bg-muted/60 text-muted-foreground hover:text-foreground border border-border/50 hover:bg-muted"
            )}
          >
            {isAgentMode ? (
              <>
                <Bot size={14} className="text-primary animate-pulse shrink-0" />
                <span className="font-semibold text-[11px] sm:text-xs">Agent</span>
                <span
                  onClick={(e) => {
                    if (!agentOnline && onOpenAgentSettings) {
                      e.stopPropagation();
                      onOpenAgentSettings();
                    }
                  }}
                  title={agentOnline ? "本地 DeepSeek Harness 在线" : "本地 Agent 未连接，点击查看配置"}
                  className={cn(
                    "inline-block w-2 h-2 rounded-full shrink-0 transition-colors",
                    agentOnline 
                      ? "bg-emerald-500 shadow-[0_0_6px_#10b981]" 
                      : "bg-amber-500/90 animate-pulse hover:scale-125"
                  )}
                />
              </>
            ) : (
              <>
                <Sparkles size={13} className="text-muted-foreground shrink-0" />
                <span className="text-[11px] sm:text-xs">普通</span>
              </>
            )}
          </button>

          {/* Main Input Area */}
          <div className="relative flex-1 h-full flex items-center min-w-0">
            {isRecording ? (
              <div className="flex-1 flex items-center justify-between px-3 h-full select-none">
                <div className="flex items-center gap-2">
                  <span className="relative flex h-2.5 w-2.5">
                    <span className={cn(
                      "animate-ping absolute inline-flex h-full w-full rounded-full opacity-75",
                      duration >= 50 ? "bg-destructive" : "bg-red-500"
                    )}></span>
                    <span className={cn(
                      "relative inline-flex rounded-full h-2.5 w-2.5",
                      duration >= 50 ? "bg-destructive" : "bg-red-500"
                    )}></span>
                  </span>
                  <span className="text-xs sm:text-sm font-medium text-foreground">
                    {duration >= 50 ? (
                      <span className="text-destructive font-semibold animate-pulse">
                        即将结束 (剩余 {maxDuration - duration}s)
                      </span>
                    ) : (
                      <span>正在录音...</span>
                    )}
                  </span>
                </div>
                <div className={cn(
                  "text-xs font-mono px-2 py-0.5 rounded-full border",
                  duration >= 50 
                    ? "bg-destructive/10 text-destructive border-destructive/30 font-bold" 
                    : "bg-muted text-muted-foreground border-border/50"
                )}>
                  {duration}s / {maxDuration}s
                </div>
              </div>
            ) : (
              <Input
                id="chat-text-input"
                ref={inputRef}
                value={text}
                onChange={(e) => {
                  setText(e.target.value);
                  if (e.target.value.trim() && isMenuOpen) {
                    setIsMenuOpen(false);
                  }
                }}
                onFocus={() => {
                  if (isMenuOpen) setIsMenuOpen(false);
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    handleSend();
                  }
                }}
                placeholder={isAgentMode ? "发送需求，由本地 DeepSeek Agent 处理..." : "输入消息..."}
                className="h-full border-none bg-transparent focus-visible:ring-0 text-sm sm:text-[15px] placeholder:text-muted-foreground pl-2 pr-2"
              />
            )}
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className={cn(
                "w-9 h-9 sm:w-11 sm:h-11 rounded-full transition-all hover:bg-primary/10 hover:text-primary active:scale-95 bg-card border shrink-0 mr-0.5 sm:mr-1",
                isRecording ? "text-primary border-primary/50" : "text-muted-foreground"
              )}
              onPointerDown={handleMicDown}
              onPointerUp={handleMicUp}
              onPointerLeave={() => {
                if (isMicLongPress.current && isRecording) {
                  stopRecording();
                  isMicLongPress.current = false;
                }
                if (micLongPressTimer.current) {
                  clearTimeout(micLongPressTimer.current);
                }
              }}
            >
              {isRecording ? <Square size={16} fill="currentColor" /> : <Mic size={16} className="sm:size-[18px]" />}
            </Button>
          </div>

          <Button 
            type="button"
            onClick={() => {
              if (text.trim() || previewImage || audioUrl) {
                handleSend();
              } else {
                setIsMenuOpen(!isMenuOpen);
              }
            }} 
            size="icon"
            className={cn(
              "shrink-0 w-10 h-10 sm:w-12 sm:h-12 rounded-full transition-all duration-300 active:scale-95",
              (text.trim() || previewImage || audioUrl)
                ? "bg-primary text-primary-foreground shadow-[0_0_15px_rgba(0,210,255,0.4)]"
                : "bg-muted text-muted-foreground hover:bg-primary/10 hover:text-primary shadow-none rotate-0"
            )}
          >
            <AnimatePresence mode="wait">
              {(text.trim() || previewImage || audioUrl) ? (
                <motion.div
                  key="send"
                  initial={{ opacity: 0, scale: 0.5, rotate: -45 }}
                  animate={{ opacity: 1, scale: 1, rotate: 0 }}
                  exit={{ opacity: 0, scale: 0.5, rotate: 45 }}
                  transition={{ duration: 0.2 }}
                >
                  <Send size={18} className="sm:size-5" />
                </motion.div>
              ) : (
                <motion.div
                  key="plus"
                  initial={{ opacity: 0, scale: 0.5, rotate: 45 }}
                  animate={{ opacity: 1, scale: 1, rotate: isMenuOpen ? 45 : 0 }}
                  exit={{ opacity: 0, scale: 0.5, rotate: -45 }}
                  transition={{ duration: 0.2 }}
                >
                  <Plus size={20} className="sm:size-6" />
                </motion.div>
              )}
            </AnimatePresence>
          </Button>
        </div>
      </div>

      <CameraScannerModal
        isOpen={isCameraModalOpen}
        onClose={() => setIsCameraModalOpen(false)}
        initialMode={cameraModalMode}
        onCaptureImage={(dataUrl) => {
          setPreviewImage(dataUrl);
        }}
        onScanTokenSuccess={(token) => {
          if (onScanToken) {
            onScanToken(token);
          }
        }}
      />
    </div>
  );
};
