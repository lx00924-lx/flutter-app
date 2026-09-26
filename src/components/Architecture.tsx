import React from 'react';
import { Smartphone, Monitor, Globe, Server, ArrowRight, ArrowLeftRight } from 'lucide-react';

export const Architecture: React.FC = () => {
  return (
    <section id="architecture" className="py-20 border-b border-slate-200/70 dark:border-slate-800/70">
      <div className="max-w-6xl mx-auto px-4 sm:px-6">
        <div className="text-center max-w-2xl mx-auto mb-16">
          <h2 className="text-xs font-bold uppercase tracking-wider text-indigo-600 dark:text-indigo-400 mb-2">
            System Topology
          </h2>
          <h3 className="text-3xl font-extrabold text-slate-900 dark:text-white tracking-tight">
            全链路闭环，数据安全流转
          </h3>
          <p className="mt-3 text-sm sm:text-base text-slate-500 dark:text-slate-400">
            理解 LxAI 如何在无需公网 IP 的环境下，实现毫秒级双向安全握手。
          </p>
        </div>

        {/* Visual Workflow Diagram */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 relative">
          {/* Node 1: Mobile & Desktop Client */}
          <div className="p-6 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-sm relative">
            <div className="w-12 h-12 rounded-xl bg-sky-50 dark:bg-sky-950/60 text-sky-600 dark:text-sky-400 border border-sky-100 dark:border-sky-900 flex items-center justify-center mb-4">
              <Smartphone className="w-6 h-6" />
            </div>
            <div className="text-xs font-bold text-sky-600 dark:text-sky-400 uppercase tracking-wider mb-1">
              Client Tier
            </div>
            <h4 className="text-lg font-bold text-slate-900 dark:text-white mb-2">
              纯原生 Flutter 客户端
            </h4>
            <p className="text-xs text-slate-600 dark:text-slate-400 leading-relaxed mb-4">
              跨 Android 手机与 Windows 桌面平台，提供毫秒级触控动画、语音输入录音与打字机式流式消息渲染。
            </p>
            <ul className="text-xs space-y-1.5 text-slate-500 dark:text-slate-400 font-medium">
              <li className="flex items-center gap-1.5">✓ 零延迟 Provider 全局状态调度</li>
              <li className="flex items-center gap-1.5">✓ 本地 SQLite / SharedPreferences 持久化</li>
            </ul>
          </div>

          {/* Node 2: Cloud Relay */}
          <div className="p-6 rounded-2xl bg-gradient-to-b from-indigo-50/50 to-white dark:from-indigo-950/20 dark:to-slate-900 border-2 border-indigo-500/30 dark:border-indigo-500/30 shadow-md relative">
            <div className="w-12 h-12 rounded-xl bg-indigo-500 text-white flex items-center justify-center mb-4 shadow-md shadow-indigo-500/25">
              <Server className="w-6 h-6" />
            </div>
            <div className="text-xs font-bold text-indigo-600 dark:text-indigo-400 uppercase tracking-wider mb-1">
              Cloud Relay Hub
            </div>
            <h4 className="text-lg font-bold text-slate-900 dark:text-white mb-2">
              高性能云端中继服务器
            </h4>
            <p className="text-xs text-slate-600 dark:text-slate-400 leading-relaxed mb-4">
              公网高速节点（`lx00924ai.top`），负责会话鉴权、Token 调度分配、设置增量漫游与信道桥接。
            </p>
            <ul className="text-xs space-y-1.5 text-slate-500 dark:text-slate-400 font-medium">
              <li className="flex items-center gap-1.5">✓ 双端互斥登录心跳保活</li>
              <li className="flex items-center gap-1.5">✓ 高效代理 FunASR 语音转写与模型转发</li>
            </ul>
          </div>

          {/* Node 3: Local Agent Bridge */}
          <div className="p-6 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-sm relative">
            <div className="w-12 h-12 rounded-xl bg-purple-50 dark:bg-purple-950/60 text-purple-600 dark:text-purple-400 border border-purple-100 dark:border-purple-900 flex items-center justify-center mb-4">
              <Monitor className="w-6 h-6" />
            </div>
            <div className="text-xs font-bold text-purple-600 dark:text-purple-400 uppercase tracking-wider mb-1">
              Intranet Host
            </div>
            <h4 className="text-lg font-bold text-slate-900 dark:text-white mb-2">
              本地私有 Agent / Bridge
            </h4>
            <p className="text-xs text-slate-600 dark:text-slate-400 leading-relaxed mb-4">
              运行于办公电脑或家庭私有服务器的 `lxai_bridge.py`，主动反向连接中继并遥控本地自动化环境。
            </p>
            <ul className="text-xs space-y-1.5 text-slate-500 dark:text-slate-400 font-medium">
              <li className="flex items-center gap-1.5">✓ 局域网无公网 IP 限制</li>
              <li className="flex items-center gap-1.5">✓ 本地 Harness 进程与自主代码执行</li>
            </ul>
          </div>
        </div>

        {/* 3 Step Quick Start */}
        <div className="mt-14 p-6 sm:p-8 rounded-2xl bg-slate-100/70 dark:bg-slate-900/80 border border-slate-200 dark:border-slate-800">
          <h4 className="text-sm font-bold text-slate-900 dark:text-white uppercase tracking-wider mb-6 text-center">
            🚀 3 步即可完成专属智能中枢搭建
          </h4>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6 text-left">
            <div className="space-y-1.5">
              <span className="text-xs font-bold text-indigo-600 dark:text-indigo-400">步骤 01</span>
              <h5 className="text-sm font-bold text-slate-900 dark:text-white">下载客户端</h5>
              <p className="text-xs text-slate-600 dark:text-slate-400 leading-relaxed">
                在手机（Android）或电脑（Windows）上安装 LxAI 客户端，打开设置面板配置服务器地址。
              </p>
            </div>
            <div className="space-y-1.5">
              <span className="text-xs font-bold text-indigo-600 dark:text-indigo-400">步骤 02</span>
              <h5 className="text-sm font-bold text-slate-900 dark:text-white">启动本地 Bridge</h5>
              <p className="text-xs text-slate-600 dark:text-slate-400 leading-relaxed">
                在内网电脑上执行 <code className="text-indigo-600 dark:text-indigo-400">python lxai_bridge.py</code> 反向挂载到云端中继。
              </p>
            </div>
            <div className="space-y-1.5">
              <span className="text-xs font-bold text-indigo-600 dark:text-indigo-400">步骤 03</span>
              <h5 className="text-sm font-bold text-slate-900 dark:text-white">随时随地畅联</h5>
              <p className="text-xs text-slate-600 dark:text-slate-400 leading-relaxed">
                掏出手机，即可实时与家里电脑的自主智能体、私有大模型展开流畅交互与远程调度！
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};
