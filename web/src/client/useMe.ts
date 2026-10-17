import { useCallback, useEffect, useState } from "react";
import { api, type MeResponse } from "./api";

export function useMe() {
  const [me, setMe] = useState<MeResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const reload = useCallback(() => {
    api<MeResponse>("/api/me").then(setMe, (e: Error) => setError(e.message));
  }, []);
  useEffect(reload, [reload]);
  return { me, error, reload };
}

export function loginHref(next = location.pathname + location.search) {
  return `/auth/github?next=${encodeURIComponent(next)}`;
}
