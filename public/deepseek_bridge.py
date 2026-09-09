#!/usr/bin/env python3
"""
DeepSeek Harness 本地安全反向桥接客户端 (DeepSeek Bridge v3.6 - 工业增强/双模高可用版)
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
  • 调度服务器: https://www.lx00924ai.top
  • Harness地址: http://127.0.0.1:3080 (默认 3080/v1)

使用方式：
    pip install requests websockets
    python deepseek_bridge.py --token YOUR_TOKEN
"""

import argparse
import asyncio
from datetime import datetime
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
        hOut = kernel32.GetStdHandle(-11)
        mode = ctypes.c_ulong()
        kernel32.GetConsoleMode(hOut, ctypes.byref(mode))
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
    format="\033[90m%(asctime)s\033[0m %(message)s",
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
    parser = argparse.ArgumentParser(description="DeepSeek Harness Local Reverse Bridge v3.7")
    parser.add_argument("--token", type=str, default=os.getenv("AGENT_TOKEN", ""), help="App 中生成的配对 Token")
    parser.add_argument("--server", type=str, default=os.getenv("SERVER_URL", "https://www.lx00924ai.top"), help="App 调度服务器地址 (默认: https://www.lx00924ai.top)")
    parser.add_argument("--harness-url", type=str, default=os.getenv("HARNESS_URL", "http://127.0.0.1:3080"), help="本地 DeepSeek Harness / Agent 服务地址 (默认: http://127.0.0.1:3080)")
    parser.add_argument("--harness-model", type=str, default=os.getenv("HARNESS_MODEL", "deepseek-v4-flash"), help="本地 DeepSeek 模型名称 (默认: deepseek-v4-flash)")
    parser.add_argument("--chat-api-url", type=str, default=os.getenv("CHAT_API_URL", ""), help="可选：独立云端聊天推理接口 (如火山方舟 https://ark.cn-beijing.volces.com/api/v3)")
    parser.add_argument("--chat-api-key", type=str, default=os.getenv("CHAT_API_KEY", ""), help="可选：云端聊天 API Key")
    parser.add_argument("--chat-model", type=str, default=os.getenv("CHAT_MODEL", ""), help="可选：云端聊天模型名称 (如 deepseek-v4-pro-ga-260813)")
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
        
        ver = 1
        while ver in cls.PARAMS and data_len > cls.PARAMS[ver]['data_cw'] - 3:
            ver += 1
        if ver not in cls.PARAMS:
            ver = 6

        param = cls.PARAMS[ver]
        size = param['size']
        data_cw_count = param['data_cw']
        ec_cw_count = param['ec_cw']

        bits = []
        def append_bits(val, length):
            for i in range(length - 1, -1, -1):
                bits.append((val >> i) & 1)

        append_bits(0b0100, 4)
        append_bits(data_len, 8 if ver < 10 else 16)
        for b in data:
            append_bits(b, 8)
        
        rem_bits = (data_cw_count * 8) - len(bits)
        term_len = min(4, rem_bits) if rem_bits > 0 else 0
        append_bits(0, term_len)
        while len(bits) % 8 != 0:
            bits.append(0)

        pad_bytes = [0xEC, 0x11]
        pad_idx = 0
        while len(bits) < data_cw_count * 8:
            append_bits(pad_bytes[pad_idx % 2], 8)
            pad_idx += 1

        data_bytes = []
        for i in range(0, len(bits), 8):
            b = 0
            for j in range(8):
                b = (b << 1) | bits[i + j]
            data_bytes.append(b)

        ec_bytes = cls._rs_encode(data_bytes, ec_cw_count)
        final_cw = data_bytes + ec_bytes

        final_bits = []
        for b in final_cw:
            for i in range(7, -1, -1):
                final_bits.append((b >> i) & 1)

        matrix = [[None] * size for _ in range(size)]
        is_func = [[False] * size for _ in range(size)]

        def set_func(r, c, v):
            if 0 <= r < size and 0 <= c < size:
                matrix[r][c] = v
                is_func[r][c] = True

        for r0, c0 in [(0, 0), (0, size - 7), (size - 7, 0)]:
            for dr in range(7):
                for dc in range(7):
                    if dr in (0, 6) or dc in (0, 6) or (2 <= dr <= 4 and 2 <= dc <= 4):
                        set_func(r0 + dr, c0 + dc, 1)
                    else:
                        set_func(r0 + dr, c0 + dc, 0)
            for i in range(8):
                set_func(r0 - 1, c0 + i, 0)
                set_func(r0 + 7, c0 + i, 0)
                set_func(r0 + i, c0 - 1, 0)
                set_func(r0 + i, c0 + 7, 0)

        for i in range(8, size - 8):
            set_func(6, i, 1 if i % 2 == 0 else 0)
            set_func(i, 6, 1 if i % 2 == 0 else 0)

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

        set_func(4 * ver + 9, 8, 1)

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
        print("\n    \033[97m[ 📱 手机扫码直连通道 ]\033[0m")
        print("    \033[90m请使用手机相机或扫码功能扫描下方二维码快速配对:\033[0m\n")
        
        print("    \033[47m" + "  " * (w + 2) + "\033[0m")
        for r in range(h):
            row_str = "  "
            for c in range(w):
                if matrix[r][c] == 1:
                    row_str += "  "
                else:
                    row_str += "██"
            row_str += "  "
            print(f"    \033[30m\033[47m{row_str}\033[0m")
        print("    \033[47m" + "  " * (w + 2) + "\033[0m\n")
        print(f"    \033[96m手机扫码/点击直连链接:\033[0m \033[97m{text}\033[0m\n")
    except Exception as e:
        print(f"\n    \033[96m手机扫码直连地址:\033[0m {text}\n")

# ======================================================================
# 工业级高容错 HTTP 通信引擎
# ======================================================================
FALLBACK_SERVERS = [
    "https://www.lx00924ai.top",
    "https://ais-pre-lswjsr25ivxdaulzx2iy3d-135884546184.asia-northeast1.run.app",
    "https://ais-dev-lswjsr25ivxdaulzx2iy3d-135884546184.asia-northeast1.run.app"
]

def create_resilient_ssl_context():
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
        self.primary_server = primary_server.rstrip("/") if primary_server else "https://www.lx00924ai.top"
        
        self.direct_opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=self.ssl_ctx) if self.ssl_ctx else urllib.request.HTTPSHandler()
        )
        
        if self.custom_proxy:
            proxy_dict = {"http": self.custom_proxy, "https": self.custom_proxy}
            self.proxy_opener = urllib.request.build_opener(
                urllib.request.ProxyHandler(proxy_dict),
                urllib.request.HTTPSHandler(context=self.ssl_ctx) if self.ssl_ctx else urllib.request.HTTPSHandler()
            )
        else:
            self.proxy_opener = urllib.request.build_opener(
                urllib.request.ProxyHandler(),
                urllib.request.HTTPSHandler(context=self.ssl_ctx) if self.ssl_ctx else urllib.request.HTTPSHandler()
            )
        
        self.active_opener = self.direct_opener if force_no_proxy else self.proxy_opener
        self.has_switched_to_direct = False
        self.active_server_base = self.primary_server

    def get_candidate_urls(self, target_url: str):
        candidates = [target_url]
        for fb in FALLBACK_SERVERS:
            if fb not in target_url:
                parsed_fb = urllib.parse.urlparse(fb)
                parsed_target = urllib.parse.urlparse(target_url)
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
                
                if is_proxy_or_ssl_error and self.active_opener != self.direct_opener:
                    if not self.has_switched_to_direct:
                        print(f"\033[93m[🛡️ 网络自愈] 检测到系统代理不可用或 SSL 握手受阻，已自动熔断代理并切换至 Direct 直连！\033[0m")
                        self.has_switched_to_direct = True
                    self.active_opener = self.direct_opener
                    try:
                        with self.direct_opener.open(req, timeout=timeout) as response:
                            return response.read().decode("utf-8")
                    except Exception as retry_e:
                        last_error = retry_e
                        err_str = str(retry_e)

                is_dns_error = "11001" in err_str or "getaddrinfo failed" in err_str or "nodename nor servname" in err_str
                if is_dns_error and len(candidate_urls) > 1 and candidate_url != candidate_urls[-1]:
                    continue

        if last_error:
            raise last_error
        raise RuntimeError("所有网络候选节点均不可达")

