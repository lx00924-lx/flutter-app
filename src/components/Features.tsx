import React from 'react';
import { Layers, ShieldCheck, Zap, CloudUpload, Cpu, Users } from 'lucide-react';

export const Features: React.FC = () => {
  const featureList = [
    {
      icon: Layers,
      color: 'text-sky-500 bg-sky-50 dark:bg-sky-950/60 border-sky-100 dark:border-sky-900',
      title: '三位一体现代架构',
      description:
        '彻底剥离传统 WebView 套壳缺陷。采用纯原生 Flutter 跨平台客户端、Node.js/Express 高并发云端中继与 Python 反向守护进程，性能与响应大幅提速。',
    },
    {
      icon: ShieldCheck,
      color: 'text-indigo-500 bg-indigo-50 dark:bg-indigo-950/60 border-indigo-100 dark:border-indigo-900',
      title: '零公网 IP 内网安全穿透',
      description:
        '无需宽带公网 IP，无需配置复杂的路由器端口转发（NAT/DDNS）。电脑端 Bridge 自动建立安全双向长连接，在任意外部网络均可无阻访问本地 Agent。',
    },
    {
      icon: CloudUpload,
      color: 'text-purple-500 bg-purple-50 dark:bg-purple-950/60 border-purple-100 dark:border-purple-900',
      title: '云端设置与数据漫游',
      description:
        '支持 API 端点卡片、模型列表、自定义 Key 与外观偏好双向增量防抖同步。更换设备或清除应用缓存后，一键登录即刻完美恢复完整工作区。',
    },
    {
      icon: Zap,
      color: 'text-amber-500 bg-amber-50 dark:bg-amber-950/60 border-amber-100 dark:border-amber-900',
      title: '极速流式交互与语音集成',
      description:
        '深度优化 SSE（Server-Sent Events）打字机流式输出体验，内建高精度语音转写（ASR）与文本生成，对话如丝般顺滑自然。',
    },
    {
      icon: Users,
      color: 'text-emerald-500 bg-emerald-50 dark:bg-emerald-950/60 border-emerald-100 dark:border-emerald-900',
      title: '双端互斥单点登录',
      description:
        '服务端严格实施 1 台手机 + 1 台电脑并行的互斥登录心跳策略，防止多端冲突覆盖，保障会话状态与通信上下文高度一致。',
    },
    {
      icon: Cpu,
      color: 'text-rose-500 bg-rose-50 dark:bg-rose-950/60 border-rose-100 dark:border-rose-900',
      title: '多模型生态自由接入',
      description:
        '原生无缝兼容 DeepSeek、OpenAI、Claude、Gemini、Ollama 等主流大语言模型与自建私有推理算力，满足多元化智能体编排需求。',
    },
  ];

  return (
    <section id="features" className="py-20 bg-slate-50/50 dark:bg-slate-900/30 border-b border-slate-200/70 dark:border-slate-800/70">
      <div className="max-w-6xl mx-auto px-4 sm:px-6">
        <div className="text-center max-w-2xl mx-auto mb-16">
          <h2 className="text-xs font-bold uppercase tracking-wider text-indigo-600 dark:text-indigo-400 mb-2">
            Features & Highlights
          </h2>
          <h3 className="text-3xl font-extrabold text-slate-900 dark:text-white tracking-tight">
            专为极致远程操控体验而生
          </h3>
          <p className="mt-3 text-sm sm:text-base text-slate-500 dark:text-slate-400">
            从移动端手指触摸到内网服务器指令执行，每一个细节都经过精密推敲。
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {featureList.map((item, index) => {
            const Icon = item.icon;
            return (
              <div
                key={index}
                className="p-6 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800/80 hover:border-indigo-500/40 dark:hover:border-indigo-500/40 transition shadow-sm hover:shadow-md group"
              >
                <div className={`w-11 h-11 rounded-xl flex items-center justify-center mb-5 border ${item.color} group-hover:scale-110 transition-transform duration-200`}>
                  <Icon className="w-5 h-5" />
                </div>
                <h4 className="text-base font-bold text-slate-900 dark:text-white mb-2">
                  {item.title}
                </h4>
                <p className="text-xs sm:text-sm text-slate-600 dark:text-slate-400 leading-relaxed">
                  {item.description}
                </p>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
};
