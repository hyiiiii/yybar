// 预览版的牌桌：没有服务端，直接在浏览器里跑 src/shared/poker 的牌局，其他座位是机器人。
import { TableRoom } from "../shared/poker/room";
import type { ClientMsg, ServerMsg } from "../shared/poker/types";
import type { TableInfo } from "./tables";
import { demoBadge, demoEmotes, demoLook, demoSpend } from "./demo";

const YOU = { userId: 1, login: "hyiiiii", avatarUrl: null };
const PEOPLE = ["nightowl", "token-burner", "vibe-coder", "mia", "lazy-dev"];
const BOTS = ["bot-紧凶", "bot-松鱼", "bot-跟注站", "bot-诈唬王", "bot-老实人"];

/** 预览里的筹码余额，和示例个人页一致 */
let balance = 160_581;

export function localBalance() {
  return balance;
}

/** 预览里在商场买东西 */
export function spendLocal(n: number) {
  balance -= n;
}

interface Local {
  room: TableRoom;
  timer?: ReturnType<typeof setTimeout>;
  listeners: Set<(msg: ServerMsg) => void>;
}

// 切走的桌子照样在后台打，切回来能接着看
const rooms = new Map<number, Local>();

function emit(t: Local) {
  const now = Date.now();
  t.room.checkEmpty(now);
  if (t.room.closable(now)) {
    clearTimeout(t.timer);
    rooms.delete(t.room.s.config.no);
    for (const fn of t.listeners) fn({ t: "closed" });
    return;
  }
  const view = t.room.view(YOU.userId, now);
  for (const fn of t.listeners) fn({ t: "state", view });
  // 预览版没有成就系统，牌桌上达成的直接丢掉
  t.room.s.unlocks = [];
  for (const c of t.room.s.cashouts) {
    balance += c.amount;
    t.room.ackCashout(c.ref);
  }
  clearTimeout(t.timer);
  const wake = t.room.nextWake();
  if (wake !== null) {
    t.timer = setTimeout(() => {
      t.room.tick(Date.now());
      emit(t);
    }, Math.max(0, wake - now));
  }
}

export function openLocalTable(
  info: Pick<TableInfo, "no" | "blinds" | "bots" | "seated" | "temporary">,
  onMsg: (msg: ServerMsg) => void,
) {
  let t = rooms.get(info.no);
  if (!t) {
    // 预览里自己开的桌没有别人会来，放三个机器人陪打；你走了桌就收掉
    const names = info.temporary ? BOTS.slice(0, 3) : (info.bots ? BOTS : PEOPLE).slice(0, Math.min(info.seated, 5));
    const room = TableRoom.create({
      no: info.no, sb: info.blinds[0], bb: info.blinds[1], bots: false, fixedBots: names, temporary: info.temporary,
    });
    t = { room, listeners: new Set() };
    rooms.set(info.no, t);
  }
  const local = t;
  local.listeners.add(onMsg);
  emit(local);

  const send = (msg: ClientMsg) => {
    const now = Date.now();
    let err: string | null = null;
    if (msg.t === "sit") {
      err = local.room.canSit(YOU.userId, msg.seat);
      const amount = local.room.pickBuyIn(balance, msg.buyIn);
      if (!err && typeof amount === "string") err = amount;
      if (!err && typeof amount === "number") {
        balance -= amount;
        err = local.room.sit({ ...YOU, back: demoLook().back, face: demoLook().face, badge: demoBadge() }, msg.seat, amount, now);
      }
    } else if (msg.t === "leave") err = local.room.leave(YOU.userId, now);
    else if (msg.t === "hold") err = local.room.hold(YOU, msg.seat, now);
    else if (msg.t === "release") local.room.release(YOU.userId);
    else if (msg.t === "show") err = local.room.show(YOU.userId, msg.which);
    else if (msg.t === "item") {
      err = local.room.canUseItem(YOU.userId, msg.item);
      if (!err) err = demoSpend(msg.item) ? local.room.useItem(YOU.userId, msg.item, now) : "这个道具用完了，去商场买一些";
    } else if (msg.t === "emote") err = local.room.emote(YOU.userId, msg.id, demoEmotes(), now);
    else if (msg.t === "act") err = local.room.act(YOU.userId, msg.action, msg.amount, now);
    if (err) onMsg({ t: "error", msg: err });
    emit(local);
  };
  return { send, close: () => local.listeners.delete(onMsg) };
}
