# -*- coding: utf-8 -*-
"""单点互斥 / 顶号语义的对抗性验证（13 项断言）。

为什么要有这个脚本：单点互斥按 clientSessionId **严格相等**判定，而本机 id 会因
"离线登录兜底"等路径与服务端记录分叉，表现为"每次重启 App 都弹账号已下线"的假顶号。
修完之后必须能证明三件事：

  1. 活跃槽位不可被陌生 id 抢走（canTakeover=false）；
  2. 真顶号（另一台同类型设备登录）时，被顶的那台拿到的**也是** canTakeover=false
     —— 否则两台机器会互相静默重登、来回顶号；
  3. 只有"槽位 3 分钟无活跃"才放开接管（canTakeover=true）。

另外验证顶号通知的设备隔离：被顶的设备类型收到 force_logout（带 kickedSessionId），
另一端（如手机）一条都不该收到。

跑法（务必用隔离实例，别拿生产中继做实验）：
    # 1) 起隔离实例：软链 dist/node_modules，独立 messages_data
    set NODE_ENV=production & set PORT=3100 & node dist/server.cjs
    # 2) 跑测试（默认 127.0.0.1:3100，可用 LXAI_TEST_API 覆盖）
    python docs/tests/session-kick-test.py

依赖：标准库 + websockets（`pip install websockets`）；第 7 段缺 websockets 时跳过。
"""
import json, os, time, uuid, urllib.request, urllib.error, threading

BASE = os.environ.get("LXAI_TEST_API", "http://127.0.0.1:3100")
WS = BASE.replace("http://", "ws://").replace("https://", "wss://") + "/ws/app"
# 第 5 步要把"对方的槽位"改成 4 分钟无活跃，需要直接改隔离实例的数据文件
DATA_DIR = os.environ.get("LXAI_TEST_DATA_DIR", r"F:\ai\flutter-app-prodtest\messages_data")
USER = "zz-kick-test"
PASS = "test-pass-1234"
ok_all = True

def post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8", "replace") or "{}")

def check(uid, dev, sid):
    url = "%s/api/check-session?userId=%s&deviceType=%s&clientSessionId=%s" % (BASE, uid, dev, sid)
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")

def expect(label, cond, extra=""):
    global ok_all
    mark = "PASS" if cond else "FAIL"
    if not cond: ok_all = False
    print("  [%s] %s %s" % (mark, label, extra))

# 注册测试账号（隔离实例自带空 users.json）
st, body = post("/api/register", {"username": USER, "password": PASS})
print("注册 %s -> HTTP %s %s" % (USER, st, str(body)[:80]))
st, _ = post("/api/login", {"username": USER, "password": PASS, "deviceType": "desktop", "clientSessionId": "warmup"})
print("预热登录 -> HTTP %s" % st)

idA = str(uuid.uuid4()); idB = str(uuid.uuid4())

print("\n[1] 登录 A（电脑端）")
st, b = post("/api/login", {"username": USER, "password": PASS, "deviceType": "desktop", "clientSessionId": idA})
expect("登录 A 成功", st == 200, "HTTP %s" % st)

print("\n[2] A 自己校验 → 应有效")
st, b = check(USER, "desktop", idA)
expect("A 校验 valid=true", st == 200 and b.get("valid") is True, str(b)[:70])

print("\n[3] 陌生 id 校验（A 的槽位新鲜）→ 应 401 且 canTakeover=false（不许抢号）")
st, b = check(USER, "desktop", str(uuid.uuid4()))
expect("陌生 id 被拒", st == 401 and b.get("valid") is False, "HTTP %s" % st)
expect("canTakeover=false（活跃槽位不可接管）", b.get("canTakeover") is False, "canTakeover=%s" % b.get("canTakeover"))

