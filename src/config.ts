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
