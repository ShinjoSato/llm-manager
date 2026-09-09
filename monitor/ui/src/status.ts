import type { SessionStatus } from "../../src/types.js";

export interface StatusStyle {
  label: string;
  dot: string;
  badge: string;
  bar: string;
  /** 目を引かせたい状態ほど小さい値。カードの並び順に使う。 */
  rank: number;
  breathe: boolean;
}

export const STATUS: Record<SessionStatus, StatusStyle> = {
  permission: {
    label: "権限待ち",
    dot: "bg-amber-400",
    badge: "border-amber-400/30 bg-amber-400/10 text-amber-300",
    bar: "bg-amber-400/70",
    rank: 0,
    breathe: true,
  },
  waiting: {
    label: "入力待ち",
    dot: "bg-sky-400",
    badge: "border-sky-400/30 bg-sky-400/10 text-sky-300",
    bar: "bg-sky-400/70",
    rank: 1,
    breathe: true,
  },
  error: {
    label: "エラー",
    dot: "bg-rose-400",
    badge: "border-rose-400/40 bg-rose-500/15 text-rose-300",
    bar: "bg-rose-400/70",
    rank: 2,
    breathe: true,
  },
  working: {
    label: "稼働中",
    dot: "bg-emerald-400",
    badge: "border-emerald-400/30 bg-emerald-400/10 text-emerald-300",
    bar: "bg-emerald-400/70",
    rank: 3,
    breathe: true,
  },
  idle: {
    label: "待機",
    dot: "bg-slate-500",
    badge: "border-white/12 bg-white/5 text-slate-300",
    bar: "bg-slate-600/70",
    rank: 4,
    breathe: false,
  },
  stopped: {
    label: "終了",
    dot: "bg-slate-700",
    badge: "border-white/8 bg-white/[0.03] text-slate-500",
    bar: "bg-slate-700/60",
    rank: 5,
    breathe: false,
  },
};

export function styleOf(status: SessionStatus): StatusStyle {
  return STATUS[status] ?? STATUS.idle;
}
