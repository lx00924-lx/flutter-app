import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { getApiBaseUrl } from '../config';

/**
 * 官网「注销账号」弹窗（**自助注销，靠邮箱验证码证明身份**）。
 *
 * 为什么放在官网：官网**刻意没有登录态**（见 RegisterModal 顶部注释 —— 网页端一旦登录就得占
 * 「1 手机 + 1 电脑」的某个槽位）。没有登录态，唯一能证明"你就是账号主人"的东西就是
 * **账号绑定的邮箱**，而这恰好也是需求本身（"注销需要验证邮箱"），所以放在官网最自然。
 *
 * ⚠️ 安全要点：验证码只发给**服务端从 users.json 里查出来的邮箱**。
 *    前端这一侧**不提供"接收验证码的邮箱"输入框** —— 否则任何人填别人的账号名 +
 *    自己的邮箱，就能把别人的账号注销掉。界面上只回显脱敏地址（`l******@gmail.com`）。
 */

// 与 RegisterModal 同理：必须写成 `import.meta.env.VITE_TURNSTILE_SITE_KEY` 字面量形式，
// 否则 Vite 的构建期静态替换不生效，运行时读到 undefined。
const TURNSTILE_SITE_KEY = String(import.meta.env.VITE_TURNSTILE_SITE_KEY || '').trim();

type Props = {
  open: boolean;
  onClose: () => void;
};

type Hint = { type: 'ok' | 'err'; text: string } | null;

type Step = 'verify' | 'confirm' | 'done';

/** 注销会一并删除的数据（与 server.ts `/api/account/delete` 的删除范围严格对应） */
const DELETE_SCOPE = [
  '账号本身（账号名、登录密码）',
  '全部聊天记录与会话列表',
  '云端同步的设置（API 端点、模型、外观等）',
  '登录设备槽位记录（手机 / 电脑）',
];

