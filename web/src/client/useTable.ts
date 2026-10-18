import { useCallback, useEffect, useRef, useState } from "react";
import type { ClientMsg, ServerMsg, TableView } from "../shared/poker/types";
import type { TableInfo } from "./tables";

export type TableConn = {
  view: TableView | null;
  /** 服务器时钟减本地时钟，算倒计时用 */
  skew: number;
  error: string | null;
  connected: boolean;
  send: (msg: ClientMsg) => void;
  clearError: () => void;
};

/**
 * 连上一张牌桌。线上走 WebSocket，断线自动重连；预览版在浏览器里跑同一套牌局逻辑，陪打的是机器人。
 */
export function useTable(table: Pick<TableInfo, "no" | "blinds" | "bots" | "seated">): TableConn {
  const [view, setView] = useState<TableView | null>(null);
  const [skew, setSkew] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const sendRef = useRef<(msg: ClientMsg) => void>(() => {});

  useEffect(() => {
    setView(null);
    setError(null);
    const onMsg = (msg: ServerMsg) => {
      if (msg.t === "state") {
        setView(msg.view);
        setSkew(msg.view.serverNow - Date.now());
      } else if (msg.t === "error") setError(msg.msg);
    };

    if (import.meta.env.VITE_DEMO) {
      let stop = () => {};
      let alive = true;
      import("./localTable").then(({ openLocalTable }) => {
        if (!alive) return;
        const t = openLocalTable(table, onMsg);
        sendRef.current = t.send;
        stop = t.close;
        setConnected(true);
      });
      return () => {
        alive = false;
        stop();
      };
    }

    let ws: WebSocket | null = null;
    let closed = false;
    let retry = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const open = () => {
      const proto = location.protocol === "https:" ? "wss" : "ws";
      ws = new WebSocket(`${proto}://${location.host}/api/tables/${table.no}/ws`);
      ws.onopen = () => {
        retry = 0;
        setConnected(true);
      };
      ws.onmessage = (e) => onMsg(JSON.parse(e.data));
      ws.onclose = () => {
        setConnected(false);
        if (closed) return;
        timer = setTimeout(open, Math.min(10_000, 800 * 2 ** retry++));
      };
    };
    open();
    sendRef.current = (msg) => {
      if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
      else setError("和牌桌的连接断了，正在重连…");
    };
    const ping = setInterval(() => ws?.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ t: "ping" })), 30_000);
    return () => {
      closed = true;
      clearTimeout(timer);
      clearInterval(ping);
      ws?.close();
    };
    // 只按桌号重连
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [table.no]);

  const send = useCallback((msg: ClientMsg) => {
    setError(null);
    sendRef.current(msg);
  }, []);
  const clearError = useCallback(() => setError(null), []);
  return { view, skew, error, connected, send, clearError };
}
