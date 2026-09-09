/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { PhoneOff, Mic, MicOff, Volume2, Loader2, RefreshCw, Send, Zap } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { AppSettings, Message } from '../../types';
import { sendMessageToGemini, normalizeWsAsrUrl } from '../../services/gemini';
import { Toast } from '@capacitor/toast';
import { cn } from '../../lib/utils';

interface CallOverlayProps {
  open: boolean;
  onClose: () => void;
  settings: AppSettings;
  historyMessages: Message[];
  onCallEnd: (newMessages: Message[]) => void;
}

type CallStatus = 'connecting' | 'listening' | 'thinking' | 'speaking' | 'error';

export const CallOverlay: React.FC<CallOverlayProps> = ({
  open,
  onClose,
  settings,
  historyMessages,
  onCallEnd,
}) => {
  const [status, setStatus] = useState<CallStatus>('connecting');
  const [errorMessage, setErrorMessage] = useState('');
  const [userText, setUserText] = useState(''); // 用户当前实时识别结果
  const [aiText, setAiText] = useState(''); // AI 当前正在说的话/回答
  const [isMuted, setIsMuted] = useState(false);
  const [volume, setVolume] = useState(0); // 音频音量用于涟漪动画
  
  // Refs
  const wsRef = useRef<WebSocket | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  
  const statusRef = useRef<CallStatus>('connecting');
  const userTextRef = useRef('');
  const aiGeneratingDoneRef = useRef(false);
  const silenceTimeRef = useRef(0);
  const hasSpokenRef = useRef(false);
  
  const localMessagesRef = useRef<Message[]>([...historyMessages]);
  const newMessagesRef = useRef<Message[]>([]); // 记录当前通话中产生的所有新消息
  
  // TTS Queue Refs
  const speechQueueRef = useRef<string[]>([]);
  const isSpeakingTtsRef = useRef(false);
  const currentUtteranceRef = useRef<SpeechSynthesisUtterance | null>(null);
  const pendingTtsTextRef = useRef('');
  const ttsCleanTimerRef = useRef<NodeJS.Timeout | null>(null);
  const heartbeatTimerRef = useRef<NodeJS.Timeout | null>(null);
  const isConfigReadyRef = useRef<boolean>(false);
  const recognitionRef = useRef<any>(null);
  const lastTtsEndTimeRef = useRef<number>(0);
  const aiScrollRef = useRef<HTMLDivElement | null>(null);

  // AI 文本更新时自动平滑滚动到底部
  useEffect(() => {
    if (aiScrollRef.current) {
      aiScrollRef.current.scrollTo({
        top: aiScrollRef.current.scrollHeight,
        behavior: 'smooth'
      });
    }
  }, [aiText]);

  // Sync status ref
  useEffect(() => {
    statusRef.current = status;
  }, [status]);

  // Clean TTS Synthesis and socket connections on mount/unmount
  useEffect(() => {
    if (open) {
      if (!settings.funasrWsEndpoint) {
        setStatus('error');
        setErrorMessage('请先在“应用设置”中配置 FunASR 实时流式语音 WS 地址。');
        return;
      }
      
      initCall();
    }

    return () => {
      cleanupCall();
    };
  }, [open, settings.funasrWsEndpoint]);

  // 初始化/重连 FunASR WebSocket
  const connectFunasrWs = (customUrl?: string) => {
    const rawEndpoint = customUrl || settings?.funasrWsEndpoint || '';
    if (!rawEndpoint.trim()) {
      if (statusRef.current === 'connecting') {
        setStatus('error');
        setErrorMessage('请先在“应用设置”中配置 FunASR 实时流式语音 WS 地址。');
      }
      return;
    }

    const targetWsUrl = normalizeWsAsrUrl(rawEndpoint);

    // 判断是否为打包 Native App 环境（如 Capacitor / Cordova / WebView / file: 协议）
    const isNativeApp = typeof window !== 'undefined' && (
      window.location.protocol === 'file:' || 
      window.location.protocol === 'capacitor:' || 
      !!(window as any).Capacitor?.isNativePlatform() ||
      window.location.hostname === 'localhost' ||
      window.location.hostname === '127.0.0.1'
    );

    // 在 Web 页面端通过服务器代理转发消除 HTTPS 混合内容限制；打包 App 则直接直连
    let finalWsUrl = targetWsUrl;
    if (!isNativeApp && !targetWsUrl.includes('/api/funasr-ws')) {
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const host = window.location.host;
      if (host && window.location.protocol.startsWith('http')) {
        finalWsUrl = `${protocol}//${host}/api/funasr-ws?endpoint=${encodeURIComponent(targetWsUrl)}`;
      }
    }
    
    console.log('Connecting to FunASR WS:', finalWsUrl, isNativeApp ? '(Native Direct)' : '(Proxy)');
    try {
      if (wsRef.current) {
        try { wsRef.current.close(); } catch (e) {}
      }
      const ws = new WebSocket(finalWsUrl, 'binary');
      wsRef.current = ws;
      ws.binaryType = 'arraybuffer';

      ws.onopen = () => {
        console.log('FunASR WS connection established');
        isConfigReadyRef.current = false;
        const config = {
          mode: "2pass",
          chunk_size: [5, 10, 5],
          chunk_interval: 10,
          audio_fs: 16000,
          wav_name: "micro",
          wav_format: "pcm",
          is_speaking: true,
          hotwords: "",
          itn: true
        };
        try {
          ws.send(JSON.stringify(config));
        } catch (e) {
          console.error("Failed to send config to WS:", e);
        }

        if (heartbeatTimerRef.current) clearInterval(heartbeatTimerRef.current);
        heartbeatTimerRef.current = setInterval(() => {
          if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
            try {
              const silenceBuffer = new Int16Array(160).buffer;
              wsRef.current.send(silenceBuffer);
            } catch (e) {
              console.error("Failed to send WS heartbeat:", e);
            }
          }
        }, 30000);
        
        // 延迟 300ms 等待 FunASR 服务端完成配置解析后再开启录音传输，避免 chunk_size not set 异常
        setTimeout(() => {
          isConfigReadyRef.current = true;
          if (statusRef.current === 'connecting') {
            startAudioCapture();
          }
        }, 300);
      };

      ws.onmessage = (event) => {
        try {
          if (statusRef.current !== 'listening' || Date.now() - lastTtsEndTimeRef.current < 1000) {
            return;
          }
          const rawText = typeof event.data === 'string' ? event.data : new TextDecoder().decode(event.data);
          console.log('[FunASR Response]:', rawText);
          const data = JSON.parse(rawText);
          const textVal = data?.text ?? data?.result ?? data?.preds ?? (Array.isArray(data) ? data[0]?.text : null);
          if (typeof textVal === 'string') {
            const transcript = textVal.trim();
            if (transcript) {
              setUserText(transcript);
              userTextRef.current = transcript;
              silenceTimeRef.current = 0;
              hasSpokenRef.current = true;
            }
          }
        } catch (err) {
          console.error('Error parsing WS message:', err);
        }
      };

      ws.onerror = (err) => {
        console.error('FunASR WS Error:', err);
        if (statusRef.current === 'connecting') {
          setStatus('error');
          const urlStr = rawEndpoint.toLowerCase();
          if (urlStr.includes('127.0.0.1') || urlStr.includes('localhost')) {
            setErrorMessage('手机上无法连接到 127.0.0.1 (这是手机本机)。请在设置中将 WS 地址修改为运行 FunASR 电脑的局域网 IP (例如 ws://192.168.1.xxx:10095)。');
          } else {
            setErrorMessage('FunASR 实时语音连接失败，请确认服务端已启动且手机与电脑在同一 Wi-Fi 下。');
          }
        }
      };

      ws.onclose = () => {
        console.log('FunASR WS closed');
        if (statusRef.current === 'connecting') {
          setStatus('error');
          const urlStr = rawEndpoint.toLowerCase();
          if (urlStr.includes('127.0.0.1') || urlStr.includes('localhost')) {
            setErrorMessage('手机上无法使用 127.0.0.1。请在设置中修改为运行 FunASR 的电脑局域网 IP (如 ws://192.168.x.x:10095)。');
          } else {
            setErrorMessage('流式语音服务连接断开。请检查 WS 地址及手机网络连接。');
          }
        }
      };

    } catch (e: any) {
      console.error('WS Connection Exception:', e);
      if (statusRef.current === 'connecting') {
        setStatus('error');
        setErrorMessage(`WS 连接建立失败: ${e.message || '未知错误'}`);
      }
    }
  };

  // 打断 AI 说话机制
  const interruptAi = () => {
    console.log('User or VAD interrupted AI speech');
    if (typeof window !== 'undefined' && 'speechSynthesis' in window && window.speechSynthesis) {
      try { window.speechSynthesis.cancel(); } catch (e) {}
    }

    speechQueueRef.current = [];
    currentUtteranceRef.current = null;
    isSpeakingTtsRef.current = false;
    if (ttsCleanTimerRef.current) clearTimeout(ttsCleanTimerRef.current);

    lastTtsEndTimeRef.current = Date.now();
    setStatus('listening');
    setVolume(0);
    setUserText('');
    userTextRef.current = '';
    silenceTimeRef.current = 0;
    hasSpokenRef.current = false;

    if (recognitionRef.current) {
      try { recognitionRef.current.start(); } catch (e) {}
    }

    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) {
      connectFunasrWs();
    }
  };

  const initCall = async () => {
    setStatus('connecting');
    setErrorMessage('');
    setUserText('');
    setAiText('');
    setVolume(0);
    newMessagesRef.current = [];
    localMessagesRef.current = [...historyMessages];
    
    // 安全初始化 TTS
    if (typeof window !== 'undefined' && 'speechSynthesis' in window && window.speechSynthesis) {
      try {
        window.speechSynthesis.cancel();
      } catch (e) {
        console.error('Error canceling speechSynthesis:', e);
      }
    }
    speechQueueRef.current = [];
    isSpeakingTtsRef.current = false;
    currentUtteranceRef.current = null;
    pendingTtsTextRef.current = '';

    connectFunasrWs();
  };

  const startAudioCapture = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;

      let audioCtx: AudioContext;
      const AudioCtxClass = window.AudioContext || (window as any).webkitAudioContext;
      try {
        audioCtx = new AudioCtxClass({ sampleRate: 16000 });
      } catch (e) {
        console.warn('AudioContext sampleRate 16000 not supported by device, falling back to default:', e);
        audioCtx = new AudioCtxClass();
      }
      
      if (audioCtx.state === 'suspended') {
        try {
          await audioCtx.resume();
        } catch (e) {
          console.warn('AudioContext resume error:', e);
        }
      }
      audioContextRef.current = audioCtx;

      const source = audioCtx.createMediaStreamSource(stream);
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 64;
      analyserRef.current = analyser;
      source.connect(analyser);

      // 创建 ScriptProcessorNode 进行 2048 采样（单声道）
      const processor = audioCtx.createScriptProcessor(2048, 1, 1);
      processorRef.current = processor;
      source.connect(processor);
      processor.connect(audioCtx.destination);

      silenceTimeRef.current = 0;
      hasSpokenRef.current = false;
      setStatus('listening');

      processor.onaudioprocess = (e) => {
        const inputData = e.inputBuffer.getChannelData(0);

        // 计算 RMS 能量（音量大小）
        let sum = 0;
        for (let i = 0; i < inputData.length; i++) {
          sum += inputData[i] * inputData[i];
        }
        const rms = Math.sqrt(sum / inputData.length);

        // 打断检测：若 AI 正在播报且用户开口说话 (rms > 0.08)，自动打断 AI 播报
        if (statusRef.current === 'speaking') {
          if (rms > 0.08 && Date.now() - lastTtsEndTimeRef.current > 600) {
            interruptAi();
            return;
          }
          return;
        }

        if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;
        if (statusRef.current !== 'listening') return; // 只有在“倾听”状态才将麦克风数据送去识别

        // AI 刚播放完语音 1.2 秒内，处于扬声器回音消散保护期
        if (Date.now() - lastTtsEndTimeRef.current < 1200) {
          setVolume(0);
          silenceTimeRef.current = 0;
          return;
        }

        // 实时音量波动动画
        setVolume(rms * 100);

        // VAD 静音判断
        if (rms < 0.015) {
          silenceTimeRef.current += e.inputBuffer.duration * 1000;
        } else {
          silenceTimeRef.current = 0;
          hasSpokenRef.current = true;
        }

        // 说话静音超过 1.5 秒且曾经说话过
        if (silenceTimeRef.current > 1500 && hasSpokenRef.current && userTextRef.current.trim()) {
          silenceTimeRef.current = 0;
          hasSpokenRef.current = false;
          triggerAISpeak();
        }

        // 转为 16位有符号 PCM 并发送 (含 16000Hz 重采样)
        if (!isMuted && isConfigReadyRef.current && wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
          try {
            const buffer = floatTo16BitPCM(inputData, e.inputBuffer.sampleRate);
            wsRef.current.send(buffer);
          } catch (sendErr) {
            console.error('Error sending audio frame via WS:', sendErr);
          }
        }
      };

      // 3. 开启浏览器原生 SpeechRecognition 作为双引擎并行识听兜底
      if (typeof window !== 'undefined') {
        const SpeechRecognitionClass = (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
        if (SpeechRecognitionClass) {
          try {
            if (recognitionRef.current) {
              try { recognitionRef.current.stop(); } catch (e) {}
            }
            const recognition = new SpeechRecognitionClass();
            recognition.continuous = true;
            recognition.interimResults = true;
            recognition.lang = 'zh-CN';

            recognition.onresult = (event: any) => {
              let text = '';
              for (let i = event.resultIndex; i < event.results.length; i++) {
                text += event.results[i][0].transcript;
              }
              const trimmed = text.trim();

              // 如果 AI 正在播报，且识别出了用户开口说的新文本，直接打断 AI
              if (statusRef.current === 'speaking' && trimmed && Date.now() - lastTtsEndTimeRef.current > 500) {
                interruptAi();
                setUserText(trimmed);
                userTextRef.current = trimmed;
                hasSpokenRef.current = true;
                return;
              }

              if (statusRef.current !== 'listening') return;
              if (Date.now() - lastTtsEndTimeRef.current < 1200) return; // 忽略 AI 播报回音

              if (trimmed) {
                setUserText(trimmed);
                userTextRef.current = trimmed;
                hasSpokenRef.current = true;
              }
            };

            recognition.onend = () => {
              // 处于倾听状态时自动重新 start，防止原生识别关闭后无法重新工作
              if (statusRef.current === 'listening') {
                setTimeout(() => {
                  if (statusRef.current === 'listening') {
                    try { recognition.start(); } catch (e) {}
                  }
                }, 300);
              }
            };

            recognition.onerror = (e: any) => {
              console.warn('Native SpeechRecognition error:', e);
            };

            recognition.start();
            recognitionRef.current = recognition;
          } catch (srErr) {
            console.warn('Native SpeechRecognition start notice:', srErr);
          }
        }
      }

    } catch (err: any) {
      console.error('Audio capture permission error:', err);
      setStatus('error');
      setErrorMessage('无法捕获麦克风。请检查应用或浏览器的麦克风权限设置。');
    }
  };

  const floatTo16BitPCM = (input: Float32Array, inputSampleRate: number): ArrayBuffer => {
    // 线性插值精确定良重采样至 16000Hz (FunASR 标准采样率)
    let samples = input;
    if (inputSampleRate && inputSampleRate !== 16000) {
      const ratio = inputSampleRate / 16000;
      const newLength = Math.round(input.length / ratio);
      const resampled = new Float32Array(newLength);
      for (let i = 0; i < newLength; i++) {
        const origIndex = i * ratio;
        const index1 = Math.floor(origIndex);
        const index2 = Math.min(index1 + 1, input.length - 1);
        const fraction = origIndex - index1;
        resampled[i] = input[index1] * (1 - fraction) + input[index2] * fraction;
      }
      samples = resampled;
    }

    const output = new Int16Array(samples.length);
    for (let i = 0; i < samples.length; i++) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      output[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
    }
    return output.buffer;
  };

  const sendWsSpeakingStatus = (isSpeaking: boolean) => {
    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      try {
        wsRef.current.send(JSON.stringify({
          mode: "2pass",
          chunk_size: [5, 10, 5],
          chunk_interval: 10,
          audio_fs: 16000,
          is_speaking: isSpeaking
        }));
      } catch (e) {
        console.error('Error sending WS status:', e);
      }
    }
  };

  const triggerAISpeak = async () => {
    const speechText = userTextRef.current.trim();
    if (!speechText) return;

    console.log('User spoke complete sentence:', speechText);
    
    // 暂停识听，避免 AI 说话期间捕获扬声器声音
    if (recognitionRef.current) {
      try { recognitionRef.current.stop(); } catch (e) {}
    }
    if (typeof window !== 'undefined' && 'speechSynthesis' in window && window.speechSynthesis) {
      try { window.speechSynthesis.cancel(); } catch (e) {}
    }

    // 1. 切换到思考状态，清空 ASR 记录
    setStatus('thinking');
    setVolume(0);
    setUserText('');
    userTextRef.current = '';
    hasSpokenRef.current = false;
    silenceTimeRef.current = 0;

    // 2. 构造 User 消息并保存到 local 历史
    const userMessage: Message = {
      id: crypto.randomUUID(),
      role: 'user',
      content: speechText,
      timestamp: new Date(),
      type: 'text'
    };
    
    localMessagesRef.current.push(userMessage);
    newMessagesRef.current.push(userMessage);

    // 3. 准备接收 AI 回复
    setAiText('');
    aiGeneratingDoneRef.current = false;
    pendingTtsTextRef.current = '';
    
    // 初始化播放队列
    speechQueueRef.current = [];
    isSpeakingTtsRef.current = false;

    let aiFullContent = '';
    
    try {
      await sendMessageToGemini(localMessagesRef.current, settings, (chunk) => {
        aiFullContent += chunk;
        setAiText(aiFullContent);
        
        // 实时对 Chunk 进行流式句号拆分并放入 TTS 播放队列
        handleTtsChunk(chunk);
      });

      // AI 回复大模型生成完成
      aiGeneratingDoneRef.current = true;
      
      // 把最后的 pending TTS 扔进队列播放
      if (pendingTtsTextRef.current.trim()) {
        queueSpeech(pendingTtsTextRef.current.trim());
        pendingTtsTextRef.current = '';
      }

      // 4. 将 AI 完整消息也记录下来
      const aiMessage: Message = {
        id: crypto.randomUUID(),
        role: 'assistant',
        content: aiFullContent,
        timestamp: new Date(),
        type: 'text'
      };
      localMessagesRef.current.push(aiMessage);
      newMessagesRef.current.push(aiMessage);

      // 清空 ASR 以便进行下一轮
      setUserText('');
      userTextRef.current = '';

    } catch (e: any) {
      console.error('Gemini call failed in call mode', e);
      setStatus('error');
      setErrorMessage(`AI 服务调用失败: ${e.message || '请检查 API 终端或 API Key'}`);
    }
  };

  // TTS 流式断句分段处理
  const handleTtsChunk = (chunk: string) => {
    pendingTtsTextRef.current += chunk;
    
    // 按逗号、句号、换行等常见断句符切分
    const sentences = pendingTtsTextRef.current.split(/[，。？！\n；,;.!?]/);
    
    if (sentences.length > 1) {
      for (let i = 0; i < sentences.length - 1; i++) {
        const sentence = sentences[i].trim();
        if (sentence) {
          queueSpeech(sentence);
        }
      }
      // 保留最后一个可能还没结束的子句
      pendingTtsTextRef.current = sentences[sentences.length - 1];
    }
  };

  const queueSpeech = (text: string) => {
    speechQueueRef.current.push(text);
    if (!isSpeakingTtsRef.current) {
      speakNextInQueue();
    }
  };

  const speakNextInQueue = () => {
    if (speechQueueRef.current.length === 0) {
      isSpeakingTtsRef.current = false;
      // 全部播放完毕后，如果大模型已经生成结束，重置为 listening 状态
      if (aiGeneratingDoneRef.current) {
        lastTtsEndTimeRef.current = Date.now(); // 记录发声结束点，开启回音保护

        if (ttsCleanTimerRef.current) clearTimeout(ttsCleanTimerRef.current);
        ttsCleanTimerRef.current = setTimeout(() => {
          setStatus('listening');
          setVolume(0);
          setUserText('');
          userTextRef.current = '';
          silenceTimeRef.current = 0;
          hasSpokenRef.current = false;
          
          // 重新拉起识听
          if (recognitionRef.current) {
            try { recognitionRef.current.start(); } catch (e) {}
          }

          // 检查并确保 FunASR WS 在新一轮对话开启时处于连接可用状态
          if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) {
            console.log('Re-establishing FunASR WS connection for next turn...');
            const rawEndpoint = settings?.funasrWsEndpoint || '';
            if (rawEndpoint.trim()) {
              let targetWsUrl = rawEndpoint.trim();
              if (!targetWsUrl.startsWith('ws://') && !targetWsUrl.startsWith('wss://')) {
                targetWsUrl = `ws://${targetWsUrl}`;
              }
              connectFunasrWs(targetWsUrl);
            }
          }
        }, 800);
      }
      return;
    }

    isSpeakingTtsRef.current = true;
    const textToSpeak = speechQueueRef.current.shift()!;
    
    // 过滤 Markdown 和无效字符
    const cleanText = textToSpeak.replace(/[#*`_~[\]()]/g, '').trim();
    if (!cleanText) {
      speakNextInQueue();
      return;
    }

    if (typeof window === 'undefined' || !('speechSynthesis' in window) || !window.speechSynthesis || typeof SpeechSynthesisUtterance === 'undefined') {
      console.warn('SpeechSynthesis is not supported on this device/app platform.');
      if (ttsCleanTimerRef.current) clearTimeout(ttsCleanTimerRef.current);
      ttsCleanTimerRef.current = setTimeout(() => {
        lastTtsEndTimeRef.current = Date.now();
        setStatus('listening');
        setVolume(0);
        setUserText('');
        userTextRef.current = '';
        silenceTimeRef.current = 0;
        hasSpokenRef.current = false;
        if (recognitionRef.current) {
          try { recognitionRef.current.start(); } catch (e) {}
        }
        if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) {
          const rawEndpoint = settings?.funasrWsEndpoint || '';
          if (rawEndpoint.trim()) {
            let targetWsUrl = rawEndpoint.trim();
            if (!targetWsUrl.startsWith('ws://') && !targetWsUrl.startsWith('wss://')) {
              targetWsUrl = `ws://${targetWsUrl}`;
            }
            connectFunasrWs(targetWsUrl);
          }
        }
      }, 1200);
      return;
    }

    try {
      const utterance = new SpeechSynthesisUtterance(cleanText);
      utterance.lang = 'zh-CN';
      utterance.rate = 1.15; // 稍快语速提高灵动感
      
      // 设置发音人
      let voices: SpeechSynthesisVoice[] = [];
      try {
        voices = window.speechSynthesis.getVoices() || [];
      } catch (e) {}
      
      const zhVoice = voices.find(v => v.lang.includes('zh') || v.lang.includes('ZH'));
      if (zhVoice) {
        utterance.voice = zhVoice;
      }

      currentUtteranceRef.current = utterance;

      utterance.onstart = () => {
        setStatus('speaking');
        if (aiScrollRef.current) {
          aiScrollRef.current.scrollTo({
            top: aiScrollRef.current.scrollHeight,
            behavior: 'smooth'
          });
        }
      };

      utterance.onend = () => {
        currentUtteranceRef.current = null;
        speakNextInQueue();
      };

      utterance.onerror = (e: SpeechSynthesisErrorEvent) => {
        console.warn('SpeechSynthesis warning/error event:', e.error || e.type || 'interrupted');
        currentUtteranceRef.current = null;
        speakNextInQueue();
      };

      window.speechSynthesis.speak(utterance);
    } catch (synthErr) {
      console.error('Failed to trigger speechSynthesis speak:', synthErr);
      speakNextInQueue();
    }
  };

  const handleHangup = () => {
    // 结束通话，输出新产生的对话消息
    onCallEnd(newMessagesRef.current);
    cleanupCall();
    onClose();
  };

  const cleanupCall = () => {
    if (recognitionRef.current) {
      try { recognitionRef.current.stop(); } catch (e) {}
      recognitionRef.current = null;
    }
    if (typeof window !== 'undefined' && 'speechSynthesis' in window && window.speechSynthesis) {
      try {
        window.speechSynthesis.cancel();
      } catch (e) {}
    }
    if (ttsCleanTimerRef.current) clearTimeout(ttsCleanTimerRef.current);
    if (heartbeatTimerRef.current) {
      clearInterval(heartbeatTimerRef.current);
      heartbeatTimerRef.current = null;
    }
    
    // 停止 WS
    if (wsRef.current) {
      try {
        if (wsRef.current.readyState === WebSocket.OPEN) {
          wsRef.current.send(JSON.stringify({ is_speaking: false }));
        }
        wsRef.current.close();
      } catch (e) {}
      wsRef.current = null;
    }

    // 停止麦克风采集
    if (streamRef.current) {
      streamRef.current.getTracks().forEach(track => track.stop());
      streamRef.current = null;
    }

    // 停止 AudioContext
    if (processorRef.current) {
      processorRef.current.disconnect();
      processorRef.current = null;
    }
    if (audioContextRef.current) {
      try {
        audioContextRef.current.close();
      } catch (e) {}
      audioContextRef.current = null;
    }
    
    analyserRef.current = null;
  };

  if (!open) return null;

  // 根据当前状态显示对应涟漪和呼吸发光效果
  const getPulseScale = () => {
    if (status === 'listening') {
      return 1 + (volume / 100) * 0.4; // 根据说话音量实时波动
    }
    return 1;
  };

  return (
    <AnimatePresence>
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        className="fixed inset-0 z-[100] flex flex-col items-center justify-between bg-black/75 backdrop-blur-xl p-6 text-white"
      >
        {/* Top bar info */}
        <div className="w-full flex items-center justify-between max-w-lg mt-4">
          <div className="flex items-center gap-2">
            <span className="relative flex h-2 w-2">
              <span className={cn(
                "animate-ping absolute inline-flex h-full w-full rounded-full opacity-75",
                status === 'listening' ? "bg-emerald-400" : status === 'thinking' ? "bg-amber-400" : status === 'speaking' ? "bg-sky-400" : "bg-destructive"
              )}></span>
              <span className={cn(
                "relative inline-flex rounded-full h-2 w-2",
                status === 'listening' ? "bg-emerald-500" : status === 'thinking' ? "bg-amber-500" : status === 'speaking' ? "bg-sky-500" : "bg-destructive"
              )}></span>
            </span>
            <span className="text-xs font-mono text-white/60 uppercase tracking-widest">
              {status === 'connecting' && '正在连接转写服务...'}
              {status === 'listening' && '正在倾听中...'}
              {status === 'thinking' && '正在理解思考...'}
              {status === 'speaking' && '正在播放语音...'}
              {status === 'error' && '语音连接错误'}
            </span>

            {/* 实时麦克风音量可视化动态小能量柱 */}
            {status === 'listening' && (
              <div className="flex items-center gap-0.5 ml-2 h-4 px-1.5 py-0.5 rounded bg-white/5 border border-white/10" title="麦克风采集音量">
                <span className="text-[10px] text-emerald-400 font-mono mr-1">MIC</span>
                {[0.2, 0.4, 0.6, 0.8, 1.0].map((threshold, idx) => {
                  const active = (volume / 100) >= (threshold * 0.2);
                  return (
                    <span
                      key={idx}
                      className={cn(
                        "w-1 rounded-full transition-all duration-75",
                        active ? "bg-emerald-400" : "bg-white/20"
                      )}
                      style={{
                        height: active ? `${Math.min(100, Math.max(30, (volume / 100) * 100 * (idx + 1) * 0.4))}%` : '20%'
                      }}
                    />
                  );
                })}
              </div>
            )}
          </div>
          
          {status !== 'error' && status !== 'connecting' && (
            <Button
              variant="ghost"
              size="icon"
              className={cn(
                "w-10 h-10 rounded-full border border-white/10 text-white/80 hover:text-white hover:bg-white/10 transition-all",
                isMuted && "bg-destructive/20 border-destructive/40 text-destructive hover:bg-destructive/30 hover:text-destructive"
              )}
              onClick={() => setIsMuted(!isMuted)}
              title={isMuted ? "取消静音" : "静音麦克风"}
            >
              {isMuted ? <MicOff size={16} /> : <Mic size={16} />}
            </Button>
          )}
        </div>

        {/* Center avatar & high-end wave ripples */}
        <div className="relative flex-1 flex items-center justify-center w-full max-w-lg">
          {/* Pulsing ripples */}
          <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
            {status === 'listening' && (
              <>
                <motion.div
                  animate={{ scale: getPulseScale(), opacity: [0.1, 0.4, 0.1] }}
                  transition={{ repeat: Infinity, duration: 1.5, ease: 'easeOut' }}
                  className="absolute w-48 h-48 rounded-full bg-emerald-500/20 border border-emerald-500/30"
                />
                <motion.div
                  animate={{ scale: getPulseScale() * 1.3, opacity: [0.05, 0.2, 0.05] }}
                  transition={{ repeat: Infinity, duration: 2, ease: 'easeOut', delay: 0.3 }}
                  className="absolute w-64 h-64 rounded-full bg-emerald-500/10 border border-emerald-500/20"
                />
              </>
            )}

            {status === 'thinking' && (
              <>
                <motion.div
                  animate={{ scale: [1, 1.15, 1], opacity: [0.2, 0.5, 0.2] }}
                  transition={{ repeat: Infinity, duration: 2, ease: 'easeInOut' }}
                  className="absolute w-48 h-48 rounded-full bg-amber-500/20 border border-amber-500/30"
                />
                <motion.div
                  animate={{ scale: [1.15, 1.3, 1.15], opacity: [0.1, 0.3, 0.1] }}
                  transition={{ repeat: Infinity, duration: 2, ease: 'easeInOut', delay: 0.5 }}
                  className="absolute w-64 h-64 rounded-full bg-amber-500/10 border border-amber-500/20"
                />
              </>
            )}

            {status === 'speaking' && (
              <>
                <motion.div
                  animate={{ scale: [1, 1.25, 1], opacity: [0.15, 0.4, 0.15] }}
                  transition={{ repeat: Infinity, duration: 1.2, ease: 'easeInOut' }}
                  className="absolute w-48 h-48 rounded-full bg-sky-500/20 border border-sky-500/30"
                />
                <motion.div
                  animate={{ scale: [1.15, 1.45, 1.15], opacity: [0.05, 0.2, 0.05] }}
                  transition={{ repeat: Infinity, duration: 1.6, ease: 'easeInOut', delay: 0.2 }}
                  className="absolute w-64 h-64 rounded-full bg-sky-500/10 border border-sky-500/20"
                />
              </>
            )}
          </div>

          {/* AI Avatar */}
          <div className="relative z-10 w-28 h-28 rounded-full overflow-hidden border-2 border-white/20 shadow-2xl bg-gradient-to-tr from-primary to-accent flex items-center justify-center">
            {settings.aiAvatar ? (
              <img src={settings.aiAvatar} alt="AI Avatar" className="w-full h-full object-cover" />
            ) : (
              <Volume2 size={40} className="text-white animate-pulse" />
            )}
          </div>
        </div>

        {/* Dynamic subtitles and transcript screen */}
        <div className="w-full max-w-lg bg-white/5 border border-white/10 rounded-[28px] p-5 backdrop-blur-md space-y-4 mb-6">
          {status === 'error' ? (
            <div className="space-y-3 py-2 text-center">
              <p className="text-sm text-destructive font-medium leading-relaxed">{errorMessage}</p>
              
              <div className="text-xs text-white/60 bg-white/5 border border-white/10 rounded-xl p-3 text-left space-y-1.5 font-sans">
                <p className="font-semibold text-white/80">📱 手机端连接排查指南：</p>
                <ol className="list-decimal list-inside space-y-1 text-[11px] leading-normal text-white/70">
                  <li><strong className="text-amber-300 font-normal">不可使用 127.0.0.1 / localhost</strong>：请在设置中更改为电脑在局域网中的真实 IP（如 <code className="text-sky-300 bg-black/30 px-1 py-0.5 rounded">ws://192.168.1.x:10095</code>）。</li>
                  <li><strong>连接同一个 Wi-Fi</strong>：确保手机与运行 FunASR 语音服务的电脑连接在同一个无线网络下，且手机未开启 4G/5G 流量。</li>
                  <li><strong>防火墙与公网服务</strong>：确认电脑防火墙允许 10095 端口入站访问；若在网页端(HTTPS)访问，建议安装打包后的 Android App 直连。</li>
                </ol>
              </div>

              <Button
                variant="outline"
                size="sm"
                className="h-8 border-white/10 bg-white/5 text-white/90 hover:bg-white/10 active:scale-95"
                onClick={initCall}
              >
                <RefreshCw size={12} className="mr-1.5" />
                重新尝试连接
              </Button>
            </div>
          ) : (
            <>
              {/* User transcript (Real-time ASR) */}
              <div className="space-y-1">
                <span className="text-[10px] font-mono text-emerald-400 uppercase tracking-widest font-semibold">你</span>
                <p className="text-sm font-medium text-white/90 line-clamp-2 min-h-[2.5rem]">
                  {userText || (status === 'listening' ? (isMuted ? '麦克风已静音' : '我在听，请开始说话...') : ' ')}
                </p>
              </div>

              {/* Divider */}
              <div className="border-t border-white/5" />

              {/* AI text (Real-time LLM) */}
              <div className="space-y-1">
                <span className="text-[10px] font-mono text-sky-400 uppercase tracking-widest font-semibold">{settings.aiName || 'AI'}</span>
                <div 
                  ref={aiScrollRef}
                  className="max-h-[160px] sm:max-h-[220px] overflow-y-auto scrollbar-thin scrollbar-thumb-white/20 scrollbar-track-transparent pr-1.5 smooth-scroll"
                >
                  <p className="text-sm text-white/80 leading-relaxed whitespace-pre-wrap break-words min-h-[3.75rem]">
                    {aiText || (status === 'thinking' ? '正在思考中...' : ' ')}
                  </p>
                </div>
              </div>
            </>
          )}
        </div>

        {/* Control bar */}
        <div className="w-full max-w-md flex items-center justify-center gap-6 pb-6">
          {(status === 'speaking' || status === 'thinking') && (
            <Button
              type="button"
              variant="secondary"
              className="h-12 px-5 rounded-full bg-amber-500/20 hover:bg-amber-500/30 text-amber-300 border border-amber-500/40 shadow-lg flex items-center gap-2 transition-all active:scale-95 animate-pulse"
              onClick={interruptAi}
              title="打断 AI 说话，切换回倾听"
            >
              <Zap size={18} className="fill-amber-300/30" />
              <span className="text-xs font-medium">打断 AI</span>
            </Button>
          )}

          {status === 'listening' && (
            <Button
              type="button"
              variant="secondary"
              className={cn(
                "h-12 px-5 rounded-full bg-white/10 hover:bg-white/20 text-white border border-white/20 shadow-lg flex items-center gap-2 transition-all active:scale-95",
                userText && "bg-emerald-500/20 hover:bg-emerald-500/30 border-emerald-500/40 text-emerald-300"
              )}
              onClick={() => {
                if (userTextRef.current.trim()) {
                  triggerAISpeak();
                } else {
                  // 如果未识别出文本，允许强行提示
                  setUserText('你好');
                  userTextRef.current = '你好';
                  triggerAISpeak();
                }
              }}
              title="说完了，立即发送给 AI"
            >
              <Send size={18} />
              <span className="text-xs font-medium">{userText ? '说完了，发送' : '说完了'}</span>
            </Button>
          )}

          <Button
            type="button"
            variant="destructive"
            size="icon"
            className="w-16 h-16 rounded-full bg-red-500 text-white shadow-xl shadow-red-500/20 hover:bg-red-600 transition-all active:scale-90 flex items-center justify-center border-4 border-black/20 shrink-0"
            onClick={handleHangup}
            title="挂断"
          >
            <PhoneOff size={24} />
          </Button>
        </div>
      </motion.div>
    </AnimatePresence>
  );
};