export function DeleteAccountModal({ open, onClose }: Props) {
  const [step, setStep] = useState<Step>('verify');
  const [username, setUsername] = useState('');
  const [code, setCode] = useState('');
  const [maskedEmail, setMaskedEmail] = useState('');
  const [ack, setAck] = useState(false);

  const [cooldown, setCooldown] = useState(0);
  const [sending, setSending] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [hint, setHint] = useState<Hint>(null);
  const [removed, setRemoved] = useState<Record<string, number> | null>(null);

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

  // ── Turnstile 显式渲染（script 在 index.html 里异步加载，轮询等它就绪）──
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

  /** Turnstile token 一次性：用过就要重置，否则第二次发送必然失败 */
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

  // 每次打开都从干净状态开始；关闭时清掉敏感输入
  useEffect(() => {
    if (open) {
      setStep('verify');
      setHint(null);
      setRemoved(null);
      setAck(false);
      return;
    }
    setCode('');
    setMaskedEmail('');
    setHint(null);
    setRemoved(null);
    setAck(false);
    setStep('verify');
    resetTurnstile();
  }, [open, resetTurnstile]);

  const apiBase = useMemo(() => getApiBaseUrl().replace(/\/+$/, ''), []);

  const usernameTrimmed = username.trim();

  /** 第一步：请求把验证码发到该账号**绑定的**邮箱 */
  const handleSendCode = async () => {
    setHint(null);
    if (usernameTrimmed.length < 3) {
      setHint({ type: 'err', text: '请先填写要注销的账号名（至少 3 个字符）' });
      return;
    }
    if (TURNSTILE_SITE_KEY && !turnstileToken) {
      setHint({ type: 'err', text: '请先完成人机验证（上方复选框）' });
      return;
    }
    setSending(true);
    try {
      const r = await fetch(`${apiBase}/api/account/delete-code`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: usernameTrimmed, turnstileToken }),
      });
      const d: any = await r.json().catch(() => ({}));
      resetTurnstile();
      if (!r.ok) {
        setHint({ type: 'err', text: d?.error || `发送失败（HTTP ${r.status}）` });
        return;
      }
      setMaskedEmail(String(d?.maskedEmail || ''));
      setCooldown(Number(d?.cooldownSec) || 60);
      setStep('confirm');
      setHint({
        type: 'ok',
        text: `验证码已发送至该账号绑定的邮箱 ${d?.maskedEmail || ''}，${
          Math.round((Number(d?.expiresInSec) || 600) / 60)
        } 分钟内有效`,
      });
    } catch (e: any) {
      setHint({ type: 'err', text: '网络错误：' + (e?.message || e) });
    } finally {
      setSending(false);
    }
  };

  /** 第二步：验证码 + 明确勾选确认后，真正执行注销 */
  const handleDelete = async (ev: React.FormEvent) => {
    ev.preventDefault();
    setHint(null);
    if (!/^\d{6}$/.test(code.trim())) {
      setHint({ type: 'err', text: '验证码是 6 位数字' });
      return;
    }
    if (!ack) {
      setHint({ type: 'err', text: '请先勾选确认，你已了解数据将被永久删除' });
      return;
    }
    setSubmitting(true);
    try {
      const r = await fetch(`${apiBase}/api/account/delete`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: usernameTrimmed, code: code.trim() }),
      });
      const d: any = await r.json().catch(() => ({}));
      if (!r.ok) {
        setHint({ type: 'err', text: d?.error || `注销失败（HTTP ${r.status}）` });
        return;
      }
      setRemoved((d?.removed as Record<string, number>) || {});
      setStep('done');
      setCode('');
    } catch (e: any) {
      setHint({ type: 'err', text: '网络错误：' + (e?.message || e) });
    } finally {
      setSubmitting(false);
    }
  };

  /** 回到上一步重新填账号名（比如账号名打错了） */
  const backToVerify = () => {
    setStep('verify');
    setCode('');
    setMaskedEmail('');
    setAck(false);
    setHint(null);
    setCooldown(0);
    resetTurnstile();
  };

  if (!open) return null;

  const inputCls =
    'w-full rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 ' +
    'px-3 py-2 text-sm outline-none transition focus:border-rose-500 dark:focus:border-rose-400 ' +
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
          <h3 className="text-base font-semibold text-rose-600 dark:text-rose-400">注销 LxAI 账号</h3>
          <button
            onClick={onClose}
            aria-label="关闭"
            className="rounded-md px-2 py-1 text-slate-400 transition hover:bg-slate-100 hover:text-slate-700 dark:hover:bg-slate-800 dark:hover:text-slate-200"
          >
            ✕
          </button>
        </div>

        {step === 'done' ? (
          <div className="space-y-4 px-5 py-8 text-center">
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-slate-700 text-2xl text-white">
              ✓
            </div>
            <p className="text-lg font-semibold">账号已注销</p>
            <p className="text-sm text-slate-500 dark:text-slate-400">
              账号
              <span className="mx-1 rounded bg-slate-100 px-1.5 py-0.5 font-mono text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                {usernameTrimmed}
              </span>
              及其云端数据已删除，无法恢复。我们已向绑定邮箱发送一封注销确认邮件。
            </p>

            {removed && Object.keys(removed).length > 0 && (
              <div className="rounded-lg bg-slate-50 px-3 py-2 text-left text-[11px] leading-relaxed text-slate-500 dark:bg-slate-900 dark:text-slate-400">
                <p className="mb-1 font-medium text-slate-600 dark:text-slate-300">实际删除项</p>
                <ul className="space-y-0.5">
                  {Object.entries(removed).map(([k, v]) => (
                    <li key={k}>
                      · {k}
                      {v ? '' : '（原本就没有）'}
                    </li>
                  ))}
                </ul>
                <p className="mt-1.5">
                  注：聊天中上传的图片 / 语音等媒体文件未删除 —— 服务端保存时用的是随机文件名，
                  无法判定归属，为避免误删他人文件而保留。
                </p>
              </div>
            )}

            <button
              onClick={onClose}
              className="w-full rounded-lg bg-slate-700 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-slate-800"
            >
              关闭
            </button>
          </div>
        ) : step === 'verify' ? (
          <div className="space-y-3.5 px-5 py-4">
            <p className="rounded-lg bg-rose-50 px-3 py-2 text-xs leading-relaxed text-rose-700 dark:bg-rose-950/40 dark:text-rose-300">
              注销会<b>永久删除</b>该账号及其全部云端数据，且<b>无法恢复</b>。
              为确认你是账号主人，验证码会发送到该账号<b>注册时绑定的邮箱</b>。
            </p>

            <div>
              <label className="mb-1 block text-xs font-medium text-slate-600 dark:text-slate-400">
                要注销的账号名
              </label>
              <div className="flex gap-2">
                <input
                  className={inputCls}
                  placeholder="你在 LxAI 客户端登录用的账号名"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  disabled={sending}
                />
                <button
                  type="button"
                  onClick={handleSendCode}
                  disabled={sending || usernameTrimmed.length < 3}
                  className="shrink-0 whitespace-nowrap rounded-lg bg-rose-600 px-3 py-2 text-xs font-medium text-white transition hover:bg-rose-700 disabled:cursor-not-allowed disabled:bg-slate-300 dark:disabled:bg-slate-700"
                >
                  {sending ? '发送中…' : '发送验证码'}
                </button>
              </div>
              <p className="mt-1 text-[11px] text-slate-400">
                没绑定邮箱的账号（注册功能上线前创建的）无法自助注销，请联系管理员。
              </p>
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
          </div>
        ) : (
          <form onSubmit={handleDelete} className="space-y-3.5 px-5 py-4">
            <p className="text-xs leading-relaxed text-slate-600 dark:text-slate-400">
              验证码已发送至
              <span className="mx-1 rounded bg-slate-100 px-1.5 py-0.5 font-mono text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                {maskedEmail || '绑定邮箱'}
              </span>
              （账号
              <span className="mx-1 font-mono">{usernameTrimmed}</span>
              绑定的邮箱）。
            </p>

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

            <div className="rounded-lg border border-rose-200 bg-rose-50/60 px-3 py-2.5 dark:border-rose-900 dark:bg-rose-950/30">
              <p className="mb-1.5 text-xs font-medium text-rose-700 dark:text-rose-300">
                以下内容将被永久删除：
              </p>
              <ul className="space-y-0.5 text-[11px] leading-relaxed text-rose-700/90 dark:text-rose-300/90">
                {DELETE_SCOPE.map((t) => (
                  <li key={t}>· {t}</li>
                ))}
              </ul>
            </div>

            <label className="flex cursor-pointer items-start gap-2 text-[11px] leading-relaxed text-slate-600 dark:text-slate-400">
              <input
                type="checkbox"
                className="mt-0.5 h-3.5 w-3.5 accent-rose-600"
                checked={ack}
                onChange={(e) => setAck(e.target.checked)}
              />
              <span>我已了解上述数据将被永久删除且无法恢复，确认注销该账号。</span>
            </label>

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

            <div className="flex gap-2">
              <button
                type="button"
                onClick={backToVerify}
                disabled={submitting}
                className="shrink-0 rounded-lg border border-slate-300 px-3 py-2.5 text-sm font-medium text-slate-600 transition hover:bg-slate-50 disabled:cursor-not-allowed dark:border-slate-700 dark:text-slate-300 dark:hover:bg-slate-800"
              >
                返回
              </button>
              <button
                type="submit"
                disabled={submitting || !ack}
                className="flex-1 rounded-lg bg-rose-600 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-rose-700 disabled:cursor-not-allowed disabled:bg-slate-300 dark:disabled:bg-slate-700"
              >
                {submitting ? '注销中…' : '永久注销账号'}
              </button>
            </div>

            <button
              type="button"
              onClick={handleSendCode}
              disabled={sending || cooldown > 0}
              className="w-full text-center text-[11px] text-slate-400 transition hover:text-slate-600 disabled:cursor-not-allowed dark:hover:text-slate-300"
            >
              {sending ? '重新发送中…' : cooldown > 0 ? `${cooldown} 秒后可重新发送` : '没收到？重新发送验证码'}
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