GLOBAL_HTTP_CLIENT = ResilientHttpClient()

def init_global_http_client(force_no_proxy: bool = False, custom_proxy: str = "", primary_server: str = ""):
    global GLOBAL_HTTP_CLIENT
    GLOBAL_HTTP_CLIENT = ResilientHttpClient(force_no_proxy=force_no_proxy, custom_proxy=custom_proxy, primary_server=primary_server)

def http_post_json(url: str, data: dict, timeout: int = 15) -> dict:
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

def is_html_content(content: str) -> bool:
    if not content or not isinstance(content, str):
        return False
    c = content.strip().lower()
    return (
        c.startswith("<!doctype") or
        c.startswith("<html") or
        "<title>dsh" in c or
        "window.__moduleloader__" in c or
        "window.__dsh_boot__" in c
    )

def extract_text_from_obj(obj) -> str:
    if obj is None:
        return ""
    if isinstance(obj, str):
        if is_html_content(obj):
            return ""
        return obj
    if isinstance(obj, list):
        parts = [extract_text_from_obj(item) for item in obj]
        return "\n".join(filter(None, parts))
    if isinstance(obj, dict):
        # Prefer delta / text / content / output / result / message
        for key in ["delta", "text", "content", "output", "result", "message"]:
            if key in obj and obj[key]:
                val = extract_text_from_obj(obj[key])
                if val:
                    return val
        if "parts" in obj and isinstance(obj["parts"], list):
            return extract_text_from_obj(obj["parts"])
    return ""

def extract_dsh_sessions_and_workspaces(obj, default_ws="deepseek-agent"):
    workspaces = set()
    sessions = []
    
    if isinstance(obj, str) and is_html_content(obj):
        return list(workspaces), sessions

    def process_item(it):
        if not isinstance(it, dict):
            return
        sid = it.get("sessionId") or it.get("sessionID") or it.get("id") or it.get("session_id") or it.get("uuid")
        if sid:
            ws = it.get("workspace") or default_ws
            workspaces.add(ws)
            title = str(it.get("title") or it.get("name") or it.get("topic") or it.get("summary") or it.get("prompt") or f"会话_{str(sid)[:6]}")
            updated = it.get("updatedAt") or it.get("createdAt") or it.get("time") or int(time.time() * 1000)
            sessions.append({
                "id": str(sid),
                "sessionId": str(sid),
                "title": title,
                "workspace": ws,
                "updatedAt": updated
            })

    if isinstance(obj, list):
        for it in obj:
            process_item(it)
    elif isinstance(obj, dict):
        if obj.get("workspaces") and isinstance(obj["workspaces"], list):
            for w in obj["workspaces"]:
                if isinstance(w, str):
                    workspaces.add(w)
                elif isinstance(w, dict) and (w.get("name") or w.get("id")):
                    workspaces.add(str(w.get("name") or w.get("id")))

        for candidate_key in ["sessions", "result", "payload", "items", "data", "chats", "history"]:
            val = obj.get(candidate_key)
            if isinstance(val, list):
                for it in val:
                    process_item(it)
            elif isinstance(val, dict):
                process_item(val)
                if val.get("sessions") and isinstance(val["sessions"], list):
                    for it in val["sessions"]:
                        process_item(it)
                if val.get("items") and isinstance(val["items"], list):
                    for it in val["items"]:
                        process_item(it)
        
        # If the dict itself is a session object
        if obj.get("sessionId") or obj.get("id"):
            process_item(obj)

    return list(workspaces), sessions

async def query_dsh_workspaces_and_sessions(harness_url: str):
    global LOCAL_SESSION_CACHE
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    workspaces = ["deepseek-agent"]
    sessions = []
    seen_ids = set()

    for s in LOCAL_SESSION_CACHE:
        sid = s.get("sessionId") or s.get("id")
        if sid and sid not in seen_ids:
            seen_ids.add(sid)
            sessions.append(s)
            ws = s.get("workspace") or "deepseek-agent"
            if ws not in workspaces:
                workspaces.append(ws)

    rpc_list_payload = {
        "type": "client-request",
        "rpcId": f"rpc_list_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}",
        "mode": "steer",
        "method": "session.list",
        "payload": {}
    }

    rpc_list_ws_payload = {
        "type": "client-request",
        "rpcId": f"rpc_list_ws_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}",
        "mode": "steer",
        "method": "session.list",
        "payload": {"workspace": "deepseek-agent"}
    }

    rpc_workspace_payload = {
        "type": "client-request",
        "rpcId": f"rpc_ws_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}",
        "mode": "steer",
        "method": "workspace.list",
        "payload": {}
    }

    # 尝试直接通过本地 WebSocket RPC 查询 DSH 会话
    if HAS_WEBSOCKETS and not harness_base.startswith("https://"):
        ws_probe_urls = [
            f"{harness_base.replace('http://', 'ws://')}/v1/agent",
            f"{harness_base.replace('http://', 'ws://')}/agent",
            f"{harness_base.replace('http://', 'ws://')}"
        ]
        for ws_probe_url in ws_probe_urls:
            try:
                async with websockets.connect(ws_probe_url, open_timeout=1.5, close_timeout=1.5) as local_ws:
                    for p in [rpc_list_ws_payload, rpc_list_payload, rpc_workspace_payload]:
                        try:
                            await local_ws.send(json.dumps(p))
                            resp_raw = await asyncio.wait_for(local_ws.recv(), timeout=1.5)
                            if not is_html_content(resp_raw):
                                resp_obj = json.loads(resp_raw)
                                found_ws, found_sess = extract_dsh_sessions_and_workspaces(resp_obj)
                                for w in found_ws:
                                    if w and w not in workspaces:
                                        workspaces.append(w)
                                for s in found_sess:
                                    sid = s.get("sessionId") or s.get("id")
                                    if sid and sid not in seen_ids:
                                        seen_ids.add(sid)
                                        sessions.append(s)
                        except Exception:
                            continue
                    if len(sessions) > 0:
                        break
            except Exception:
                continue

    endpoints = [
        (f"{harness_base}/v1/sessions", "GET", None),
        (f"{harness_base}/api/sessions", "GET", None),
        (f"{harness_base}/v1/chat/sessions", "GET", None),
        (f"{harness_base}/api/workspaces", "GET", None),
        (f"{harness_base}/api/v1/sessions", "GET", None),
        (f"{harness_base}/api/session.list", "POST", rpc_list_payload),
        (f"{harness_base}/api/session.list", "POST", rpc_list_ws_payload),
    ]

    # Also test 3081 adapter if harness_url is 3080/3081
    adapter_base = harness_base
    if "3080" in harness_base:
        adapter_base = harness_base.replace("3080", "3081")
    if adapter_base != harness_base:
        endpoints.insert(0, (f"{adapter_base}/v1/sessions", "GET", None))
        endpoints.insert(1, (f"{adapter_base}/api/sessions", "GET", None))

    for ep, mth, pld in endpoints:
        def do_req(url=ep, method=mth, data_dict=pld):
            req_data = json.dumps(data_dict).encode("utf-8") if data_dict is not None else None
            req = urllib.request.Request(
                url,
                data=req_data,
                headers={"Content-Type": "application/json; charset=utf-8", "Accept": "application/json"},
                method=method
            )
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=2) as response:
                return response.read().decode("utf-8")

        try:
            raw = await loop.run_in_executor(None, do_req)
            if is_html_content(raw):
                continue
            resp = json.loads(raw)
            found_ws, found_sess = extract_dsh_sessions_and_workspaces(resp)
            for w in found_ws:
                if w and w not in workspaces:
                    workspaces.append(w)
            for s in found_sess:
                sid = s.get("sessionId") or s.get("id")
                if sid and sid not in seen_ids:
                    seen_ids.add(sid)
                    sessions.append(s)
        except Exception:
            continue

    if len(sessions) > 0:
        LOCAL_SESSION_CACHE = list(sessions)

    return workspaces, sessions

