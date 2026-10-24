import { useCallback, useEffect, useState } from "react";
import { api, type MeResponse } from "./api";

const ME_CHANGED = "yyb:me-changed";

export function useMe() {
  const [me, setMe] = useState<MeResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const reload = useCallback(() => {
    api<MeResponse>("/api/me").then(setMe, (e: Error) => setError(e.message));
  }, []);
  useEffect(() => {
    reload();
    addEventListener(ME_CHANGED, reload);
    return () => removeEventListener(ME_CHANGED, reload);
  }, [reload]);
  return { me, error, reload };
}

/** 登录状态变了（登录、退出、改设置）时通知所有用到 useMe 的组件。 */
export function notifyMeChanged() {
  dispatchEvent(new Event(ME_CHANGED));
}

export function loginHref(next = location.pathname + location.search) {
  return `/auth/github?next=${encodeURIComponent(next)}`;
}
