import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function estimateTokens(text: string): number {
  return Math.ceil(text.length * 1.5);
}

export function formatMessageDate(date: Date | string): string {
  const d = new Date(date);
  const now = new Date();
  const diff = now.getTime() - d.getTime();
  const oneDay = 24 * 60 * 60 * 1000;
  
  const timeStr = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
  
  if (diff < oneDay && now.getDate() === d.getDate()) {
    return timeStr;
  } else if (diff < oneDay * 2 || (diff < oneDay * 3 && now.getDate() - d.getDate() === 1)) {
    // Check if it was actually yesterday
    const yesterday = new Date(now);
    yesterday.setDate(now.getDate() - 1);
    if (yesterday.getDate() === d.getDate()) {
      return `昨天 ${timeStr}`;
    }
  }
  
  const year = d.getFullYear();
  const month = (d.getMonth() + 1).toString().padStart(2, '0');
  const day = d.getDate().toString().padStart(2, '0');
  
  return `${year}-${month}-${day} ${timeStr}`;
}

export function safeSaveToLocalStorage(key: string, value: any): boolean {
  try {
    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch (err) {
    console.warn(`LocalStorage write failed for key "${key}":`, err);
    return false;
  }
}