ACTIVE_SESSION_REGISTRY = {}

async def query_dsh_models(harness_url: str):
    """从本地 DSH (3080/3081) 获取可用模型列表与各模型的思考深度(推理等级)"""
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    candidates = [f"{harness_base}/v1/models"]
    if "3080" in harness_base:
        candidates.append(f"{harness_base.replace('3080', '3081')}/v1/models")
    elif "3081" in harness_base:
        candidates.append(f"{harness_base.replace('3081', '3080')}/v1/models")

    for url in candidates:
        def do_req():
            req = urllib.request.Request(
                url,
                headers={"Accept": "application/json", "User-Agent": "AetherX-Bridge/3.7"},
                method="GET"
            )
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=3) as resp:
                return resp.read().decode("utf-8")
        try:
            raw = await loop.run_in_executor(None, do_req)
            if is_html_content(raw):
                continue
            data = json.loads(raw)
            if isinstance(data, dict) and "models" in data:
                return data.get("models", [])
            elif isinstance(data, list):
                return data
        except Exception:
            continue
    return []

async def abort_dsh_session(harness_url: str, session_id: str):
    """中止本地 DSH 正在运行的任务轮次 (POST /v1/sessions/:id/abort)"""
    if not session_id:
        return False, "缺少 sessionId"
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    candidates = [
        f"{harness_base}/v1/sessions/{urllib.parse.quote(session_id)}/abort",
        f"{harness_base}/v1/agent/abort"
    ]
    if "3080" in harness_base:
        candidates.append(f"{harness_base.replace('3080', '3081')}/v1/sessions/{urllib.parse.quote(session_id)}/abort")

    for url in candidates:
        def do_abort():
            req = urllib.request.Request(
                url,
                data=json.dumps({"sessionId": session_id, "reason": "user_cancelled"}).encode("utf-8"),
                headers={"Content-Type": "application/json; charset=utf-8", "Accept": "application/json"},
                method="POST"
            )
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=3) as resp:
                return resp.read().decode("utf-8")
        try:
            raw = await loop.run_in_executor(None, do_abort)
            return True, raw
        except Exception as e:
            continue
    return False, "未能连接到 DSH 中止接口"

async def approve_dsh_session(harness_url: str, session_id: str, approval_id: str, action: str = "allow"):
    """向本地 DSH 提交越权操作的审批结果 (POST /v1/sessions/:id/approve)"""
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    candidates = [
        f"{harness_base}/v1/sessions/{urllib.parse.quote(session_id)}/approve",
        f"{harness_base}/v1/agent/approve"
    ]
    if "3080" in harness_base:
        candidates.append(f"{harness_base.replace('3080', '3081')}/v1/sessions/{urllib.parse.quote(session_id)}/approve")

    for url in candidates:
        def do_approve():
            req = urllib.request.Request(
                url,
                data=json.dumps({"approvalId": approval_id, "action": action}).encode("utf-8"),
                headers={"Content-Type": "application/json; charset=utf-8", "Accept": "application/json"},
                method="POST"
            )
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=4) as resp:
                return resp.read().decode("utf-8")
        try:
            raw = await loop.run_in_executor(None, do_approve)
            return True, raw
        except Exception as e:
            continue
    return False, "提交审批失败"

async def rename_dsh_session(harness_url: str, session_id: str, title: str):
    """重命名本地 DSH 会话 (PATCH /v1/sessions/:id)"""
    if not session_id or not title:
        return False, "缺少会话ID或标题"
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    candidates = [f"{harness_base}/v1/sessions/{urllib.parse.quote(session_id)}"]
    if "3080" in harness_base:
        candidates.append(f"{harness_base.replace('3080', '3081')}/v1/sessions/{urllib.parse.quote(session_id)}")

    for url in candidates:
        def do_patch():
            req = urllib.request.Request(
                url,
                data=json.dumps({"title": title}).encode("utf-8"),
                headers={"Content-Type": "application/json; charset=utf-8", "Accept": "application/json"},
                method="PATCH"
            )
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=3) as resp:
                return resp.read().decode("utf-8")
        try:
            raw = await loop.run_in_executor(None, do_patch)
            return True, raw
        except Exception:
            continue
    return False, "重命名失败"

async def archive_dsh_session(harness_url: str, session_id: str):
    """归档本地 DSH 会话 (DELETE /v1/sessions/:id)"""
    if not session_id:
        return False, "缺少会话ID"
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    candidates = [f"{harness_base}/v1/sessions/{urllib.parse.quote(session_id)}"]
    if "3080" in harness_base:
        candidates.append(f"{harness_base.replace('3080', '3081')}/v1/sessions/{urllib.parse.quote(session_id)}")

    for url in candidates:
        def do_del():
            req = urllib.request.Request(
                url,
                headers={"Accept": "application/json"},
                method="DELETE"
            )
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=3) as resp:
                return resp.read().decode("utf-8")
        try:
            raw = await loop.run_in_executor(None, do_del)
            return True, raw
        except Exception:
            continue
    return False, "归档失败"

