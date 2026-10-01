// 「あなたの返答待ち」で止まっているセッションの扱い。hub から切り出して単体で試せるようにする。
import type { SessionStatus } from "./types.js";

/** 人の操作が要る状態。画面で強調し、待ち時間を数える対象。 */
export function needsAttention(status: SessionStatus | null): boolean {
  return status === "permission" || status === "waiting" || status === "error";
}

/** 前のフックの待ちがまだ続いているか。フックより新しいログ活動があれば、その待ちには答えが出ている。 */
export function heldStatus(
  hookStatus: SessionStatus | null,
  hookAt: number,
  lastActivityAt: number,
): SessionStatus | null {
  return lastActivityAt > hookAt ? null : hookStatus;
}

/**
 * 待ち始めの時刻を更新する。要対応の間に種類が変わっても（権限待ち→入力待ち）待たされ続けているので引き継ぐ。
 */
export function nextAttentionSince(
  prevStatus: SessionStatus | null,
  prevSince: number | null,
  nextStatus: SessionStatus | null,
  now: number,
): number | null {
  if (!needsAttention(nextStatus)) return null;
  if (needsAttention(prevStatus) && prevSince !== null) return prevSince;
  return now;
}

/** 通知文「… permission to use X」から X を取り出す。形が違えば null。 */
export function toolFromMessage(message: string | null): string | null {
  const m = message?.match(/permission to use ([\w.:-]+)/i);
  return m?.[1] ?? null;
}

/**
 * 権限待ちで何を聞かれているかの一行。フックは tool_name しか持たないことが多いので、
 * ログから読んだ直前のツールの説明（同じツールと確かめられた時だけ）を添える。
 */
export function permissionDetail(
  toolName: string | null,
  message: string | null,
  currentTool: string | null,
  currentAction: string | null,
): string | null {
  const base = toolName || message || null;
  // 別のツールの説明を添えると、違う操作の許可を求めているように読めてしまう。
  const asked = toolName || toolFromMessage(message);
  const action = currentAction && asked && asked === currentTool ? currentAction : null;
  if (!action) return base;
  if (!base) return action;
  return `${base}: ${action}`;
}
