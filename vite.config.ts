import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { defineConfig, loadEnv } from 'vite';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '');
  return {
    base: './',
    plugins: [react(), tailwindcss()],
    define: {
      'process.env.GEMINI_API_KEY': JSON.stringify(env.GEMINI_API_KEY),
    },
    resolve: {
      alias: {
        '@': path.resolve(__dirname, './src'),
      },
    },
    server: {
      // HMR is disabled in AI Studio via DISABLE_HMR env var.
      // Do not modify—file watching is disabled to prevent flickering during agent edits.
      hmr: process.env.DISABLE_HMR !== 'true',
      // 允许访问 dev server 的 Host 白名单。默认放行本项目生产域名与本机回环；
      // 自建部署可在 .env 里用 VITE_ALLOWED_HOSTS="a.com,b.com" 追加自己的域名。
      allowedHosts: [
        'www.lx00924ai.top',
        'localhost',
        '127.0.0.1',
        ...(env.VITE_ALLOWED_HOSTS
          ? env.VITE_ALLOWED_HOSTS.split(',')
              .map((host: string) => host.trim())
              .filter(Boolean)
          : []),
      ],
    },
  };
});