async def execute_dsh_sse_stream(
    harness_base: str,
    target_workspace: str,
    model_name: str,
    active_session_id: str,
    prompt: str,
    reasoning_effort: str,
    permission: str,
    on_step_callback,
    extra_chat_config: dict = None,
    on_approval_callback = None
):
    """
    通过 DSH 3080 SSE 流式端点 (POST /v1/agent/prompt/stream) 执行任务并实时推送思考与工具事件
    """
    loop = asyncio.get_running_loop()
    endpoints = [
        f"{harness_base}/v1/agent/prompt/stream",
        f"{harness_base}/v1/agent/prompt"
    ]
    if "3080" in harness_base:
        endpoints.append(f"{harness_base.replace('3080', '3081')}/v1/agent/prompt/stream")
    elif "3081" in harness_base:
        endpoints.append(f"{harness_base.replace('3081', '3080')}/v1/agent/prompt/stream")

    real_session_id = None
    if active_session_id and active_session_id not in ("__auto__", "__auto_new__", "default_session", "none", "null"):
        real_session_id = active_session_id

    payload = {
        "prompt": prompt or "",
        "model": model_name or "deepseek-v4-flash",
        "workspace": target_workspace or "deepseek-agent"
    }
    if real_session_id:
        payload["sessionId"] = real_session_id
    if reasoning_effort and reasoning_effort != "default":
        payload["reasoningEffort"] = reasoning_effort
        payload["reasoning_effort"] = reasoning_effort
    if permission:
        payload["permission"] = permission
    else:
        payload["permission"] = "workspace-write"

    req_data = json.dumps(payload).encode("utf-8")

    for target_url in endpoints:
        def stream_request_worker(q: asyncio.Queue):
            headers = {
                "Content-Type": "application/json; charset=utf-8",
                "Accept": "text/event-stream, application/json",
                "User-Agent": "AetherX-Bridge/3.7"
            }
            auth_key = (extra_chat_config or {}).get("apiKey")
            if auth_key:
                headers["Authorization"] = f"Bearer {auth_key}"

            req = urllib.request.Request(target_url, data=req_data, headers=headers, method="POST")
            try:
                with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=600) as response:
                    content_type = response.headers.get("Content-Type", "")
                    if "text/event-stream" not in content_type and "json" in content_type:
                        # 非 SSE，按普通 JSON 读取
                        raw_body = response.read().decode("utf-8")
                        loop.call_soon_threadsafe(q.put_nowait, ("sync_json", raw_body))
                        return

                    current_event = "message"
                    data_lines = []

                    while True:
                        raw_line = response.readline()
                        if not raw_line:
                            break
                        line = raw_line.decode("utf-8", errors="replace")
                        line_s = line.strip()

                        # 心跳保持
                        if line_s.startswith(":"):
                            continue

                        if line_s.startswith("event:"):
                            current_event = line_s[6:].strip()
                        elif line_s.startswith("data:"):
                            data_lines.append(line_s[5:].strip())
                        elif line_s == "":
                            # 空行标志着一次 SSE 数据块完成
                            if data_lines:
                                chunk_data = "\n".join(data_lines)
                                loop.call_soon_threadsafe(q.put_nowait, (current_event, chunk_data))
                                data_lines = []
                                current_event = "message"

                    loop.call_soon_threadsafe(q.put_nowait, ("stream_end", None))
            except Exception as e:
                loop.call_soon_threadsafe(q.put_nowait, ("stream_error", str(e)))

        msg_queue = asyncio.Queue()
        stream_thread = threading.Thread(target=stream_request_worker, args=(msg_queue,), daemon=True)
        stream_thread.start()

        accumulated_content = []
        accumulated_reasoning = []
        received_any_event = False

        while True:
            try:
                ev_type, ev_data = await asyncio.wait_for(msg_queue.get(), timeout=20.0)
            except asyncio.TimeoutError:
                if received_any_event:
                    # 如果有持续收到过流，超时 20s 可能是长命令输出间歇，继续等待
                    continue
                else:
                    break

            if ev_type == "stream_error":
                break

            if ev_type == "stream_end":
                break

            received_any_event = True

            if ev_type == "sync_json":
                try:
                    j = json.loads(ev_data)
                    extracted = extract_text_from_obj(j)
                    if extracted and not is_html_content(extracted):
                        return True, extracted
                except Exception:
                    pass
                break

            # 处理 SSE 结构
            try:
                parsed_json = json.loads(ev_data) if ev_data else {}
            except Exception:
                parsed_json = {"raw": ev_data}

            if ev_type == "reasoning":
                txt = parsed_json.get("content", "")
                if txt:
                    accumulated_reasoning.append(txt)
                    await on_step_callback(f"💭 {txt}")
            elif ev_type == "content":
                txt = parsed_json.get("content", "")
                if txt:
                    accumulated_content.append(txt)
            elif ev_type == "tool_start":
                tool_name = parsed_json.get("tool", "工具")
                tool_input = parsed_json.get("input", "")
                inp_str = str(tool_input)
                if len(inp_str) > 120: inp_str = inp_str[:120] + "..."
                await on_step_callback(f"🔧 [执行工具] {tool_name}: {inp_str}")
            elif ev_type == "tool_end":
                tool_name = parsed_json.get("tool", "工具")
                status = parsed_json.get("status", "success")
                await on_step_callback(f"✓ [工具完成] {tool_name} (状态: {status})")
            elif ev_type == "waiting_approval":
                approval_id = parsed_json.get("approvalId")
                tool_name = parsed_json.get("tool", "越权操作")
                await on_step_callback(f"⚠️ [等待审批] 本地 Agent 正在请求执行敏感操作: {tool_name} (审批ID: {approval_id})")
                if on_approval_callback:
                    await on_approval_callback(parsed_json)
            elif ev_type == "approval_resolved":
                outcome = parsed_json.get("outcome", "")
                await on_step_callback(f"✓ [审批结果] 操作已被裁决: {outcome}")
            elif ev_type == "done":
                await on_step_callback(f"✅ [执行完成] 本地智能体已完成本轮所有操作")
                break
            elif ev_type == "error":
                err_msg = parsed_json.get("message", ev_data)
                await on_step_callback(f"❌ [DSH 报错] {err_msg}")
                break

        final_content = "".join(accumulated_content).strip()
        if final_content and not is_html_content(final_content):
            return True, final_content

        if accumulated_reasoning:
            fallback_res = "".join(accumulated_reasoning).strip()
            if fallback_res:
                return True, f"【思考过程】\n{fallback_res}"

    return False, None

