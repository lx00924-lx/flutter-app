/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import { GoogleGenAI } from "@google/genai";
import { Message, AppSettings } from "../types";
import { Capacitor, CapacitorHttp } from '@capacitor/core';
import { estimateTokens } from "../lib/utils";
import { API_BASE_URL } from "../config";

// Helper to normalize and sanitize custom OpenAI-compatible API endpoints
export function normalizeApiBaseUrl(rawEndpoint: string): string {
  if (!rawEndpoint) return '';
  let endpoint = rawEndpoint.trim();
  
  // 1. 补全协议头
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

  // 2. 清除末尾多余斜杠
  endpoint = endpoint.replace(/\/+$/, '');

  // 3. 智能去除用户可能手动粘贴的各类动作后缀（防止重复拼接）
  endpoint = endpoint
    .replace(/\/chat\/completions\/?$/i, '')
    .replace(/\/completions\/?$/i, '')
    .replace(/\/models\/?$/i, '')
    .replace(/\/responses\/?$/i, '')
    .replace(/\/embeddings\/?$/i, '')
    .replace(/\/+$/, '');

  // 4. 国内及国际主流特殊厂商智能路由规则
  // (1) 阿里通义千问 / 阿里云百炼 (DashScope)
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

  // (2) 智谱 AI / 清言 (ZhipuAI GLM)
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

  // (3) 火山引擎 / 豆包 / 火山方舟 (Volces / Ark)
  if (endpoint.includes('volces.com') || endpoint.includes('volcengine.com')) {
    if (!endpoint.includes('/api/v3') && !endpoint.includes('/api/')) {
      endpoint = `${endpoint}/api/v3`;
    }
    return endpoint;
  }

  // (4) 百度文心千帆平台 (Baidu Qianfan)
  if (endpoint.includes('qianfan.baidubce.com')) {
    if (!endpoint.includes('/v2') && !endpoint.includes('/v1')) {
      endpoint = `${endpoint}/v2`;
    }
    return endpoint;
  }

  // 5. 判断是否已经包含版本号路径（例如 /v1, /v2, /v3, /v4, /api/v1 等）
  const hasVersionPath = /\/(v\d+|api\/v\d+|compatible-mode\/v\d+|api\/paas\/v\d+)$/i.test(endpoint) || /\/v\d+\//i.test(endpoint) || /\/api\//i.test(endpoint);

  // 如果是纯域名且未包含任何版本路径，默认自动补齐标准 /v1
  if (!hasVersionPath) {
    endpoint = `${endpoint}/v1`;
  }

  return endpoint;
}

export function getChatCompletionsUrl(endpoint: string): string {
  const base = normalizeApiBaseUrl(endpoint);
  return `${base}/chat/completions`;
}

export function getModelsUrl(endpoint: string): string {
  const base = normalizeApiBaseUrl(endpoint);
  return `${base}/models`;
}

/**
 * 智能规范化 FunASR HTTP 转写接口地址
 * 1. 自动去除首尾空格与多余末尾斜杠
 * 2. 自动修正/补齐协议 (http:// 或 https://，如果是 ws:// 自动转换为 http://)
 * 3. 本地/局域网 IP 默认使用 http://，外部域名使用 https://
 */
export function normalizeHttpAsrUrl(rawEndpoint: string): string {
  if (!rawEndpoint) return '';
  let endpoint = rawEndpoint.trim();

  // 修正误填的 ws 协议
  if (endpoint.startsWith('ws://')) {
    endpoint = endpoint.replace('ws://', 'http://');
  } else if (endpoint.startsWith('wss://')) {
    endpoint = endpoint.replace('wss://', 'https://');
  } else if (!endpoint.startsWith('http://') && !endpoint.startsWith('https://')) {
    if (
      endpoint.startsWith('localhost') || 
      endpoint.startsWith('127.0.0.1') || 
      endpoint.startsWith('192.168.') || 
      endpoint.startsWith('10.') || 
      endpoint.startsWith('172.') ||
      /^(\d{1,3}\.){3}\d{1,3}/.test(endpoint)
    ) {
      endpoint = `http://${endpoint}`;
    } else {
      endpoint = `https://${endpoint}`;
    }
  }

  // 清除末尾多余斜杠
  endpoint = endpoint.replace(/\/+$/, '');
  return endpoint;
}

