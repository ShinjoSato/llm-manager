import { ShieldQuestion } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { PendingPermission } from "../../../src/types.js";
import { readResult } from "../api.js";

type Phase = "idle" | "sending" | "error";

const DECIDE_TIMEOUT_MS = 20_000;
/** 確認を出しっぱなしにしない。押し忘れて残った「許可する」を後から踏むのを防ぐ。 */
const CONFIRM_TIMEOUT_MS = 6_000;

/**
 * 保留中の権限確認 1 件。拒否は 1 押し、許可だけ確認を挟む（誤クリックで通さないため）。
 * 答えると保留が消え、SSE の更新でこの要素ごと消える。
 */
export function PermissionPrompt({
  permission,
  showProject,
}: {
  permission: PendingPermission;
  /** セッションに紐づけられなかった分だけ、どのプロジェクトかを併記する。 */
  showProject?: boolean;
}) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  const confirmTimer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(confirmTimer.current), []);

  function askConfirm() {
    setConfirming(true);
    window.clearTimeout(confirmTimer.current);
    confirmTimer.current = window.setTimeout(() => setConfirming(false), CONFIRM_TIMEOUT_MS);
  }

  function cancelConfirm() {
    window.clearTimeout(confirmTimer.current);
    setConfirming(false);
  }

  async function decide(decision: "allow" | "deny") {
    if (phase === "sending") return;
    cancelConfirm();
    setPhase("sending");
    setError(null);

    const abort = new AbortController();
    const timer = window.setTimeout(() => abort.abort(), DECIDE_TIMEOUT_MS);
    try {
      const res = await fetch(`/api/permissions/${permission.requestId}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ decision }),
        signal: abort.signal,
      });
      const json = await readResult(res);
      // 成功なら保留が消え、この要素も次の更新で消える。失敗した時だけ文言を残す。
      if (json.ok) return;
      setError(json.error ?? "答えられませんでした");
      setPhase("error");
    } catch (e) {
      setError(abort.signal.aborted ? "応答がありませんでした" : String(e));
      setPhase("error");
    } finally {
      window.clearTimeout(timer);
    }
  }

  const busy = phase === "sending";

  return (
    <div className="mt-2 rounded-xl border border-amber-400/30 bg-amber-400/5 p-2.5">
      <div className="mb-1 flex items-center gap-1.5">
        <ShieldQuestion size={12} className="shrink-0 text-amber-300" />
        <span className="text-[11px] font-semibold text-amber-200">権限の確認</span>
        <span className="chip font-mono">{permission.toolName}</span>
        {showProject && permission.project && (
          <span className="min-w-0 truncate text-[11px] text-slate-400">{permission.project}</span>
        )}
      </div>

      {permission.description && (
        <div className="mb-1 break-words text-[12px] text-slate-300">{permission.description}</div>
      )}
      {permission.inputPreview && (
        <pre
          className="mb-2 max-h-[120px] overflow-auto rounded-lg border border-white/10 bg-black/30 px-2 py-1.5
                     font-mono text-[11px] whitespace-pre-wrap break-all text-slate-300"
        >
          {permission.inputPreview}
        </pre>
      )}

      <div className="flex flex-wrap items-center gap-1.5">
        <button
          onClick={() => void decide("deny")}
          disabled={busy}
          className="chip inline-flex items-center gap-1 border-rose-400/30 bg-rose-500/10 text-rose-200
                     transition hover:bg-rose-500/20"
        >
          拒否
        </button>
        <button
          onClick={askConfirm}
          disabled={busy || confirming}
          title="押すともう一度たしかめます"
          className={`chip inline-flex items-center gap-1 transition hover:bg-white/10 ${
            busy || confirming ? "opacity-50" : ""
          }`}
        >
          許可
        </button>
        <span className="min-w-0 truncate text-[11px] text-slate-500">
          {permission.requestId}
        </span>
      </div>

      {/* 確認は別の行に出す。許可を押した指の下に「許可する」を置かないため。 */}
      {confirming && (
        <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
          <span className="text-[11px] text-amber-200">このツール実行を許可しますか？</span>
          <button
            onClick={() => void decide("allow")}
            disabled={busy}
            className="chip inline-flex items-center gap-1 border-emerald-400/30 bg-emerald-500/10 text-emerald-200
                       transition hover:bg-emerald-500/20"
          >
            はい、許可する
          </button>
          <button
            onClick={cancelConfirm}
            className="chip inline-flex items-center gap-1 transition hover:bg-white/10"
          >
            やめる
          </button>
        </div>
      )}

      {phase === "error" && error && (
        <div className="mt-1.5 break-words text-[11px] text-rose-300">{error}</div>
      )}
    </div>
  );
}
