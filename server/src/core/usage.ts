import { readFileSync } from "node:fs";
import { USAGE_JSON } from "./paths.js";
import type { UsageData, UsageWindow } from "../../../shared/types.js";

// Claude Code の 5時間 / 7日間ウィンドウの使用量。monitor/scripts/statusline.sh が書いたファイルを読むだけ。
// statusLine が未設定ならファイルが無いので、カレンダー未設定時と同じく null で no-op になる。

export function collectUsage(path: string = USAGE_JSON): UsageData | null {
  try {
    return parseUsage(readFileSync(path, "utf-8"));
  } catch {
    return null;
  }
}

/** 読んだ JSON をドメイン型に落とす。書き手が変わっても壊れないよう値を検分する。 */
export function parseUsage(text: string): UsageData | null {
  let o: unknown;
  try {
    o = JSON.parse(text);
  } catch {
    return null;
  }
  if (!o || typeof o !== "object") return null;
  const raw = o as Record<string, unknown>;
  const fetchedAt = num(raw.fetchedAt);
  if (fetchedAt === null) return null;
  const fiveHour = window(raw.fiveHour);
  const sevenDay = window(raw.sevenDay);
  if (!fiveHour && !sevenDay) return null;
  return { fetchedAt, fiveHour, sevenDay };
}

function window(v: unknown): UsageWindow | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const used = num(o.usedPercentage);
  if (used === null) return null;
  return { usedPercentage: used, resetsAt: num(o.resetsAt) };
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}