/**
 * 智能规范化 FunASR 实时流式 WebSocket 接口地址
 * 1. 自动去除首尾空格与多余末尾斜杠
 * 2. 自动修正/补齐 ws 协议 (如果是 http:// 自动转换为 ws://，https:// 转换为 wss://)
 * 3. 本地/局域网 IP 默认使用 ws://，其他外网域名默认使用 wss://
 */
export function normalizeWsAsrUrl(rawEndpoint: string): string {
  if (!rawEndpoint) return '';
  let endpoint = rawEndpoint.trim();

  // 修正误填的 http 协议
  if (endpoint.startsWith('http://')) {
    endpoint = endpoint.replace('http://', 'ws://');
  } else if (endpoint.startsWith('https://')) {
    endpoint = endpoint.replace('https://', 'wss://');
  } else if (!endpoint.startsWith('ws://') && !endpoint.startsWith('wss://')) {
    if (
      endpoint.startsWith('localhost') || 
      endpoint.startsWith('127.0.0.1') || 
      endpoint.startsWith('192.168.') || 
      endpoint.startsWith('10.') || 
      endpoint.startsWith('172.') ||
      /^(\d{1,3}\.){3}\d{1,3}/.test(endpoint)
    ) {
      endpoint = `ws://${endpoint}`;
    } else {
      endpoint = `wss://${endpoint}`;
    }
  }

  // 清除末尾多余斜杠
  endpoint = endpoint.replace(/\/+$/, '');
  return endpoint;
}

