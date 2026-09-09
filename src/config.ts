/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

// 动态自适应当前访问域名（在网页端自动优先使用当前 window.location.origin）
export const getApiBaseUrl = (): string => {
  if (typeof window !== 'undefined' && window.location) {
    const origin = window.location.origin;
    if (origin && origin !== 'null' && !origin.startsWith('file://')) {
      return origin;
    }
  }
  return 'https://www.lx00924ai.top';
};

export const API_BASE_URL = getApiBaseUrl();
