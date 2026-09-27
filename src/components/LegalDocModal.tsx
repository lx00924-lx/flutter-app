import React, { useEffect } from 'react';
import { X } from 'lucide-react';

/**
 * 官网的页内法务文档弹窗（用户协议 / 隐私政策 / 开源许可）。
 *
 * 为什么放在官网里而不是只给 GitHub 链接：用户是从这个下载门户下载 App 的，
 * 下载前就该能直接读到条款；弹窗内容由 Vite 的 `?raw` 在构建时内联进来，
 * 与仓库根目录的 TERMS.md / PRIVACY.md 永远是同一份，不会各自漂移。
 */
export interface LegalDoc {
  /** 用于 React key 与 aria，取值 terms / privacy / license。 */
  key: string;
  title: string;
  body: string;
}

interface LegalDocModalProps {
  doc: LegalDoc | null;
  onClose: () => void;
}

export const LegalDocModal: React.FC<LegalDocModalProps> = ({ doc, onClose }) => {
  useEffect(() => {
    if (!doc) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [doc, onClose]);

  if (!doc) return null;

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label={doc.title}
    >
      <div
        className="w-full max-w-3xl overflow-hidden rounded-2xl bg-white dark:bg-slate-900 shadow-2xl border border-slate-200 dark:border-slate-700"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 px-5 py-3">
          <h3 className="font-bold text-slate-900 dark:text-white">{doc.title}</h3>
          <button
            onClick={onClose}
            className="p-1.5 rounded-lg text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800 transition"
            title="关闭"
            aria-label="关闭"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
        <pre className="max-h-[70vh] overflow-y-auto whitespace-pre-wrap break-words px-5 py-4 text-[12.5px] leading-relaxed text-slate-700 dark:text-slate-300 font-sans">
          {doc.body}
        </pre>
      </div>
    </div>
  );
};
