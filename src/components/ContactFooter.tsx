import React, { useState } from 'react';
import { Mail, Github, MessageSquare, Copy, Check, Heart, ExternalLink } from 'lucide-react';

interface ContactFooterProps {
  userEmail?: string;
  githubUrl: string;
}

export const ContactFooter: React.FC<ContactFooterProps> = ({
  userEmail = 'lx00924@gmail.com',
  githubUrl = 'https://github.com/lx00924-lx/flutter-app',
}) => {
  const [copiedEmail, setCopiedEmail] = useState(false);

  const copyEmail = () => {
    navigator.clipboard.writeText(userEmail);
    setCopiedEmail(true);
    setTimeout(() => setCopiedEmail(false), 2000);
  };

  return (
    <footer id="contact" className="bg-slate-900 text-slate-300 pt-16 pb-12 transition-colors">
      <div className="max-w-6xl mx-auto px-4 sm:px-6">
        <div className="grid grid-cols-1 md:grid-cols-12 gap-10 pb-12 border-b border-slate-800">
          {/* Brand Info */}
          <div className="md:col-span-6 space-y-4">
            <div className="flex items-center gap-2">
              <span className="font-black text-xl text-white tracking-tight">LxAI</span>
              <span className="px-2 py-0.5 text-[10px] font-bold rounded-full bg-indigo-500/20 text-indigo-400 border border-indigo-500/30">
                Open Source Ecosystem
              </span>
            </div>
            <p className="text-xs sm:text-sm text-slate-400 max-w-md leading-relaxed">
              让每一个开发者与 AI 爱好者，都能拥有无拘无束、随时远程调度的私有智能体工作区。纯原生 Flutter 研发，数据完全属于您自己。
            </p>
            <div className="pt-2 text-xs text-slate-500 flex items-center gap-2">
              <span>Made with</span>
              <Heart className="w-3.5 h-3.5 text-rose-500 fill-rose-500" />
              <span>for Open Source Community</span>
            </div>
          </div>

          {/* Quick Links & GitHub */}
          <div className="md:col-span-3 space-y-3">
            <h5 className="text-xs font-bold uppercase tracking-wider text-white">
              开源与社区
            </h5>
            <ul className="text-xs space-y-2.5">
              <li>
                <a
                  href={githubUrl}
                  target="_blank"
                  rel="noreferrer"
                  className="flex items-center gap-2 hover:text-white transition"
                >
                  <Github className="w-4 h-4 text-indigo-400" />
                  <span>GitHub 项目仓库</span>
                </a>
              </li>
              <li>
                <a
                  href={`${githubUrl}/releases`}
                  target="_blank"
                  rel="noreferrer"
                  className="flex items-center gap-2 hover:text-white transition"
                >
                  <ExternalLink className="w-4 h-4 text-emerald-400" />
                  <span>全部发行版本 (Releases)</span>
                </a>
              </li>
              <li>
                <a
                  href={`${githubUrl}/issues`}
                  target="_blank"
                  rel="noreferrer"
                  className="flex items-center gap-2 hover:text-white transition"
                >
                  <MessageSquare className="w-4 h-4 text-sky-400" />
                  <span>反馈问题 / 提交 Issue</span>
                </a>
              </li>
            </ul>
          </div>

          {/* Contact Us */}
          <div className="md:col-span-3 space-y-3">
            <h5 className="text-xs font-bold uppercase tracking-wider text-white">
              联系我们
            </h5>
            <p className="text-xs text-slate-400">
              有任何功能建议、商业合作或部署技术疑问，欢迎随时邮件交流：
            </p>

            <div className="pt-1">
              <div className="flex items-center justify-between p-2.5 rounded-xl bg-slate-800/80 border border-slate-700/60">
                <div className="flex items-center gap-2 min-w-0">
                  <Mail className="w-4 h-4 text-indigo-400 shrink-0" />
                  <span className="text-xs font-mono text-white truncate">{userEmail}</span>
                </div>
                <button
                  onClick={copyEmail}
                  className="shrink-0 p-1.5 rounded-lg hover:bg-slate-700 text-slate-400 hover:text-white transition ml-2"
                  title="复制邮箱"
                >
                  {copiedEmail ? (
                    <Check className="w-3.5 h-3.5 text-emerald-400" />
                  ) : (
                    <Copy className="w-3.5 h-3.5" />
                  )}
                </button>
              </div>
              <a
                href={`mailto:${userEmail}`}
                className="mt-2 inline-flex items-center gap-1.5 text-xs text-indigo-400 hover:text-indigo-300 font-medium transition"
              >
                <span>直接发送邮件 ➔</span>
              </a>
            </div>
          </div>
        </div>

        {/* Bottom Copyright */}
        <div className="pt-8 flex flex-col sm:flex-row items-center justify-between text-xs text-slate-500 gap-4">
          <div>
            © {new Date().getFullYear()} LxAI Team. Released under the MIT License.
          </div>
          <div className="flex items-center gap-6">
            <a href="#features" className="hover:text-slate-400 transition">
              特性
            </a>
            <a href="#architecture" className="hover:text-slate-400 transition">
              架构
            </a>
            <a href="#downloads" className="hover:text-slate-400 transition">
              下载
            </a>
            <a href={githubUrl} target="_blank" rel="noreferrer" className="hover:text-slate-400 transition">
              GitHub
            </a>
          </div>
        </div>
      </div>
    </footer>
  );
};
