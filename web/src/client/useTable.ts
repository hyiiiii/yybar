import { useCallback, useEffect, useRef, useState } from "react";
import type { ClientMsg, ServerMsg, TableView } from "../shared/poker/types";
import type { TableInfo } from "./tables";

export type TableConn = {
  view: TableView | null;
  /** 服务器时钟减本地时钟，算倒计时用 */
  skew: number;
  error: string | null;
  connected: boolean;
  /** 玩家开的桌没人了，已经收掉 */
  closed: boolean;
  send: (msg: ClientMsg) => void;
  clearError: () => void;
};

type Info = Pick<TableInfo, "no" | "blinds" | "bots" | "seated" | "temporary">;

interface Handlers {
  onMsg: (msg: ServerMsg) => void;
  onOpen: (open: boolean) => void;
}

/**
 * 连上一张牌桌，返回发消息和断开的函数。线上走 WebSocket，断线自动重连（桌子收掉了就不再连）；
 * 预览版在浏览器里跑同一套牌局逻辑，陪打的是机器人。
 */
function connect(table: Info, { onMsg, onOpen }: Handlers): { send: (msg: ClientMsg) => boolean; close: () => void } {
  if (import.meta.env.VITE_DEMO) {
    let local: { send: (msg: ClientMsg) => void; close: () => void } | null = null;
    let alive = true;
    import("./localTable").then(({ openLocalTable }) => {
      if (!alive) return;
      local = openLocalTable(table, onMsg);
      onOpen(true);
    });
    return {
      send: (msg) => (local?.send(msg), !!local),
      close: () => {
        alive = false;
        local?.close();
      },
    };
  }

  let ws: WebSocket | null = null;
  let closed = false;
  let gone = false;
  let retry = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const open = () => {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    ws = new WebSocket(`${proto}://${location.host}/api/tables/${table.no}/ws`);
    ws.onopen = () => {
      retry = 0;
      onOpen(true);
    };
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data) as ServerMsg;
      if (msg.t === "closed") gone = true;
      onMsg(msg);
    };
    ws.onclose = () => {
      onOpen(false);
      if (closed || gone) return;
      timer = setTimeout(open, Math.min(10_000, 800 * 2 ** retry++));
    };
  };
  open();
  const ping = setInterval(() => ws?.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ t: "ping" })), 30_000);
  return {
    send: (msg) => {
      if (ws?.readyState !== WebSocket.OPEN) return false;
      ws.send(JSON.stringify(msg));
      return true;
    },
    close: () => {
      closed = true;
      clearTimeout(timer);
      clearInterval(ping);
      ws?.close();
    },
  };
}

/** 正在看的这张桌。 */
export function useTable(table: Info): TableConn {
  const [view, setView] = useState<TableView | null>(null);
  const [skew, setSkew] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const [closed, setClosed] = useState(false);
  const sendRef = useRef<(msg: ClientMsg) => boolean>(() => false);

  useEffect(() => {
    setView(null);
    setError(null);
    setClosed(false);
    const conn = connect(table, {
      onMsg: (msg) => {
        if (msg.t === "state") {
          setView(msg.view);
          setSkew(msg.view.serverNow - Date.now());
        } else if (msg.t === "error") setError(msg.msg);
        else if (msg.t === "closed") setClosed(true);
      },
      onOpen: setConnected,
    });
    sendRef.current = conn.send;
    return conn.close;
    // 只按桌号重连
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [table.no]);

  const send = useCallback((msg: ClientMsg) => {
    setError(null);
    if (!sendRef.current(msg)) setError("和牌桌的连接断了，正在重连…");
  }, []);
  const clearError = useCallback(() => setError(null), []);
  return { view, skew, error, connected, closed, send, clearError };
}

/**
 * 在后台连着自己坐着的其他几张桌：保持在线（不算掉线），并且知道哪张桌轮到自己行动。
 * 返回每张桌最新的牌桌视图。
 */
export function useSeatWatch(tables: Info[]): Map<number, TableView> {
  const [views, setViews] = useState<Map<number, TableView>>(new Map());
  const key = tables.map((t) => t.no).sort((a, b) => a - b).join();

  useEffect(() => {
    const conns = tables.map((t) =>
      connect(t, {
        onMsg: (msg) => {
          if (msg.t === "state") setViews((m) => new Map(m).set(t.no, msg.view));
          else if (msg.t === "closed") setViews((m) => ((m = new Map(m)), m.delete(t.no), m));
        },
        onOpen: () => {},
      }),
    );
    setViews((m) => new Map([...m].filter(([no]) => tables.some((t) => t.no === no))));
    return () => conns.forEach((c) => c.close());
    // 只按桌号集合重连
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  return views;
}
