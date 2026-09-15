import React from 'react';
import { Download, Monitor, Smartphone, ExternalLink, CheckCircle2, ArrowRight } from 'lucide-react';
import { ReleaseAsset, GitHubRelease } from '../types/landing';

interface HeroProps {
  latestRelease: GitHubRelease | null;
  isLoadingRelease: boolean;
  onDownload: (url: string, platform: string) => void;
  androidAsset: ReleaseAsset | null;
  windowsAsset: ReleaseAsset | null;
}

export const Hero: React.FC<HeroProps> = ({
  latestRelease,
  isLoadingRelease,
  onDownload,
  androidAsset,
  windowsAsset,
}) => {
  const versionTag = latestRelease?.tag_name || 'v1.0.0';

  const formatSize = (bytes: number) => {
    if (!bytes) return '';
    return `(${(bytes / (1024 * 1024)).toFixed(1)} MB)`;
  };

  return (
    <section className="relative overflow-hidden pt-12 pb-20 md:pt-20 md:pb-28 border-b border-slate-200/70 dark:border-slate-800/70">
      {/* Background Gradient Accents */}
      <div className="absolute top-1/4 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[600px] h-[350px] bg-gradient-to-tr from-sky-400/15 via-indigo-500/15 to-purple-500/15 blur-3xl -z-10 pointer-events-none rounded-full" />

      <div className="max-w-5xl mx-auto px-4 sm:px-6 text-center">
        {/* Release Tag Pill */}
        <div className="inline-flex items-center gap-2 px-3.5 py-1.5 rounded-full border border-indigo-200/70 dark:border-indigo-800/70 bg-indigo-50/80 dark:bg-indigo-950/50 text-indigo-700 dark:text-indigo-300 text-xs font-semibold mb-6 shadow-sm">
          <span className="w-2 h-2 rounded-full bg-indigo-500 animate-pulse" />
          <span>最新发布版本 {versionTag}</span>
          <ArrowRight className="w-3.5 h-3.5 opacity-70" />
        </div>

        {/* Hero Title */}
        <h1 className="text-4xl sm:text-5xl md:text-6xl font-extrabold tracking-tight text-slate-900 dark:text-white leading-[1.15] mb-6">
          跨端私有 Agent{' '}
          <span className="bg-gradient-to-r from-sky-500 via-indigo-500 to-purple-600 bg-clip-text text-transparent">
            智能控制中枢
          </span>
        </h1>

        {/* Subtitle */}
        <p className="max-w-2xl mx-auto text-base sm:text-lg text-slate-600 dark:text-slate-300 mb-10 leading-relaxed">
          基于 Flutter 纯原生多端架构打造。借助高性能云端中继与反向长连接内网穿透技术，无论身处何地，手机与电脑均可零延迟远程遥控局域网内私有模型与自主工作区。
        </p>

        {/* Action Download Buttons */}
        <div className="flex flex-col sm:flex-row items-center justify-center gap-4 mb-10">
          {/* Windows Download */}
          <button
            onClick={() => {
              if (windowsAsset?.browser_download_url) {
                onDownload(windowsAsset.browser_download_url, 'Windows');
              } else if (latestRelease?.html_url) {
                window.open(latestRelease.html_url, '_blank');
              } else {
                window.open('https://github.com/lx00924-lx/flutter-app/releases', '_blank');
              }
            }}
            className="w-full sm:w-auto flex items-center justify-center gap-2.5 px-6 py-3.5 rounded-2xl bg-indigo-600 hover:bg-indigo-700 active:scale-95 text-white font-semibold text-sm shadow-lg shadow-indigo-600/25 transition duration-150"
          >
            <Monitor className="w-4 h-4" />
            <span>下载 Windows 桌面版</span>
            {windowsAsset && (
              <span className="text-indigo-200 text-xs font-normal">
                {formatSize(windowsAsset.size)}
              </span>
            )}
          </button>

          {/* Android Download */}
          <button
            onClick={() => {
              if (androidAsset?.browser_download_url) {
                onDownload(androidAsset.browser_download_url, 'Android');
              } else if (latestRelease?.html_url) {
                window.open(latestRelease.html_url, '_blank');
              } else {
                window.open('https://github.com/lx00924-lx/flutter-app/releases', '_blank');
              }
            }}
            className="w-full sm:w-auto flex items-center justify-center gap-2.5 px-6 py-3.5 rounded-2xl bg-slate-900 hover:bg-slate-800 dark:bg-slate-100 dark:hover:bg-white dark:text-slate-900 active:scale-95 text-white font-semibold text-sm shadow-md transition duration-150"
          >
            <Smartphone className="w-4 h-4" />
            <span>下载 Android 安装包</span>
            {androidAsset && (
              <span className="text-slate-300 dark:text-slate-600 text-xs font-normal">
                {formatSize(androidAsset.size)}
              </span>
            )}
          </button>

          {/* GitHub Source Code */}
          <a
            href="https://github.com/lx00924-lx/flutter-app"
            target="_blank"
            rel="noreferrer"
            className="w-full sm:w-auto flex items-center justify-center gap-2 px-5 py-3.5 rounded-2xl border border-slate-200 dark:border-slate-800 hover:bg-slate-100 dark:hover:bg-slate-900 text-slate-700 dark:text-slate-200 font-semibold text-sm transition"
          >
            <span>GitHub 源码</span>
            <ExternalLink className="w-4 h-4 opacity-70" />
          </a>
        </div>

        {/* Trust Badges */}
        <div className="flex flex-wrap items-center justify-center gap-6 sm:gap-8 text-xs font-medium text-slate-500 dark:text-slate-400">
          <div className="flex items-center gap-1.5">
            <CheckCircle2 className="w-4 h-4 text-emerald-500" />
            <span>100% 纯原生 Flutter 架构</span>
          </div>
          <div className="flex items-center gap-1.5">
            <CheckCircle2 className="w-4 h-4 text-emerald-500" />
            <span>无需公网 IP / 路由器端口映射</span>
          </div>
          <div className="flex items-center gap-1.5">
            <CheckCircle2 className="w-4 h-4 text-emerald-500" />
            <span>端到端云端设置防抖同步</span>
          </div>
          <div className="flex items-center gap-1.5">
            <CheckCircle2 className="w-4 h-4 text-emerald-500" />
            <span>开源免费 & 隐私数据自主可控</span>
          </div>
        </div>
      </div>
    </section>
  );
};
