// ツール・サブエージェント種別を、持ち物と職業に対応づける。
import {
  ITEM_BOOK,
  ITEM_CANVAS,
  ITEM_HAMMER,
  ITEM_NOTE,
  ITEM_QUESTION,
  ITEM_SCOPE,
  ITEM_SCROLL,
  ITEM_TERMINAL,
  type Sprite,
} from "./sprites.js";
import type { Palette } from "./PixelArt.js";

export interface Item {
  sprite: Sprite;
  palette: Palette;
  /** 一言に使う動詞。「〜している」の形。 */
  verb: string;
}

const METAL: Palette = { M: "#cbd5e1", T: "#a16207", K: "#334155", W: "#e2e8f0", L: "#64748b", G: "#34d399", P: "#a16207" };

const ITEMS: Record<string, Item> = {
  Bash: { sprite: ITEM_TERMINAL, palette: { ...METAL, K: "#475569", G: "#34d399" }, verb: "端末を叩いている" },
  Read: { sprite: ITEM_BOOK, palette: METAL, verb: "本を読んでいる" },
  Grep: { sprite: ITEM_BOOK, palette: METAL, verb: "書物を探っている" },
  Glob: { sprite: ITEM_BOOK, palette: METAL, verb: "書物を探っている" },
  Edit: { sprite: ITEM_HAMMER, palette: METAL, verb: "槌を振るっている" },
  Write: { sprite: ITEM_HAMMER, palette: METAL, verb: "槌を振るっている" },
  NotebookEdit: { sprite: ITEM_HAMMER, palette: METAL, verb: "槌を振るっている" },
  Skill: { sprite: ITEM_SCROLL, palette: { ...METAL, P: "#f59e0b", L: "#92400e" }, verb: "巻物を広げている" },
  WebFetch: { sprite: ITEM_SCOPE, palette: METAL, verb: "遠くを覗いている" },
  WebSearch: { sprite: ITEM_SCOPE, palette: METAL, verb: "遠くを覗いている" },
  ToolSearch: { sprite: ITEM_SCOPE, palette: METAL, verb: "道具を探している" },
  AskUserQuestion: { sprite: ITEM_QUESTION, palette: { ...METAL, G: "#fbbf24" }, verb: "問いかけている" },
  Artifact: { sprite: ITEM_CANVAS, palette: { ...METAL, G: "#22d3ee" }, verb: "画布に描いている" },
  TodoWrite: { sprite: ITEM_NOTE, palette: METAL, verb: "帳面をつけている" },
  SendUserFile: { sprite: ITEM_NOTE, palette: METAL, verb: "書簡を届けている" },
  SendMessage: { sprite: ITEM_NOTE, palette: METAL, verb: "文を送っている" },
};

const FALLBACK: Item = { sprite: ITEM_NOTE, palette: METAL, verb: "手を動かしている" };

export function itemFor(tool: string | null, skill?: string | null): Item | null {
  // スキル実行中は配下のツールが次々変わるので、巻物を持たせ続ける。
  if (skill) return ITEMS.Skill!;
  if (!tool) return null;
  // Agent は子が出るので持ち物にしない。
  if (tool === "Agent" || tool === "Task") return null;
  return ITEMS[tool] ?? FALLBACK;
}

/** 一言に使う動作だけを取り出す。 */
export function itemForVerb(tool: string | null): string | null {
  return itemFor(tool)?.verb ?? null;
}

/** 肌と目の色は職業によらず共通。 */
export const SKIN: Palette = { S: "#f6d3ab", K: "#0a0e14" };

const jobPalettes = new Map<string, Palette>();

/** 同じ色の組み合わせでは同じオブジェクトを返す。毎回作ると memo が外れる。 */
export function jobPalette(job: Job): Palette {
  const key = `${job.light}/${job.dark}`;
  let p = jobPalettes.get(key);
  if (!p) {
    p = { ...SKIN, C: job.light, E: job.dark, F: job.dark };
    jobPalettes.set(key, p);
  }
  return p;
}

export interface Job {
  label: string;
  /** 何をする役割か。ツールチップで出す。 */
  role: string;
  /** 明色（頭・上半身）と濃色（胴）。 */
  light: string;
  dark: string;
}

const JOBS: Record<string, Job> = {
  "developer-plugin:code-reviewer": { label: "監査役", role: "差分を静的にレビューする", light: "#fbbf24", dark: "#b45309" },
  "developer-plugin:swiftui-implementer": { label: "iOS職人", role: "iOS（SwiftUI）を実装する", light: "#60a5fa", dark: "#1d4ed8" },
  "developer-plugin:go-api-implementer": { label: "サーバ職人", role: "Go の API と DB 層を実装する", light: "#22d3ee", dark: "#0e7490" },
  "developer-plugin:ios-sim-tester": { label: "試験官", role: "シミュレータで操作して確かめる", light: "#4ade80", dark: "#15803d" },
  "developer-plugin:ios-context-scout": { label: "斥候", role: "既存構成を調べて地図を返す", light: "#c084fc", dark: "#7e22ce" },
  "developer-plugin:pr-verifier": { label: "検証官", role: "PR を実際に動かして検証する", light: "#f472b6", dark: "#be185d" },
  "developer-plugin:agent-scout": { label: "斥候", role: "agents / skills 構成を診断する", light: "#c084fc", dark: "#7e22ce" },
  "developer-plugin:prompt-analyst": { label: "記録係", role: "プロンプト履歴を分析する", light: "#a3e635", dark: "#4d7c0f" },
  "appstore-plugin:appstore-review": { label: "審査官", role: "App Store 審査観点で点検する", light: "#fb923c", dark: "#c2410c" },
  "appstore-plugin:appstore-meta-inspector": { label: "調査役", role: "App Store Connect の登録内容を読む", light: "#fb923c", dark: "#c2410c" },
  "fable-mode-plugin:fable-verifier": { label: "検証官", role: "実装への反証を試みる", light: "#f472b6", dark: "#be185d" },
  "fable-mode-plugin:fable-judge": { label: "審判", role: "複数案を採点して順位づける", light: "#facc15", dark: "#a16207" },
  "fable-mode-plugin:fable-ui-reviewer": { label: "意匠番", role: "UI の見た目を審査する", light: "#e879f9", dark: "#a21caf" },
  Explore: { label: "斥候", role: "広く探索して場所を特定する", light: "#c084fc", dark: "#7e22ce" },
  Plan: { label: "軍師", role: "実装の計画を立てる", light: "#818cf8", dark: "#4338ca" },
  "general-purpose": { label: "何でも屋", role: "汎用の調査・作業", light: "#94a3b8", dark: "#475569" },
};

const UNKNOWN_JOB: Job = {
  label: "従者",
  role: "種別が判別できないサブエージェント",
  light: "#94a3b8",
  dark: "#475569",
};

export function jobFor(type: string | null): Job {
  if (!type) return UNKNOWN_JOB;
  return JOBS[type] ?? UNKNOWN_JOB;
}

/** `developer-plugin:dev-done` → `dev-done`。巻物の銘として出す。 */
export function skillLabel(skill: string): string {
  const i = skill.indexOf(":");
  return i >= 0 ? skill.slice(i + 1) : skill;
}
