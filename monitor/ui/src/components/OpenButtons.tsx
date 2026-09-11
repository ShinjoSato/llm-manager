import { CodeXml, Hammer } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { readResult } from "../api.js";

type OpenApp = "vscode" | "xcode";
type Phase = "idle" | "opening" | "opened" | "error";

const OPEN_TIMEOUT_MS = 20_000;
const RESET_DELAY_MS = 2_000;

/** そのセッションの作業場所をエディタで開く。開く先はサーバーが sessionId から引く。 */
export function OpenButtons({
  sessionId,
  xcodeProject,
}: {
  sessionId: string;
  /** 無いセッションでは Xcode ボタンを出さない。 */
  xcodeProject: string | null;
}) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [pending, setPending] = useState<OpenApp | null>(null);
  const [error, setError] = useState<string | null>(null);
  const resetTimer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(resetTimer.current), []);

  async function open(app: OpenApp) {
    if (phase === "opening") return;
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

  const cls = (app: OpenApp) =>
    `chip inline-flex items-center gap-1 transition hover:bg-white/10 ${
      phase === "opening" && pending === app ? "opacity-50" : ""
    }`;

  return (
    <div className="mt-2 flex items-center gap-1.5 border-t border-white/8 pt-2">
      <button onClick={() => void open("vscode")} disabled={phase === "opening"} className={cls("vscode")}>
        <CodeXml size={11} className="shrink-0 text-slate-500" />
        VSCode
      </button>
      {xcodeProject && (
        <button
          onClick={() => void open("xcode")}
          disabled={phase === "opening"}
          title={xcodeProject}
          className={cls("xcode")}
        >
          <Hammer size={11} className="shrink-0 text-slate-500" />
          Xcode
        </button>
      )}
      {phase === "error" && error && (
        <span className="min-w-0 truncate text-[11px] text-rose-300">{error}</span>
      )}
      {phase === "opened" && <span className="text-[11px] text-emerald-300">開きました</span>}
    </div>
  );
}
