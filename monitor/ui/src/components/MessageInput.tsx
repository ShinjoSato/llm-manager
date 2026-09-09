import { Check, Send, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";

type Phase = "idle" | "sending" | "sent" | "error";

const MAX_CHARS = 100_000;
const SEND_TIMEOUT_MS = 20_000;
const RESET_DELAY_MS = 2_000;

/** そのセッションの受信箱へ 1 通送る。届くのは指示ではなくメッセージ。 */
export function MessageInput({ sessionId, disabled }: { sessionId: string; disabled: boolean }) {
  const [text, setText] = useState("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const resetTimer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(resetTimer.current), []);

  async function send() {
    const body = text.trim();
    if (!body || phase === "sending") return;
    // 前回の後始末タイマーが、これから出す結果を消さないように止める。
    window.clearTimeout(resetTimer.current);
    setPhase("sending");
    setError(null);

    const abort = new AbortController();
    const timer = window.setTimeout(() => abort.abort(), SEND_TIMEOUT_MS);
    try {
      const res = await fetch(`/api/sessions/${sessionId}/message`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: body }),
        signal: abort.signal,
      });
      const json = (await res.json()) as { ok: boolean; error?: string };
      if (json.ok) {
        setText("");
        setPhase("sent");
        resetTimer.current = window.setTimeout(() => setPhase("idle"), RESET_DELAY_MS);
      } else {
        setError(json.error ?? "送信できませんでした");
        setPhase("error");
      }
    } catch (e) {
      setError(abort.signal.aborted ? "応答がありませんでした" : String(e));
      setPhase("error");
    } finally {
      window.clearTimeout(timer);
    }
  }

  if (disabled) return null;

  return (
    <div className="mt-2 border-t border-white/8 pt-2">
      <div className="flex items-center gap-1.5">
        <input
          value={text}
          maxLength={MAX_CHARS}
          disabled={phase === "sending"}
          onChange={(e) => {
            setText(e.target.value);
            if (phase === "error") setPhase("idle");
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) void send();
          }}
          placeholder="伝言を送る…"
          aria-label="このセッションへメッセージを送る"
          className="min-w-0 flex-1 rounded-lg border border-white/10 bg-white/5 px-2.5 py-1.5 text-[12px]
                     text-slate-200 placeholder:text-slate-600 focus:border-emerald-400/40 focus:outline-none
                     disabled:opacity-50"
        />
        <button
          onClick={() => void send()}
          disabled={!text.trim() || phase === "sending"}
          aria-label="送信"
          className="grid h-[30px] w-[30px] shrink-0 place-items-center rounded-lg border border-white/10
                     bg-white/5 text-slate-300 transition hover:bg-white/10 disabled:opacity-40"
        >
          {phase === "sent" ? (
            <Check size={13} className="text-emerald-300" />
          ) : phase === "error" ? (
            <X size={13} className="text-rose-300" />
          ) : (
            <Send size={13} className={phase === "sending" ? "opacity-50" : ""} />
          )}
        </button>
      </div>
      {phase === "error" && error && (
        <div className="mt-1 truncate text-[11px] text-rose-300">{error}</div>
      )}
      {phase === "sent" && <div className="mt-1 text-[11px] text-emerald-300">送信しました</div>}
    </div>
  );
}
