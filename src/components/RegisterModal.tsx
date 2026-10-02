import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { getApiBaseUrl } from '../config';

/**
 * 官网注册弹窗（**只做注册，不做登录**）。
 *
 * 为什么不做登录：服务端按「1 台手机 + 1 台电脑」分槽做单点互斥，网页端一旦登录就得决定
 * 它占哪个槽 —— 复用"电脑"槽会把桌面 App 顶下线，新开槽又要动那套很微妙的互斥逻辑。
 * 官网只负责把账号建出来，登录仍在 App 里。
 *
 * Turnstile 的 site key 走构建期环境变量 `VITE_TURNSTILE_SITE_KEY`：
 * 没配时（本地开发）不渲染组件，服务端在非 production 下也会跳过校验。
 */
const TURNSTILE_SITE_KEY = String(
  (import.meta as any)?.env?.VITE_TURNSTILE_SITE_KEY || '',
).trim();

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

type Props = {
  open: boolean;
  onClose: () => void;
};

type Hint = { type: 'ok' | 'err'; text: string } | null;

export function RegisterModal({ open, onClose }: Props) {
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPwd, setShowPwd] = useState(false);

  const [cooldown, setCooldown] = useState(0);
  const [sending, setSending] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [hint, setHint] = useState<Hint>(null);
  const [done, setDone] = useState(false);

  const [turnstileToken, setTurnstileToken] = useState('');
  const turnstileBox = useRef<HTMLDivElement | null>(null);
  const widgetId = useRef<string | null>(null);

  // ── 发送冷却倒计时 ────────────────────────────────────────
  useEffect(() => {
    if (cooldown <= 0) return;
    const t = window.setInterval(() => {
      setCooldown((c) => (c <= 1 ? 0 : c - 1));
    }, 1000);
    return () => window.clearInterval(t);
  }, [cooldown]);

  // ── Turnstile 显式渲染（script 在 index.html 里异步加载，所以要轮询等它就绪）──
  useEffect(() => {
    if (!open || !TURNSTILE_SITE_KEY) return;
    let cancelled = false;
    const tryRender = (): boolean => {
      const ts = (window as any).turnstile;
      if (!ts || !turnstileBox.current) return false;
      if (widgetId.current) return true;
      widgetId.current = ts.render(turnstileBox.current, {
        sitekey: TURNSTILE_SITE_KEY,
        theme: 'auto',
        callback: (token: string) => setTurnstileToken(token),
        'expired-callback': () => setTurnstileToken(''),
        'error-callback': () => setTurnstileToken(''),
      });
      return true;
    };
    if (tryRender()) return;
    const timer = window.setInterval(() => {
      if (cancelled || tryRender()) window.clearInterval(timer);
    }, 300);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [open]);

  /** Turnstile 的 token 是**一次性**的：用过就得重置，否则第二次发送必然失败 */
  const resetTurnstile = useCallback(() => {
    const ts = (window as any).turnstile;
    if (ts && widgetId.current) {
      try {
        ts.reset(widgetId.current);
      } catch {
        /* 忽略：组件未就绪时无需重置 */
      }
    }
    setTurnstileToken('');
  }, []);

  // 关闭时清理，避免下次打开残留上一次的状态
  useEffect(() => {
    if (open) return;
    setHint(null);
    setDone(false);
    setCode('');
    resetTurnstile();
  }, [open, resetTurnstile]);

  const emailOk = useMemo(() => EMAIL_RE.test(email.trim()), [email]);

  const apiBase = useMemo(() => getApiBaseUrl().replace(/\/+$/, ''), []);

  const handleSendCode = async () => {
    setHint(null);
    if (!emailOk) {
      setHint({ type: 'err', text: '请先填写正确的邮箱地址' });
      return;
    }
    if (TURNSTILE_SITE_KEY && !turnstileToken) {
      setHint({ type: 'err', text: '请先完成人机验证（上方复选框）' });
      return;
    }
    setSending(true);
    try {
      const r = await fetch(`${apiBase}/api/register/send-code`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: email.trim(), turnstileToken }),
      });
      const d: any = await r.json().catch(() => ({}));
      if (!r.ok) {
        setHint({ type: 'err', text: d?.error || `发送失败（HTTP ${r.status}）` });
        resetTurnstile();
        return;
      }
      setCooldown(Number(d?.cooldownSec) || 60);
      setHint({
        type: 'ok',
        text: `验证码已发送至 ${email.trim()}，${Math.round((Number(d?.expiresInSec) || 600) / 60)} 分钟内有效`,
      });
      resetTurnstile();
    } catch (e: any) {
      setHint({ type: 'err', text: '网络错误：' + (e?.message || e) });
    } finally {
      setSending(false);
    }
  };

  const handleSubmit = async (ev: React.FormEvent) => {
    ev.preventDefault();
    setHint(null);
    if (!emailOk) return setHint({ type: 'err', text: '邮箱格式不正确' });
    if (!/^\d{6}$/.test(code.trim())) return setHint({ type: 'err', text: '验证码是 6 位数字' });
    if (username.trim().length < 3) return setHint({ type: 'err', text: '账号名至少 3 个字符' });
    if (password.length < 8) return setHint({ type: 'err', text: '密码至少 8 位' });

    setSubmitting(true);
    try {
      const r = await fetch(`${apiBase}/api/register`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: username.trim(),
          password,
          email: email.trim(),
          code: code.trim(),
        }),
      });
      const d: any = await r.json().catch(() => ({}));
      if (!r.ok) {
        setHint({ type: 'err', text: d?.error || `注册失败（HTTP ${r.status}）` });
        return;
      }
      setDone(true);
    } catch (e: any) {
      setHint({ type: 'err', text: '网络错误：' + (e?.message || e) });
    } finally {
      setSubmitting(false);
    }
  };

  if (!open) return null;

  const inputCls =
    'w-full rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 ' +
    'px-3 py-2 text-sm outline-none transition focus:border-indigo-500 dark:focus:border-indigo-400 ' +
    'placeholder:text-slate-400';

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/60 p-4 backdrop-blur-sm"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="w-full max-w-md overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-2xl dark:border-slate-800 dark:bg-slate-950">
        <div className="flex items-center justify-between border-b border-slate-200 px-5 py-3.5 dark:border-slate-800">
          <h3 className="text-base font-semibold">注册 LxAI 账号</h3>
          <button
            onClick={onClose}
            aria-label="关闭"
            className="rounded-md px-2 py-1 text-slate-400 transition hover:bg-slate-100 hover:text-slate-700 dark:hover:bg-slate-800 dark:hover:text-slate-200"
          >
            ✕
          </button>
        </div>

        {done ? (
          <div className="space-y-4 px-5 py-8 text-center">
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-emerald-500 text-2xl text-white">
              ✓
            </div>
            <p className="text-lg font-semibold">注册成功</p>
            <p className="text-sm text-slate-500 dark:text-slate-400">
              请打开 LxAI 客户端，用刚注册的账号名
              <span className="mx-1 rounded bg-slate-100 px-1.5 py-0.5 font-mono text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                {username.trim()}
              </span>
              登录。
            </p>
            <button
              onClick={onClose}
              className="w-full rounded-lg bg-indigo-600 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-indigo-700"
            >
              好的
            </button>
          </div>
        ) : (
          <form onSubmit={handleSubmit} className="space-y-3.5 px-5 py-4">
            <div>
              <label className="mb-1 block text-xs font-medium text-slate-600 dark:text-slate-400">
                邮箱（一个邮箱只能注册一个账号）
              </label>
              <div className="flex gap-2">
                <input
                  className={inputCls}
                  type="email"
                  autoComplete="email"
                  placeholder="you@example.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  disabled={cooldown > 0 || sending}
                />
                <button
                  type="button"
                  onClick={handleSendCode}
                  disabled={sending || cooldown > 0 || !emailOk}
                  className="shrink-0 whitespace-nowrap rounded-lg bg-indigo-600 px-3 py-2 text-xs font-medium text-white transition hover:bg-indigo-700 disabled:cursor-not-allowed disabled:bg-slate-300 dark:disabled:bg-slate-700"
                >
                  {sending ? '发送中…' : cooldown > 0 ? `${cooldown} 秒后重发` : '发送验证码'}
                </button>
              </div>
            </div>

            <div>
              <label className="mb-1 block text-xs font-medium text-slate-600 dark:text-slate-400">
                邮箱验证码
              </label>
              <input
                className={inputCls + ' tracking-[0.4em] font-mono'}
                inputMode="numeric"
                maxLength={6}
                placeholder="000000"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))}
              />
            </div>

            <div>
              <label className="mb-1 block text-xs font-medium text-slate-600 dark:text-slate-400">
                账号名（登录用，注册后不可更改）
              </label>
              <input
                className={inputCls}
                placeholder="3~32 个字符"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
              />
            </div>

            <div>
              <label className="mb-1 block text-xs font-medium text-slate-600 dark:text-slate-400">
                密码（至少 8 位）
              </label>
              <div className="relative">
                <input
                  className={inputCls + ' pr-14'}
                  type={showPwd ? 'text' : 'password'}
                  autoComplete="new-password"
                  placeholder="请设置密码"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
                <button
                  type="button"
                  onClick={() => setShowPwd((v) => !v)}
                  className="absolute right-2 top-1/2 -translate-y-1/2 rounded px-2 py-1 text-xs text-slate-500 hover:text-slate-800 dark:hover:text-slate-200"
                >
                  {showPwd ? '隐藏' : '显示'}
                </button>
              </div>
            </div>

            {TURNSTILE_SITE_KEY ? (
              <div ref={turnstileBox} className="flex justify-center pt-1" />
            ) : (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-700 dark:bg-amber-950/40 dark:text-amber-300">
                未配置人机验证（VITE_TURNSTILE_SITE_KEY）—— 本地开发可用，正式环境请在构建时注入。
              </p>
            )}

            {hint && (
              <p
                className={
                  'rounded-lg px-3 py-2 text-xs ' +
                  (hint.type === 'ok'
                    ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300'
                    : 'bg-rose-50 text-rose-700 dark:bg-rose-950/40 dark:text-rose-300')
                }
              >
                {hint.text}
              </p>
            )}

            <button
              type="submit"
              disabled={submitting}
              className="w-full rounded-lg bg-indigo-600 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-indigo-700 disabled:cursor-not-allowed disabled:bg-slate-300 dark:disabled:bg-slate-700"
            >
              {submitting ? '注册中…' : '注册'}
            </button>

            <p className="text-center text-[11px] leading-relaxed text-slate-400">
              注册即表示同意用户协议与隐私政策。官网只负责注册，登录请在客户端进行。
            </p>
          </form>
        )}
      </div>
    </div>
  );
}