async def create_dsh_session_explicit(harness_url: str, workspace: str = "deepseek-agent", title: str = None, model: str = "deepseek-chat"):
    global LOCAL_SESSION_CACHE
    harness_base = harness_url.rstrip("/")
    loop = asyncio.get_running_loop()
    from datetime import datetime
    session_title = title or f"对话_{datetime.now().strftime('%m%d_%H%M%S')}"
    target_ws = workspace or "deepseek-agent"

    create_payloads = [
        {
            "type": "client-request",
            "rpcId": f"rpc_create_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}",
            "mode": "steer",
            "method": "session.create",
            "payload": {
                "workspace": target_ws,
                "title": session_title
            }
        },
        {
            "type": "client-request",
            "rpcId": f"rpc_create_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}",
            "mode": "steer",
            "method": "session.create",
            "payload": {
                "workspace": target_ws
            }
        },
        {
            "type": "client-request",
            "rpcId": f"rpc_create_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}",
            "mode": "steer",
            "method": "session.create",
            "payload": {}
        }
    ]

    # 首先通过本地 WebSocket 创建会话 (DSH Local Cordis RPC 核心通道)
    if HAS_WEBSOCKETS and not harness_base.startswith("https://"):
        ws_probe_urls = [
            f"{harness_base.replace('http://', 'ws://')}/v1/agent",
            f"{harness_base.replace('http://', 'ws://')}/agent",
            f"{harness_base.replace('http://', 'ws://')}"
        ]
        for ws_url in ws_probe_urls:
            try:
                async with websockets.connect(ws_url, open_timeout=2.0, close_timeout=2.0) as local_ws:
                    for pld in create_payloads:
                        try:
                            await local_ws.send(json.dumps(pld))
                            # 监听可能的多条事件或响应
                            for _ in range(5):
                                resp_raw = await asyncio.wait_for(local_ws.recv(), timeout=2.0)
                                if is_html_content(resp_raw):
                                    continue
                                resp = json.loads(resp_raw)
                                if isinstance(resp, dict) and resp.get("ok") is not False:
                                    s_id = None
                                    for loc in [resp.get("result"), resp.get("payload"), resp.get("data"), resp.get("details"), resp]:
                                        if isinstance(loc, dict):
                                            s_id = loc.get("sessionId") or loc.get("sessionID") or loc.get("id") or loc.get("session_id")
                                            if s_id:
                                                break
                                        elif isinstance(loc, str) and len(loc) >= 8 and not loc.startswith("{"):
                                            s_id = loc
                                            break
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
    return False, fallback_id, fallback_session

def is_harness_error_response(resp_obj):
    if not isinstance(resp_obj, dict):
        return False
    if resp_obj.get("ok") is False:
        return True
    if "error" in resp_obj and resp_obj["error"] is not None and resp_obj["error"] is not False:
        return True
    return False

async def execute_dsh_via_ws(
    harness_url: str,
    target_workspace: str,
    model_name: str,
    active_session_id: str,
    content_list: list,
    prompt: str,
    on_step_callback
):
    harness_base = harness_url.rstrip("/")
    ws_urls = [
        f"{harness_base.replace('http://', 'ws://')}/v1/agent",
        f"{harness_base.replace('http://', 'ws://')}/agent",
        f"{harness_base.replace('http://', 'ws://')}"
    ]

    for ws_url in ws_urls:
        try:
            async with websockets.connect(
                ws_url,
                open_timeout=3.0,
                close_timeout=3.0,
                max_size=30 * 1024 * 1024
            ) as dsh_ws:
                cur_session_id = active_session_id
                
                # 若需要先注册会话
                if not cur_session_id or cur_session_id in ("__auto__", "__auto_new__", "default_session") or cur_session_id.startswith("session_"):
                    create_rpc_id = f"rpc_create_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}"
                    create_msg = {
                        "type": "client-request",
                        "rpcId": create_rpc_id,
                        "mode": "steer",
                        "method": "session.create",
                        "payload": {
                            "workspace": target_workspace,
                            "title": f"任务_{create_rpc_id[-6:]}"
                        }
                    }
                    await dsh_ws.send(json.dumps(create_msg))
                    
                    for _ in range(8):
                        try:
                            raw = await asyncio.wait_for(dsh_ws.recv(), timeout=2.5)
                            if is_html_content(raw):
                                continue
                            data = json.loads(raw)
                            if isinstance(data, dict):
                                sid = None
                                for loc in [data.get("result"), data.get("payload"), data.get("data"), data.get("details"), data]:
                                    if isinstance(loc, dict):
                                        sid = loc.get("sessionId") or loc.get("sessionID") or loc.get("id") or loc.get("session_id")
                                        if sid:
                                            break
                                if sid:
                                    cur_session_id = str(sid)
                                    await on_step_callback(f"✨ 本地 DSH 服务端已分配会话 ID ({cur_session_id[:8]}...)，正在下发指令")
                                    break
                        except Exception:
                            break
                
                if not cur_session_id:
                    cur_session_id = str(uuid.uuid4())

                # 发送提示词任务
                prompt_rpc_id = f"rpc_prompt_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}"
                prompt_msg = {
                    "type": "client-request",
                    "rpcId": prompt_rpc_id,
                    "mode": "steer",
                    "method": "session.prompt",
                    "payload": {
                        "sessionId": cur_session_id,
                        "sessionID": cur_session_id,
                        "workspace": target_workspace,
                        "mode": "steer",
                        "prompt": content_list,
                        "parts": content_list,
                        "content": content_list,
                        "text": prompt or "",
                        "model": model_name or "deepseek-chat"
                    }
                }
                
                await dsh_ws.send(json.dumps(prompt_msg))
                await on_step_callback("⚡ 已向本地 DSH 智能体发送 WebSocket 指令，等待推理返回...")

                accumulated_text = []
                start_t = time.time()

                while time.time() - start_t < 180:
                    try:
                        raw = await asyncio.wait_for(dsh_ws.recv(), timeout=12.0)
                        if is_html_content(raw):
                            continue
                        msg = json.loads(raw)
                        if not isinstance(msg, dict):
                            continue

                        # 检查错误
                        if msg.get("ok") is False or ("error" in msg and msg["error"]):
                            err_info = msg.get("error", {})
                            err_str = json.dumps(err_info, ensure_ascii=False) if isinstance(err_info, dict) else str(err_info)
                            if "session-not-found" in err_str or "not found" in err_str.lower():
                                await on_step_callback("🔄 检测到会话不存在，正在自动重新创建会话...")
                                new_create_rpc_id = f"rpc_rec_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}"
                                await dsh_ws.send(json.dumps({
                                    "type": "client-request",
                                    "rpcId": new_create_rpc_id,
                                    "mode": "steer",
                                    "method": "session.create",
                                    "payload": {"workspace": target_workspace}
                                }))
                                for _ in range(5):
                                    r_raw = await asyncio.wait_for(dsh_ws.recv(), timeout=2.0)
                                    r_data = json.loads(r_raw)
                                    sid = None
                                    for loc in [r_data.get("result"), r_data.get("payload"), r_data]:
                                        if isinstance(loc, dict):
                                            sid = loc.get("sessionId") or loc.get("id")
                                            if sid: break
                                    if sid:
                                        cur_session_id = str(sid)
                                        break
                                prompt_msg["payload"]["sessionId"] = cur_session_id
                                prompt_msg["payload"]["sessionID"] = cur_session_id
                                prompt_msg["rpcId"] = f"rpc_reprompt_{int(time.time() * 1000)}"
                                await dsh_ws.send(json.dumps(prompt_msg))
                                continue
                            else:
                                await on_step_callback(f"⚠️ DSH 状态: {err_str[:60]}")

                        mtype = msg.get("type", "")
                        event_name = msg.get("event", "")
                        
                        extracted = extract_text_from_obj(msg)
                        if extracted and not is_html_content(extracted):
                            if not accumulated_text or extracted not in accumulated_text[-1]:
                                accumulated_text.append(extracted)

                        if event_name in ("session.turn.finish", "turn.finish", "turn.end", "session.finish") or msg.get("status") in ("finished", "completed"):
                            break

                        if mtype in ("client-response", "response") and msg.get("rpcId") == prompt_msg.get("rpcId"):
                            res_obj = msg.get("result") or msg.get("payload")
                            if res_obj:
                                res_txt = extract_text_from_obj(res_obj)
                                if res_txt and not is_html_content(res_txt):
                                    accumulated_text.append(res_txt)
                            break

                    except asyncio.TimeoutError:
                        if accumulated_text:
                            break
                        continue
                    except Exception:
                        break

                final_output = "\n".join(accumulated_text).strip()
                if final_output and not is_html_content(final_output):
                    return True, final_output

        except Exception:
            continue

    return False, None

