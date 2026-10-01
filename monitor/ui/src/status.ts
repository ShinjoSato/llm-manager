import type { SessionStatus } from "../../src/types.js";

export interface StatusStyle {
  label: string;
  dot: string;
  badge: string;
  bar: string;
  /** 目を引かせたい状態ほど小さい値。カードの並び順に使う。 */
  rank: number;
  breathe: boolean;
  /** 人の操作が要る。カードを縁取り、待ち時間と「ここで答える」を出す。 */
  attention: boolean;
  /** 要対応のカードの縁と地。要対応でなければ空。 */
  frame: string;
  /** 待ち時間や問いの文字色。 */
  ink: string;
  /** VSCode を開くボタンの文言と色。答える場所はあちらなので、押した先で何をするかを書く。 */
  answer: { label: string; tone: string } | null;
}

export const STATUS: Record<SessionStatus, StatusStyle> = {
  permission: {
    label: "権限待ち",
    dot: "bg-amber-400",
    badge: "border-amber-400/30 bg-amber-400/10 text-amber-300",
    bar: "bg-amber-400/70",
    rank: 0,
    breathe: true,
    attention: true,
    frame:
      "border-amber-400/60 bg-amber-400/[0.07] shadow-[0_0_28px_-6px_rgba(251,191,36,0.45)]",
    ink: "text-amber-200",
    answer: {
      label: "ここで答える",
      tone: "border-amber-300/50 bg-amber-400/15 text-amber-100 hover:bg-amber-400/25",
    },
  },
  waiting: {
    label: "入力待ち",
    dot: "bg-sky-400",
    badge: "border-sky-400/30 bg-sky-400/10 text-sky-300",
    bar: "bg-sky-400/70",
    rank: 1,
    breathe: true,
    attention: true,
    frame: "border-sky-400/60 bg-sky-400/[0.07] shadow-[0_0_28px_-6px_rgba(56,189,248,0.45)]",
    ink: "text-sky-200",
    answer: {
      label: "ここで答える",
      tone: "border-sky-300/50 bg-sky-400/15 text-sky-100 hover:bg-sky-400/25",
    },
  },
  error: {
    label: "エラー",
    dot: "bg-rose-400",
    badge: "border-rose-400/40 bg-rose-500/15 text-rose-300",
    bar: "bg-rose-400/70",
    rank: 2,
    breathe: true,
    attention: true,
    frame: "border-rose-400/60 bg-rose-500/[0.08] shadow-[0_0_28px_-6px_rgba(251,113,133,0.45)]",
    ink: "text-rose-200",
    answer: {
      label: "ここで再開する",
      tone: "border-rose-300/50 bg-rose-500/15 text-rose-100 hover:bg-rose-500/25",
    },
  },
  working: {
    label: "稼働中",
    dot: "bg-emerald-400",
    badge: "border-emerald-400/30 bg-emerald-400/10 text-emerald-300",
    bar: "bg-emerald-400/70",
    rank: 3,
    breathe: true,
    attention: false,
    frame: "",
    ink: "text-emerald-300",
    answer: null,
  },
  idle: {
    label: "待機",
    dot: "bg-slate-500",
    badge: "border-white/12 bg-white/5 text-slate-300",
    bar: "bg-slate-600/70",
    rank: 4,
    breathe: false,
    attention: false,
    frame: "",
    ink: "text-slate-300",
    answer: null,
  },
  stopped: {
    label: "終了",
    dot: "bg-slate-700",
    badge: "border-white/8 bg-white/[0.03] text-slate-500",
    bar: "bg-slate-700/60",
    rank: 5,
    breathe: false,
    attention: false,
    frame: "",
    ink: "text-slate-400",
    answer: null,
  },
};

export function styleOf(status: SessionStatus): StatusStyle {
  return STATUS[status] ?? STATUS.idle;
}
