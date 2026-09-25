// Claude Code の使用量。statusline スクリプトが書いた data/claude-usage.json を読むだけ。
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { UsageSnapshot, UsageWindow } from "./types.js";

const HERE = dirname(fileURLToPath(import.meta.url));
export const USAGE_JSON = process.env.MONITOR_USAGE_FILE ?? join(HERE, "..", "..", "data", "claude-usage.json");

/** ファイルを読む。未生成・壊れていれば null（statusLine 未設定でも動くように）。 */
export function readUsage(path: string = USAGE_JSON): UsageSnapshot | null {
  try {
    return parseUsage(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

/** 読んだ JSON をドメイン型に落とす。書き手が変わっても壊れないよう値を検分する。 */
export function parseUsage(text: string): UsageSnapshot | null {
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