export async function fetchModels(settings: AppSettings): Promise<string[]> {
  if (!settings.apiEndpoint) return [];
  
  try {
    const url = getModelsUrl(settings.apiEndpoint);
    
    const options = {
      url: url,
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${settings.apiKey || "lm-studio"}`
      },
      connectTimeout: 5000,
      readTimeout: 5000
    };
    
    const response = await CapacitorHttp.request(options);
    if (response.status === 200 && Array.isArray(response.data?.data)) {
      return response.data.data.map((m: any) => m.id);
    }
  } catch (err) {
    console.error("Failed to fetch models:", err);
  }
  return [];
}

export async function sendMessageToGemini(
  messages: Message[],
  settings: AppSettings,
  onChunk?: (chunk: string) => void
) {
  try {
    if (settings.apiEndpoint) {
      // Use CapacitorHttp for better compatibility and to bypass CORS on mobile
      const url = getChatCompletionsUrl(settings.apiEndpoint);
      console.log("Attempting to connect to API endpoint:", url);
      
      const systemMessage = settings.systemInstruction 
        ? [{ role: 'system', content: settings.systemInstruction }] 
        : [];

      const mapMessageToCustomContent = (msg: Message) => {
        const parts: any[] = [];
        let text = msg.content;
        
        // Ensure some text exists for all messages to satisfy strict proxies
        if (!text) {
          if (msg.type === 'image') text = '[图片]';
          else if (msg.type === 'voice') text = '[语音]';
          else text = ' '; // At least a space
        }

        if (msg.quote) {
          text = `引用消息: "${msg.quote.content}"\n\n回复上面的消息: ${text}`;
        }
        
        if (text) {
          parts.push({ type: 'text', text });
        }

        if (msg.type === 'image' && msg.mediaUrl) {
          parts.push({
            type: 'image_url',
            image_url: {
              url: msg.mediaUrl
            }
          });
        }
        
        // Voice is tricky for OpenAI format, usually handled as audio uploads or separate fields.
        // For now, we'll focus on image recognition as requested.
        
        return parts.length === 1 && parts[0].type === 'text' ? parts[0].text : parts;
      };

      const MAX_TOKENS = settings.contextLength || 30000;
      let currentTokens = 0;
      const recentHistory: Message[] = [];
      const historyMessages = messages.slice(0, -1).reverse();
      for (const msg of historyMessages) {
        const msgTokens = estimateTokens(msg.content || "");
        if (currentTokens + msgTokens > MAX_TOKENS) break;
        currentTokens += msgTokens;
        recentHistory.unshift(msg);
      }

      const history = recentHistory.map(msg => {
        const customContent = mapMessageToCustomContent(msg);
        return {
          role: msg.role === 'assistant' ? 'assistant' : 'user',
          content: customContent || ' ',
          // Some proxies require a string 'content' or 'message_content'
          message_content: msg.content || ' '
        };
      });

      const lastMessage = messages[messages.length - 1];
      const userContent = mapMessageToCustomContent(lastMessage);

      // Use CapacitorHttp for better compatibility and to bypass CORS on mobile
      const options = {
        url: url,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AetherX/1.0',
          'Authorization': `Bearer ${settings.apiKey || "lm-studio"}`
        },
        data: {
          model: settings.modelName || "local-model",
          messages: [
            ...systemMessage,
            ...history,
            { 
              role: 'user', 
              content: userContent || ' ',
              // Some proxies expect a string content even for vision
              ...(typeof userContent !== 'string' ? { text: lastMessage.content || ' ' } : {})
            }
          ],
          stream: false,
        },
        connectTimeout: 30000,
        readTimeout: 60000
      };

      const response = await CapacitorHttp.request(options);

      if (response.status < 200 || response.status >= 300) {
        console.error("API Response Error:", response);
        throw new Error(`API 请求失败: ${response.status} ${response.data?.error?.message || ''}`);
      }

      const fullText = response.data.choices[0]?.message?.content || "";
      
      if (fullText) {
        onChunk?.(fullText);
      }
      
      return fullText;
    }

    // Use GoogleGenAI client
    const ai = new GoogleGenAI({ 
      apiKey: settings.apiKey || process.env.GEMINI_API_KEY || ""
    });

    const modelName = settings.modelName || "gemini-3-flash-preview";
    const systemInstruction = settings.systemInstruction;

    // Helper to map message to Gemini parts
    const mapMessageToParts = (msg: Message) => {
      console.log("Mapping message to parts, type:", msg.type, "hasMediaUrl:", !!msg.mediaUrl);
      const msgParts: any[] = [];
      let finalContent = msg.content;

      // Ensure some text exists for all messages
      if (!finalContent) {
        if (msg.type === 'image') finalContent = '[图片]';
        else if (msg.type === 'voice') finalContent = '[语音]';
        else finalContent = ' ';
      }

      // Handle quotes
      if (msg.quote) {
        finalContent = `引用消息: "${msg.quote.content}"\n\n回复上面的消息: ${finalContent}`;
      }

      msgParts.push({ text: finalContent || ' ' });

      if ((msg.type === 'image' || msg.type === 'voice') && msg.mediaUrl) {
        try {
          // Robustly handle data URI
          const commaIndex = msg.mediaUrl.indexOf(',');
          if (commaIndex === -1) throw new Error("Invalid media URL format: no comma");
          
          const base64Data = msg.mediaUrl.substring(commaIndex + 1);
          const metaPart = msg.mediaUrl.substring(0, commaIndex);
          
          const mimeTypeMatch = metaPart.match(/data:([a-zA-Z0-9-]+\/[a-zA-Z0-9-.+]+)/);
          const mimeType = mimeTypeMatch ? mimeTypeMatch[1] : (msg.type === 'voice' ? 'audio/wav' : 'image/jpeg');

          msgParts.push({
            inlineData: {
              data: base64Data,
              mimeType: mimeType
            }
          });
        } catch (e) {
          console.error("Error parsing media URL:", e);
        }
      }
      return msgParts;
    };

    const MAX_TOKENS = settings.contextLength || 30000;
    let currentTokens = 0;
    const recentHistory: Message[] = [];
    const historyMessages = messages.slice(0, -1).reverse();
    for (const msg of historyMessages) {
      const msgTokens = estimateTokens(msg.content || "");
      if (currentTokens + msgTokens > MAX_TOKENS) break;
      currentTokens += msgTokens;
      recentHistory.unshift(msg);
    }

    const history = recentHistory.map(msg => ({
      role: msg.role === 'assistant' ? 'model' : 'user',
      parts: mapMessageToParts(msg),
    }));

    const lastMessage = messages[messages.length - 1];
    const parts = mapMessageToParts(lastMessage);

    const responseStream = await ai.models.generateContentStream({
      model: modelName,
      contents: [
        ...history,
        { role: 'user', parts }
      ],
      config: {
        ...(systemInstruction ? { systemInstruction } : {}),
        tools: [{ googleSearch: {} }] as any,
      }
    });

    let fullText = "";
    for await (const chunk of responseStream) {
      const text = chunk.text;
      if (text) {
        fullText += text;
        onChunk?.(text);
      }
    }

    return fullText;
  } catch (error) {
    console.error("API Error:", error);
    if (error instanceof Error) {
      if (error.message.includes('fetch') || error.message.includes('network') || error.message.includes('Failed to fetch')) {
        throw new Error("网络连接错误，请检查您的网络设置、API 端点配置，或确保安卓应用已开启明文 HTTP 请求权限。");
      }
      throw new Error(`API 错误: ${error.message}`);
    }
    throw new Error("发生未知错误，请稍后再试。");
  }
}

export interface TranscribeOptions {
  apiKey?: string;
  model?: string;
}

export async function transcribeAudio(
  mediaUrl: string, 
  endpointOrSettings: string | AppSettings,
  options?: TranscribeOptions
): Promise<string> {
  let endpoint = "";
  let apiKey = options?.apiKey || "";
  let model = options?.model || "";

  if (typeof endpointOrSettings === 'object' && endpointOrSettings !== null) {
    endpoint = endpointOrSettings.funasrHttpEndpoint || "";
    apiKey = apiKey || endpointOrSettings.asrApiKey || endpointOrSettings.apiKey || "";
    model = model || endpointOrSettings.asrModel || "";
  } else if (typeof endpointOrSettings === 'string') {
    endpoint = endpointOrSettings;
  }

  const normalizedEndpoint = normalizeHttpAsrUrl(endpoint);
  let blob: Blob;
  
  if (mediaUrl.startsWith('data:')) {
    const commaIndex = mediaUrl.indexOf(',');
    const base64Data = mediaUrl.substring(commaIndex + 1);
    const mimeMatch = mediaUrl.match(/data:([^;]+);/);
    const mimeType = mimeMatch ? mimeMatch[1] : 'audio/wav';
    
    const bstr = atob(base64Data);
    let n = bstr.length;
    const u8arr = new Uint8Array(n);
    while (n--) {
      u8arr[n] = bstr.charCodeAt(n);
    }
    blob = new Blob([u8arr], { type: mimeType });
  } else {
    const res = await fetch(mediaUrl);
    blob = await res.blob();
  }

  try {
    const formData = new FormData();
    formData.append('file', blob, 'audio.wav');
    formData.append('audio', blob, 'audio.wav');
    formData.append('audio_in', blob, 'audio.wav');
    if (model) {
      formData.append('model', model);
    }
    
    const baseUrl = Capacitor.isNativePlatform() ? API_BASE_URL : '';
    let proxyUrl = `${baseUrl}/api/funasr-transcribe?endpoint=${encodeURIComponent(normalizedEndpoint)}`;
    if (model) {
      proxyUrl += `&model=${encodeURIComponent(model)}`;
    }
    
    const headers: Record<string, string> = {};
    if (apiKey) {
      headers['x-asr-api-key'] = apiKey;
      headers['Authorization'] = `Bearer ${apiKey}`;
    }

    const response = await fetch(proxyUrl, {
      method: 'POST',
      headers,
      body: formData,
    });
    
    if (!response.ok) {
      const errJson = await response.json().catch(() => ({}));
      throw new Error(errJson.error || `HTTP 错误 ${response.status}`);
    }
    const data = await response.json();
    const text = data.text || data.transcription || data.result || (Array.isArray(data.data) ? data.data[0] : null) || (data.data && data.data.text) || (typeof data === 'string' ? data : JSON.stringify(data));
    return typeof text === 'string' ? text.trim() : JSON.stringify(text);
  } catch (err) {
    console.error("ASR Transcribe connection error:", err);
    throw err;
  }
}