print("\n[4] 另一台电脑 B 登录（真顶号）")
st, b = post("/api/login", {"username": USER, "password": PASS, "deviceType": "desktop", "clientSessionId": idB})
expect("登录 B 成功", st == 200, "HTTP %s" % st)
st, b = check(USER, "desktop", idA)
expect("A 现在被拒（真顶号）", st == 401, "HTTP %s" % st)
expect("真顶号 canTakeover=false（B 槽位新鲜，A 不该反抢）", b.get("canTakeover") is False, "canTakeover=%s" % b.get("canTakeover"))

print("\n[5] 让 B 的槽位过期（模拟对方早就不用了 / 本地与服务端分叉）")
p = os.path.join(DATA_DIR, "active_sessions.json")
sess = json.load(open(p, encoding="utf-8"))
sess[USER]["desktop"]["lastActive"] = int(time.time() * 1000) - 4 * 60 * 1000
json.dump(sess, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
st, b = check(USER, "desktop", idA)
expect("过期槽位放行接管", b.get("canTakeover") is True, "canTakeover=%s" % b.get("canTakeover"))

print("\n[6] 接管：A 用账号密码重新登录")
st, b = post("/api/login", {"username": USER, "password": PASS, "deviceType": "desktop", "clientSessionId": idA})
expect("A 重新登录成功", st == 200, "HTTP %s" % st)
st, b = check(USER, "desktop", idA)
expect("A 恢复有效", st == 200 and b.get("valid") is True, str(b)[:60])

print("\n[7] 推送通道 /ws/app 握手 + 顶号通知的设备隔离")
try:
    from websockets.sync.client import connect as ws_connect
except Exception as e:
    print("  跳过（websockets 不可用: %s）" % e); raise SystemExit(0 if ok_all else 1)

recv = {"desktop": [], "mobile": []}
ready = threading.Event()

def listen(name, sid, dev, hold):
    try:
        with ws_connect("%s?userId=%s&clientSessionId=%s&deviceType=%s" % (WS, USER, sid, dev), open_timeout=8) as ws:
            while True:
                msg = ws.recv(timeout=hold)
                ev = json.loads(msg)
                recv[name].append(ev)
                if ev.get("event") == "ready": ready.set()
    except Exception:
        pass

idD = str(uuid.uuid4()); idM = str(uuid.uuid4())
st, _ = post("/api/login", {"username": USER, "password": PASS, "deviceType": "desktop", "clientSessionId": idD})
st, _ = post("/api/login", {"username": USER, "password": PASS, "deviceType": "mobile", "clientSessionId": idM})

td = threading.Thread(target=listen, args=("desktop", idD, "desktop", 12), daemon=True)
tm = threading.Thread(target=listen, args=("mobile", idM, "mobile", 12), daemon=True)
td.start(); tm.start()
time.sleep(2.5)
expect("桌面端推送通道收到 ready", any(e.get("event") == "ready" for e in recv["desktop"]), str(recv["desktop"])[:80])
expect("手机端推送通道收到 ready", any(e.get("event") == "ready" for e in recv["mobile"]), str(recv["mobile"])[:80])

# 触发桌面端顶号：再登录一台电脑
idD2 = str(uuid.uuid4())
post("/api/login", {"username": USER, "password": PASS, "deviceType": "desktop", "clientSessionId": idD2})
time.sleep(3)
d_ev = [e for e in recv["desktop"] if e.get("event") == "force_logout"]
m_ev = [e for e in recv["mobile"] if e.get("event") == "force_logout"]
expect("被顶的桌面端收到 force_logout", len(d_ev) > 0, str(d_ev)[:110])
expect("force_logout 带 kickedSessionId", bool(d_ev) and bool((d_ev[0].get("data") or {}).get("kickedSessionId")), str((d_ev[0].get("data") if d_ev else {}))[:110])
expect("手机端未被误通知", len(m_ev) == 0, "手机收到 %d 条" % len(m_ev))

print("\n=== 结果: %s ===" % ("全部通过" if ok_all else "存在失败项"))
raise SystemExit(0 if ok_all else 1)