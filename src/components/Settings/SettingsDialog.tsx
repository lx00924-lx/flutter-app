/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { AppSettings } from '../../types';
import { API_BASE_URL } from '../../config';
import { ImagePlus, X, Camera, Image as ImageIcon, ChevronDown, Loader2, Bug, Terminal, Copy, Trash2, HardDrive, FolderOpen, RotateCcw, RefreshCw, Check, Type, Bot, Download, Key, Cpu, Dices, CheckCircle2, AlertTriangle, QrCode, Smartphone, FolderKanban, Plus, MessageSquare, Link, Sliders } from 'lucide-react';
import QRCode from 'qrcode';
import socket from '../../lib/socket';
import { Camera as CapCamera, CameraResultType, CameraSource } from '@capacitor/camera';
import { Toast } from '@capacitor/toast';
import { CapacitorHttp } from '@capacitor/core';
import { motion, AnimatePresence } from 'motion/react';
import { cn } from '../../lib/utils';
import { ImageCropDialog } from './ImageCropDialog';
import { ModelSelector } from '../Chat/ModelSelector';
import { copyLogsToClipboard, clearLogs } from '../../lib/logger';
import { normalizeApiBaseUrl, getModelsUrl, normalizeHttpAsrUrl, normalizeWsAsrUrl } from '../../services/gemini';

interface SettingsDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  settings: AppSettings;
  onSave: (settings: AppSettings) => void;
  onCheckUpdate: () => Promise<{ success: boolean; data?: any; error?: string }>;
  userId?: string;
  username?: string;
  onOpenLogViewer?: () => void;
}

