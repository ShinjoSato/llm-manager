import { useEffect, useRef, useState } from "react";
import type { SessionSnapshot, SessionStatus } from "../../src/types.js";

const STORAGE_KEY = "monitor.notify";
/**
 * 同じセッションで鳴らし続けないための間隔。
 * 許可プロンプトは数秒間隔で続くことがあるので、長くすると 2 つ目を取りこぼす。
 */
const COOLDOWN_MS = 4_000;

export interface NotifySetting {
  /** 応答が終わって次の指示待ちになった時。 */
  idle: boolean;
  /** 許可や返答を求めて止まった時。フック設定が要る。 */
  attention: boolean;
}

const DEFAULT: NotifySetting = { idle: false, attention: true };

const ATTENTION: SessionStatus[] = ["permission", "waiting", "error"];

/** その遷移で鳴らすか。初回（was が無い）と据え置きは鳴らさない。 */
export function shouldNotify(
  was: SessionStatus | undefined,
  now: SessionStatus,
  setting: NotifySetting,
): boolean {
  if (was === undefined || was === now) return false;
  if (setting.idle && now === "idle" && was === "working") return true;
  return setting.attention && ATTENTION.includes(now);
}

export function loadSetting(): NotifySetting {
  try {
    const o = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "null");
    if (!o || typeof o !== "object") return DEFAULT;
    return { idle: Boolean(o.idle), attention: Boolean(o.attention) };
  } catch {
    return DEFAULT;
  }
}

function saveSetting(s: NotifySetting): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(s));
  } catch {
    // 保存できなくても通知そのものは動かす。
  }
}

function labelFor(status: SessionStatus, detail: string | null): string {
  switch (status) {
    case "permission":
      return detail ? `許可を待っています: ${detail}` : "許可を待っています";
    case "waiting":
      return "入力を待っています";
    case "error":
      return detail ? `停止しました: ${detail}` : "停止しました";
    case "idle":
      return "応答が終わりました";
    default:
      return "状態が変わりました";
  }
}

/**
 * 状態が変わった瞬間だけ画面通知を出す。
 * 通知の許可はユーザー操作を起点に求める必要があるので、設定を有効にした時に要求する。
 */
export function useNotify(sessions: SessionSnapshot[]) {
  const [setting, setSetting] = useState<NotifySetting>(loadSetting);
  const [permission, setPermission] = useState<NotificationPermission | "unsupported">(() =>
    typeof Notification === "undefined" ? "unsupported" : Notification.permission,
  );
  const prev = useRef(new Map<string, SessionStatus>());
  const lastNotified = useRef(new Map<string, number>());

  useEffect(() => saveSetting(setting), [setting]);

  useEffect(() => {
    const before = prev.current;
    const now = Date.now();

    for (const s of sessions) {
      const was = before.get(s.sessionId);
      before.set(s.sessionId, s.status);
      if (!shouldNotify(was, s.status, setting)) continue;
      if (now - (lastNotified.current.get(s.sessionId) ?? 0) < COOLDOWN_MS) continue;

      lastNotified.current.set(s.sessionId, now);
      show(s);
    }

    // 消えたセッションの記録は残さない。
    const alive = new Set(sessions.map((s) => s.sessionId));
    for (const id of [...before.keys()]) if (!alive.has(id)) before.delete(id);
    for (const id of [...lastNotified.current.keys()]) {
      if (!alive.has(id)) lastNotified.current.delete(id);
    }
  }, [sessions, setting]);

  /** 通知の許可を求める。ユーザー操作からのみ呼べる。 */
  async function requestPermission() {
    if (typeof Notification === "undefined") return;
    try {
      const p = await Notification.requestPermission();
      // 古い実装はコールバック形式で undefined を返す。
      if (p) setPermission(p);
      else setPermission(Notification.permission);
    } catch {
      // 要求が失敗しても設定の変更は通す。
    }
  }

  /** 設定を変える。有効にする時は許可も求める。 */
  async function update(next: NotifySetting) {
    // 直前の値ではなく更新関数で反映する（許可ダイアログ中に別のトグルを押しても消えない）。
    setSetting(() => next);
    const wantsAny = next.idle || next.attention;
    if (wantsAny && typeof Notification !== "undefined" && Notification.permission === "default") {
      await requestPermission();
    }
  }

  /** 通知を出したいのに許可がまだ取れていない。 */
  const needsPermission = (setting.idle || setting.attention) && permission === "default";

  return { setting, permission, needsPermission, requestPermission, update };
}

function show(s: SessionSnapshot): void {
  if (typeof Notification === "undefined" || Notification.permission !== "granted") return;
  try {
    const n = new Notification(`${s.project}${s.branch ? ` (${s.branch})` : ""}`, {
      body: labelFor(s.status, s.statusDetail),
      tag: s.sessionId, // 同じセッションの通知は積み上げず置き換える
    });
    n.onclick = () => {
      window.focus();
      n.close();
    };
  } catch {
    // 通知が出せない状況でも画面は壊さない。
  }
}
