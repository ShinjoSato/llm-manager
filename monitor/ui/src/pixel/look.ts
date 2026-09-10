// 状態ごとの姿勢・色・頭上マーク。2D 表示と 3D 表示で同じ絵を使う。
import type { Palette } from "./PixelArt.js";
import type { SessionStatus } from "../../../src/types.js";
import { SKIN } from "./kit.js";
import {
  AGENT_DOWN,
  AGENT_SIT,
  AGENT_STAND,
  MARK_BANG,
  MARK_QUESTION,
  MARK_SLEEP,
  type Sprite,
} from "./sprites.js";

export interface Look {
  sprite: Sprite;
  palette: Palette;
  mark?: Sprite;
  markPalette?: Palette;
  /** その状態が何を意味するか。ラベル自体は status.ts の 1 箇所に持たせる。 */
  note: string;
}

export const LOOK: Record<SessionStatus, Look> = {
  working: {
    sprite: AGENT_STAND,
    palette: { ...SKIN, G: "#34d399", B: "#10b981", D: "#0f766e" },
    note: "ツールを実行しているか、応答を組み立てている",
  },
  permission: {
    sprite: AGENT_STAND,
    palette: { ...SKIN, G: "#fbbf24", B: "#d97706", D: "#92400e" },
    mark: MARK_BANG,
    markPalette: { A: "#fbbf24" },
    note: "許可を求めて止まっている。あなたの操作が要る",
  },
  waiting: {
    sprite: AGENT_STAND,
    palette: { ...SKIN, G: "#60a5fa", B: "#2563eb", D: "#1e40af" },
    mark: MARK_QUESTION,
    markPalette: { A: "#60a5fa" },
    note: "問いかけたまま止まっている。あなたの返答が要る",
  },
  error: {
    sprite: AGENT_DOWN,
    palette: { ...SKIN, G: "#f87171", B: "#dc2626", D: "#991b1b" },
    note: "API エラーなどでターンが終わっている",
  },
  idle: {
    sprite: AGENT_SIT,
    palette: { S: "#cbb99c", K: "#0a0e14", G: "#64748b", B: "#475569", D: "#334155" },
    mark: MARK_SLEEP,
    markPalette: { A: "#64748b" },
    note: "応答を終えて次の指示を待っている",
  },
  stopped: {
    sprite: AGENT_SIT,
    palette: { S: "#8b8378", K: "#1e293b", G: "#3f4c5e", B: "#334155", D: "#1e293b" },
    note: "プロセスが終了している（5 分で一覧から消える）",
  },
};

export const FALLBACK_MARK: Palette = { A: "#94a3b8" };

export function lookOf(status: SessionStatus): Look {
  return LOOK[status] ?? LOOK.idle;
}

/** 頭上マークの位置。座り姿勢は頭が下がるぶん下げる。 */
export function markTop(status: SessionStatus): string {
  return status === "idle" || status === "stopped" ? "top-6" : "top-0";
}
