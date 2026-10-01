// 「あなたの返答待ち」で止まっているセッションの扱い。hub から切り出して単体で試せるようにする。
import type { SessionStatus } from "./types.js";

/** 人の操作が要る状態。画面で強調し、待ち時間を数える対象。 */
export function needsAttention(status: SessionStatus | null): boolean {
  return status === "permission" || status === "waiting" || status === "error";
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

/**
 * 権限待ちで何を聞かれているかの一行。フックは tool_name しか持たないことが多いので、
 * ログから読んだ直前のツールの説明（同じツールの時だけ）を添える。
 */
export function permissionDetail(
  toolName: string | null,
  message: string | null,
  currentTool: string | null,
  currentAction: string | null,
): string | null {
  const base = toolName || message || null;
  // 別のツールの説明を添えると、違う操作の許可を求めているように読めてしまう。
  const action = currentAction && (!toolName || toolName === currentTool) ? currentAction : null;
  if (!action) return base;
  if (!base) return action;
  return `${base}: ${action}`;
}