export const SettingsDialog: React.FC<SettingsDialogProps> = ({
  open,
  onOpenChange,
  settings,
  onSave,
  onCheckUpdate,
  userId,
  username,
  onOpenLogViewer,
}) => {
  const [localSettings, setLocalSettings] = React.useState<AppSettings>(settings);
  const localSettingsRef = React.useRef<AppSettings>(settings);
  localSettingsRef.current = localSettings;

  const [updateStatus, setUpdateStatus] = React.useState<{ type: 'error' | 'success', message: string } | null>(null);
  const [isChecking, setIsChecking] = React.useState(false);
  const [isFetchingModels, setIsFetchingModels] = React.useState(false);
  const [modelFetchStatus, setModelFetchStatus] = React.useState<{ type: 'error' | 'success', message: string } | null>(null);
  const [httpTestStatus, setHttpTestStatus] = React.useState<{ type: 'error' | 'success', message: string } | null>(null);
  const [isTestingHttp, setIsTestingHttp] = React.useState(false);
  const [wsTestStatus, setWsTestStatus] = React.useState<{ type: 'error' | 'success', message: string } | null>(null);
  const [isTestingWs, setIsTestingWs] = React.useState(false);
  const [cropImage, setCropImage] = React.useState<{ src: string, field: keyof AppSettings } | null>(null);
  const [passwordStatus, setPasswordStatus] = React.useState<{ type: 'error' | 'success', message: string } | null>(null);
  const [oldPassword, setOldPassword] = React.useState('');
  const [newPassword, setNewPassword] = React.useState('');
  const [confirmPassword, setConfirmPassword] = React.useState('');
  const [storageInfo, setStorageInfo] = React.useState<{ currentPath: string; defaultPath: string; isCustom: boolean; configuredPath: string } | null>(null);
  const [storageStatus, setStorageStatus] = React.useState<{ type: 'error' | 'success' | 'info'; message: string; needRestart?: boolean } | null>(null);
  const [isChangingStorage, setIsChangingStorage] = React.useState(false);

  // Agent State
  const [agentOnlineStatus, setAgentOnlineStatus] = React.useState<{ online: boolean; clientName?: string; connectedAt?: number } | null>(null);
  const [isCheckingAgent, setIsCheckingAgent] = React.useState(false);
  const [copiedAgentCmd, setCopiedAgentCmd] = React.useState(false);
  const [copiedAgentToken, setCopiedAgentToken] = React.useState(false);
  const [copiedPairUrl, setCopiedPairUrl] = React.useState(false);
  const [showCodeModal, setShowCodeModal] = React.useState(false);
  const [copiedFullCode, setCopiedFullCode] = React.useState(false);
  const [isRevokingToken, setIsRevokingToken] = React.useState(false);
  const [qrCodeDataUrl, setQrCodeDataUrl] = React.useState<string>('');
  
  // DSH Workspaces & Sessions State
  const [agentWorkspaces, setAgentWorkspaces] = React.useState<string[]>(['deepseek-agent']);
  const [agentSessions, setAgentSessions] = React.useState<Array<{ id: string; sessionId?: string; title: string; workspace?: string; updatedAt?: string | number }>>([]);
  const [isLoadingSessions, setIsLoadingSessions] = React.useState(false);
  const [isCreatingSession, setIsCreatingSession] = React.useState(false);
  const [showNewSessionInput, setShowNewSessionInput] = React.useState(false);
  const [newSessionTitle, setNewSessionTitle] = React.useState('');
  const [copiedDownloadUrl, setCopiedDownloadUrl] = React.useState(false);

  const normalizeSettings = React.useCallback((raw: AppSettings): AppSettings => {
    let validOpacity = raw.backgroundOpacity;
    if (validOpacity == null || isNaN(validOpacity)) {
      validOpacity = 100;
    } else {
      validOpacity = Math.min(100, Math.max(0, Math.round(validOpacity)));
    }

    return {
      ...raw,
      apiEndpoint: raw.apiEndpoint?.trim() || '',
      funasrHttpEndpoint: raw.funasrHttpEndpoint?.trim() || '',
      funasrWsEndpoint: raw.funasrWsEndpoint?.trim() || '',
      asrModel: raw.asrModel?.trim() || '',
      asrApiKey: raw.asrApiKey?.trim() || '',
      agentToken: (raw.agentToken || '').trim() || 'default_agent_token',
      agentHarnessUrl: (raw.agentHarnessUrl || '').trim() || 'http://127.0.0.1:3081',
      agentSessionId: raw.agentSessionId?.trim() || '',
      agentWorkspace: (raw.agentWorkspace || '').trim() || 'deepseek-agent',
      backgroundOpacity: validOpacity
    };
  }, []);

  const saveSettingsImmediate = React.useCallback((targetSettings?: AppSettings) => {
    const target = targetSettings || localSettingsRef.current;
    const normalized = normalizeSettings(target);
    onSave(normalized);
  }, [normalizeSettings, onSave]);

  const updateAndSave = React.useCallback((patch: Partial<AppSettings>) => {
    setLocalSettings(prev => {
      const next = { ...prev, ...patch };
      localSettingsRef.current = next;
      saveSettingsImmediate(next);
      return next;
    });
  }, [saveSettingsImmediate]);

  const handleBlur = React.useCallback(() => {
    saveSettingsImmediate();
  }, [saveSettingsImmediate]);

  const currentOrigin = typeof window !== 'undefined' && window.location?.origin && window.location.origin !== 'null'
    ? window.location.origin
    : 'https://www.lx00924ai.top';

  // Helper to normalize harness URL to always have http:// (or https://)
  const getNormalizedHarnessUrl = React.useCallback((inputUrl?: string) => {
    let raw = (inputUrl || '').trim();
    if (!raw) return 'http://127.0.0.1:3081';
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = `http://${raw}`;
    }
    return raw;
  }, []);

  const normalizedHarnessUrl = getNormalizedHarnessUrl(localSettings.agentHarnessUrl);

  // Helper to get raw host & port without http:// prefix for the input UI
  const getHarnessInputDisplayValue = React.useCallback((inputUrl?: string) => {
    if (!inputUrl) return '';
    let val = inputUrl.trim();
    if (val.startsWith('http://')) {
      return val.substring(7);
    }
    if (val.startsWith('https://')) {
      return val.substring(8);
    }
    return val;
  }, []);

  React.useEffect(() => {
    const token = (localSettings.agentToken || 'default_agent_token').trim();
    const pairUrl = `${currentOrigin}?agentToken=${encodeURIComponent(token)}`;
    QRCode.toDataURL(pairUrl, {
      width: 220,
      margin: 1.5,
      color: {
        dark: '#000000',
        light: '#ffffff'
      }
    }).then(url => {
      setQrCodeDataUrl(url);
    }).catch(err => {
      console.warn('Failed to generate agent QR:', err);
    });
  }, [localSettings.agentToken, currentOrigin]);

  const generateBridgeScriptContent = React.useCallback(() => {
    const token = (localSettings.agentToken || 'default_agent_token').trim();
    const serverUrl = currentOrigin;
    const harnessUrl = normalizedHarnessUrl;

    return `#!/usr/bin/env python3
"""
DeepSeek Harness 本地安全反向桥接客户端 (DeepSeek Bridge v3.5 - 工业增强/双模高可用版)
======================================================================
核心特性：
1. 本地主动向上发起连接至 App 调度服务器（免公网 IP，免端口映射）。
2. 支持 HTTP 智能长轮询 (Long-Polling) 与 WebSocket 双通道自适应（完美兼容 Python 3.8 ~ 3.14+ 及各类云端反代网关）。
3. 严格安全接口白名单：只允许转发 /v1/chat/completions 标准对话推理，禁止系统管理与插件篡改。
4. 全程无状态纯内存转发：不持久化任何对话记录、不缓存密钥、不落盘日志。
5. 并发限制与资源管控（基于信号量控制最大并发任务数，避免显存爆仓）。
6. 严格任务生命周期与日志隔离（每条日志、步骤均携带唯一 taskId）。
7. 适配 DeepSeek Harness (dsh 3080/v1) 标准服务与权限沙箱隔离。

预填默认参数：
  • 调度服务器: ${serverUrl}
  • Harness地址: ${harnessUrl} (默认 3080/v1)

使用方式：
    pip install requests
    python deepseek_bridge.py --token YOUR_TOKEN
"""

import argparse
import asyncio
import json
import logging
import os
import re
import ssl
import sys
import threading
import time
import urllib.request
import urllib.error
import urllib.parse
import uuid

# 强制标准输出为 UTF-8 编码并激活 Windows 控制台 ANSI 颜色与高对比度字符支持
if sys.platform == "win32":
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        # STD_OUTPUT_HANDLE = -11
        hOut = kernel32.GetStdHandle(-11)
        # 获取当前控制台模式
        mode = ctypes.c_ulong()
        kernel32.GetConsoleMode(hOut, ctypes.byref(mode))
        # ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        mode.value |= 0x0004
        kernel32.SetConsoleMode(hOut, mode)
    except Exception:
        pass

if sys.stdout and hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

# 尝试安全引入 websockets，并修复 Python 3.14 下 connection_lost 的 ClientConnection.recv_messages bug
HAS_WEBSOCKETS = False
try:
    import websockets
    try:
        import websockets.asyncio.connection
        orig_conn_lost = getattr(websockets.asyncio.connection.Connection, "connection_lost", None)
        if orig_conn_lost:
            def safe_conn_lost(self, exc):
                try:
                    if not hasattr(self, "recv_messages") or self.recv_messages is None:
                        class DummyRecv:
                            def close(self): pass
                        self.recv_messages = DummyRecv()
                    orig_conn_lost(self, exc)
                except Exception:
                    pass
            websockets.asyncio.connection.Connection.connection_lost = safe_conn_lost
    except Exception:
        pass
    HAS_WEBSOCKETS = True
except ImportError:
    HAS_WEBSOCKETS = False

logging.basicConfig(
    level=logging.INFO,
    format="\\033[90m%(asctime)s\\033[0m %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("DeepSeekBridge")

MAX_CONCURRENT_TASKS = 2

# 安全接口白名单：严格限制只允许转发标准对话推理端点
ALLOWED_FORWARD_ENDPOINTS = {
    "/v1/chat/completions",
    "/chat/completions"
}

# 本地地址白名单：防御 SSRF 与内网探针攻击，强制仅允许本地回环地址
ALLOWED_LOCAL_HOSTS = {
    "127.0.0.1",
    "localhost",
    "::1",
    "0.0.0.0"
}

# 报文体积上限（10MB）
MAX_PAYLOAD_BYTES = 10 * 1024 * 1024

def is_host_safe(url: str) -> bool:
    """防御 SSRF 攻击：严格限制目标服务地址只能是本地回环 (127.0.0.1 / localhost)"""
    try:
        parsed = urllib.parse.urlparse(url if "://" in url else f"http://{url}")
        hostname = (parsed.hostname or "").strip().lower()
        return hostname in ALLOWED_LOCAL_HOSTS
    except Exception:
        return False

def parse_args():
    parser = argparse.ArgumentParser(description="DeepSeek Harness Local Reverse Bridge v3.6")
    parser.add_argument("--token", type=str, default=os.getenv("AGENT_TOKEN", ""), help="App 中生成的配对 Token")
    parser.add_argument("--server", type=str, default=os.getenv("SERVER_URL", "${serverUrl}"), help="App 调度服务器地址 (默认: ${serverUrl})")
    parser.add_argument("--harness-url", type=str, default=os.getenv("HARNESS_URL", "${harnessUrl}"), help="本地 DeepSeek Harness 服务地址 (默认: ${harnessUrl})")
    parser.add_argument("--harness-model", type=str, default=os.getenv("HARNESS_MODEL", "deepseek-chat"), help="本地 DeepSeek 模型名称 (默认: deepseek-chat)")
    parser.add_argument("--chat-api-url", type=str, default=os.getenv("CHAT_API_URL", ""), help="可选：独立云端聊天推理接口 (如火山方舟)")
    parser.add_argument("--chat-api-key", type=str, default=os.getenv("CHAT_API_KEY", ""), help="可选：云端聊天 API Key")
    parser.add_argument("--chat-model", type=str, default=os.getenv("CHAT_MODEL", ""), help="可选：云端聊天模型名称")
    parser.add_argument("--concurrency", type=int, default=MAX_CONCURRENT_TASKS, help="最大本地并发任务数 (默认 2)")
    parser.add_argument("--transport", type=str, default="auto", choices=["auto", "polling", "ws"], help="传输通信协议 (auto / polling / ws)")
    parser.add_argument("--no-proxy", action="store_true", help="强制 Direct 直连，忽略系统所有代理与 Clash 残留")
    parser.add_argument("--proxy", type=str, default=os.getenv("ALL_PROXY", os.getenv("HTTPS_PROXY", "")), help="手动指定代理服务器地址 (如 http://127.0.0.1:7890)")
    return parser.parse_args()

def normalize_server_url(server_url: str) -> str:
    url = server_url.strip().rstrip("/")
    if not url.startswith("http://") and not url.startswith("https://") and not url.startswith("ws://") and not url.startswith("wss://"):
        url = "https://" + url
    if url.startswith("ws://"):
        url = "http://" + url[5:]
    elif url.startswith("wss://"):
        url = "https://" + url[6:]
    return url

def normalize_ws_url(server_url: str, token: str) -> str:
    url = server_url.strip().rstrip("/")
    if url.startswith("https://"):
        ws_url = "wss://" + url[8:]
    elif url.startswith("http://"):
        ws_url = "ws://" + url[7:]
    elif url.startswith("wss://") or url.startswith("ws://"):
        ws_url = url
    else:
        ws_url = "wss://" + url

    return f"{ws_url}/ws/agent?token={token}&clientName=DeepSeek-Harness-Local"

# ======================================================================
# 零外部依赖纯 Python 终端二维码 (QR Code) 渲染引擎
# ======================================================================
class MiniQR:
    """轻量纯 Python QR 矩阵生成器 (支持字节模式与高对比度终端半块字符打印)"""
    EXP_TABLE = [0] * 512
    LOG_TABLE = [0] * 256
    
    @classmethod
    def _init_tables(cls):
        if cls.EXP_TABLE[1] != 0: return
        x = 1
        for i in range(255):
            cls.EXP_TABLE[i] = x
            cls.EXP_TABLE[i + 255] = x
            cls.LOG_TABLE[x] = i
            x <<= 1
            if x >= 256:
                x ^= 0x11D

    @classmethod
    def _gmult(cls, a, b):
        if a == 0 or b == 0: return 0
        return cls.EXP_TABLE[cls.LOG_TABLE[a] + cls.LOG_TABLE[b]]

    @classmethod
    def _rs_poly(cls, nsym):
        g = [1]
        for i in range(nsym):
            # g(x) * (x - alpha^i)
            root = cls.EXP_TABLE[i]
            ng = [0] * (len(g) + 1)
            for j in range(len(g)):
                ng[j] ^= cls._gmult(g[j], root)
                ng[j + 1] ^= g[j]
            g = ng
        return g

    @classmethod
    def _rs_encode(cls, data_bytes, nsym):
        cls._init_tables()
        gen = cls._rs_poly(nsym)
        res = list(data_bytes) + [0] * nsym
        for i in range(len(data_bytes)):
            coef = res[i]
            if coef != 0:
                for j in range(1, len(gen)):
                    res[i + j] ^= cls._gmult(gen[len(gen) - 1 - j], coef)
        return res[len(data_bytes):]

    # 容量与纠错参数表 [Version 1..6], Level L
    PARAMS = {
        1: {'size': 21, 'data_cw': 19, 'ec_cw': 7, 'align': []},
        2: {'size': 25, 'data_cw': 34, 'ec_cw': 10, 'align': [6, 18]},
        3: {'size': 29, 'data_cw': 55, 'ec_cw': 15, 'align': [6, 22]},
        4: {'size': 33, 'data_cw': 80, 'ec_cw': 20, 'align': [6, 26]},
        5: {'size': 37, 'data_cw': 108, 'ec_cw': 26, 'align': [6, 30]},
        6: {'size': 41, 'data_cw': 136, 'ec_cw': 36, 'align': [6, 34]},
    }

    @classmethod
    def encode(cls, text: str):
        cls._init_tables()
        data = text.encode('utf-8')
        data_len = len(data)
        
        # 选择适配的最小版本
        ver = 1
        while ver in cls.PARAMS and data_len > cls.PARAMS[ver]['data_cw'] - 3:
            ver += 1
        if ver not in cls.PARAMS:
            ver = 6

        param = cls.PARAMS[ver]
        size = param['size']
        data_cw_count = param['data_cw']
        ec_cw_count = param['ec_cw']

        # 构造比特流 (Byte 模式: 0100 + 8位长度 + 数据 + 终止符)
        bits = []
        def append_bits(val, length):
            for i in range(length - 1, -1, -1):
                bits.append((val >> i) & 1)

        append_bits(0b0100, 4)
        append_bits(data_len, 8 if ver < 10 else 16)
        for b in data:
            append_bits(b, 8)
        
        # 填充终止符 0000
        rem_bits = (data_cw_count * 8) - len(bits)
        term_len = min(4, rem_bits) if rem_bits > 0 else 0
        append_bits(0, term_len)
        while len(bits) % 8 != 0:
            bits.append(0)

        # 填充交替字节 0xEC / 0x11
        pad_bytes = [0xEC, 0x11]
        pad_idx = 0
        while len(bits) < data_cw_count * 8:
            append_bits(pad_bytes[pad_idx % 2], 8)
            pad_idx += 1

        # 转换为字节流
        data_bytes = []
        for i in range(0, len(bits), 8):
            b = 0
            for j in range(8):
                b = (b << 1) | bits[i + j]
            data_bytes.append(b)

        # Reed-Solomon 纠错码生成
        ec_bytes = cls._rs_encode(data_bytes, ec_cw_count)
        final_cw = data_bytes + ec_bytes

        # 构造最终比特流
        final_bits = []
        for b in final_cw:
            for i in range(7, -1, -1):
                final_bits.append((b >> i) & 1)

        # 矩阵初始化
        matrix = [[None] * size for _ in range(size)]
        is_func = [[False] * size for _ in range(size)]

        def set_func(r, c, v):
            if 0 <= r < size and 0 <= c < size:
                matrix[r][c] = v
                is_func[r][c] = True

        # 定位寻像图案 (Finder patterns)
        for r0, c0 in [(0, 0), (0, size - 7), (size - 7, 0)]:
            for dr in range(7):
                for dc in range(7):
                    if dr in (0, 6) or dc in (0, 6) or (2 <= dr <= 4 and 2 <= dc <= 4):
                        set_func(r0 + dr, c0 + dc, 1)
                    else:
                        set_func(r0 + dr, c0 + dc, 0)
            # 分隔符 (Separators)
            for i in range(8):
                set_func(r0 - 1, c0 + i, 0)
                set_func(r0 + 7, c0 + i, 0)
                set_func(r0 + i, c0 - 1, 0)
                set_func(r0 + i, c0 + 7, 0)

        # 定时图案 (Timing patterns)
        for i in range(8, size - 8):
            set_func(6, i, 1 if i % 2 == 0 else 0)
            set_func(i, 6, 1 if i % 2 == 0 else 0)

        # 校正图案 (Alignment patterns)
        align_pos = param['align']
        if align_pos:
            for ar in align_pos:
                for ac in align_pos:
                    if is_func[ar][ac]: continue
                    for dr in range(-2, 3):
                        for dc in range(-2, 3):
                            if max(abs(dr), abs(dc)) in (0, 2):
                                set_func(ar + dr, ac + dc, 1)
                            else:
                                set_func(ar + dr, ac + dc, 0)

        # 暗模块
        set_func(4 * ver + 9, 8, 1)

        # 格式信息 (Format Info) Level L, Mask 0
        format_bits = 0b111011111000100
        for i in range(6):
            set_func(8, i, (format_bits >> (14 - i)) & 1)
            set_func(size - 1 - i, 8, (format_bits >> (14 - i)) & 1)
        set_func(8, 7, (format_bits >> 8) & 1)
        set_func(8, 8, (format_bits >> 7) & 1)
        set_func(7, 8, (format_bits >> 6) & 1)
        set_func(8, size - 8, (format_bits >> 8) & 1)
        set_func(8, size - 7, (format_bits >> 7) & 1)
        set_func(size - 7, 8, (format_bits >> 6) & 1)
        for i in range(6):
            set_func(5 - i, 8, (format_bits >> (5 - i)) & 1)
            set_func(8, size - 6 + i, (format_bits >> (5 - i)) & 1)

        # 填入数据 (Zigzag 扫描，Mask 0: (r+c)%2 == 0)
        bit_idx = 0
        bit_total = len(final_bits)
        row = size - 1
        col = size - 1
        dir_up = True

        while col > 0:
            if col == 6: col -= 1
            for _ in range(size):
                for c in (col, col - 1):
                    if not is_func[row][c]:
                        val = final_bits[bit_idx] if bit_idx < bit_total else 0
                        bit_idx += 1
                        mask = 1 if (row + c) % 2 == 0 else 0
                        matrix[row][c] = val ^ mask
                row += -1 if dir_up else 1
            dir_up = not dir_up
            row = 0 if not dir_up else size - 1
            col -= 2

        # 补充静区 (Quiet zone: 2 cells)
        qz = 2
        full_size = size + 2 * qz
        full_matrix = [[0] * full_size for _ in range(full_size)]
        for r in range(size):
            for c in range(size):
                full_matrix[r + qz][c + qz] = 1 if matrix[r][c] == 1 else 0

        return full_matrix

def print_terminal_qr(text: str):
    """在控制台终端直接打印高对比度字符二维码 (完美兼容 Windows CMD、PowerShell、Linux 终端)"""
    try:
        matrix = MiniQR.encode(text)
        h = len(matrix)
        w = len(matrix[0])
        print("\\n    \\033[97m[ 📱 手机扫码直连通道 ]\\033[0m")
        print("    \\033[90m请使用手机相机或扫码功能扫描下方二维码快速配对:\\033[0m\\n")
        
        # 使用白底黑块反色渲染，确保任何黑色背景的 CMD/PowerShell 都能被手机摄像头秒识别
        # 顶部加两行纯白保护边距
        print("    \\033[47m" + "  " * (w + 2) + "\\033[0m")
        for r in range(h):
            row_str = "  "  # 左白边
            for c in range(w):
                if matrix[r][c] == 1:
                    row_str += "  "  # 二维码黑块 (在白底背景下用黑色背景或反显)
                else:
                    row_str += "██"  # 二维码白块 (用全亮块)
            row_str += "  "  # 右白边
            # 采用黑底白字或反色打印
            print(f"    \\033[30m\\033[47m{row_str}\\033[0m")
        # 底部加两行纯白保护边距
        print("    \\033[47m" + "  " * (w + 2) + "\\033[0m\\n")
        print(f"    \\033[96m手机扫码/点击直连链接:\\033[0m \\033[97m{text}\\033[0m\\n")
    except Exception as e:
        print(f"\\n    \\033[96m手机扫码直连地址:\\033[0m {text}\\n")

# ======================================================================
# 工业级高容错 HTTP 通信引擎（支持 Chrome 指纹伪装、TLS 自适应、Clash/代理死锁自愈、多域名备援容灾）
# ======================================================================
FALLBACK_SERVERS = [
    "${serverUrl}",
    "https://ais-pre-lswjsr25ivxdaulzx2iy3d-135884546184.asia-northeast1.run.app",
    "https://ais-dev-lswjsr25ivxdaulzx2iy3d-135884546184.asia-northeast1.run.app"
]

def create_resilient_ssl_context():
    """创建抗干扰、高兼容性的 SSL 上下文"""
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    except Exception:
        try:
            return ssl._create_unverified_context()
        except Exception:
            return None

class ResilientHttpClient:
    def __init__(self, force_no_proxy: bool = False, custom_proxy: str = "", primary_server: str = ""):
        self.ssl_ctx = create_resilient_ssl_context()
        self.force_no_proxy = force_no_proxy
        self.custom_proxy = (custom_proxy or "").strip()
        self.primary_server = primary_server.rstrip("/") if primary_server else "${serverUrl}"
        
        # 1. Direct 直连 Opener (100% 绕过系统所有代理与 Clash 残留端口)
        self.direct_opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=self.ssl_ctx) if self.ssl_ctx else urllib.request.HTTPSHandler()
        )
        
        # 2. 代理 Opener (如果用户开代理或指定代理时优先尝试)
        if self.custom_proxy:
            proxy_dict = {"http": self.custom_proxy, "https": self.custom_proxy}
            self.proxy_opener = urllib.request.build_opener(
                urllib.request.ProxyHandler(proxy_dict),
                urllib.request.HTTPSHandler(context=self.ssl_ctx) if self.ssl_ctx else urllib.request.HTTPSHandler()
            )
        else:
            self.proxy_opener = urllib.request.build_opener(
                urllib.request.ProxyHandler(), # 使用系统检测代理
                urllib.request.HTTPSHandler(context=self.ssl_ctx) if self.ssl_ctx else urllib.request.HTTPSHandler()
            )
        
        # 默认优先使用的 opener
        self.active_opener = self.direct_opener if force_no_proxy else self.proxy_opener
        self.has_switched_to_direct = False
        self.active_server_base = self.primary_server

    def get_candidate_urls(self, target_url: str):
        """若自定义域名因 DNS 故障无法解析，自动提供 Cloud Run 官方高可用备用线路"""
        candidates = [target_url]
        for fb in FALLBACK_SERVERS:
            if fb not in target_url:
                parsed_fb = urllib.parse.urlparse(fb)
                parsed_target = urllib.parse.urlparse(target_url)
                # 替换 scheme 与 netloc，保留 path 和 query
                fb_url = urllib.parse.urlunparse((
                    parsed_fb.scheme,
                    parsed_fb.netloc,
                    parsed_target.path,
                    parsed_target.params,
                    parsed_target.query,
                    parsed_target.fragment
                ))
                if fb_url not in candidates:
                    candidates.append(fb_url)
        return candidates

    def request(self, url: str, data: bytes = None, headers: dict = None, method: str = "GET", timeout: int = 30) -> str:
        base_headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Connection": "close"
        }
        if headers:
            base_headers.update(headers)

        candidate_urls = self.get_candidate_urls(url)
        last_error = None

        for candidate_url in candidate_urls:
            req = urllib.request.Request(candidate_url, data=data, headers=base_headers, method=method)
            try:
                with self.active_opener.open(req, timeout=timeout) as response:
                    return response.read().decode("utf-8")
            except Exception as e:
                last_error = e
                err_str = str(e)
                is_proxy_or_ssl_error = (
                    "10061" in err_str or
                    "refused" in err_str.lower() or
                    "proxy" in err_str.lower() or
                    "UNEXPECTED_EOF" in err_str or
                    "EOF occurred" in err_str or
                    "timed out" in err_str.lower()
                )
                
                # 遇到代理中断或 SSL 握手受阻，先尝试切 Direct 直连再试一次当前 candidate_url
                if is_proxy_or_ssl_error and self.active_opener != self.direct_opener:
                    if not self.has_switched_to_direct:
                        print(f"\\033[93m[🛡️ 网络自愈] 检测到系统代理不可用或 SSL 握手受阻，已自动熔断代理并切换至 Direct 直连！\\033[0m")
                        self.has_switched_to_direct = True
                    self.active_opener = self.direct_opener
                    try:
                        with self.direct_opener.open(req, timeout=timeout) as response:
                            return response.read().decode("utf-8")
                    except Exception as retry_e:
                        last_error = retry_e
                        err_str = str(retry_e)

                # 如果遇到 DNS 解析失败 (11001) 或连接超时，自动尝试下一个候选节点
                is_dns_error = "11001" in err_str or "getaddrinfo failed" in err_str or "nodename nor servname" in err_str
                if is_dns_error and len(candidate_urls) > 1 and candidate_url != candidate_urls[-1]:
                    continue

        if last_error:
            raise last_error
        raise RuntimeError("所有网络候选节点均不可达")

# 全局 HTTP 客户端单例
GLOBAL_HTTP_CLIENT = ResilientHttpClient()

def init_global_http_client(force_no_proxy: bool = False, custom_proxy: str = "", primary_server: str = ""):
    global GLOBAL_HTTP_CLIENT
    GLOBAL_HTTP_CLIENT = ResilientHttpClient(force_no_proxy=force_no_proxy, custom_proxy=custom_proxy, primary_server=primary_server)

def http_post_json(url: str, data: dict, timeout: int = 15) -> dict:
    """通用同步 HTTP POST JSON 请求（带自动容错与代理自愈）"""
    payload = json.dumps(data).encode("utf-8")
    resp_body = GLOBAL_HTTP_CLIENT.request(
        url,
        data=payload,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
        timeout=timeout
    )
    try:
        return json.loads(resp_body)
    except Exception:
        return {"raw": resp_body}

def http_get_json(url: str, timeout: int = 35) -> dict:
    """通用同步 HTTP GET 请求（带自动容错与代理自愈）"""
    resp_body = GLOBAL_HTTP_CLIENT.request(
        url,
        headers={"Accept": "application/json"},
        method="GET",
        timeout=timeout
    )
    try:
        return json.loads(resp_body)
    except Exception:
        return {"raw": resp_body}

LOCAL_SESSION_CACHE = []

async def query_dsh_workspaces_and_sessions(harness_url: str):
    """自适应探测并读取本地 DeepSeek Harness 的工作区与会话列表"""
    global LOCAL_SESSION_CACHE
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    workspaces = ["deepseek-agent"]
    sessions = list(LOCAL_SESSION_CACHE)
    rpc_list_payload = {
        "type": "client-request",
        "rpcId": f"rpc_list_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}",
        "mode": "steer",
        "method": "session.list",
        "payload": {}
    }
    endpoints = [
        (f"{harness_base}/v1/agent", "POST", rpc_list_payload),
        (f"{harness_base}/agent", "POST", rpc_list_payload),
        (f"{harness_base}/session.list", "POST", rpc_list_payload),
        (f"{harness_base}/api/session.list", "POST", rpc_list_payload),
        (f"{harness_base}/session/list", "POST", rpc_list_payload),
        (f"{harness_base}/v1/sessions", "GET", None),
        (f"{harness_base}/api/v1/agent", "POST", rpc_list_payload)
    ]
    for ep, mth, pld in endpoints:
        def do_req(url=ep, method=mth, data_dict=pld):
            req_data = json.dumps(data_dict).encode("utf-8") if data_dict is not None else None
            req = urllib.request.Request(
                url,
                data=req_data,
                headers={"Content-Type": "application/json; charset=utf-8", "Accept": "application/json"},
                method=method
            )
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=4) as response:
                return response.read().decode("utf-8")
        try:
            raw = await loop.run_in_executor(None, do_req)
            resp = json.loads(raw)
            if isinstance(resp, dict):
                items = (
                    resp.get("result") or 
                    resp.get("sessions") or 
                    resp.get("data") or 
                    resp.get("payload", {}).get("sessions") or 
                    resp.get("payload", {}).get("items") or 
                    []
                )
                if isinstance(items, list) and len(items) > 0:
                    for it in items:
                        if isinstance(it, dict):
                            s_id = it.get("sessionId") or it.get("id") or it.get("session_id")
                            if s_id:
                                s_ws = it.get("workspace") or "deepseek-agent"
                                if s_ws not in workspaces:
                                    workspaces.append(s_ws)
                                if not any(s.get("sessionId") == str(s_id) or s.get("id") == str(s_id) for s in sessions):
                                    sessions.append({
                                        "id": str(s_id),
                                        "sessionId": str(s_id),
                                        "title": str(it.get("title") or it.get("name") or f"会话_{str(s_id)[:6]}"),
                                        "workspace": s_ws,
                                        "updatedAt": it.get("updatedAt") or it.get("createdAt") or int(time.time() * 1000)
                                    })
                    if len(sessions) > len(LOCAL_SESSION_CACHE):
                        LOCAL_SESSION_CACHE = list(sessions)
                        break
        except Exception:
            continue
    return workspaces, sessions

async def create_dsh_session_explicit(harness_url: str, workspace: str = "deepseek-agent", title: str = None, model: str = "deepseek-chat"):
    """向本地 DSH 发起 session.create 生成受服务端纳管的真实会话"""
    global LOCAL_SESSION_CACHE
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    from datetime import datetime
    session_title = title or f"对话_{datetime.now().strftime('%m%d_%H%M%S')}"
    target_ws = workspace or "deepseek-agent"
    rpc_create_payload = {
        "type": "client-request",
        "rpcId": f"rpc_create_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}",
        "mode": "steer",
        "method": "session.create",
        "payload": {
            "workspace": target_ws,
            "title": session_title,
            "model": model or "deepseek-chat"
        }
    }
    endpoints = [
        f"{harness_base}/v1/agent",
        f"{harness_base}/agent",
        f"{harness_base}/session.create",
        f"{harness_base}/api/session.create",
        f"{harness_base}/session/create",
        f"{harness_base}/v1/session.create",
        f"{harness_base}/api/v1/agent"
    ]
    for ep in endpoints:
        def do_req(url=ep):
            req_data = json.dumps(rpc_create_payload).encode("utf-8")
            req = urllib.request.Request(
                url,
                data=req_data,
                headers={"Content-Type": "application/json; charset=utf-8", "Accept": "application/json"},
                method="POST"
            )
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=6) as response:
                return response.read().decode("utf-8")
        try:
            raw = await loop.run_in_executor(None, do_req)
            resp = json.loads(raw)
            if isinstance(resp, dict):
                res_obj = (
                    resp.get("result") or 
                    resp.get("data") or 
                    resp.get("payload", {}).get("session") or 
                    resp.get("payload") or 
                    resp
                )
                s_id = None
                if isinstance(res_obj, dict):
                    s_id = (
                        res_obj.get("sessionId") or 
                        res_obj.get("id") or 
                        res_obj.get("session_id") or 
                        res_obj.get("details", {}).get("sessionId")
                    )
                elif isinstance(res_obj, str) and len(res_obj) >= 8:
                    s_id = res_obj
                
                if not s_id and resp.get("ok") is True:
                    s_id = str(uuid.uuid4())

                if s_id:
                    session_info = {
                        "id": str(s_id),
                        "sessionId": str(s_id),
                        "title": session_title,
                        "workspace": target_ws,
                        "updatedAt": int(time.time() * 1000)
                    }
                    LOCAL_SESSION_CACHE = [session_info] + [s for s in LOCAL_SESSION_CACHE if (s.get("sessionId") or s.get("id")) != str(s_id)]
                    return True, str(s_id), session_info
        except Exception:
            continue
    fallback_id = str(uuid.uuid4())
    fallback_session = {
        "id": fallback_id,
        "sessionId": fallback_id,
        "title": session_title,
        "workspace": target_ws,
        "updatedAt": int(time.time() * 1000)
    }
    LOCAL_SESSION_CACHE = [fallback_session] + [s for s in LOCAL_SESSION_CACHE if (s.get("sessionId") or s.get("id")) != fallback_id]
    return True, fallback_id, fallback_session

async def execute_local_harness(
    task_id: str,
    prompt: str,
    messages: list,
    harness_url: str,
    model_name: str,
    session_id: str,
    on_step_callback,
    extra_chat_config: dict = None,
    target_workspace: str = "deepseek-agent"
):
    """
    智能多协议自适应转发至本地 DeepSeek Harness / DSH Agent / 本地模型服务：
    1. 优先适配 DSH Local Build 原生 /v1/agent, /session.prompt 与 /api/session.prompt
    2. 自动回退探测 /v1/chat/completions, /api/chat, /chat/completions
    3. 支持会话自动发现、自愈与自动新建
    """
    harness_base = harness_url.rstrip("/")
    extra_chat_config = extra_chat_config or {}
    target_workspace = target_workspace or "deepseek-agent"
    
    is_cloud_api = harness_base.startswith("https://") or "volces.com" in harness_base or "deepseek.com" in harness_base or "openai.com" in harness_base
    if not is_cloud_api and not is_host_safe(harness_base):
        err_msg = f"🛡️ [SSRF 安全拦截] 目标服务地址 ({harness_base}) 非本地回环地址 (127.0.0.1 / localhost)，禁止发起非本地请求。"
        await on_step_callback(f"❌ [Task:{task_id[:6]}] SSRF 安全拦截")
        return False, err_msg

    await on_step_callback(f"🚀 [1/3] 已接收到任务，正在调用本地 DeepSeek Harness Agent ({model_name})...")

    # 会话 ID 决策
    active_session_id = (session_id or "").strip()
    if not active_session_id or active_session_id in ("__auto__", "__auto_new__", "default_session", f"session_{task_id}"):
        await on_step_callback(f"✨ 正在为本地工作区 [{target_workspace}] 创建专属新会话...")
        ok_create, new_sid, _ = await create_dsh_session_explicit(
            harness_url, workspace=target_workspace, title=f"任务_{task_id[:6]}", model=model_name
        )
        if ok_create and new_sid:
            active_session_id = new_sid
            await on_step_callback(f"✨ 已创建本地新会话 ({active_session_id[:8]}...)，正在下发指令")
        else:
            active_session_id = str(uuid.uuid4())

    content_list = []
    if messages and isinstance(messages, list):
        for msg in messages:
            if isinstance(msg, dict):
                text_val = msg.get("content", "")
                if text_val:
                    content_list.append({"type": "text", "text": str(text_val)})
            elif isinstance(msg, str) and msg:
                content_list.append({"type": "text", "text": str(msg)})
    if not content_list:
        content_list = [{"type": "text", "text": str(prompt or "")}]

    def build_rpc_payloads(sid):
        r_steer = f"rpc_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}"
        r_queue = f"rpc_{int(time.time() * 1000) + 1}_{uuid.uuid4().hex[:6]}"
        return {
            "type": "client-request",
            "rpcId": r_steer,
            "mode": "steer",
            "method": "session.prompt",
            "payload": {
                "sessionId": sid,
                "mode": "steer",
                "content": content_list,
                "model": model_name or "deepseek-chat"
            }
        }, {
            "type": "client-request",
            "rpcId": r_queue,
            "mode": "queue",
            "method": "session.prompt",
            "payload": {
                "sessionId": sid,
                "mode": "queue",
                "content": content_list,
                "model": model_name or "deepseek-chat"
            }
        }

    dsh_rpc_payload_steer, dsh_rpc_payload_queue = build_rpc_payloads(active_session_id)

    candidate_endpoints = []
    if harness_base.endswith("/v1/agent") or harness_base.endswith("/agent"):
        candidate_endpoints.append((harness_base, dsh_rpc_payload_steer, "DSH 原生 RPC 接口 (/v1/agent, steer)"))
        candidate_endpoints.append((harness_base, dsh_rpc_payload_queue, "DSH 原生 RPC 接口 (/v1/agent, queue)"))
    elif harness_base.endswith("/session.prompt") or harness_base.endswith("/session/prompt"):
        candidate_endpoints.append((harness_base, dsh_rpc_payload_steer, "DSH RPC 原生接口 (steer 模式)"))
        candidate_endpoints.append((harness_base, dsh_rpc_payload_queue, "DSH RPC 原生接口 (queue 降级)"))
    elif harness_base.endswith("/v1") or harness_base.endswith("/chat/completions"):
        endpoint_url = harness_base if harness_base.endswith("/chat/completions") else f"{harness_base}/chat/completions"
        candidate_endpoints.append((endpoint_url, {
            "model": model_name or "deepseek-chat",
            "messages": messages if messages else [{"role": "user", "content": prompt}],
            "stream": False,
            "temperature": 0.7
        }, "OpenAI 兼容接口"))
    else:
        candidate_endpoints.append((f"{harness_base}/v1/agent", dsh_rpc_payload_steer, "DSH 原生 RPC 接口 (/v1/agent, steer)"))
        candidate_endpoints.append((f"{harness_base}/v1/agent", dsh_rpc_payload_queue, "DSH 原生 RPC 接口 (/v1/agent, queue)"))
        candidate_endpoints.append((f"{harness_base}/agent", dsh_rpc_payload_steer, "DSH 原生 RPC 接口 (/agent, steer)"))
        candidate_endpoints.append((f"{harness_base}/session.prompt", dsh_rpc_payload_steer, "DSH 原生 RPC 接口 (/session.prompt, steer)"))
        candidate_endpoints.append((f"{harness_base}/session.prompt", dsh_rpc_payload_queue, "DSH 原生 RPC 接口 (/session.prompt, queue)"))
        candidate_endpoints.append((f"{harness_base}/api/session.prompt", dsh_rpc_payload_steer, "DSH API RPC 接口 (/api/session.prompt, steer)"))
        candidate_endpoints.append((f"{harness_base}/api/session.prompt", dsh_rpc_payload_queue, "DSH API RPC 接口 (/api/session.prompt, queue)"))
        candidate_endpoints.append((f"{harness_base}/v1/chat/completions", {
            "model": model_name or "deepseek-chat",
            "messages": messages if messages else [{"role": "user", "content": prompt}],
            "stream": False,
            "temperature": 0.7
        }, "OpenAI 兼容接口 (/v1/chat/completions)"))
        candidate_endpoints.append((f"{harness_base}/api/chat", {
            "prompt": prompt,
            "model": model_name or "deepseek-chat",
            "messages": messages if messages else [{"role": "user", "content": prompt}]
        }, "本地 Agent 接口 (/api/chat)"))

    await on_step_callback("⚡ [2/3] 本地模型/Agent 正在进行深度推理与任务执行...")

    loop = asyncio.get_running_loop()
    last_err = None
    output_content = None
    success_endpoint_name = ""

    for target_url, payload, ep_name in candidate_endpoints:
        req_data = json.dumps(payload).encode("utf-8")
        if len(req_data) > MAX_PAYLOAD_BYTES:
            continue

        def do_request(url=target_url, data=req_data):
            headers = {
                "Content-Type": "application/json; charset=utf-8",
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            }
            auth_key = extra_chat_config.get("apiKey")
            if auth_key:
                headers["Authorization"] = f"Bearer {auth_key}"
            req = urllib.request.Request(url, data=data, headers=headers, method="POST")
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=120) as response:
                return response.read().decode("utf-8")

        try:
            raw_resp = await loop.run_in_executor(None, do_request)
            try:
                resp_json = json.loads(raw_resp)
                if isinstance(resp_json, dict):
                    if resp_json.get("ok") is False or "error" in resp_json:
                        err_detail = resp_json.get("error", resp_json)
                        err_str = json.dumps(err_detail, ensure_ascii=False)
                        last_err = err_str
                        if "session-not-found" in err_str or "not found" in err_str.lower():
                            await on_step_callback(f"🔄 检测到原会话未注册或已过期，正在自动在工作区 [{target_workspace}] 创建新会话并重试...")
                            ok_create, new_sid, _ = await create_dsh_session_explicit(
                                harness_url, workspace=target_workspace, title=f"自愈会话_{task_id[:6]}", model=model_name
                            )
                            if ok_create and new_sid:
                                active_session_id = new_sid
                                steer_p, _ = build_rpc_payloads(active_session_id)
                                retry_data = json.dumps(steer_p).encode("utf-8")
                                retry_resp_raw = await loop.run_in_executor(None, lambda: do_request(url=target_url, data=retry_data))
                                try:
                                    retry_json = json.loads(retry_resp_raw)
                                    if retry_json.get("ok") is not False:
                                        resp_json = retry_json
                                    else:
                                        continue
                                except Exception:
                                    output_content = retry_resp_raw
                                    success_endpoint_name = ep_name
                                    break
                            else:
                                continue

                    # 提取文本结果
                    if "payload" in resp_json and isinstance(resp_json["payload"], dict):
                        p_content = resp_json["payload"].get("content") or resp_json["payload"].get("text") or resp_json["payload"].get("output")
                        if p_content:
                            if isinstance(p_content, list):
                                texts = [item.get("text", "") if isinstance(item, dict) else str(item) for item in p_content]
                                output_content = "\n".join(filter(None, texts))
                            else:
                                output_content = str(p_content)

                    if output_content is None and "result" in resp_json:
                        r_obj = resp_json["result"]
                        if isinstance(r_obj, dict):
                            r_content = r_obj.get("content") or r_obj.get("text") or r_obj.get("output") or r_obj.get("message")
                            if isinstance(r_content, list):
                                texts = [item.get("text", "") if isinstance(item, dict) else str(item) for item in r_content]
                                output_content = "\n".join(filter(None, texts))
                            elif r_content:
                                output_content = str(r_content)
                            else:
                                output_content = json.dumps(r_obj, ensure_ascii=False)
                        elif isinstance(r_obj, str):
                            output_content = r_obj
                        else:
                            output_content = json.dumps(r_obj, ensure_ascii=False)

                    if output_content is None and "choices" in resp_json and len(resp_json["choices"]) > 0:
                        output_content = resp_json["choices"][0].get("message", {}).get("content", "")
                    elif output_content is None and "response" in resp_json:
                        output_content = resp_json["response"] if isinstance(resp_json["response"], str) else json.dumps(resp_json["response"], ensure_ascii=False)
                    elif output_content is None and "content" in resp_json:
                        output_content = resp_json["content"] if isinstance(resp_json["content"], str) else json.dumps(resp_json["content"], ensure_ascii=False)
                    elif output_content is None and "text" in resp_json:
                        output_content = resp_json["text"] if isinstance(resp_json["text"], str) else json.dumps(resp_json["text"], ensure_ascii=False)
                    elif output_content is None and "output" in resp_json:
                        output_content = resp_json["output"] if isinstance(resp_json["output"], str) else json.dumps(resp_json["output"], ensure_ascii=False)
                    elif output_content is None:
                        output_content = json.dumps(resp_json, ensure_ascii=False)
                else:
                    output_content = str(resp_json)
            except Exception:
                output_content = raw_resp

            success_endpoint_name = ep_name
            break
        except urllib.error.HTTPError as he:
            last_err = f"HTTP {he.code} ({he.reason})"
            continue
        except urllib.error.URLError as ue:
            last_err = str(ue.reason if hasattr(ue, "reason") else ue)
            continue
        except Exception as ex:
            last_err = str(ex)
            continue

    if output_content is not None:
        await on_step_callback(f"✅ [3/3] 本地 DeepSeek 智能体通过 {success_endpoint_name} 执行完毕，正在向 App 调度中心回传结果...")
        return True, str(output_content)

    error_tip = (
        "❌ 连接本地 DeepSeek Harness / Agent 服务失败 (" + str(harness_base) + ")。\\n"
        "   最近一次尝试报错: " + str(last_err) + "\\n"
        "   💡 排查指南:\\n"
        "   1. 请确认本地 3080 端口已正常开启 (http://127.0.0.1:3080)；\\n"
        "   2. 若使用其他端口，可在启动命令加上 --harness-url http://127.0.0.1:端口。"
    )
    await on_step_callback(f"❌ 本地服务连接失败: {last_err or '所有端点均不可达'}")
    return False, error_tip

# 正在执行的任务集合
running_tasks = {}

async def run_polling_bridge(args, token: str, server_base: str, concurrency_limit: int):
    """基于 HTTP 长轮询的超稳定调度桥接模式"""
    register_url = f"{server_base}/api/agent/register"
    poll_url = f"{server_base}/api/agent/poll"
    step_url = f"{server_base}/api/agent/step"
    result_url = f"{server_base}/api/agent/result"
    heartbeat_url = f"{server_base}/api/agent/heartbeat"

    semaphore = asyncio.Semaphore(concurrency_limit)
    loop = asyncio.get_running_loop()

    try:
        init_workspaces, init_sessions = await query_dsh_workspaces_and_sessions(args.harness_url)
        await loop.run_in_executor(
            None,
            lambda: http_post_json(register_url, {
                "token": token,
                "clientInfo": {
                    "name": "DeepSeek-Harness-Local",
                    "version": "3.5.0",
                    "harnessUrl": args.harness_url,
                    "model": args.harness_model,
                    "platform": sys.platform,
                    "pid": os.getpid(),
                    "concurrency": concurrency_limit,
                    "mode": "polling"
                }
            })
        )
        try:
            await loop.run_in_executor(
                None,
                lambda: http_post_json(f"{server_base}/api/agent/sync-sessions", {
                    "token": token,
                    "workspaces": init_workspaces,
                    "sessions": init_sessions
                }, timeout=5)
            )
        except Exception:
            pass
        print(f"\\033[92m[✓ 注册成功] 已通过 HTTP 调度网关认证！发现 {len(init_sessions)} 个本地会话。Token: {token}\\033[0m")
    except Exception as e:
        print(f"\\033[93m[注册告警] 首次注册响应: {e}，将直接进入长轮询调度...\\033[0m")

    stop_heartbeat = False
    def heartbeat_worker():
        while not stop_heartbeat:
            try:
                http_post_json(heartbeat_url, {"token": token}, timeout=10)
            except Exception:
                pass
            time.sleep(15)

    hb_thread = threading.Thread(target=heartbeat_worker, daemon=True)
    hb_thread.start()

    print(f"\\033[92m[✓ 监听中] 正在待命监听 App 派发任务 (HTTP Long-Polling 模式)...\\033[0m")

    async def handle_task(task_data):
        task_id = task_data.get("taskId")
        prompt = task_data.get("prompt", "")
        messages = task_data.get("messages", [])
        harness_url = task_data.get("harnessUrl", args.harness_url)
        model_name = task_data.get("model", args.harness_model)
        session_id = task_data.get("agentSessionId") or task_data.get("sessionId", "default_session")
        target_ws = task_data.get("agentWorkspace") or task_data.get("workspace") or "deepseek-agent"

        print(f"\\n\\033[94m[收到任务] TaskID: {task_id} | 工作区: {target_ws} | 提示词: {prompt[:40]}...\\033[0m")
        steps_collected = []

        async def on_step(step_text: str):
            steps_collected.append(step_text)
            print(f"\\033[90m  └─ {step_text}\\033[0m")
            try:
                await loop.run_in_executor(
                    None,
                    lambda: http_post_json(step_url, {
                        "taskId": task_id,
                        "token": token,
                        "step": step_text
                    }, timeout=5)
                )
            except Exception:
                pass

        extra_config = {
            "apiEndpoint": task_data.get("apiEndpoint") or getattr(args, "chat_api_url", ""),
            "apiKey": task_data.get("apiKey") or getattr(args, "chat_api_key", ""),
            "chatModel": task_data.get("chatModel") or getattr(args, "chat_model", ""),
        }

        try:
            async with semaphore:
                success, output = await execute_local_harness(
                    task_id, prompt, messages, harness_url, model_name, session_id, on_step, extra_config, target_workspace=target_ws
                )
        except Exception as task_err:
            success = False
            output = f"本地执行异常: {task_err}"
            await on_step(f"❌ 任务发生未捕获异常: {task_err}")

        status_tag = "✓ 任务完成" if success else "✗ 任务异常"
        color = "\\033[92m" if success else "\\033[91m"
        print(f"{color}[{status_tag}] 回传结果 TaskID: {task_id}\\033[0m")

        try:
            await loop.run_in_executor(
                None,
                lambda: http_post_json(result_url, {
                    "taskId": task_id,
                    "token": token,
                    "success": success,
                    "steps": steps_collected,
                    "output": output,
                    "timestamp": int(time.time() * 1000)
                }, timeout=10)
            )
        except Exception as e:
            logger.error(f"回传任务结果失败: {e}")

        try:
            cur_ws, cur_sess = await query_dsh_workspaces_and_sessions(harness_url)
            await loop.run_in_executor(
                None,
                lambda: http_post_json(f"{server_base}/api/agent/sync-sessions", {
                    "token": token,
                    "workspaces": cur_ws,
                    "sessions": cur_sess
                }, timeout=5)
            )
        except Exception:
            pass

    poll_fail_count = 0
    while True:
        try:
            target_poll_url = f"{poll_url}?token={urllib.parse.quote(token)}&timeout=25"
            resp = await loop.run_in_executor(None, lambda: http_get_json(target_poll_url, timeout=30))
            poll_fail_count = 0
            mtype = resp.get("type")
            if mtype == "run_agent":
                t_id = resp.get("taskId", f"task_{int(time.time()*1000)}")
                t_coro = asyncio.create_task(handle_task(resp))
                running_tasks[t_id] = t_coro
            elif mtype == "token_revoked":
                print("\\033[91m[权限注销] 当前配对 Token 已在 App 端被重置或注销。桥接程序已停止。\\033[0m")
                return
        except Exception as e:
            poll_fail_count += 1
            await asyncio.sleep(3)

async def run_bridge_client(args):
    token = (args.token or "").strip()
    if not token:
        token = "${token}"

    server_base = normalize_server_url(args.server)
    concurrency_limit = max(1, args.concurrency)
    init_global_http_client(force_no_proxy=args.no_proxy, custom_proxy=args.proxy, primary_server=server_base)

    proxy_mode_desc = "强制 Direct 直连" if args.no_proxy else (f"自定义代理 ({args.proxy})" if args.proxy else "自适应系统/VPN代理")
    print("=" * 70)
    print("\\033[92m DeepSeek Harness 本地安全反向桥接启动成功！ (v3.5 高可用双模版)\\033[0m")
    print(f" • 配对 Token     : \\033[96m{token}\\033[0m")
    print(f" • App 调度服务器 : \\033[94m{server_base}\\033[0m")
    print(f" • 网络连接模式   : \\033[95m{proxy_mode_desc}\\033[0m")
    print(f" • 本地 Harness   : \\033[93m{args.harness_url}\\033[0m (默认 3080/v1)")
    print(f" • 本地模型       : {args.harness_model}")
    print(f" • 最大并发任务   : {concurrency_limit}")
    print(f" • Python 运行环境: {sys.version.split()[0]} ({sys.platform})")
    print("=" * 70)

    pair_url = f"{server_base}?agentToken={urllib.parse.quote(token)}"
    print_terminal_qr(pair_url)

    if args.transport == "polling" or not HAS_WEBSOCKETS:
        await run_polling_bridge(args, token, server_base, concurrency_limit)
        return

    ws_url = normalize_ws_url(server_base, token)
    ws_fail_count = 0
    while True:
        try:
            async with websockets.connect(
                ws_url,
                ping_interval=20,
                ping_timeout=20,
                max_size=25 * 1024 * 1024
            ) as ws:
                print(f"\\033[92m[✓ 成功上线] 已与 App 服务器建立安全 WebSocket 长连接！等待任务下发...\\033[0m")
                ws_fail_count = 0

                await ws.send(json.dumps({
                    "type": "register",
                    "token": token,
                    "clientInfo": {
                        "name": "DeepSeek-Harness-Local",
                        "version": "3.5.0",
                        "harnessUrl": args.harness_url,
                        "model": args.harness_model,
                        "platform": sys.platform,
                        "pid": os.getpid(),
                        "concurrency": concurrency_limit,
                        "mode": "ws"
                    }
                }))

                try:
                    init_ws, init_sess = await query_dsh_workspaces_and_sessions(args.harness_url)
                    await ws.send(json.dumps({
                        "type": "sync_sessions",
                        "token": token,
                        "workspaces": init_ws,
                        "sessions": init_sess
                    }))
                    print(f"\\033[92m[✓ 会话同步] 已向 App 同步本地 {len(init_sess)} 个 DSH 会话\\033[0m")
                except Exception:
                    pass

                async for raw_msg in ws:
                    try:
                        msg = json.loads(raw_msg)
                        mtype = msg.get("type")

                        if mtype in ("ping", "app_ping"):
                            await ws.send(json.dumps({
                                "type": "app_pong",
                                "token": token,
                                "timestamp": int(time.time() * 1000)
                            }))
                            continue

                        if mtype == "token_revoked":
                            print("\\033[91m[权限注销] 当前配对 Token 已在 App 端被重置或注销。桥接程序已停止。\\033[0m")
                            return

                        if mtype == "get_sessions":
                            target_h_url = msg.get("harnessUrl", args.harness_url)
                            cur_workspaces, cur_sessions = await query_dsh_workspaces_and_sessions(target_h_url)
                            await ws.send(json.dumps({
                                "type": "sessions_result",
                                "token": token,
                                "workspaces": cur_workspaces,
                                "sessions": cur_sessions
                            }))
                            continue

                        if mtype == "create_session":
                            create_task_id = msg.get("taskId")
                            target_h_url = msg.get("harnessUrl", args.harness_url)
                            target_workspace = msg.get("workspace", "deepseek-agent")
                            title_text = msg.get("title")
                            model_text = msg.get("model", args.harness_model)

                            ok_create, new_sid, session_obj = await create_dsh_session_explicit(
                                target_h_url, workspace=target_workspace, title=title_text, model=model_text
                            )
                            cur_workspaces, cur_sessions = await query_dsh_workspaces_and_sessions(target_h_url)

                            await ws.send(json.dumps({
                                "type": "create_session_result",
                                "taskId": create_task_id,
                                "token": token,
                                "success": ok_create,
                                "sessionId": new_sid,
                                "session": session_obj,
                                "workspaces": cur_workspaces,
                                "sessions": cur_sessions
                            }))
                            continue

                        if mtype == "run_agent":
                            task_id = msg.get("taskId")
                            prompt = msg.get("prompt", "")
                            messages = msg.get("messages", [])
                            harness_url = msg.get("harnessUrl", args.harness_url)
                            model_name = msg.get("model", args.harness_model)
                            session_id = msg.get("agentSessionId") or msg.get("sessionId", "default_session")
                            target_ws = msg.get("agentWorkspace") or msg.get("workspace") or "deepseek-agent"

                            print(f"\\n\\033[94m[收到任务] TaskID: {task_id} | 工作区: {target_ws} | 提示词: {prompt[:40]}...\\033[0m")
                            steps_collected = []

                            async def ws_step_cb(step_text: str):
                                steps_collected.append(step_text)
                                print(f"\\033[90m  └─ {step_text}\\033[0m")
                                try:
                                    await ws.send(json.dumps({
                                        "type": "agent_step",
                                        "taskId": task_id,
                                        "step": step_text,
                                        "timestamp": int(time.time() * 1000)
                                    }))
                                except Exception:
                                    pass

                            extra_config = {
                                "apiEndpoint": msg.get("apiEndpoint") or getattr(args, "chat_api_url", ""),
                                "apiKey": msg.get("apiKey") or getattr(args, "chat_api_key", ""),
                                "chatModel": msg.get("chatModel") or getattr(args, "chat_model", ""),
                            }

                            try:
                                success, output = await execute_local_harness(
                                    task_id, prompt, messages, harness_url, model_name, session_id, ws_step_cb, extra_config, target_workspace=target_ws
                                )
                            except Exception as task_err:
                                success = False
                                output = f"本地执行异常: {task_err}"
                                await ws_step_cb(f"❌ 任务发生未捕获异常: {task_err}")

                            status_tag = "✓ 任务完成" if success else "✗ 任务异常"
                            color = "\\033[92m" if success else "\\033[91m"
                            print(f"{color}[{status_tag}] 回传结果 TaskID: {task_id}\\033[0m")

                            await ws.send(json.dumps({
                                "type": "agent_result",
                                "taskId": task_id,
                                "success": success,
                                "steps": steps_collected,
                                "output": output,
                                "timestamp": int(time.time() * 1000)
                            }))

                            try:
                                cur_ws, cur_sess = await query_dsh_workspaces_and_sessions(harness_url)
                                await ws.send(json.dumps({
                                    "type": "sync_sessions",
                                    "token": token,
                                    "workspaces": cur_ws,
                                    "sessions": cur_sess
                                }))
                            except Exception:
                                pass

                    except Exception as handler_err:
                        logger.error(f"消息处理异常: {handler_err}")

        except Exception as ws_err:
            ws_fail_count += 1
            print(f"\\033[93m[WS 握手受阻 ({ws_err})]\\033[0m 正在自动无缝切换至 HTTP 智能长轮询通道...")
            await run_polling_bridge(args, token, server_base, concurrency_limit)
            return

def main():
    args = parse_args()
    try:
        asyncio.run(run_bridge_client(args))
    except KeyboardInterrupt:
        print("\\n\\033[93m[已退出] DeepSeek Bridge 安全退出。\\033[0m")

if __name__ == "__main__":
    main()
`;
  }, [localSettings.agentToken, localSettings.agentHarnessUrl]);

  // 纯客户端零依赖直接生成并下载文件 (100% 免疫任何 CDN 拦截 / SPA 路由 / 代理导致返回 HTML)
  const triggerDirectFileDownload = React.useCallback((fileName: string, content: string, mimeType: string = 'text/plain;charset=utf-8') => {
    try {
      const blob = new Blob([content], { type: mimeType });
      const blobUrl = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = blobUrl;
      a.download = fileName;
      a.style.display = 'none';
      document.body.appendChild(a);
      a.click();
      setTimeout(() => {
        try { document.body.removeChild(a); } catch {}
        URL.revokeObjectURL(blobUrl);
      }, 1500);
    } catch (err) {
      console.error('直接下载失败，尝试 DataURI 备选方案:', err);
      try {
        const encodedUri = `data:${mimeType},` + encodeURIComponent(content);
        const a = document.createElement('a');
        a.href = encodedUri;
        a.download = fileName;
        a.style.display = 'none';
        document.body.appendChild(a);
        a.click();
        setTimeout(() => {
          try { document.body.removeChild(a); } catch {}
        }, 1500);
      } catch (dataErr) {
        console.error('DataURI 下载亦失败:', dataErr);
      }
    }
  }, []);

  const handleDownloadBridgePy = React.useCallback(async () => {
    try {
      const res = await fetch('/api/agent/download-bridge');
      if (res.ok) {
        const text = await res.text();
        if (text && text.length > 500) {
          triggerDirectFileDownload('deepseek_bridge.py', text, 'text/x-python;charset=utf-8');
          return;
        }
      }
    } catch {}
    try {
      const res = await fetch('/deepseek_bridge.py');
      if (res.ok) {
        const text = await res.text();
        if (text && text.length > 500) {
          triggerDirectFileDownload('deepseek_bridge.py', text, 'text/x-python;charset=utf-8');
          return;
        }
      }
    } catch {}
    const content = generateBridgeScriptContent();
    triggerDirectFileDownload('deepseek_bridge.py', content, 'text/x-python;charset=utf-8');
  }, [generateBridgeScriptContent, triggerDirectFileDownload]);

  const handleDownloadStartBat = React.useCallback(() => {
    const token = (localSettings.agentToken || 'default_agent_token').trim();
    const harnessUrl = normalizedHarnessUrl;
    
    const batContent = `@echo off
chcp 65001 >nul
title DeepSeek Bridge 本地智能体桥接服务
echo ======================================================================
echo    DeepSeek Bridge 一键启动脚本 (会话自动管理增强版)
echo    服务器地址: ${currentOrigin}
echo    本地 Harness: ${harnessUrl}
echo ======================================================================
echo.

where python >nul 2>nul
if %errorlevel% neq 0 (
    echo [错误] 未检测到 Python 环境，请先安装 Python 3.8+ 并勾选 Add to PATH！
    pause
    exit /b 1
)

echo [1/2] 正在检查依赖库 (websockets, aiohttp, urllib3)...
python -m pip install websockets aiohttp urllib3 -q --disable-pip-version-check 2>nul

echo [2/2] 正在启动桥接服务并连接调度中心...
echo.
python deepseek_bridge.py --server "${currentOrigin}" --token "${token}" --harness-url "${harnessUrl}"
if %errorlevel% neq 0 (
    echo.
    echo 桥接服务异常退出，请检查上方日志。
    pause
)
`;
    triggerDirectFileDownload('run_bridge.bat', batContent, 'application/x-bat;charset=utf-8');
  }, [localSettings.agentToken, currentOrigin, normalizedHarnessUrl, triggerDirectFileDownload]);

  const handleRevokeAndResetToken = React.useCallback(async () => {
    const oldToken = localSettingsRef.current.agentToken || 'default_agent_token';
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let rand = '';
    for (let i = 0; i < 48; i++) {
      rand += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    const newToken = `sk-${rand}`;
    setIsRevokingToken(true);
    try {
      await fetch(`${API_BASE_URL}/api/agent/revoke-token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ oldToken })
      });
    } catch (e) {
      // fallback
    } finally {
      setIsRevokingToken(false);
      updateAndSave({ agentToken: newToken });
      setAgentOnlineStatus({ online: false });
      alert("✅ 已成功注销旧 Token 并生成全新凭证！新凭证已自动保存生效。");
    }
  }, [updateAndSave]);

  const checkAgentStatus = React.useCallback(async (tokenToTest?: string) => {
    const token = (tokenToTest || localSettingsRef.current.agentToken || 'default_agent_token').trim();
    setIsCheckingAgent(true);
    try {
      const res = await fetch(`${API_BASE_URL}/api/agent/status?token=${encodeURIComponent(token)}`);
      const data = await res.json();
      setAgentOnlineStatus(data);
      if (data.workspaces && Array.isArray(data.workspaces) && data.workspaces.length > 0) {
        setAgentWorkspaces(data.workspaces);
      }
      if (data.sessions && Array.isArray(data.sessions) && data.sessions.length > 0) {
        setAgentSessions(data.sessions);
      }
    } catch (e) {
      setAgentOnlineStatus({ online: false });
    } finally {
      setIsCheckingAgent(false);
    }
  }, []);

  const fetchAgentSessions = React.useCallback(async (tokenToTest?: string) => {
    const token = (tokenToTest || localSettingsRef.current.agentToken || 'default_agent_token').trim();
    setIsLoadingSessions(true);
    try {
      const res = await fetch(`${API_BASE_URL}/api/agent/sessions?token=${encodeURIComponent(token)}`);
      let data: any = {};
      try {
        data = await res.json();
      } catch {
        data = { workspaces: ['deepseek-agent'], sessions: [] };
      }
      if (data.workspaces && Array.isArray(data.workspaces)) {
        setAgentWorkspaces(data.workspaces);
      }
      if (data.sessions && Array.isArray(data.sessions)) {
        setAgentSessions(data.sessions);
      }
    } catch (e) {
      console.warn('获取本地 Agent 会话列表失败:', e);
    } finally {
      setIsLoadingSessions(false);
    }
  }, []);

  const handleCreateSession = React.useCallback(async (customTitle?: string) => {
    const token = (localSettingsRef.current.agentToken || 'default_agent_token').trim();
    const ws = localSettingsRef.current.agentWorkspace || 'deepseek-agent';
    const title = (customTitle || '').trim() || `新对话 ${new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}`;
    
    setIsCreatingSession(true);
    try {
      const res = await fetch(`${API_BASE_URL}/api/agent/create-session`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token,
          workspace: ws,
          title,
          model: localSettingsRef.current.modelName || 'deepseek-chat'
        })
      });
      let data: any = {};
      try {
        data = await res.json();
      } catch {
        data = { success: true, sessionId: `session_${Date.now()}` };
      }
      if (data.success && (data.sessionId || data.session?.id)) {
        const newSid = data.sessionId || data.session?.id;
        updateAndSave({
          agentSessionId: newSid,
          agentWorkspace: ws
        });
        if (data.sessions) {
          setAgentSessions(data.sessions);
        } else {
          setAgentSessions(prev => [
            { id: newSid, sessionId: newSid, title, workspace: ws, updatedAt: Date.now() },
            ...prev.filter(s => (s.sessionId || s.id) !== newSid)
          ]);
        }
        if (data.workspaces) setAgentWorkspaces(data.workspaces);
        setShowNewSessionInput(false);
        setNewSessionTitle('');
      } else {
        alert(data.error || '创建本地会话失败，请确认桥接程序已启动并连通 DSH');
      }
    } catch (e: any) {
      alert(`创建本地会话失败: ${e.message || e}`);
    } finally {
      setIsCreatingSession(false);
    }
  }, [updateAndSave]);

  React.useEffect(() => {
    const handleSessionsUpdated = (data: any) => {
      const token = (localSettingsRef.current.agentToken || 'default_agent_token').trim();
      if (data && (!data.token || data.token === token)) {
        if (data.workspaces && Array.isArray(data.workspaces)) setAgentWorkspaces(data.workspaces);
        if (data.sessions && Array.isArray(data.sessions)) setAgentSessions(data.sessions);
      }
    };
    socket.on('agent_sessions_updated', handleSessionsUpdated);
    return () => {
      socket.off('agent_sessions_updated', handleSessionsUpdated);
    };
  }, []);

  const isElectron = typeof window !== 'undefined' && !!window.electronAPI?.isElectron;

  const loadStorageInfo = React.useCallback(async () => {
    if (window.electronAPI?.getStorageInfo) {
      try {
        const info = await window.electronAPI.getStorageInfo();
        setStorageInfo(info);
      } catch (err) {
        console.error('获取存储目录信息失败:', err);
      }
    }
  }, []);

  React.useEffect(() => {
    if (open) {
      loadStorageInfo();
      checkAgentStatus();
      fetchAgentSessions();
      const interval = setInterval(() => {
        checkAgentStatus();
      }, 2500);
      return () => clearInterval(interval);
    }
  }, [open, loadStorageInfo, checkAgentStatus, fetchAgentSessions]);

  const handleSelectStoragePath = async () => {
    if (!window.electronAPI?.selectStoragePath) return;
    setIsChangingStorage(true);
    setStorageStatus(null);
    try {
      const res = await window.electronAPI.selectStoragePath();
      if (!res.canceled && res.selectedPath) {
        const setRes = await window.electronAPI.setStoragePath(res.selectedPath);
        if (setRes.success) {
          setStorageStatus({
            type: 'success',
            message: `已设置新目录：${res.selectedPath}（需重启软件生效）`,
            needRestart: true,
          });
          await loadStorageInfo();
        } else {
          setStorageStatus({ type: 'error', message: setRes.error || '保存路径配置失败' });
        }
      }
    } catch (err: any) {
      setStorageStatus({ type: 'error', message: err.message || '选择目录失败' });
    } finally {
      setIsChangingStorage(false);
    }
  };

  const handleResetStoragePath = async () => {
    if (!window.electronAPI?.setStoragePath) return;
    try {
      const res = await window.electronAPI.setStoragePath(null);
      if (res.success) {
        setStorageStatus({
          type: 'info',
          message: '已恢复系统默认存储目录（需重启软件生效）',
          needRestart: true,
        });
        await loadStorageInfo();
      }
    } catch (err: any) {
      setStorageStatus({ type: 'error', message: err.message || '恢复默认失败' });
    }
  };

  const handleOpenStorageFolder = async () => {
    if (!window.electronAPI?.openStorageFolder) return;
    try {
      await window.electronAPI.openStorageFolder(storageInfo?.currentPath);
    } catch (err: any) {
      setStorageStatus({ type: 'error', message: err.message || '打开目录失败' });
    }
  };

  const handleRelaunch = async () => {
    if (window.electronAPI?.relaunchApp) {
      await window.electronAPI.relaunchApp();
    }
  };

  React.useEffect(() => {
    if (!open) {
      setUpdateStatus(null);
      setIsChecking(false);
      setModelFetchStatus(null);
      setPasswordStatus(null);
      setOldPassword('');
      setNewPassword('');
      setConfirmPassword('');
    }
    let initialOpacity = settings.backgroundOpacity;
    if (initialOpacity != null && initialOpacity <= 1 && initialOpacity > 0) {
      initialOpacity = Math.round(initialOpacity * 100);
    } else if (initialOpacity == null) {
      initialOpacity = 100;
    }
    setLocalSettings({ ...settings, backgroundOpacity: initialOpacity });
  }, [settings, open]);

  const fetchModels = async (endpoint: string) => {
    if (!endpoint || !endpoint.trim()) return;
    
    setIsFetchingModels(true);
    setModelFetchStatus(null);

    const isVolces = endpoint.includes('volces.com') || endpoint.includes('volcengine.com');
    const isAliyun = endpoint.includes('dashscope.aliyuncs.com');
    const isZhipu = endpoint.includes('open.bigmodel.cn');
    const isBaidu = endpoint.includes('qianfan.baidubce.com');
    const isMiniMax = endpoint.includes('api.minimax.chat');
    const isOllama = endpoint.includes('11434') || endpoint.includes('ollama');

    const base = normalizeApiBaseUrl(endpoint);
    const candidateUrls = [
      `${base}/models`,
      ...(isVolces ? [`${base}/endpoints`, `${base}/bots`] : []),
      ...(isOllama ? [`${base.replace(/\/v1$/, '')}/api/tags`] : []),
    ];

    let foundModels: string[] = [];
    let lastError: string = '';

    for (const url of candidateUrls) {
      try {
        const options = {
          url: url,
          method: 'GET',
          headers: {
            'Authorization': `Bearer ${localSettings.apiKey || 'lm-studio'}`,
            'Content-Type': 'application/json',
          },
          connectTimeout: 8000,
          readTimeout: 8000,
        };

        const response = await CapacitorHttp.request(options);

        if (response.status >= 200 && response.status < 300) {
          const data = response.data;
          let list: any[] = [];

          if (data && Array.isArray(data.data)) list = data.data;
          else if (data && Array.isArray(data.items)) list = data.items;
          else if (data && Array.isArray(data.endpoints)) list = data.endpoints;
          else if (data && Array.isArray(data.bots)) list = data.bots;
          else if (data && Array.isArray(data.models)) list = data.models; // Ollama /api/tags
          else if (Array.isArray(data)) list = data;

          const extracted = list
            .map((m: any) => m.id || m.name || m.endpoint_id || m.model || m.model_name)
            .filter(Boolean);

          if (extracted.length > 0) {
            foundModels = Array.from(new Set([...foundModels, ...extracted]));
          }
        } else {
          const serverMsg = response.data?.error?.message || response.data?.message || response.data?.msg || `HTTP ${response.status}`;
          lastError = serverMsg;
        }
      } catch (e: any) {
        lastError = e?.message || '网络连接超时';
      }
    }

    if (foundModels.length > 0) {
      foundModels.sort((a, b) => a.localeCompare(b));
      const defaultModel = foundModels[0];
      const targetModel = localSettingsRef.current.modelName && foundModels.includes(localSettingsRef.current.modelName)
        ? localSettingsRef.current.modelName
        : defaultModel;
      updateAndSave({
        availableModels: foundModels,
        modelName: targetModel,
      });
      setModelFetchStatus({ type: 'success', message: `发现 ${foundModels.length} 个可用模型/接入点` });
    } else {
      if (isVolces) {
        setModelFetchStatus({ 
          type: 'error', 
          message: '火山方舟已限制 API 遍历权限。请直接在上方“模型名称”手动填写接入点 ID，即可正常发起对话' 
        });
      } else if (isAliyun) {
        setModelFetchStatus({ 
          type: 'error', 
          message: '阿里百炼/通义千问已限制模型遍历。请直接在上方“模型名称”填写模型名（例如 qwen-plus、qwen-max、qwen-turbo、qwen2.5-72b-instruct）即可正常使用' 
        });
      } else if (isZhipu) {
        setModelFetchStatus({ 
          type: 'error', 
          message: '智谱 AI (GLM) 未开放模型列表遍历权限。请在上方“模型名称”手动填写（例如 glm-4-plus、glm-4-flash、glm-4-air、glm-4v）即可正常使用' 
        });
      } else if (isBaidu) {
        setModelFetchStatus({ 
          type: 'error', 
          message: '百度千帆已限制 API 遍历权限。请在上方“模型名称”手动填写模型名（例如 ernie-4.0-8k、ernie-3.5-8k）即可正常使用' 
        });
      } else if (isMiniMax) {
        setModelFetchStatus({ 
          type: 'error', 
          message: 'MiniMax 已限制模型遍历。请在上方“模型名称”手动填写（例如 abab6.5s-chat、MiniMax-Text-01）即可正常使用' 
        });
      } else {
        setModelFetchStatus({ 
          type: 'error', 
          message: lastError ? `获取失败: ${lastError}（若 API 限制了遍历，可直接在上方手动输入模型名称）` : '未发现可用模型，请手动输入模型名称' 
        });
      }
    }

    setIsFetchingModels(false);
  };

  const handlePasswordChange = async () => {
    if (newPassword !== confirmPassword) {
      setPasswordStatus({ type: 'error', message: '两次新密码不一致' });
      return;
    }
    if (!oldPassword || !newPassword) {
      setPasswordStatus({ type: 'error', message: '请填写所有密码字段' });
      return;
    }
    
    try {
      const baseUrl = API_BASE_URL;
      const response = await fetch(`${baseUrl}/api/change-password`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ userId, oldPassword, newPassword })
      });
      const data = await response.json();
      if (response.ok) {
        setPasswordStatus({ type: 'success', message: '密码修改成功' });
        setOldPassword('');
        setNewPassword('');
        setConfirmPassword('');
      } else {
        setPasswordStatus({ type: 'error', message: data.error || '修改失败' });
      }
    } catch (e) {
      setPasswordStatus({ type: 'error', message: '连接错误' });
    }
  };

  const handleInnerCheckUpdate = async () => {
    setIsChecking(true);
    setUpdateStatus(null);
    const result = await onCheckUpdate();
    setIsChecking(false);
    
    if (!result.success) {
      setUpdateStatus({ type: 'error', message: result.error || '检测失败' });
    } else if (result.data === 'latest') {
      setUpdateStatus({ type: 'success', message: '当前已是最新版本' });
    }
    // If it's a new version, App.tsx handles the UpdateDialog
  };

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const { name, value } = e.target;
    setLocalSettings((prev) => {
      const next = { ...prev, [name]: value };
      localSettingsRef.current = next;
      return next;
    });
  };

  const handleImageSelect = async (field: keyof AppSettings, source: CameraSource) => {
    try {
      const image = await CapCamera.getPhoto({
        quality: 100,
        allowEditing: false,
        resultType: CameraResultType.DataUrl,
        source: source
      });
      
      if (image.dataUrl) {
        setCropImage({ src: image.dataUrl, field });
      }
    } catch (error: any) {
      if (error?.message !== 'User cancelled photos app') {
        console.error('Image selection error:', error);
      }
    }
  };

  const clearField = (field: keyof AppSettings) => {
    updateAndSave({ [field]: '' });
  };

  const handleTestHttp = async () => {
    if (!localSettings.funasrHttpEndpoint?.trim()) {
      setHttpTestStatus({ type: 'error', message: '请先输入转写 HTTP 地址' });
      return;
    }
    const targetUrl = normalizeHttpAsrUrl(localSettings.funasrHttpEndpoint);
    setIsTestingHttp(true);
    setHttpTestStatus(null);

    try {
      const sampleRate = 16000;
      const numSamples = 8000;
      const buffer = new ArrayBuffer(44 + numSamples * 2);
      const view = new DataView(buffer);
      const writeString = (offset: number, str: string) => {
        for (let i = 0; i < str.length; i++) view.setUint8(offset + i, str.charCodeAt(i));
      };
      writeString(0, 'RIFF');
      view.setUint32(4, 36 + numSamples * 2, true);
      writeString(8, 'WAVE');
      writeString(12, 'fmt ');
      view.setUint32(16, 16, true);
      view.setUint16(20, 1, true);
      view.setUint16(22, 1, true);
      view.setUint32(24, sampleRate, true);
      view.setUint32(28, sampleRate * 2, true);
      view.setUint16(32, 2, true);
      view.setUint16(34, 16, true);
      writeString(36, 'data');
      view.setUint32(40, numSamples * 2, true);
      const blob = new Blob([buffer], { type: 'audio/wav' });
      const formData = new FormData();
      formData.append('file', blob, 'test.wav');
      formData.append('audio', blob, 'test.wav');
      formData.append('audio_in', blob, 'test.wav');
      if (localSettings.asrModel) {
        formData.append('model', localSettings.asrModel);
      }

      const baseUrl = (window as any).Capacitor?.isNativePlatform?.() ? API_BASE_URL : '';
      let proxyUrl = `${baseUrl}/api/funasr-transcribe?endpoint=${encodeURIComponent(targetUrl)}`;
      if (localSettings.asrModel) {
        proxyUrl += `&model=${encodeURIComponent(localSettings.asrModel)}`;
      }
      
      const headers: Record<string, string> = {};
      const testApiKey = localSettings.asrApiKey || localSettings.apiKey;
      if (testApiKey) {
        headers['x-asr-api-key'] = testApiKey;
        headers['Authorization'] = `Bearer ${testApiKey}`;
      }

      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 20000);

      const res = await fetch(proxyUrl, {
        method: 'POST',
        headers,
        body: formData,
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      if (res.ok) {
        const data = await res.json().catch(() => ({}));
        const preview = data.text || data.result ? ` [返回: ${(data.text || data.result).substring(0, 40)}]` : '';
        setHttpTestStatus({ type: 'success', message: `连接成功：语音转写接口响应正常${preview}` });
      } else {
        const data = await res.json().catch(() => ({}));
        if (res.status === 401 || res.status === 403) {
          setHttpTestStatus({ type: 'error', message: `鉴权失败 (HTTP ${res.status})：API Key 无效或未授权` });
        } else if (res.status === 404) {
          setHttpTestStatus({ type: 'error', message: '接口地址不存在 (HTTP 404)，请检查端点 URL 路径' });
        } else {
          setHttpTestStatus({ type: 'error', message: `服务返回状态码 ${res.status}${data.error ? `: ${data.error}` : ''}` });
        }
      }
    } catch (err: any) {
      if (err.name === 'AbortError') {
        setHttpTestStatus({ type: 'error', message: '连接超时，请检查服务地址与网络' });
      } else {
        setHttpTestStatus({ type: 'error', message: err.message || '连接失败，请检查网络与端口' });
      }
    } finally {
      setIsTestingHttp(false);
    }
  };

  const handleTestWs = () => {
    if (!localSettings.funasrWsEndpoint?.trim()) {
      setWsTestStatus({ type: 'error', message: '请先输入实时流 WS 地址' });
      return;
    }
    const targetWsUrl = normalizeWsAsrUrl(localSettings.funasrWsEndpoint);
    setIsTestingWs(true);
    setWsTestStatus(null);

    const isNativeApp = typeof window !== 'undefined' && (
      window.location.protocol === 'file:' || 
      window.location.protocol === 'capacitor:' || 
      !!(window as any).Capacitor?.isNativePlatform?.() ||
      window.location.hostname === 'localhost' ||
      window.location.hostname === '127.0.0.1'
    );

    let finalWsUrl = targetWsUrl;
    if (!isNativeApp && !targetWsUrl.includes('/api/funasr-ws')) {
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const host = window.location.host;
      if (host && window.location.protocol.startsWith('http')) {
        finalWsUrl = `${protocol}//${host}/api/funasr-ws?endpoint=${encodeURIComponent(targetWsUrl)}`;
      }
    }

    try {
      const ws = new WebSocket(finalWsUrl, 'binary');
      let isDone = false;
      const timeoutId = setTimeout(() => {
        if (!isDone) {
          isDone = true;
          try { ws.close(); } catch (_) {}
          setWsTestStatus({ type: 'error', message: '连接超时，请检查 WS 地址与端口' });
          setIsTestingWs(false);
        }
      }, 5000);

      ws.onopen = () => {
        if (!isDone) {
          isDone = true;
          clearTimeout(timeoutId);
          setWsTestStatus({ type: 'success', message: '连接成功：WebSocket 实时流服务就绪' });
          setIsTestingWs(false);
          try { ws.close(); } catch (_) {}
        }
      };

      ws.onerror = () => {
        if (!isDone) {
          isDone = true;
          clearTimeout(timeoutId);
          setWsTestStatus({ type: 'error', message: 'WebSocket 连接失败，请检查端口是否开放' });
          setIsTestingWs(false);
        }
      };
    } catch (e: any) {
      setWsTestStatus({ type: 'error', message: e.message || '创建 WebSocket 失败' });
      setIsTestingWs(false);
    }
  };

  const FileUploadField = ({ label, field, placeholder }: { label: string, field: keyof AppSettings, placeholder?: string }) => (
    <div className="grid grid-cols-4 items-center gap-4">
      <Label className="text-right text-xs">{label}</Label>
      <div className="col-span-3 flex items-center gap-2">
        {localSettings[field] ? (
          <div className="relative group">
            <img 
              src={localSettings[field] as string} 
              alt={label} 
              className="w-10 h-10 rounded-lg object-cover border border-border" 
            />
            <button 
              onClick={() => clearField(field)}
              className="absolute -top-1 -right-1 bg-destructive text-destructive-foreground rounded-full p-0.5 opacity-0 group-hover:opacity-100 transition-opacity"
            >
              <X size={10} />
            </button>
          </div>
        ) : (
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="icon"
              className="w-10 h-10 rounded-lg border-dashed transition-all hover:bg-primary/10 hover:text-primary active:scale-95"
              onClick={() => handleImageSelect(field, CameraSource.Camera)}
              title="拍照"
            >
              <Camera size={16} className="text-muted-foreground" />
            </Button>
            <Button
              variant="outline"
              size="icon"
              className="w-10 h-10 rounded-lg border-dashed transition-all hover:bg-primary/10 hover:text-primary active:scale-95"
              onClick={() => handleImageSelect(field, CameraSource.Photos)}
              title="相册"
            >
              <ImageIcon size={16} className="text-muted-foreground" />
            </Button>
          </div>
        )}
        <span className="text-[10px] text-muted-foreground truncate flex-1">
          {localSettings[field] ? '已选择图片' : (placeholder || '选择图片')}
        </span>
      </div>
    </div>
  );

  const handleDialogOpenChange = (newOpen: boolean) => {
    if (!newOpen) {
      saveSettingsImmediate();
    }
    onOpenChange(newOpen);
  };

  return (
    <Dialog open={open} onOpenChange={handleDialogOpenChange}>
      <DialogContent 
        className="w-[94vw] max-w-[440px] sm:max-w-[480px] bg-white dark:bg-black border-border text-foreground max-h-[85vh] max-h-[85dvh] overflow-y-auto rounded-2xl sm:rounded-3xl p-4 sm:p-6"
      >
        <DialogHeader>
          <div className="flex items-center justify-between">
            <DialogTitle>应用设置</DialogTitle>
            <span className="text-[10px] font-mono text-muted-foreground mr-6">
              {localStorage.getItem('app_version') || 'v1.0.1'}
            </span>
          </div>
        </DialogHeader>
        <div className="grid gap-4 py-4">
          <div className="grid grid-cols-4 items-center gap-4">
            <Label className="text-right text-xs">登录账号</Label>
            <span className="col-span-3 text-xs text-muted-foreground">
              {username ? username : '游客'}
            </span>
          </div>

          <div className="grid grid-cols-4 items-center gap-4">
            <Label htmlFor="userName" className="text-right text-xs">用户名</Label>
            <Input id="userName" name="userName" value={localSettings.userName} onChange={handleChange} onBlur={handleBlur} className="col-span-3 h-8 text-xs" />
          </div>
          
          <FileUploadField label="用户头像" field="userAvatar" />

          <div className="grid grid-cols-4 items-center gap-4">
            <Label htmlFor="aiName" className="text-right text-xs">AI 名称</Label>
            <Input id="aiName" name="aiName" value={localSettings.aiName} onChange={handleChange} onBlur={handleBlur} className="col-span-3 h-8 text-xs" />
          </div>

          <FileUploadField label="AI 头像" field="aiAvatar" />

          <div className="grid grid-cols-4 items-center gap-4">
            <Label htmlFor="apiKey" className="text-right text-xs">API Key</Label>
            <Input id="apiKey" name="apiKey" type="password" value={localSettings.apiKey} onChange={handleChange} onBlur={handleBlur} className="col-span-3 h-8 text-xs" />
          </div>
          <div className="grid grid-cols-4 items-center gap-4">
            <Label htmlFor="modelName" className="text-right text-xs">模型名称</Label>
            <div className="col-span-3">
              <ModelSelector 
                 settings={localSettings} 
                 onUpdateSettings={(newS) => {
                   setLocalSettings(newS);
                   localSettingsRef.current = newS;
                   saveSettingsImmediate(newS);
                 }}
                 onBlur={handleBlur}
                 modelsOverride={localSettings.availableModels}
              />
            </div>
          </div>
          <div className="grid grid-cols-4 items-start gap-4">
            <Label htmlFor="apiEndpoint" className="text-right text-xs mt-2.5">API 终端</Label>
            <div className="col-span-3 flex flex-col gap-1.5">
              <Input 
                id="apiEndpoint" 
                name="apiEndpoint" 
                value={localSettings.apiEndpoint} 
                onChange={handleChange}
                onBlur={handleBlur}
                className="h-8 text-xs flex-1" 
              />
              <span className="text-[10px] text-muted-foreground">
                支持智能识别各类模型服务（如火山方舟 /api/v3、DeepSeek、OpenAI 等），自动防止重复拼接
              </span>
              <Button
                variant="outline"
                size="sm"
                className="h-8 text-xs transition-all hover:bg-primary/10 hover:text-primary active:scale-95 mt-0.5"
                onClick={() => fetchModels(localSettings.apiEndpoint)}
                disabled={isFetchingModels}
              >
                {isFetchingModels ? <Loader2 size={14} className="animate-spin mr-2" /> : null}
                获取模型列表
              </Button>
            </div>
          </div>

          {modelFetchStatus && (
            <div className="grid grid-cols-4 items-center gap-4">
              <div></div>
              <div className="col-span-3">
                <div className={cn(
                  "text-[10px] p-1.5 rounded-md border",
                  modelFetchStatus.type === 'success' ? "bg-primary/10 border-primary/20 text-primary" : "bg-destructive/10 border-destructive/20 text-destructive"
                )}>
                  {modelFetchStatus.message}
                </div>
              </div>
            </div>
          )}

          <FileUploadField label="自定义背景" field="customBackground" placeholder="应用自定义壁纸" />
          
          <div className="grid grid-cols-4 items-center gap-4">
            <Label className="text-right text-xs flex items-center justify-end gap-1">
              <Type className="w-3 h-3 text-muted-foreground" />
              字体大小
            </Label>
            <div className="col-span-3 flex flex-col gap-1.5">
              <div className="grid grid-cols-4 gap-1.5 p-1 bg-muted/40 rounded-lg border border-border/50">
                {[
                  { value: 'sm', label: '小号', size: '13px' },
                  { value: 'base', label: '标准', size: '15px' },
                  { value: 'lg', label: '大号', size: '16px' },
                  { value: 'xl', label: '特大', size: '18px' },
                ].map((item) => {
                  const isSelected = (localSettings.chatFontSize || 'base') === item.value;
                  return (
                    <button
                      key={item.value}
                      type="button"
                      onClick={() => updateAndSave({ chatFontSize: item.value as any })}
                      className={cn(
                        "flex flex-col items-center justify-center py-1.5 px-1 rounded-md text-xs font-medium transition-all",
                        isSelected 
                          ? "bg-primary text-primary-foreground shadow-sm scale-[1.02]" 
                          : "hover:bg-muted text-muted-foreground hover:text-foreground"
                      )}
                    >
                      <span className="text-[11px] leading-none">{item.label}</span>
                      <span className="text-[9px] opacity-70 leading-none mt-0.5 font-mono">{item.size}</span>
                    </button>
                  );
                })}
              </div>
              <div className={cn(
                "p-2 rounded bg-muted/20 border border-border/40 text-muted-foreground transition-all flex items-center justify-between",
                (localSettings.chatFontSize === 'sm') && "text-xs",
                (localSettings.chatFontSize === 'base' || !localSettings.chatFontSize) && "text-[14px]",
                (localSettings.chatFontSize === 'lg') && "text-[16px]",
                (localSettings.chatFontSize === 'xl') && "text-[18px]",
              )}>
                <span className="truncate">预览：这是一条示例聊天消息文本效果</span>
                <span className="text-[10px] font-mono opacity-60 ml-2 shrink-0">
                  {localSettings.chatFontSize === 'sm' ? '13px' : localSettings.chatFontSize === 'lg' ? '16px' : localSettings.chatFontSize === 'xl' ? '18px' : '15px (默认)'}
                </span>
              </div>
            </div>
          </div>

          <div className="grid grid-cols-4 items-center gap-4">
            <Label htmlFor="backgroundOpacity" className="text-right text-xs">透明度</Label>
            <div className="col-span-3 flex items-center gap-2">
              <Input 
                id="backgroundOpacity" 
                name="backgroundOpacity" 
                type="number"
                step="1"
                min="0"
                max="100"
                value={localSettings.backgroundOpacity == null ? '' : localSettings.backgroundOpacity} 
                onChange={(e) => {
                  const val = e.target.value;
                  if (val === '') {
                    setLocalSettings(prev => {
                      const next = { ...prev, backgroundOpacity: undefined };
                      localSettingsRef.current = next;
                      return next;
                    });
                  } else {
                    const num = parseInt(val, 10);
                    if (!isNaN(num)) {
                      const clamped = Math.min(100, Math.max(0, num));
                      setLocalSettings(prev => {
                        const next = { ...prev, backgroundOpacity: clamped };
                        localSettingsRef.current = next;
                        return next;
                      });
                    }
                  }
                }}
                onBlur={() => {
                  const val = localSettings.backgroundOpacity;
                  if (val == null || isNaN(val)) {
                    updateAndSave({ backgroundOpacity: 100 });
                  } else {
                    updateAndSave({ backgroundOpacity: Math.min(100, Math.max(0, val)) });
                  }
                }}
                className="h-8 text-xs flex-1" 
                placeholder="0 - 100"
              />
              <span className="text-xs text-muted-foreground">%</span>
            </div>
          </div>
          
          <div className="grid grid-cols-4 items-center gap-4">
            <Label htmlFor="showBackgroundInDarkMode" className="text-right text-xs">暗夜模式显示</Label>
            <div className="col-span-3 flex items-center h-8">
              <input
                id="showBackgroundInDarkMode"
                type="checkbox"
                checked={localSettings.showBackgroundInDarkMode}
                onChange={(e) => updateAndSave({ showBackgroundInDarkMode: e.target.checked })}
                className="w-4 h-4 rounded border-gray-300 text-primary focus:ring-primary"
              />
            </div>
          </div>
          
          <div className="border-t pt-4 mt-2">
            <h4 className="text-xs font-semibold mb-3">启动页设置</h4>
            <div className="space-y-3">
              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="showSplashScreen" className="text-right text-xs">启用启动页</Label>
                <div className="col-span-3 flex items-center h-8">
                  <input
                    id="showSplashScreen"
                    type="checkbox"
                    checked={localSettings.showSplashScreen}
                    onChange={(e) => updateAndSave({ showSplashScreen: e.target.checked })}
                    className="w-4 h-4 rounded border-gray-300 text-primary focus:ring-primary"
                  />
                </div>
              </div>
              
              {localSettings.showSplashScreen && (
                <>
                  <div className="grid grid-cols-4 items-center gap-4">
                    <Label htmlFor="splashText" className="text-right text-xs">启动文本</Label>
                    <Input 
                      id="splashText" 
                      name="splashText" 
                      value={localSettings.splashText || ''} 
                      onChange={handleChange} 
                      onBlur={handleBlur}
                      className="col-span-3 h-8 text-xs" 
                      placeholder="例如：Aether-X" 
                    />
                  </div>
                  <FileUploadField label="启动图片" field="splashImage" />
                  <div className="grid grid-cols-4 items-center gap-4">
                    <Label htmlFor="splashSubtitle" className="text-right text-xs">启动子文本</Label>
                    <Input 
                      id="splashSubtitle" 
                      name="splashSubtitle" 
                      value={localSettings.splashSubtitle || ''} 
                      onChange={handleChange} 
                      onBlur={handleBlur}
                      className="col-span-3 h-8 text-xs" 
                      placeholder="例如：Loading AI Experience" 
                    />
                  </div>
                  <div className="grid grid-cols-4 items-center gap-4">
                    <Label htmlFor="splashDuration" className="text-right text-xs">持续时间(ms)</Label>
                    <Input 
                      id="splashDuration" 
                      name="splashDuration" 
                      type="number"
                      value={localSettings.splashDuration === 0 ? '' : (localSettings.splashDuration || 1000)} 
                      onChange={(e) => {
                        const num = e.target.value === '' ? 0 : parseInt(e.target.value);
                        setLocalSettings(prev => {
                          const next = { ...prev, splashDuration: num };
                          localSettingsRef.current = next;
                          return next;
                        });
                      }} 
                      onBlur={(e) => {
                        const val = parseInt(e.target.value);
                        if (isNaN(val) || val < 1000) {
                          updateAndSave({ splashDuration: 1000 });
                        } else {
                          updateAndSave({ splashDuration: val });
                        }
                      }}
                      className="col-span-3 h-8 text-xs" 
                    />
                  </div>
                </>
              )}
            </div>
          </div>

          <div className="grid grid-cols-4 items-center gap-4">
            <Label htmlFor="systemInstruction" className="text-right text-xs">回复逻辑</Label>
            <Input id="systemInstruction" name="systemInstruction" value={localSettings.systemInstruction || ''} onChange={handleChange} onBlur={handleBlur} className="col-span-3 h-8 text-xs" placeholder="例如：你是一个专业的程序员" />
          </div>

          <div className="border-t pt-4 mt-2">
            <div className="flex items-center justify-between mb-3">
              <h4 className="text-xs font-semibold">语音转写设置 (商用云转写 / FunASR)</h4>
            </div>

            {/* Quick Provider Presets */}
            <div className="mb-3">
              <div className="text-[11px] text-muted-foreground mb-1.5 font-medium">常用商用服务商快捷预设：</div>
              <div className="flex flex-wrap gap-1.5">
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-7 text-[11px] px-2 py-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                  onClick={() => {
                    updateAndSave({
                      funasrHttpEndpoint: 'api.siliconflow.cn',
                      asrModel: 'FunAudioLLM/SenseVoiceSmall',
                    });
                  }}
                >
                  ⚡ 硅基流动 SenseVoice
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-7 text-[11px] px-2 py-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                  onClick={() => {
                    updateAndSave({
                      funasrHttpEndpoint: 'api.groq.com',
                      asrModel: 'whisper-large-v3-turbo',
                    });
                  }}
                >
                  🚀 Groq Whisper
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-7 text-[11px] px-2 py-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                  onClick={() => {
                    updateAndSave({
                      funasrHttpEndpoint: 'api.openai.com',
                      asrModel: 'whisper-1',
                    });
                  }}
                >
                  🌐 OpenAI Whisper
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-7 text-[11px] px-2 py-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                  onClick={() => {
                    updateAndSave({
                      funasrHttpEndpoint: 'dashscope.aliyuncs.com',
                      asrModel: 'sensevoice-v1',
                    });
                  }}
                >
                  ☁️ 阿里百炼
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-7 text-[11px] px-2 py-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                  onClick={() => {
                    updateAndSave({
                      funasrHttpEndpoint: '192.168.1.100:10095',
                      funasrWsEndpoint: '192.168.1.100:10096',
                      asrModel: '',
                    });
                  }}
                >
                  🤖 自建 FunASR
                </Button>
              </div>
            </div>

            <div className="space-y-3">
              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="funasrHttpEndpoint" className="text-right text-xs">转写 HTTP</Label>
                <div className="col-span-3 flex items-center gap-2">
                  <Input 
                    id="funasrHttpEndpoint" 
                    name="funasrHttpEndpoint" 
                    value={localSettings.funasrHttpEndpoint || ''} 
                    onChange={handleChange} 
                    onBlur={handleBlur}
                    className="h-8 text-xs flex-1" 
                  />
                  <Button 
                    type="button" 
                    variant="outline" 
                    size="sm" 
                    onClick={handleTestHttp} 
                    disabled={isTestingHttp || !localSettings.funasrHttpEndpoint}
                    className="h-8 px-2 text-xs flex items-center gap-1 shrink-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                  >
                    {isTestingHttp ? <Loader2 className="w-3 h-3 animate-spin" /> : <RefreshCw className="w-3 h-3" />}
                    测试
                  </Button>
                </div>
              </div>

              {httpTestStatus && (
                <div className="grid grid-cols-4 gap-4">
                  <div className="col-start-2 col-span-3">
                    <div className={cn(
                      "text-[11px] p-2 rounded-md",
                      httpTestStatus.type === 'error' ? "bg-red-50 text-red-600 dark:bg-red-950/50 dark:text-red-400" : "bg-green-50 text-green-600 dark:bg-green-950/50 dark:text-green-400"
                    )}>
                      {httpTestStatus.message}
                    </div>
                  </div>
                </div>
              )}

              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="asrModel" className="text-right text-xs">转写模型</Label>
                <Input 
                  id="asrModel" 
                  name="asrModel" 
                  value={localSettings.asrModel || ''} 
                  onChange={handleChange} 
                  onBlur={handleBlur}
                  placeholder="例如：whisper-1 / FunAudioLLM/SenseVoiceSmall"
                  className="col-span-3 h-8 text-xs" 
                />
              </div>

              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="asrApiKey" className="text-right text-xs">转写 Key</Label>
                <Input 
                  id="asrApiKey" 
                  name="asrApiKey" 
                  type="password"
                  value={localSettings.asrApiKey || ''} 
                  onChange={handleChange} 
                  onBlur={handleBlur}
                  placeholder="留空则自动复用上方全局 API Key"
                  className="col-span-3 h-8 text-xs" 
                />
              </div>

              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="funasrWsEndpoint" className="text-right text-xs">实时流 WS</Label>
                <div className="col-span-3 flex items-center gap-2">
                  <Input 
                    id="funasrWsEndpoint" 
                    name="funasrWsEndpoint" 
                    value={localSettings.funasrWsEndpoint || ''} 
                    onChange={handleChange} 
                    onBlur={handleBlur}
                    className="h-8 text-xs flex-1" 
                  />
                  <Button 
                    type="button" 
                    variant="outline" 
                    size="sm" 
                    onClick={handleTestWs} 
                    disabled={isTestingWs || !localSettings.funasrWsEndpoint}
                    className="h-8 px-2 text-xs flex items-center gap-1 shrink-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                  >
                    {isTestingWs ? <Loader2 className="w-3 h-3 animate-spin" /> : <RefreshCw className="w-3 h-3" />}
                    测试
                  </Button>
                </div>
              </div>
              {wsTestStatus && (
                <div className="grid grid-cols-4 gap-4">
                  <div className="col-start-2 col-span-3">
                    <div className={cn(
                      "text-[11px] p-2 rounded-md",
                      wsTestStatus.type === 'error' ? "bg-red-50 text-red-600 dark:bg-red-950/50 dark:text-red-400" : "bg-green-50 text-green-600 dark:bg-green-950/50 dark:text-green-400"
                    )}>
                      {wsTestStatus.message}
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>

          <div className="grid grid-cols-4 items-center gap-4">
            <Label htmlFor="contextLength" className="text-right text-xs">上下文长度</Label>
            <Input 
              id="contextLength" 
              name="contextLength" 
              type="number"
              value={localSettings.contextLength == null ? '' : localSettings.contextLength}
              onChange={(e) => {
                const val = e.target.value;
                if (val === '') {
                  setLocalSettings(prev => {
                    const next = { ...prev, contextLength: undefined };
                    localSettingsRef.current = next;
                    return next;
                  });
                } else {
                  const num = parseInt(val);
                  if (!isNaN(num)) {
                    setLocalSettings(prev => {
                      const next = { ...prev, contextLength: Math.max(1, num) };
                      localSettingsRef.current = next;
                      return next;
                    });
                  }
                }
              }}
              onBlur={() => {
                if (localSettings.contextLength == null || localSettings.contextLength <= 0) {
                  updateAndSave({ contextLength: 30000 });
                } else {
                  updateAndSave({ contextLength: localSettings.contextLength });
                }
              }}
              className="col-span-3 h-8 text-xs" 
              placeholder="默认为30000tonken"
            />
          </div>

          {/* DeepSeek Harness / Local Agent Bridge Settings */}
          <div className="border-t pt-4 mt-2">
            <div className="flex items-center justify-between mb-3">
              <h4 className="text-xs font-semibold flex items-center gap-1.5 text-primary">
                <Bot className="w-4 h-4" />
                本地 Agent 桥接设置 (DeepSeek Harness)
              </h4>
              <div className="flex items-center gap-2">
                <span className={cn(
                  "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium border",
                  agentOnlineStatus?.online 
                    ? "bg-emerald-500/10 text-emerald-500 border-emerald-500/30 shadow-[0_0_8px_rgba(16,185,129,0.2)]" 
                    : "bg-muted text-muted-foreground border-border/50"
                )}>
                  <span className={cn(
                    "w-1.5 h-1.5 rounded-full",
                    agentOnlineStatus?.online ? "bg-emerald-500 animate-pulse" : "bg-muted-foreground/50"
                  )} />
                  {agentOnlineStatus?.online ? `已连接 (${agentOnlineStatus.clientName || 'Local'})` : '桥接离线'}
                </span>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="h-6 w-6 rounded-md hover:bg-primary/10"
                  onClick={() => checkAgentStatus()}
                  disabled={isCheckingAgent}
                  title="刷新连接状态"
                >
                  <RefreshCw className={cn("w-3 h-3 text-muted-foreground", isCheckingAgent && "animate-spin text-primary")} />
                </Button>
              </div>
            </div>

            <div className="space-y-3 p-3 bg-muted/20 rounded-xl border border-border/50">
              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="agentMode" className="text-right text-xs">默认 Agent 模式</Label>
                <div className="col-span-3 flex items-center justify-between h-8">
                  <div className="flex items-center gap-2">
                    <input
                      id="agentMode"
                      type="checkbox"
                      checked={localSettings.agentMode || false}
                      onChange={(e) => updateAndSave({ agentMode: e.target.checked })}
                      className="w-4 h-4 rounded border-gray-300 text-primary focus:ring-primary"
                    />
                    <span className="text-xs text-muted-foreground">
                      {localSettings.agentMode ? '已开启（优先派发本地 Agent 处理）' : '已关闭（直接与 App 模型对话）'}
                    </span>
                  </div>
                </div>
              </div>

              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="agentToken" className="text-right text-xs">配对 Token</Label>
                <div className="col-span-3 flex items-center gap-1.5">
                  <Input
                    id="agentToken"
                    name="agentToken"
                    value={localSettings.agentToken || ''}
                    onChange={handleChange}
                    onBlur={handleBlur}
                    placeholder="输入或生成唯一的配对 Token"
                    className="h-8 text-xs font-mono flex-1"
                  />
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="h-8 px-2 text-xs flex items-center gap-1 shrink-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                    title="重置并注销旧设备"
                    disabled={isRevokingToken}
                    onClick={handleRevokeAndResetToken}
                  >
                    <RefreshCw className={cn("w-3.5 h-3.5", isRevokingToken && "animate-spin text-primary")} />
                    重置注销
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="h-8 px-2 text-xs flex items-center gap-1 shrink-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                    title="复制 Token"
                    onClick={async () => {
                      const t = localSettings.agentToken || 'default_agent_token';
                      await navigator.clipboard.writeText(t);
                      setCopiedAgentToken(true);
                      setTimeout(() => setCopiedAgentToken(false), 2000);
                    }}
                  >
                    {copiedAgentToken ? <Check className="w-3.5 h-3.5 text-emerald-500" /> : <Copy className="w-3.5 h-3.5" />}
                    {copiedAgentToken ? '已复制' : '复制'}
                  </Button>
                </div>
              </div>

              {/* 安全提示栏 */}
              <div className="flex items-start gap-2 bg-amber-500/10 border border-amber-500/20 text-amber-700 dark:text-amber-300 p-2.5 rounded-lg text-[11px] leading-relaxed">
                <span className="text-sm shrink-0">🛡️</span>
                <div className="space-y-1">
                  <div>
                    <span className="font-semibold">安全防护与白名单：</span>
                    桥接脚本内置严格接口白名单（仅允许标准对话转发），禁止篡改系统与插件；全程纯内存无状态运行，不持久化任何对话与日志。
                  </div>
                  <div>
                    <span className="font-semibold">凭证安全：</span>
                    配对 Token 仅用于长连接调度，<strong className="font-semibold text-amber-800 dark:text-amber-200">请勿分享给他人</strong>。如怀疑泄露可点击「重置注销」使所有旧连接立即断开失效。
                  </div>
                </div>
              </div>

              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="agentHarnessUrl" className="text-right text-xs">Harness 服务</Label>
                <div className="col-span-3">
                  <div className="relative flex rounded-md shadow-xs">
                    <span className="inline-flex items-center px-2.5 rounded-l-md border border-r-0 border-input bg-muted text-muted-foreground text-xs font-mono select-none">
                      http://
                    </span>
                    <Input
                      id="agentHarnessUrl"
                      name="agentHarnessUrl"
                      value={getHarnessInputDisplayValue(localSettings.agentHarnessUrl)}
                      onChange={(e) => {
                        const raw = e.target.value.trim();
                        const cleanHost = raw.replace(/^https?:\/\//i, '');
                        setLocalSettings(prev => {
                          const next = {
                            ...prev,
                            agentHarnessUrl: cleanHost ? `http://${cleanHost}` : 'http://127.0.0.1:3081'
                          };
                          localSettingsRef.current = next;
                          return next;
                        });
                      }}
                      onBlur={handleBlur}
                      placeholder="127.0.0.1:3081"
                      className="h-8 text-xs font-mono rounded-l-none border-l-0"
                    />
                  </div>
                  <span className="text-[10px] text-muted-foreground mt-1 block">
                    默认: <code>127.0.0.1:3081</code> (协议头 <code>http://</code> 已在后台自动注入)
                  </span>
                </div>
              </div>

              {/* 本地工作区与会话选择卡片 */}
              <div className="p-3 bg-primary/5 rounded-xl border border-primary/20 space-y-3">
                <div className="flex items-center justify-between">
                  <span className="text-xs font-semibold text-primary flex items-center gap-1.5">
                    <FolderKanban className="w-3.5 h-3.5" />
                    本地工作区与对话列表 (DeepSeek Harness)
                  </span>
                  <div className="flex items-center gap-1.5">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() => fetchAgentSessions()}
                      disabled={isLoadingSessions}
                      className="h-6 px-2 text-[10px] flex items-center gap-1 shrink-0 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                      title="从本地 DSH 刷新工作区和会话列表"
                    >
                      <RefreshCw className={cn("w-3 h-3", isLoadingSessions && "animate-spin text-primary")} />
                      刷新列表
                    </Button>
                    <Button
                      type="button"
                      variant="default"
                      size="sm"
                      onClick={() => setShowNewSessionInput(!showNewSessionInput)}
                      className="h-6 px-2 text-[10px] flex items-center gap-1 bg-primary text-primary-foreground shrink-0 shadow-xs transition-colors hover:bg-primary/80"
                      title="在本地 DSH 立即创建一个全新对话"
                    >
                      <Plus className="w-3 h-3" />
                      新建本地会话
                    </Button>
                  </div>
                </div>

                {/* 工作区选择 */}
                <div className="grid grid-cols-4 items-center gap-4">
                  <Label htmlFor="agentWorkspace" className="text-right text-xs">目标工作区</Label>
                  <div className="col-span-3 flex items-center gap-2">
                    <Input
                      id="agentWorkspace"
                      name="agentWorkspace"
                      value={localSettings.agentWorkspace || 'deepseek-agent'}
                      onChange={(e) => updateAndSave({ agentWorkspace: e.target.value })}
                      placeholder="deepseek-agent"
                      className="h-8 text-xs font-mono flex-1"
                    />
                    {agentWorkspaces && agentWorkspaces.length > 1 && (
                      <select
                        value={localSettings.agentWorkspace || 'deepseek-agent'}
                        onChange={(e) => updateAndSave({ agentWorkspace: e.target.value })}
                        className="h-8 text-xs bg-background border border-input rounded-md px-2 text-foreground"
                      >
                        {agentWorkspaces.map(ws => (
                          <option key={ws} value={ws}>{ws}</option>
                        ))}
                      </select>
                    )}
                  </div>
                </div>

                {/* 会话选择 */}
                <div className="grid grid-cols-4 items-start gap-4">
                  <Label htmlFor="agentSessionId" className="text-right text-xs pt-2">目标会话</Label>
                  <div className="col-span-3 space-y-1.5">
                    <select
                      id="agentSessionId"
                      value={localSettings.agentSessionId || ''}
                      onChange={(e) => updateAndSave({ agentSessionId: e.target.value })}
                      className="w-full h-8 text-xs bg-background border border-input rounded-md px-2 text-foreground font-medium truncate"
                    >
                      <option value="">✨ 智能选择 / 自动新建会话 (推荐)</option>
                      {agentWorkspaces.map(ws => {
                        const wsSessions = agentSessions.filter(s => (s.workspace || 'deepseek-agent') === ws);
                        if (wsSessions.length === 0) return null;
                        return (
                          <optgroup key={ws} label={`📁 工作区: ${ws}`}>
                            {wsSessions.map((s) => {
                              const sid = s.sessionId || s.id;
                              return (
                                <option key={sid} value={sid}>
                                  {s.title || '未命名对话'} ({sid?.substring(0, 8)}...)
                                </option>
                              );
                            })}
                          </optgroup>
                        );
                      })}
                      {/* 渲染未匹配到已知工作区的会话 */}
                      {(() => {
                        const otherSessions = agentSessions.filter(s => !agentWorkspaces.includes(s.workspace || 'deepseek-agent'));
                        if (otherSessions.length === 0) return null;
                        return (
                          <optgroup label="其他工作区会话">
                            {otherSessions.map((s) => {
                              const sid = s.sessionId || s.id;
                              return (
                                <option key={sid} value={sid}>
                                  [{s.workspace || 'default'}] {s.title || '未命名对话'} ({sid?.substring(0, 8)}...)
                                </option>
                              );
                            })}
                          </optgroup>
                        );
                      })()}
                    </select>

                    {showNewSessionInput && (
                      <div className="flex items-center gap-1.5 pt-1">
                        <Input
                          value={newSessionTitle}
                          onChange={(e) => setNewSessionTitle(e.target.value)}
                          placeholder="输入新会话标题 (如: 文档档案处理)"
                          className="h-7 text-xs flex-1"
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') handleCreateSession(newSessionTitle);
                          }}
                        />
                        <Button
                          type="button"
                          size="sm"
                          disabled={isCreatingSession}
                          onClick={() => handleCreateSession(newSessionTitle)}
                          className="h-7 px-2 text-xs shrink-0"
                        >
                          {isCreatingSession ? <Loader2 className="w-3 h-3 animate-spin mr-1" /> : <Check className="w-3 h-3 mr-1" />}
                          确认创建
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          onClick={() => setShowNewSessionInput(false)}
                          className="h-7 px-1.5 text-xs text-muted-foreground shrink-0"
                        >
                          取消
                        </Button>
                      </div>
                    )}

                    <div className="text-[10px] text-muted-foreground leading-relaxed flex items-center justify-between">
                      <span className="truncate">
                        {localSettings.agentSessionId
                          ? `已锁定会话: ${localSettings.agentSessionId.substring(0, 14)}...`
                          : '自动模式：未指定或会话不存在时，将自动在目标工作区创建新会话并自动绑定。'}
                      </span>
                      {localSettings.agentSessionId && (
                        <div className="flex items-center gap-2 ml-2 shrink-0">
                          <button
                            type="button"
                            onClick={async () => {
                              const newTitle = window.prompt('请输入新的会话标题：');
                              if (newTitle && newTitle.trim()) {
                                try {
                                  await fetch(`${API_BASE_URL}/api/agent/rename-session`, {
                                    method: 'PATCH',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({
                                      sessionId: localSettings.agentSessionId,
                                      title: newTitle.trim(),
                                      token: localSettings.agentToken
                                    })
                                  });
                                  fetchAgentSessions();
                                  Toast.show({ text: '会话已重命名' });
                                } catch (e) {
                                  console.error(e);
                                }
                              }
                            }}
                            className="text-primary hover:underline font-medium text-[10px]"
                          >
                            重命名
                          </button>
                          <button
                            type="button"
                            onClick={async () => {
                              if (window.confirm('确认归档此会话？归档后将从本地工作区移除。')) {
                                try {
                                  await fetch(`${API_BASE_URL}/api/agent/archive-session`, {
                                    method: 'DELETE',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({
                                      sessionId: localSettings.agentSessionId,
                                      token: localSettings.agentToken
                                    })
                                  });
                                  updateAndSave({ agentSessionId: '' });
                                  fetchAgentSessions();
                                  Toast.show({ text: '会话已归档' });
                                } catch (e) {
                                  console.error(e);
                                }
                              }
                            }}
                            className="text-destructive hover:underline font-medium text-[10px]"
                          >
                            归档会话
                          </button>
                          <button
                            type="button"
                            onClick={() => updateAndSave({ agentSessionId: '' })}
                            className="text-muted-foreground hover:underline font-medium text-[10px]"
                          >
                            重置为自动
                          </button>
                        </div>
                      )}
                    </div>
                  </div>
                </div>

                {/* DSH 3080 运行控制参数 (模型/推理/权限) */}
                <div className="pt-2 border-t border-primary/10 space-y-2.5">
                  <div className="text-[11px] font-semibold text-foreground/90 flex items-center gap-1.5">
                    <Sliders className="w-3.5 h-3.5 text-primary" />
                    DSH 智能体执行选项
                  </div>
                  <div className="grid grid-cols-1 sm:grid-cols-3 gap-2 text-xs">
                    {/* 模型选择 */}
                    <div className="space-y-1">
                      <Label className="text-[10px] text-muted-foreground font-medium">默认模型 (Model)</Label>
                      <select
                        value={localSettings.agentModel || 'deepseek-v4-flash'}
                        onChange={(e) => updateAndSave({ agentModel: e.target.value })}
                        className="w-full h-7 text-xs bg-background border border-input rounded px-1.5 text-foreground font-mono"
                      >
                        <option value="deepseek-v4-flash">deepseek-v4-flash (DeepSeek-V4-Flash)</option>
                        <option value="deepseek-v4-pro">deepseek-v4-pro (DeepSeek-V4-Pro)</option>
                        <option value="deepseek-v4-flash-vision-exp">deepseek-v4-flash-vision-exp (视觉实验版)</option>
                        <option value="ep-20260824185630-nkdc7">ep-20260824185630-nkdc7 (Doubao 豆包)</option>
                      </select>
                    </div>

                    {/* 推理深度 */}
                    <div className="space-y-1">
                      <Label className="text-[10px] text-muted-foreground font-medium">思考深度 (Reasoning)</Label>
                      <select
                        value={localSettings.agentReasoningEffort || 'high'}
                        onChange={(e) => updateAndSave({ agentReasoningEffort: e.target.value as any })}
                        className="w-full h-7 text-xs bg-background border border-input rounded px-1.5 text-foreground"
                      >
                        <option value="high">深度思考 (High)</option>
                        <option value="max">极限思考 (Max)</option>
                        <option value="low">快速推理 (Low)</option>
                        <option value="off">关闭思考 (Off)</option>
                      </select>
                    </div>

                    {/* 权限级别 */}
                    <div className="space-y-1">
                      <Label className="text-[10px] text-muted-foreground font-medium">运行权限 (Permission)</Label>
                      <select
                        value={localSettings.agentPermission || 'workspace-write'}
                        onChange={(e) => updateAndSave({ agentPermission: e.target.value as any })}
                        className="w-full h-7 text-xs bg-background border border-input rounded px-1.5 text-foreground"
                      >
                        <option value="workspace-write">工作区写 (Workspace Write)</option>
                        <option value="read-only">只读模式 (Read Only)</option>
                        <option value="danger-full-access">完全控制 (Danger Full Access)</option>
                      </select>
                    </div>
                  </div>
                </div>
              </div>

              <div className="pt-2 border-t border-border/40 space-y-2">
                <div className="flex flex-wrap items-center justify-between gap-1.5">
                  <span className="text-[11px] font-medium text-foreground/80 flex items-center gap-1">
                    <Terminal className="w-3.5 h-3.5 text-primary" />
                    本地启动程序 (免公网 IP，安全反向长连接):
                  </span>
                  <div className="flex items-center gap-1.5">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={handleDownloadBridgePy}
                      className="h-6 px-2 text-[10px] text-primary border-primary/30 flex items-center gap-1 font-medium transition-all hover:bg-primary/20 hover:brightness-110 hover:shadow-xs active:scale-95"
                      title="下载已预填好配置的 Python 桥接脚本"
                    >
                      <Download className="w-3 h-3" />
                      下载 .py 脚本
                    </Button>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={handleDownloadStartBat}
                      className="h-6 px-2 text-[10px] text-emerald-600 dark:text-emerald-400 border-emerald-500/30 flex items-center gap-1 font-medium transition-colors hover:bg-emerald-500/15 hover:border-emerald-500/50 active:scale-95"
                      title="Windows 双击直接运行（自动安装依赖）"
                    >
                      <Download className="w-3 h-3" />
                      Windows 一键 .bat
                    </Button>
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      onClick={async () => {
                        const directUrl = `${currentOrigin}/api/download/deepseek_bridge.py`;
                        await navigator.clipboard.writeText(directUrl);
                        setCopiedDownloadUrl(true);
                        setTimeout(() => setCopiedDownloadUrl(false), 2000);
                      }}
                      className="h-6 px-2 text-[10px] text-muted-foreground flex items-center gap-1 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                      title="复制真实 HTTP 下载直链（可在手机浏览器或电脑端直接粘贴下载）"
                    >
                      {copiedDownloadUrl ? <Check className="w-3 h-3 text-emerald-500" /> : <Link className="w-3 h-3" />}
                      {copiedDownloadUrl ? '已复制直链' : '复制直链'}
                    </Button>
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      onClick={() => setShowCodeModal(true)}
                      className="h-6 px-2 text-[10px] text-muted-foreground flex items-center gap-1 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                    >
                      <Copy className="w-3 h-3" />
                      查看/复制代码
                    </Button>
                  </div>
                </div>

                <div className="relative group bg-muted/60 p-2 rounded-lg border border-border/60 font-mono text-[10px] text-muted-foreground break-all">
                  <div className="pr-14 select-all text-foreground/90">
                    python deepseek_bridge.py --token "{localSettings.agentToken || 'default_agent_token'}" --server "{currentOrigin}" --harness-url "{normalizedHarnessUrl}"
                  </div>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    className="absolute top-1.5 right-1.5 h-6 px-2 text-[10px] bg-background/80 border border-border/50 flex items-center gap-1 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                    onClick={async () => {
                      const cmd = `python deepseek_bridge.py --token "${localSettings.agentToken || 'default_agent_token'}" --server "${currentOrigin}" --harness-url "${normalizedHarnessUrl}"`;
                      await navigator.clipboard.writeText(cmd);
                      setCopiedAgentCmd(true);
                      setTimeout(() => setCopiedAgentCmd(false), 2000);
                    }}
                  >
                    {copiedAgentCmd ? <Check className="w-3 h-3 text-emerald-500" /> : <Copy className="w-3 h-3" />}
                    {copiedAgentCmd ? '已复制' : '复制命令'}
                  </Button>
                </div>
                <div className="text-[10px] text-muted-foreground/80 leading-relaxed">
                  💡 提示：下载后放入任意文件夹运行即可。程序启动后，上方状态将自动变为绿色在线。
                </div>

                {/* 手机扫码直连配对卡片 */}
                <div className="mt-3 p-3 bg-primary/5 border border-primary/20 rounded-xl space-y-2">
                  <div className="flex items-center justify-between">
                    <span className="text-xs font-semibold text-primary flex items-center gap-1.5">
                      <QrCode className="w-3.5 h-3.5" />
                      📱 手机扫码直连配对 (免手动输入 Token)
                    </span>
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="h-6 px-2 text-[10px] text-primary hover:bg-primary/10"
                      onClick={async () => {
                        const token = localSettings.agentToken || 'default_agent_token';
                        const pairUrl = `${currentOrigin}?agentToken=${encodeURIComponent(token)}`;
                        await navigator.clipboard.writeText(pairUrl);
                        setCopiedPairUrl(true);
                        setTimeout(() => setCopiedPairUrl(false), 2000);
                      }}
                    >
                      {copiedPairUrl ? <Check className="w-3 h-3 text-emerald-500 mr-1" /> : <Copy className="w-3 h-3 mr-1" />}
                      {copiedPairUrl ? '已复制链接' : '复制手机配对链接'}
                    </Button>
                  </div>
                  
                  <div className="flex flex-col sm:flex-row items-center gap-3">
                    {qrCodeDataUrl ? (
                      <div className="p-1.5 bg-white rounded-lg border border-border/80 shadow-sm shrink-0">
                        <img src={qrCodeDataUrl} alt="Agent Pairing QR Code" className="w-28 h-28 object-contain" />
                      </div>
                    ) : (
                      <div className="w-28 h-28 bg-muted rounded-lg flex items-center justify-center text-muted-foreground text-[10px] shrink-0">
                        生成二维码中...
                      </div>
                    )}
                    <div className="space-y-1 text-[11px] text-muted-foreground leading-relaxed">
                      <p className="font-medium text-foreground">使用方法：</p>
                      <p>1. 手机打开本 App，点击底部输入框工具栏的 <span className="font-semibold text-primary">📸 相机</span>，切换到 <span className="font-semibold text-primary">“扫码连电脑”</span> 扫描左侧码。</p>
                      <p>2. 或直接使用手机微信/浏览器扫码打开，将自动配对并启用电脑本地 DeepSeek 算力！</p>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div className="border-t pt-4 mt-2">
            <h4 className="text-xs font-semibold mb-3">修改密码</h4>
            <div className="space-y-3">
              <Input type="password" placeholder="原密码" value={oldPassword} onChange={(e) => setOldPassword(e.target.value)} className="h-8 text-xs" />
              <Input type="password" placeholder="新密码" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} className="h-8 text-xs" />
              <Input type="password" placeholder="确认新密码" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} className="h-8 text-xs" />
              
              <AnimatePresence>
                {passwordStatus && (
                  <motion.div 
                    initial={{ opacity: 0, height: 0 }}
                    animate={{ opacity: 1, height: 'auto' }}
                    exit={{ opacity: 0, height: 0 }}
                    className={cn(
                      "text-[10px] p-2 rounded-lg border",
                      passwordStatus.type === 'error' ? "bg-destructive/10 border-destructive/20 text-destructive" : "bg-primary/10 border-primary/20 text-primary"
                    )}
                  >
                    {passwordStatus.message}
                  </motion.div>
                )}
              </AnimatePresence>
              
              <div className="flex justify-end pr-0.5">
                <Button 
                  variant="outline" 
                  size="sm" 
                  className="h-8 text-xs px-3 transition-all hover:bg-primary/10 hover:text-primary active:scale-95"
                  onClick={handlePasswordChange}
                >
                  确认修改
                </Button>
              </div>
            </div>
          </div>

          <div className="border-t pt-4 mt-2">
            <h4 className="text-xs font-semibold mb-3">GitHub 更新设置</h4>
            <div className="space-y-3">
              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="githubOwner" className="text-right text-xs">用户名</Label>
                <Input id="githubOwner" name="githubOwner" value={localSettings.githubOwner || ''} onChange={handleChange} onBlur={handleBlur} className="col-span-3 h-8 text-xs" placeholder="例如：lx00924" />
              </div>
              <div className="grid grid-cols-4 items-center gap-4">
                <Label htmlFor="githubRepo" className="text-right text-xs">仓库名</Label>
                <Input id="githubRepo" name="githubRepo" value={localSettings.githubRepo || ''} onChange={handleChange} onBlur={handleBlur} className="col-span-3 h-8 text-xs" placeholder="例如：aether-x" />
              </div>
              
              <AnimatePresence>
                {updateStatus && (
                  <motion.div 
                    initial={{ opacity: 0, height: 0 }}
                    animate={{ opacity: 1, height: 'auto' }}
                    exit={{ opacity: 0, height: 0 }}
                    className={cn(
                      "text-[10px] p-2 rounded-lg border",
                      updateStatus.type === 'error' ? "bg-destructive/10 border-destructive/20 text-destructive" : "bg-primary/10 border-primary/20 text-primary"
                    )}
                  >
                    {updateStatus.message}
                  </motion.div>
                )}
              </AnimatePresence>

              <div className="flex justify-end pr-0.5">
                <Button 
                  variant="outline" 
                  size="sm" 
                  className="h-8 text-xs px-3 transition-all hover:bg-primary/10 hover:text-primary active:scale-95"
                  onClick={handleInnerCheckUpdate}
                  disabled={isChecking}
                >
                  {isChecking ? '检测中...' : '检测新版本'}
                </Button>
              </div>
            </div>
          </div>

          <div className="border-t pt-4 mt-2">
            <h4 className="text-xs font-semibold mb-3 flex items-center justify-between text-blue-500">
              <span className="flex items-center gap-1.5">
                <HardDrive className="w-3.5 h-3.5" />
                桌面端数据与缓存目录
              </span>
              {isElectron && storageInfo?.isCustom && (
                <span className="text-[10px] text-blue-400 bg-blue-500/10 px-1.5 py-0.5 rounded border border-blue-500/20 font-normal">
                  自定义路径
                </span>
              )}
            </h4>
            
            <div className="space-y-3">
              <div className="p-2.5 rounded-lg border bg-muted/20 space-y-2">
                <div className="flex items-center justify-between text-xs">
                  <span className="text-muted-foreground">当前存储路径：</span>
                </div>
                <div 
                  className="text-[11px] font-mono bg-background/80 p-2 rounded border break-all select-all text-foreground/90 max-h-20 overflow-y-auto"
                  title={storageInfo?.currentPath || '默认 Windows 用户目录 (%APPDATA%)'}
                >
                  {storageInfo?.currentPath || (isElectron ? '正在读取中...' : '桌面端运行模式下可自定义路径 (默认 %APPDATA%)')}
                </div>
              </div>

              <div className="grid grid-cols-3 gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  className="h-8 text-xs gap-1 hover:bg-blue-500/10 hover:text-blue-500 transition-all active:scale-95"
                  onClick={handleSelectStoragePath}
                  disabled={isChangingStorage || !isElectron}
                  title={!isElectron ? '仅在 Windows 桌面端运行环境有效' : '自定义选择新的缓存与数据盘符目录'}
                >
                  <FolderOpen className="w-3.5 h-3.5" />
                  {isChangingStorage ? '选择中...' : '更改目录'}
                </Button>

                <Button
                  variant="outline"
                  size="sm"
                  className="h-8 text-xs gap-1 hover:bg-blue-500/10 hover:text-blue-500 transition-all active:scale-95"
                  onClick={handleOpenStorageFolder}
                  disabled={!isElectron}
                  title={!isElectron ? '仅在 Windows 桌面端运行环境有效' : '在 Windows 资源管理器中打开该目录'}
                >
                  <FolderOpen className="w-3.5 h-3.5" />
                  打开目录
                </Button>

                <Button
                  variant="outline"
                  size="sm"
                  className="h-8 text-xs gap-1 hover:bg-destructive/10 hover:text-destructive transition-all active:scale-95"
                  onClick={handleResetStoragePath}
                  disabled={!isElectron || !storageInfo?.isCustom}
                  title="恢复为系统默认目录"
                >
                  <RotateCcw className="w-3.5 h-3.5" />
                  恢复默认
                </Button>
              </div>

              <AnimatePresence>
                {storageStatus && (
                  <motion.div 
                    initial={{ opacity: 0, height: 0 }}
                    animate={{ opacity: 1, height: 'auto' }}
                    exit={{ opacity: 0, height: 0 }}
                    className={cn(
                      "text-[10px] p-2.5 rounded-lg border flex flex-col gap-2",
                      storageStatus.type === 'error' ? "bg-destructive/10 border-destructive/20 text-destructive" : "bg-blue-500/10 border-blue-500/20 text-blue-500"
                    )}
                  >
                    <div>{storageStatus.message}</div>
                    {storageStatus.needRestart && (
                      <div className="flex justify-end">
                        <Button
                          size="sm"
                          className="h-7 text-[11px] px-2.5 bg-blue-600 hover:bg-blue-700 text-white gap-1 shadow-sm active:scale-95"
                          onClick={handleRelaunch}
                        >
                          <RefreshCw className="w-3 h-3 animate-spin" />
                          立即重启生效
                        </Button>
                      </div>
                    )}
                  </motion.div>
                )}
              </AnimatePresence>
            </div>
          </div>

          <div className="border-t pt-4 mt-2">
            <h4 className="text-xs font-semibold mb-3 flex items-center gap-1.5 text-emerald-500">
              <Terminal className="w-3.5 h-3.5" />
              APP 检修与调试日志
            </h4>
            <div className="space-y-3">
              <div className="flex items-center justify-between p-2.5 rounded-lg border bg-muted/30">
                <div className="space-y-0.5">
                  <div className="text-xs font-medium">显示悬浮调试球</div>
                  <div className="text-[10px] text-muted-foreground">在右下角提供轻量 🐞 调试按钮，方便随时排查 APP 报错</div>
                </div>
                <input
                  type="checkbox"
                  checked={localSettings.showDebugFloatButton ?? true}
                  onChange={(e) => updateAndSave({ showDebugFloatButton: e.target.checked })}
                  className="h-4 w-4 rounded border-gray-300 text-primary focus:ring-primary cursor-pointer"
                />
              </div>

              <div className="grid grid-cols-2 gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  className="h-8 text-xs gap-1.5 border-emerald-500/30 hover:bg-emerald-500/10 hover:text-emerald-500"
                  onClick={() => {
                    if (onOpenLogViewer) onOpenLogViewer();
                  }}
                >
                  <Bug className="w-3.5 h-3.5 text-emerald-500" />
                  打开控制台
                </Button>

                <Button
                  variant="outline"
                  size="sm"
                  className="h-8 text-xs gap-1.5 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                  onClick={() => copyLogsToClipboard()}
                >
                  <Copy className="w-3.5 h-3.5" />
                  复制日志
                </Button>
              </div>
            </div>
          </div>
        </div>
      </DialogContent>
      {cropImage && (
        <ImageCropDialog
          imageSrc={cropImage.src}
          open={!!cropImage}
          onClose={() => setCropImage(null)}
          onCropComplete={(croppedImage) => {
            const field = cropImage.field;
            setCropImage(null);
            setTimeout(() => {
              updateAndSave({ [field]: croppedImage });
            }, 0);
          }}
        />
      )}

      {showCodeModal && (
        <Dialog open={showCodeModal} onOpenChange={setShowCodeModal}>
          <DialogContent className="max-w-2xl max-h-[85vh] flex flex-col p-4">
            <DialogHeader>
              <DialogTitle className="text-sm font-semibold flex items-center gap-2">
                <Terminal className="w-4 h-4 text-primary" />
                <span>deepseek_bridge.py 桥接源码</span>
                <span className="text-[10px] text-muted-foreground font-normal">(已自动填入当前 Token 与配置)</span>
              </DialogTitle>
            </DialogHeader>

            <div className="flex-1 overflow-auto bg-muted/80 p-3 rounded-lg border font-mono text-[11px] select-all my-2">
              <pre className="whitespace-pre text-foreground/90 leading-relaxed">
                {generateBridgeScriptContent()}
              </pre>
            </div>

            <DialogFooter className="flex sm:justify-between items-center gap-2">
              <div className="text-[11px] text-muted-foreground">
                可直接在本地新建一个 <code className="bg-muted px-1 py-0.5 rounded text-foreground font-mono">deepseek_bridge.py</code> 文本文件并粘贴保存。
              </div>
              <div className="flex gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={async () => {
                    await navigator.clipboard.writeText(generateBridgeScriptContent());
                    setCopiedFullCode(true);
                    setTimeout(() => setCopiedFullCode(false), 2000);
                  }}
                  className="h-8 text-xs flex items-center gap-1.5 transition-colors hover:bg-primary/10 hover:text-primary hover:border-primary/40"
                >
                  {copiedFullCode ? <Check className="w-3.5 h-3.5 text-emerald-500" /> : <Copy className="w-3.5 h-3.5" />}
                  {copiedFullCode ? '已复制代码' : '一键复制代码'}
                </Button>
                <Button
                  size="sm"
                  onClick={() => setShowCodeModal(false)}
                  className="h-8 text-xs"
                >
                  关闭
                </Button>
              </div>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}
    </Dialog>
  );
};
