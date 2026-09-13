import { CodeXml, Hammer, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { readResult } from "../api.js";

type OpenApp = "vscode" | "xcode";
type Phase = "idle" | "opening" | "opened" | "closing" | "closed" | "error";
type CloseState = "closed" | "not_open" | "not_running";

const OPEN_TIMEOUT_MS = 20_000;
const RESET_DELAY_MS = 2_000;
/** 確認を出しっぱなしにしない。押し忘れて残った「はい」を後から踏むのを防ぐ。 */
const CONFIRM_TIMEOUT_MS = 6_000;

/** 未保存の変更があると Xcode が確認ダイアログを出すので、閉じたとは断定しない。 */
const CLOSE_NOTES: Record<CloseState, string> = {
  closed: "閉じるよう伝えました",
  not_open: "Xcode では開いていません",
  not_running: "Xcode は起動していません",
};

/** そのセッションの作業場所をエディタで開く／閉じる。対象はサーバーが sessionId から引く。 */
export function OpenButtons({
  sessionId,
  xcodeProject,
}: {
  sessionId: string;
  /** 無いセッションでは Xcode のボタンを出さない。 */
  xcodeProject: string | null;
}) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [pending, setPending] = useState<OpenApp | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  const resetTimer = useRef<number | undefined>(undefined);
  const confirmTimer = useRef<number | undefined>(undefined);

  useEffect(
    () => () => {
      window.clearTimeout(resetTimer.current);
      window.clearTimeout(confirmTimer.current);
    },
    [],
  );

  const busy = phase === "opening" || phase === "closing";

  function askConfirm() {
    setConfirming(true);
    window.clearTimeout(confirmTimer.current);
    confirmTimer.current = window.setTimeout(() => setConfirming(false), CONFIRM_TIMEOUT_MS);
  }

  function cancelConfirm() {
    window.clearTimeout(confirmTimer.current);
    setConfirming(false);
  }

  async function open(app: OpenApp) {
    if (busy) return;
    // 前回の後始末タイマーが、これから出す結果を消さないように止める。
    window.clearTimeout(resetTimer.current);
    setPhase("opening");
    setPending(app);
    setError(null);

    const abort = new AbortController();
    const timer = window.setTimeout(() => abort.abort(), OPEN_TIMEOUT_MS);
    try {
      const res = await fetch(`/api/sessions/${sessionId}/open`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ app }),
        signal: abort.signal,
      });
      const json = await readResult(res);
      if (json.ok) {
        setPhase("opened");
        resetTimer.current = window.setTimeout(() => setPhase("idle"), RESET_DELAY_MS);
      } else {
        setError(json.error ?? "開けませんでした");
        setPhase("error");
      }
    } catch (e) {
      setError(abort.signal.aborted ? "応答がありませんでした" : String(e));
      setPhase("error");
    } finally {
      window.clearTimeout(timer);
      setPending(null);
    }
  }

  async function closeXcode() {
    if (busy) return;
    cancelConfirm();
    window.clearTimeout(resetTimer.current);
    setPhase("closing");
    setError(null);
    setNote(null);

    const abort = new AbortController();
    const timer = window.setTimeout(() => abort.abort(), OPEN_TIMEOUT_MS);
    try {
      const res = await fetch(`/api/sessions/${sessionId}/close`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ app: "xcode" }),
        signal: abort.signal,
      });
      const json = (await readResult(res)) as { ok: boolean; error?: string; state?: CloseState };
      if (json.ok) {
        setNote(CLOSE_NOTES[json.state ?? "closed"] ?? CLOSE_NOTES.closed);
        setPhase("closed");
        resetTimer.current = window.setTimeout(() => setPhase("idle"), RESET_DELAY_MS * 2);
      } else {
        setError(json.error ?? "閉じられませんでした");
        setPhase("error");
      }
    } catch (e) {
      setError(abort.signal.aborted ? "応答がありませんでした" : String(e));
      setPhase("error");
    } finally {
      window.clearTimeout(timer);
    }
  }

  const cls = (app: OpenApp) =>
    `chip inline-flex items-center gap-1 transition hover:bg-white/10 ${
      phase === "opening" && pending === app ? "opacity-50" : ""
    }`;

  return (
    <div className="mt-2 flex items-center gap-1.5 border-t border-white/8 pt-2">
      <button onClick={() => void open("vscode")} disabled={busy} className={cls("vscode")}>
        <CodeXml size={11} className="shrink-0 text-slate-500" />
        VSCode
      </button>
      {xcodeProject && (
        <button
          onClick={() => void open("xcode")}
          disabled={busy}
          title={xcodeProject}
          className={cls("xcode")}
        >
          <Hammer size={11} className="shrink-0 text-slate-500" />
          Xcode
        </button>
      )}
      {xcodeProject &&
        (confirming ? (
          <>
            <span className="text-[11px] text-slate-400">閉じますか？</span>
            <button
              onClick={() => void closeXcode()}
              disabled={busy}
              className="chip inline-flex items-center gap-1 border-rose-400/30 bg-rose-500/10 text-rose-200 transition hover:bg-rose-500/20"
            >
              はい
            </button>
            <button
              onClick={cancelConfirm}
              className="chip inline-flex items-center gap-1 transition hover:bg-white/10"
            >
              やめる
            </button>
          </>
        ) : (
          <button
            onClick={askConfirm}
            disabled={busy}
            title={`Xcode から閉じる: ${xcodeProject}`}
            className={`chip inline-flex items-center gap-1 transition hover:bg-white/10 ${
              phase === "closing" ? "opacity-50" : ""
            }`}
          >
            <X size={11} className="shrink-0 text-slate-500" />
            閉じる
          </button>
        ))}
      {phase === "error" && error && (
        <span className="min-w-0 truncate text-[11px] text-rose-300">{error}</span>
      )}
      {phase === "opened" && <span className="text-[11px] text-emerald-300">開きました</span>}
      {phase === "closed" && note && (
        <span className="min-w-0 truncate text-[11px] text-emerald-300">{note}</span>
      )}
    </div>
  );
}
