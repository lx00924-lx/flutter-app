/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * 中继服务端地址解析优先级：
 *
 * 1. 显式配置 `.env` / `.env.local` 里的 `VITE_SERVER_BASE_URL`
 *    （自建部署或把静态产物放到 CDN 时使用，见 .env.example）；
 * 2. 网页端自适应当前访问域名（`window.location.origin`）；
 * 3. 兜底使用本项目默认生产地址。
 */
const DEFAULT_SERVER_BASE_URL = 'https://www.lx00924ai.top';

export const getApiBaseUrl = (): string => {
  const configured = (import.meta.env.VITE_SERVER_BASE_URL as string | undefined)?.trim();
  if (configured) {
    return configured.replace(/\/+$/, '');
  }

  if (typeof window !== 'undefined' && window.location) {
    const origin = window.location.origin;
    if (origin && origin !== 'null' && !origin.startsWith('file://')) {
      return origin;
    }
  }

  return DEFAULT_SERVER_BASE_URL;
};

export const API_BASE_URL = getApiBaseUrl();

/**
 * 官网展示 / 分发的 GitHub 仓库，格式 `owner/repo`。
 *
 * 自建 / fork 部署**应当改这里**（或在 `.env` 里设 `VITE_GITHUB_REPO=你的用户名/你的仓库`）——
 * 否则你的官网「下载」区会列出并分发**原作者的安装包**，导航栏与页脚的链接也都指向原仓库。
 *
 * ⚠️ 与 Vite 的其它环境变量一样，这是**构建期静态文本替换**：
 * 必须写成 `import.meta.env.VITE_GITHUB_REPO` 这个字面量，
 * 用 `(import.meta as any)` 包一层会让替换失效。改完要重新 `npm run build`。
 */
const DEFAULT_GITHUB_REPO = 'lx00924-lx/flutter-app';

export const getGithubRepo = (): string => {
  const configured = (import.meta.env.VITE_GITHUB_REPO as string | undefined)?.trim();
  return (configured || DEFAULT_GITHUB_REPO).replace(/^\/+|\/+$/g, '');
};

/** `owner/repo` —— 读 Release、拼链接都用它 */
export const GITHUB_REPO = getGithubRepo();

/** `https://github.com/owner/repo` */
export const GITHUB_URL = `https://github.com/${GITHUB_REPO}`;

/** `https://github.com/owner/repo/releases` */
export const GITHUB_RELEASES_URL = `${GITHUB_URL}/releases`;

/**
 * 当前站点的主机名。
 *
 * `Architecture` 那类纯展示文案里要出现域名，以前是**写死**的原作者域名 ——
 * 自建部署的人页面上会挂着别人的域名。这里改成从同一个配置入口推导。
 */
export const getSiteHost = (): string => {
  try {
    return new URL(getApiBaseUrl()).host;
  } catch {
    return DEFAULT_SERVER_BASE_URL.replace(/^https?:\/\//, '');
  }
};
