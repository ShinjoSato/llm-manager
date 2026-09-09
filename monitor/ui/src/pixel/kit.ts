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

export function itemFor(tool: string | null): Item | null {
  if (!tool) return null;
  // Agent は子が出るので持ち物にしない。
  if (tool === "Agent" || tool === "Task") return null;
  return ITEMS[tool] ?? FALLBACK;
}

export interface Job {
  label: string;
  /** 明色（頭・上半身）と濃色（胴）。 */
  light: string;
  dark: string;
}

const JOBS: Record<string, Job> = {
  "developer-plugin:code-reviewer": { label: "監査役", light: "#fbbf24", dark: "#b45309" },
  "developer-plugin:swiftui-implementer": { label: "iOS職人", light: "#60a5fa", dark: "#1d4ed8" },
  "developer-plugin:go-api-implementer": { label: "サーバ職人", light: "#22d3ee", dark: "#0e7490" },
  "developer-plugin:ios-sim-tester": { label: "試験官", light: "#4ade80", dark: "#15803d" },
  "developer-plugin:ios-context-scout": { label: "斥候", light: "#c084fc", dark: "#7e22ce" },
  "developer-plugin:pr-verifier": { label: "検証官", light: "#f472b6", dark: "#be185d" },
  "developer-plugin:agent-scout": { label: "斥候", light: "#c084fc", dark: "#7e22ce" },
  "developer-plugin:prompt-analyst": { label: "記録係", light: "#a3e635", dark: "#4d7c0f" },
  "appstore-plugin:appstore-review": { label: "審査官", light: "#fb923c", dark: "#c2410c" },
  "appstore-plugin:appstore-meta-inspector": { label: "調査役", light: "#fb923c", dark: "#c2410c" },
  "fable-mode-plugin:fable-verifier": { label: "検証官", light: "#f472b6", dark: "#be185d" },
  "fable-mode-plugin:fable-judge": { label: "審判", light: "#facc15", dark: "#a16207" },
  "fable-mode-plugin:fable-ui-reviewer": { label: "意匠番", light: "#e879f9", dark: "#a21caf" },
  Explore: { label: "斥候", light: "#c084fc", dark: "#7e22ce" },
  Plan: { label: "軍師", light: "#818cf8", dark: "#4338ca" },
  "general-purpose": { label: "何でも屋", light: "#94a3b8", dark: "#475569" },
};

const UNKNOWN_JOB: Job = { label: "従者", light: "#94a3b8", dark: "#475569" };

export function jobFor(type: string | null): Job {
  if (!type) return UNKNOWN_JOB;
  return JOBS[type] ?? UNKNOWN_JOB;
}

/** `developer-plugin:dev-done` → `dev-done`。巻物の銘として出す。 */
export function skillLabel(skill: string): string {
  const i = skill.indexOf(":");
  return i >= 0 ? skill.slice(i + 1) : skill;
}
