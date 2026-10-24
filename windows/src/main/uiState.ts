// 主窗口关闭后保留的界面选择（时间范围、服务筛选、排序……）。主窗口关闭即销毁，
// 这些选择存在后台内存里（退出 App 后回到默认），和 Mac 版一样。

import { useEffect, useState } from "react";
import { api, inTauri } from "../shared/api";

let cache: Record<string, unknown> | null = inTauri ? null : {};
let timer: ReturnType<typeof setTimeout> | undefined;

export async function loadUiState(): Promise<void> {
  if (cache) return;
  cache = (await api.getUiState()) ?? {};
}

export function uiValue<T>(key: string, fallback: T): T {
  const v = cache?.[key];
  return v === undefined ? fallback : (v as T);
}

export function setUiValue(key: string, value: unknown) {
  if (!cache) cache = {};
  cache[key] = value;
  clearTimeout(timer);
  timer = setTimeout(() => api.setUiState(cache!), 300);
}

/** 像 useState，但值会在主窗口关闭后保留。 */
export function usePersisted<T>(key: string, fallback: T): [T, (v: T | ((old: T) => T)) => void] {
  const [value, setValue] = useState<T>(() => uiValue(key, fallback));
  useEffect(() => setUiValue(key, value), [key, value]);
  return [value, setValue];
}
