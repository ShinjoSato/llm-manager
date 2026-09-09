import { Check, Send, X } from "lucide-react";
import { useState } from "react";

type Phase = "idle" | "sending" | "sent" | "error";

/** そのセッションの受信箱へ 1 通送る。届くのは指示ではなくメッセージ。 */
export function MessageInput({ sessionId, disabled }: { sessionId: string; disabled: boolean }) {
  const [text, setText] = useState("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);

  async function send() {
    const body = text.trim();
    if (!body || phase === "sending") return;
    setPhase("sending");
    setError(null);
    try {
      const res = await fetch(`/api/sessions/${sessionId}/message`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: body }),
      });
      const json = (await res.json()) as { ok: boolean; error?: string };
      if (json.ok) {
        setText("");
        setPhase("sent");
        window.setTimeout(() => setPhase("idle"), 2000);
      } else {
        setError(json.error ?? "送信できませんでした");
        setPhase("error");
      }
    } catch (e) {
      setError(String(e));
      setPhase("error");
    }
  }

  if (disabled) return null;

  return (
    <div className="mt-2 border-t border-white/8 pt-2">
      <div className="flex items-center gap-1.5">
        <input
          value={text}
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
                     text-slate-200 placeholder:text-slate-600 focus:border-emerald-400/40 focus:outline-none"
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
      {phase === "sent" && <div className="mt-1 text-[11px] text-emerald-300">届けました</div>}
    </div>
  );
}
