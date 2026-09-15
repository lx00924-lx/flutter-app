import React from 'react';
import { Download, Monitor, Smartphone, ExternalLink, Calendar, HardDrive, RefreshCw } from 'lucide-react';
import { ReleaseAsset, GitHubRelease } from '../types/landing';

interface DownloadsProps {
  latestRelease: GitHubRelease | null;
  isLoading: boolean;
  onRefresh: () => void;
  onDownload: (url: string, platform: string) => void;
  androidAsset: ReleaseAsset | null;
  windowsAsset: ReleaseAsset | null;
}

export const Downloads: React.FC<DownloadsProps> = ({
  latestRelease,
  isLoading,
  onRefresh,
  onDownload,
  androidAsset,
  windowsAsset,
}) => {
  const versionTag = latestRelease?.tag_name || 'v1.0.0';
  const publishDate = latestRelease?.published_at
    ? new Date(latestRelease.published_at).toLocaleDateString('zh-CN', {
        year: 'numeric',
        month: 'long',
        day: 'numeric',
      })
    : '近期发布';

  const formatSize = (bytes: number) => {
    if (!bytes) return '待获取';
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  };

  return (
    <section id="downloads" className="py-20 bg-slate-50/50 dark:bg-slate-900/30 border-b border-slate-200/70 dark:border-slate-800/70">
      <div className="max-w-6xl mx-auto px-4 sm:px-6">
        <div className="flex flex-col sm:flex-row items-start sm:items-end justify-between mb-12 gap-4">
          <div>
            <h2 className="text-xs font-bold uppercase tracking-wider text-indigo-600 dark:text-indigo-400 mb-2">
              Releases & Packages
            </h2>
            <h3 className="text-3xl font-extrabold text-slate-900 dark:text-white tracking-tight">
              应用全平台安装包下载
            </h3>
            <p className="mt-2 text-sm text-slate-500 dark:text-slate-400">
              数据直连 GitHub Releases 官方存储分发通道，点击立即唤起浏览器极速下载。
            </p>
          </div>

          <button
            onClick={onRefresh}
            disabled={isLoading}
            className="flex items-center gap-2 px-3.5 py-2 text-xs font-medium rounded-xl border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 hover:bg-slate-100 dark:hover:bg-slate-800 text-slate-700 dark:text-slate-200 transition shadow-sm disabled:opacity-50"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${isLoading ? 'animate-spin' : ''}`} />
            <span>刷新最新固件</span>
          </button>
        </div>

        {/* 2 Platform Cards */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-8 mb-12">
          {/* Windows Package */}
          <div className="p-8 rounded-3xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800/80 shadow-sm hover:shadow-lg transition-all duration-200 flex flex-col justify-between">
            <div>
              <div className="flex items-center justify-between mb-6">
                <div className="w-14 h-14 rounded-2xl bg-indigo-50 dark:bg-indigo-950/70 border border-indigo-100 dark:border-indigo-900 text-indigo-600 dark:text-indigo-400 flex items-center justify-center">
                  <Monitor className="w-7 h-7" />
                </div>
                <span className="px-3 py-1 rounded-full text-xs font-semibold bg-indigo-50 text-indigo-600 dark:bg-indigo-950/80 dark:text-indigo-300 border border-indigo-200/60 dark:border-indigo-800/60">
                  {versionTag}
                </span>
              </div>

              <h4 className="text-xl font-bold text-slate-900 dark:text-white mb-2">
                Windows 桌面端安装程序
              </h4>
              <p className="text-xs sm:text-sm text-slate-600 dark:text-slate-400 mb-6 leading-relaxed">
                适用于 Windows 10 / 11 64 位操作系统。包含完整的独立执行程序，已支持高分屏 DPI 自适应缩放及脱钩独立静默更新。
              </p>

              <div className="p-4 rounded-2xl bg-slate-50 dark:bg-slate-800/60 border border-slate-100 dark:border-slate-800 space-y-2 mb-6">
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500 flex items-center gap-1.5">
                    <HardDrive className="w-3.5 h-3.5" /> 文件体积
                  </span>
                  <span className="font-semibold text-slate-800 dark:text-slate-200">
                    {windowsAsset ? formatSize(windowsAsset.size) : '以 Release 为准'}
                  </span>
                </div>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500 flex items-center gap-1.5">
                    <Calendar className="w-3.5 h-3.5" /> 发布日期
                  </span>
                  <span className="text-slate-700 dark:text-slate-300">{publishDate}</span>
                </div>
              </div>
            </div>

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
              className="w-full flex items-center justify-center gap-2 py-3.5 px-6 rounded-2xl bg-indigo-600 hover:bg-indigo-700 active:scale-98 text-white font-semibold text-sm shadow-md shadow-indigo-600/20 transition duration-150"
            >
              <Download className="w-4 h-4" />
              <span>下载 Windows 版 (.exe)</span>
            </button>
          </div>

          {/* Android Package */}
          <div className="p-8 rounded-3xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800/80 shadow-sm hover:shadow-lg transition-all duration-200 flex flex-col justify-between">
            <div>
              <div className="flex items-center justify-between mb-6">
                <div className="w-14 h-14 rounded-2xl bg-emerald-50 dark:bg-emerald-950/70 border border-emerald-100 dark:border-emerald-900 text-emerald-600 dark:text-emerald-400 flex items-center justify-center">
                  <Smartphone className="w-7 h-7" />
                </div>
                <span className="px-3 py-1 rounded-full text-xs font-semibold bg-emerald-50 text-emerald-600 dark:bg-emerald-950/80 dark:text-emerald-300 border border-emerald-200/60 dark:border-emerald-800/60">
                  {versionTag}
                </span>
              </div>

              <h4 className="text-xl font-bold text-slate-900 dark:text-white mb-2">
                Android 手机端安装包
              </h4>
              <p className="text-xs sm:text-sm text-slate-600 dark:text-slate-400 mb-6 leading-relaxed">
                适用于 Android 8.0 及以上版本手机。内建大厂级通知栏流式更新、应用内断点防重复缓存及自动调起系统安装向导。
              </p>

              <div className="p-4 rounded-2xl bg-slate-50 dark:bg-slate-800/60 border border-slate-100 dark:border-slate-800 space-y-2 mb-6">
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500 flex items-center gap-1.5">
                    <HardDrive className="w-3.5 h-3.5" /> 文件体积
                  </span>
                  <span className="font-semibold text-slate-800 dark:text-slate-200">
                    {androidAsset ? formatSize(androidAsset.size) : '以 Release 为准'}
                  </span>
                </div>
                <div className="flex items-center justify-between text-xs">
                  <span className="text-slate-500 flex items-center gap-1.5">
                    <Calendar className="w-3.5 h-3.5" /> 发布日期
                  </span>
                  <span className="text-slate-700 dark:text-slate-300">{publishDate}</span>
                </div>
              </div>
            </div>

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
              className="w-full flex items-center justify-center gap-2 py-3.5 px-6 rounded-2xl bg-slate-900 hover:bg-slate-800 dark:bg-slate-100 dark:hover:bg-white dark:text-slate-900 active:scale-98 text-white font-semibold text-sm shadow-md transition duration-150"
            >
              <Download className="w-4 h-4" />
              <span>下载 Android 版 (.apk)</span>
            </button>
          </div>
        </div>

        {/* Release Notes / All Assets Dropdown */}
        {latestRelease && latestRelease.assets && latestRelease.assets.length > 0 && (
          <div className="p-6 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800">
            <h4 className="text-sm font-bold text-slate-900 dark:text-white mb-3">
              📦 本次版本全部发布产物 ({latestRelease.assets.length})
            </h4>
            <div className="divide-y divide-slate-100 dark:divide-slate-800">
              {latestRelease.assets.map((asset) => (
                <div
                  key={asset.id}
                  className="py-3 flex items-center justify-between gap-4 text-xs"
                >
                  <div className="flex items-center gap-2 min-w-0">
                    <Download className="w-4 h-4 text-indigo-500 shrink-0" />
                    <span className="font-mono text-slate-800 dark:text-slate-200 truncate font-medium">
                      {asset.name}
                    </span>
                    <span className="text-slate-400">({formatSize(asset.size)})</span>
                  </div>
                  <a
                    href={asset.browser_download_url}
                    target="_blank"
                    rel="noreferrer"
                    className="shrink-0 px-3 py-1 rounded-lg bg-slate-100 dark:bg-slate-800 hover:bg-indigo-50 hover:text-indigo-600 dark:hover:bg-indigo-950 dark:hover:text-indigo-400 transition font-semibold"
                  >
                    直接下载
                  </a>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </section>
  );
};