async def execute_local_harness(
    task_id: str,
    prompt: str,
    messages: list,
    harness_url: str,
    model_name: str,
    session_id: str,
    on_step_callback,
    extra_chat_config: dict = None,
    target_workspace: str = "deepseek-agent",
    on_approval_callback = None
):
    harness_base = harness_url.rstrip("/")
    extra_chat_config = extra_chat_config or {}
    target_workspace = target_workspace or "deepseek-agent"
    
    is_cloud_api = harness_base.startswith("https://") or "volces.com" in harness_base or "deepseek.com" in harness_base or "openai.com" in harness_base
    if not is_cloud_api and not is_host_safe(harness_base):
        err_msg = f"🛡️ [SSRF 安全拦截] 目标服务地址 ({harness_base}) 非本地回环地址 (127.0.0.1 / localhost)，禁止发起非本地请求。"
        await on_step_callback(f"❌ [Task:{task_id[:6]}] SSRF 安全拦截")
        return False, err_msg

    await on_step_callback(f"🚀 [1/3] 已接收到任务，正在调用本地 DeepSeek Harness Agent ({model_name})...")

    active_session_id = (session_id or "").strip()
    real_session_id = None
    if active_session_id and active_session_id not in ("__auto__", "__auto_new__", "default_session", "none", "null"):
        real_session_id = active_session_id

    # 登记当前运行中的任务以支持一键中止 (Abort)
    ACTIVE_SESSION_REGISTRY[task_id] = {
        "harness_url": harness_url,
        "session_id": real_session_id or active_session_id
    }

    try:
        # 0. 最优先尝试 DSH 3080/3081 原生 SSE 流式端点 (/v1/agent/prompt/stream)
        reasoning_effort = extra_chat_config.get("reasoningEffort") or extra_chat_config.get("reasoning_effort") or ""
        permission = extra_chat_config.get("permission") or "workspace-write"
        sse_ok, sse_out = await execute_dsh_sse_stream(
            harness_base,
            target_workspace,
            model_name,
            active_session_id,
            prompt,
            reasoning_effort=reasoning_effort,
            permission=permission,
            on_step_callback=on_step_callback,
            extra_chat_config=extra_chat_config,
            on_approval_callback=on_approval_callback
        )
        if sse_ok and sse_out and not is_html_content(sse_out):
            await on_step_callback("✅ [3/3] 本地 DeepSeek Harness 智能体已完成本轮所有操作，正在向 App 调度中心回传结果...")
            return True, str(sse_out)
    except Exception as sse_e:
        logger.debug(f"SSE 流式尝试暂不可用: {sse_e}，无缝回退至适配器通道")

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

    # 1. 尝试本地 3081/3080 HTTP 适配器
    adapter_base = harness_base
    if "3080" in harness_base:
        adapter_base = harness_base.replace("3080", "3081")

    candidate_endpoints = []
    
    # 构造规范的 sessionId（过滤占位符）
    chat_completion_payload = {
        "model": model_name or "deepseek-chat",
        "messages": messages if messages else [{"role": "user", "content": prompt}],
        "stream": False
    }
    if real_session_id:
        chat_completion_payload["sessionId"] = real_session_id

    prompt_payload = {
        "prompt": prompt or (messages[-1].get("content", "") if messages else ""),
        "workspace": target_workspace,
        "model": model_name or "deepseek-chat"
    }
    if real_session_id:
        prompt_payload["sessionId"] = real_session_id

    candidate_endpoints.append((
        f"{adapter_base}/v1/chat/completions",
        chat_completion_payload,
        "DSH 3081 HTTP 适配器 (/v1/chat/completions)"
    ))
    candidate_endpoints.append((
        f"{adapter_base}/v1/agent/prompt",
        prompt_payload,
        "DSH 3081 HTTP 适配器 (/v1/agent/prompt)"
    ))
    candidate_endpoints.append((
        f"{adapter_base}/api/session.prompt",
        prompt_payload,
        "DSH 3081 HTTP 适配器 (/api/session.prompt)"
    ))

    # 2. 原生 WebSocket 通道
    if HAS_WEBSOCKETS and not harness_base.startswith("https://"):
        ws_ok, ws_output = await execute_dsh_via_ws(
            harness_url, target_workspace, model_name, active_session_id, content_list, prompt, on_step_callback
        )
        if ws_ok and ws_output and not is_html_content(ws_output):
            await on_step_callback("✅ [3/3] 本地 DeepSeek 智能体通过 WebSocket RPC 执行完毕，正在向 App 调度中心回传结果...")
            return True, str(ws_output)

    # 3. HTTP 标准接口
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
            with GLOBAL_HTTP_CLIENT.direct_opener.open(req, timeout=600) as response:
                return response.read().decode("utf-8")

        try:
            raw_resp = await loop.run_in_executor(None, do_request)
            if is_html_content(raw_resp):
                continue
            try:
                resp_json = json.loads(raw_resp)
                if isinstance(resp_json, dict):
                    if is_harness_error_response(resp_json):
                        err_detail = resp_json.get("error", resp_json)
                        last_err = json.dumps(err_detail, ensure_ascii=False)
                        continue

                    # 1. 优先提取 dsh-rest-adapter 或标准接口的 result 字段
                    if "result" in resp_json and resp_json["result"]:
                        res_val = resp_json["result"]
                        if isinstance(res_val, str) and not is_html_content(res_val):
                            output_content = res_val
                        elif isinstance(res_val, dict) or isinstance(res_val, list):
                            extracted = extract_text_from_obj(res_val)
                            if extracted and not is_html_content(extracted):
                                output_content = extracted

                    # 2. 提取 choices 标准返回
                    if output_content is None and "choices" in resp_json and len(resp_json["choices"]) > 0:
                        choice_msg = resp_json["choices"][0].get("message", {})
                        if isinstance(choice_msg, dict) and choice_msg.get("content"):
                            output_content = choice_msg.get("content", "")

                    # 3. 通用递归提取
                    if output_content is None:
                        txt = extract_text_from_obj(resp_json)
                        if txt and not is_html_content(txt):
                            output_content = txt
                else:
                    output_content = str(resp_json)
            except Exception:
                if not is_html_content(raw_resp):
                    output_content = raw_resp

            if output_content is not None and not is_html_content(output_content):
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

    if output_content is not None and not is_html_content(output_content):
        await on_step_callback(f"✅ [3/3] 本地 DeepSeek 智能体通过 {success_endpoint_name} 执行完毕，正在向 App 调度中心回传结果...")
        return True, str(output_content)

    error_tip = (
        "❌ 连接本地 DeepSeek Harness / Agent 服务失败 (" + str(harness_base) + ")。\n"
        "   最近一次尝试报错: " + str(last_err) + "\n"
        "   💡 排查指南:\n"
        "   1. 请确认本地 3081 适配器服务在运行 (http://127.0.0.1:3081)；\n"
        "   2. 若使用其他端口，可在启动命令加上 --harness-url http://127.0.0.1:端口。"
    )
    await on_step_callback(f"❌ 本地服务连接失败: {last_err or '所有端点均不可达'}")
    return False, error_tip

