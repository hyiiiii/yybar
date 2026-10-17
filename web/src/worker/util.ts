const encoder = new TextEncoder();

export function randomToken(bytes = 32): string {
  const buf = crypto.getRandomValues(new Uint8Array(bytes));
  return base64url(buf);
}

export function base64url(buf: Uint8Array): string {
  let s = "";
  for (const b of buf) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function nowIso(): string {
  return new Date().toISOString();
}

/** 把 App 发来的十进制美元字符串（如 "1.2345678"）转成微美元整数，第 7 位小数四舍五入。 */
export function parseCostMicro(value: unknown): number | null {
  if (typeof value === "number") value = String(value);
  if (typeof value !== "string") return null;
  const m = /^(\d{1,9})(?:\.(\d+))?$/.exec(value.trim());
  if (!m) return null;
  const frac = (m[2] ?? "").padEnd(7, "0");
  let micro = Number(m[1]) * 1_000_000 + Number(frac.slice(0, 6));
  if (Number(frac[6]) >= 5) micro += 1;
  return micro;
}

/** 1 美元 = 100 积分。 */
export const MICRO_PER_POINT = 10_000;

export function pointsFromMicro(micro: number): number {
  return Math.floor(micro / MICRO_PER_POINT);
}

export function isoDay(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return isoDay(d);
}
