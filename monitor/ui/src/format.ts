const pad = (n: number) => String(n).padStart(2, "0");

export function clock(ts: number): string {
  const d = new Date(ts);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

/** now を引数に取り、経過時間の再計算を React の再描画に委ねる。 */
export function ago(ts: number | null, now: number): string {
  if (!ts) return "—";
  const s = Math.max(0, Math.floor((now - ts) / 1000));
  if (s < 60) return `${s}秒前`;
  if (s < 3600) return `${Math.floor(s / 60)}分前`;
  if (s < 86400) return `${Math.floor(s / 3600)}時間前`;
  return `${Math.floor(s / 86400)}日前`;
}

export function dur(ts: number | null, now: number): string {
  if (!ts) return "—";
  const s = Math.max(0, Math.floor((now - ts) / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}時間${m}分` : `${m}分`;
}

/** 返答待ちの長さ。止まっている事実が伝わるよう、1 分未満も秒で出す。 */
export function waited(ts: number | null, now: number, verb = "待っています"): string | null {
  if (!ts) return null;
  const s = Math.max(0, Math.floor((now - ts) / 1000));
  if (s < 60) return `${s}秒${verb}`;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}時間${m}分${verb}` : `${m}分${verb}`;
}

/** 未来の時刻までの残り。dur の向き違い。 */
export function until(ts: number | null, now: number): string {
  if (!ts) return "—";
  const s = Math.max(0, Math.floor((ts - now) / 1000));
  if (s < 60) return "まもなく";
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}時間${m}分後` : `${m}分後`;
}

// statusline は Claude Code が動いている間しか呼ばれない。これを超えたら古い値として扱う。
export const USAGE_STALE_MS = 10 * 60_000;

/** 上限ウィンドウの残り%。使用率は 0〜100 に収める。 */
export function remainingPct(used: number): number {
  return Math.max(0, Math.min(100, 100 - used));
}

export function kilo(n: number): string {
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n);
}