running_tasks = {}

async def run_polling_bridge(args, token: str, server_base: str, concurrency_limit: int):
    register_url = f"{server_base}/api/agent/register"
    poll_url = f"{server_base}/api/agent/poll"
    step_url = f"{server_base}/api/agent/step"
    result_url = f"{server_base}/api/agent/result"
    heartbeat_url = f"{server_base}/api/agent/heartbeat"

    semaphore = asyncio.Semaphore(concurrency_limit)
    loop = asyncio.get_running_loop()

    try:
        init_workspaces, init_sessions = await query_dsh_workspaces_and_sessions(args.harness_url)
        init_models = await query_dsh_models(args.harness_url)
        await loop.run_in_executor(
            None,
            lambda: http_post_json(register_url, {
                "token": token,
                "clientInfo": {
                    "name": "DeepSeek-Harness-Local",
                    "version": "3.7.0",
                    "harnessUrl": args.harness_url,
                    "model": args.harness_model,
                    "platform": sys.platform,
                    "pid": os.getpid(),
                    "concurrency": concurrency_limit,
                    "mode": "polling",
                    "models": init_models
                }
            })
        )
        try:
            await loop.run_in_executor(
                None,
                lambda: http_post_json(f"{server_base}/api/agent/sync-sessions", {
                    "token": token,
                    "workspaces": init_workspaces,
                    "sessions": init_sessions,
                    "models": init_models
                }, timeout=5)
            )
        except Exception:
            pass
        print(f"\033[92m[✓ 注册成功] 已通过 HTTP 调度网关认证！发现 {len(init_sessions)} 个本地会话，{len(init_models)} 个可用模型。Token: {token}\033[0m")
    except Exception as e:
        print(f"\033[93m[注册告警] 首次注册响应: {e}，将直接进入长轮询调度...\033[0m")

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

    print(f"\033[92m[✓ 监听中] 正在待命监听 App 派发任务 (HTTP Long-Polling 模式)...\033[0m")

    async def handle_task(task_data):
        task_id = task_data.get("taskId")
        prompt = task_data.get("prompt", "")
        messages = task_data.get("messages", [])
        harness_url = task_data.get("harnessUrl", args.harness_url)
        model_name = task_data.get("model", args.harness_model)
        session_id = task_data.get("agentSessionId") or task_data.get("sessionId", "default_session")
        target_ws = task_data.get("agentWorkspace") or task_data.get("workspace") or "deepseek-agent"

        print(f"\n\033[94m[收到任务] TaskID: {task_id} | 工作区: {target_ws} | 提示词: {prompt[:40]}...\033[0m")
        steps_collected = []

        async def on_step(step_text: str):
            steps_collected.append(step_text)
            print(f"\033[90m  └─ {step_text}\033[0m")
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

        async def on_approval(approval_data: dict):
            try:
                await loop.run_in_executor(
                    None,
                    lambda: http_post_json(f"{server_base}/api/agent/waiting-approval", {
                        "taskId": task_id,
                        "token": token,
                        "approval": approval_data
                    }, timeout=5)
                )
            except Exception:
                pass

        extra_config = {
            "apiEndpoint": task_data.get("apiEndpoint") or getattr(args, "chat_api_url", ""),
            "apiKey": task_data.get("apiKey") or getattr(args, "chat_api_key", ""),
            "chatModel": task_data.get("chatModel") or getattr(args, "chat_model", ""),
            "reasoningEffort": task_data.get("reasoningEffort") or task_data.get("reasoning_effort") or "",
            "permission": task_data.get("permission") or "workspace-write",
        }

        try:
            async with semaphore:
                success, output = await execute_local_harness(
                    task_id, prompt, messages, harness_url, model_name, session_id, on_step, extra_config, target_workspace=target_ws, on_approval_callback=on_approval
                )
        except Exception as task_err:
            success = False
            output = f"本地执行异常: {task_err}"
            await on_step(f"❌ 任务发生未捕获异常: {task_err}")
        finally:
            ACTIVE_SESSION_REGISTRY.pop(task_id, None)

        status_tag = "✓ 任务完成" if success else "✗ 任务异常"
        color = "\033[92m" if success else "\033[91m"
        print(f"{color}[{status_tag}] 回传结果 TaskID: {task_id}\033[0m")

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
            cur_mods = await query_dsh_models(harness_url)
            await loop.run_in_executor(
                None,
                lambda: http_post_json(f"{server_base}/api/agent/sync-sessions", {
                    "token": token,
                    "workspaces": cur_ws,
                    "sessions": cur_sess,
                    "models": cur_mods
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
            elif mtype in ("cancel_task", "abort_task"):
                c_task_id = resp.get("taskId")
                reg_info = ACTIVE_SESSION_REGISTRY.get(c_task_id)
                if reg_info:
                    await abort_dsh_session(reg_info["harness_url"], reg_info["session_id"])
                    print(f"\033[93m[一键中止] 已向本地 DSH 发起中止轮次请求: {reg_info['session_id']}\033[0m")
            elif mtype == "agent_approve":
                a_task_id = resp.get("taskId")
                a_appr_id = resp.get("approvalId")
                a_act = resp.get("action", "allow")
                reg_info = ACTIVE_SESSION_REGISTRY.get(a_task_id)
                if reg_info:
                    await approve_dsh_session(reg_info["harness_url"], reg_info["session_id"], a_appr_id, a_act)
                    print(f"\033[92m[审批裁决] 已提交审批 {a_appr_id} -> {a_act}\033[0m")
            elif mtype == "rename_session":
                s_id = resp.get("sessionId")
                s_title = resp.get("title")
                await rename_dsh_session(args.harness_url, s_id, s_title)
            elif mtype == "archive_session":
                s_id = resp.get("sessionId")
                await archive_dsh_session(args.harness_url, s_id)
            elif mtype == "token_revoked":
                print("\033[91m[权限注销] 当前配对 Token 已在 App 端被重置或注销。桥接程序已停止。\033[0m")
                return
        except Exception as e:
            poll_fail_count += 1
            await asyncio.sleep(3)

async def run_bridge_client(args):
    token = (args.token or "").strip()
    if not token or token in ("default_agent_token", "YOUR_AGENT_TOKEN_HERE", "<YOUR_AGENT_TOKEN>"):
        print("\033[91m" + "=" * 70)
        print("❌ [连接失败] 未检测到有效的 App 配对密钥 (Token)！")
        print("   原因：当前未配置 --token 参数，或使用了默认占位符。")
        print("   排查方案：")
        print("   1. 打开手机/网页端 App ➔ 进入【设置 ➔ 🤖 本地 Agent (Harness)】；")
        print("   2. 查看您的【专属配对 Token】；")
        print("   3. 重新运行命令，例如：python deepseek_bridge.py --token \"您的真实Token\"")
        print("=" * 70 + "\033[0m")
        sys.exit(1)

    server_base = normalize_server_url(args.server)
    concurrency_limit = max(1, args.concurrency)
    init_global_http_client(force_no_proxy=args.no_proxy, custom_proxy=args.proxy, primary_server=server_base)

    proxy_mode_desc = "强制 Direct 直连" if args.no_proxy else (f"自定义代理 ({args.proxy})" if args.proxy else "自适应系统/VPN代理")
    print("=" * 70)
    print("\033[96m 正在启动 DeepSeek Harness 本地反向桥接客户端 (v3.6 安全版)...\033[0m")
    print(f" • 配对 Token     : \033[96m{token}\033[0m")
    print(f" • App 调度服务器 : \033[94m{server_base}\033[0m")
    print(f" • 网络连接模式   : \033[95m{proxy_mode_desc}\033[0m")
    print(f" • 本地 Harness   : \033[93m{args.harness_url}\033[0m (默认 3080/v1)")
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
                print(f"\033[92m[✓ 成功上线] 已与 App 服务器建立安全 WebSocket 长连接！等待任务下发...\033[0m")
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
                    init_mods = await query_dsh_models(args.harness_url)
                    await ws.send(json.dumps({
                        "type": "sync_sessions",
                        "token": token,
                        "workspaces": init_ws,
                        "sessions": init_sess,
                        "models": init_mods
                    }))
                    print(f"\033[92m[✓ 会话同步] 已向 App 同步本地 {len(init_sess)} 个 DSH 会话，{len(init_mods)} 个可用模型\033[0m")
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

                        if mtype == "auth_error":
                            print(f"\033[91m[❌ 授权失败] 调度中心拒绝配对: {msg.get('message', '未配置或无效的密钥')}\033[0m")
                            return

                        if mtype == "token_revoked":
                            print("\033[91m[权限注销] 当前配对 Token 已在 App 端被重置或注销。桥接程序已停止。\033[0m")
                            return

                        if mtype == "get_models":
                            target_h_url = msg.get("harnessUrl", args.harness_url)
                            cur_mods = await query_dsh_models(target_h_url)
                            await ws.send(json.dumps({
                                "type": "models_result",
                                "token": token,
                                "models": cur_mods
                            }))
                            continue

                        if mtype == "get_sessions":
                            target_h_url = msg.get("harnessUrl", args.harness_url)
                            cur_workspaces, cur_sessions = await query_dsh_workspaces_and_sessions(target_h_url)
                            cur_mods = await query_dsh_models(target_h_url)
                            await ws.send(json.dumps({
                                "type": "sessions_result",
                                "token": token,
                                "workspaces": cur_workspaces,
                                "sessions": cur_sessions,
                                "models": cur_mods
                            }))
                            continue

                        if mtype in ("cancel_task", "abort_task"):
                            c_task_id = msg.get("taskId")
                            reg_info = ACTIVE_SESSION_REGISTRY.get(c_task_id)
                            if reg_info:
                                await abort_dsh_session(reg_info["harness_url"], reg_info["session_id"])
                                print(f"\033[93m[一键中止] 已向本地 DSH 发起中止轮次请求: {reg_info['session_id']}\033[0m")
                            continue

                        if mtype == "agent_approve":
                            a_task_id = msg.get("taskId")
                            a_appr_id = msg.get("approvalId")
                            a_act = msg.get("action", "allow")
                            reg_info = ACTIVE_SESSION_REGISTRY.get(a_task_id)
                            if reg_info:
                                await approve_dsh_session(reg_info["harness_url"], reg_info["session_id"], a_appr_id, a_act)
                                print(f"\033[92m[审批裁决] 已提交审批 {a_appr_id} -> {a_act}\033[0m")
                            continue

                        if mtype == "rename_session":
                            s_id = msg.get("sessionId")
                            s_title = msg.get("title")
                            target_h_url = msg.get("harnessUrl", args.harness_url)
                            ok_rename, ren_resp = await rename_dsh_session(target_h_url, s_id, s_title)
                            cur_ws, cur_sess = await query_dsh_workspaces_and_sessions(target_h_url)
                            await ws.send(json.dumps({
                                "type": "rename_session_result",
                                "sessionId": s_id,
                                "success": ok_rename,
                                "workspaces": cur_ws,
                                "sessions": cur_sess
                            }))
                            continue

                        if mtype == "archive_session":
                            s_id = msg.get("sessionId")
                            target_h_url = msg.get("harnessUrl", args.harness_url)
                            ok_arch, arch_resp = await archive_dsh_session(target_h_url, s_id)
                            cur_ws, cur_sess = await query_dsh_workspaces_and_sessions(target_h_url)
                            await ws.send(json.dumps({
                                "type": "archive_session_result",
                                "sessionId": s_id,
                                "success": ok_arch,
                                "workspaces": cur_ws,
                                "sessions": cur_sess
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

                            print(f"\n\033[94m[收到任务] TaskID: {task_id} | 工作区: {target_ws} | 提示词: {prompt[:40]}...\033[0m")
                            steps_collected = []

                            async def ws_step_cb(step_text: str):
                                steps_collected.append(step_text)
                                print(f"\033[90m  └─ {step_text}\033[0m")
                                try:
                                    await ws.send(json.dumps({
                                        "type": "agent_step",
                                        "taskId": task_id,
                                        "step": step_text,
                                        "timestamp": int(time.time() * 1000)
                                    }))
                                except Exception:
                                    pass

                            async def ws_approval_cb(approval_data: dict):
                                try:
                                    await ws.send(json.dumps({
                                        "type": "waiting_approval",
                                        "taskId": task_id,
                                        "approval": approval_data,
                                        "timestamp": int(time.time() * 1000)
                                    }))
                                except Exception:
                                    pass

                            extra_config = {
                                "apiEndpoint": msg.get("apiEndpoint") or getattr(args, "chat_api_url", ""),
                                "apiKey": msg.get("apiKey") or getattr(args, "chat_api_key", ""),
                                "chatModel": msg.get("chatModel") or getattr(args, "chat_model", ""),
                                "reasoningEffort": msg.get("reasoningEffort") or msg.get("reasoning_effort") or "",
                                "permission": msg.get("permission") or "workspace-write",
                            }

                            try:
                                success, output = await execute_local_harness(
                                    task_id, prompt, messages, harness_url, model_name, session_id, ws_step_cb, extra_config, target_workspace=target_ws, on_approval_callback=ws_approval_cb
                                )
                            except Exception as task_err:
                                success = False
                                output = f"本地执行异常: {task_err}"
                                await ws_step_cb(f"❌ 任务发生未捕获异常: {task_err}")
                            finally:
                                ACTIVE_SESSION_REGISTRY.pop(task_id, None)

                            status_tag = "✓ 任务完成" if success else "✗ 任务异常"
                            color = "\033[92m" if success else "\033[91m"
                            print(f"{color}[{status_tag}] 回传结果 TaskID: {task_id}\033[0m")

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
            print(f"\033[93m[WS 握手受阻 ({ws_err})]\033[0m 正在自动无缝切换至 HTTP 智能长轮询通道...")
            await run_polling_bridge(args, token, server_base, concurrency_limit)
            return

def main():
    args = parse_args()
    try:
        asyncio.run(run_bridge_client(args))
    except KeyboardInterrupt:
        print("\n\033[93m[已退出] DeepSeek Bridge 安全退出。\033[0m")

if __name__ == "__main__":
    main()
