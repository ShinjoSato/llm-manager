import { GitBranch, Hourglass } from "lucide-react";
import { lazy, Suspense } from "react";
import type { PendingPermission, SessionSnapshot } from "../../../src/types.js";
import { ago, dur, kilo, waited } from "../format.js";
import { AgentStage } from "../pixel/AgentStage.js";
import { MessageInput } from "./MessageInput.js";
import { OpenButtons } from "./OpenButtons.js";
import { PermissionPrompt } from "./PermissionPrompt.js";
import { itemForVerb, jobFor, skillLabel } from "../pixel/kit.js";
import { styleOf } from "../status.js";

// 立体表示に切り替えた時だけ three.js を読み込む。2D のままなら一切読まない。
const VoxelArt = lazy(() => import("../three/VoxelArt.js"));

/** いま何をしているかの一行。スキルの銘 > 具体的な説明 > 持ち物の動作 の順に選ぶ。 */
function actionLine(s: SessionSnapshot): string | null {
  if (s.status !== "working") return null;
  if (s.currentSkill) return `巻物『${skillLabel(s.currentSkill)}』を広げている`;
  if (s.currentAction) return s.currentAction;
  return itemForVerb(s.currentTool);
}

/** カードの DOM id。ヘッダーの「要対応」から飛ぶ先になる。 */
export function cardId(sessionId: string): string {
  return `session-${sessionId}`;
}

function escortLine(s: SessionSnapshot): string | null {
  if (!s.agents.length) return null;
  // agents は更新時刻順なので、代表者は id 順で選んで文言のちらつきを防ぐ。
  const head = [...s.agents].sort((a, b) => a.id.localeCompare(b.id))[0]!;
  const first = jobFor(head.type).label;
  return s.agents.length > 1 ? `${first} ほか${s.agents.length - 1}名が随伴` : `${first}が随伴`;
}

export function SessionCard({
  s,
  now,
  solid,
  permissions = [],
}: {
  s: SessionSnapshot;
  now: number;
  /** キャラを立体で描く。読み込み中は 2D のまま見せる。 */
  solid: boolean;
  /** このセッションの保留中の権限確認。手元で開いた画面にだけ届く。 */
  permissions?: PendingPermission[];
}) {
  const st = styleOf(s.status);
  const action = actionLine(s);
  const escort = escortLine(s);
  // エラーは返答を待っているわけではないので、止まっている事実として出す。
  const wait = st.attention
    ? waited(s.attentionSince, now, s.status === "error" ? "止まっています" : "待っています")
    : null;

  return (
    <div
      id={cardId(s.sessionId)}
      data-attention={st.attention || undefined}
      className={`glass relative scroll-mt-4 overflow-hidden p-4 ${st.frame}`}
    >
      <div
        className={`absolute inset-y-0 left-0 ${st.attention ? "w-[5px]" : "w-[3px]"} ${st.bar}`}
      />

      <div className="mb-1 flex items-center gap-2">
        <span className="truncate text-[14px] font-semibold text-slate-100">{s.project}</span>
        {s.branch && (
          <span className="chip inline-flex max-w-[150px] items-center gap-1 font-mono">
            <GitBranch size={10} className="shrink-0 text-slate-500" />
            <span className="truncate">{s.branch}</span>
          </span>
        )}
        <span className={`badge ml-auto ${st.badge}`}>
          <i className={`h-1.5 w-1.5 rounded-full ${st.dot} ${st.breathe ? "breathe" : ""}`} />
          {st.label}
        </span>
      </div>

      {solid ? (
        <Suspense fallback={<AgentStage session={s} now={now} />}>
          <AgentStage session={s} now={now} art={VoxelArt} />
        </Suspense>
      ) : (
        <AgentStage session={s} now={now} />
      )}

      {st.attention && (
        <div className={`mb-2 rounded-lg border border-white/10 bg-black/25 px-2.5 py-2 ${st.ink}`}>
          <div className="flex items-center gap-1.5 text-[12px] font-semibold tabular-nums">
            <Hourglass size={12} className="shrink-0" />
            {wait ?? `${st.label}で止まっています`}
          </div>
          {/* 何を聞かれているかを切ると、結局どのウィンドウか開いて確かめることになる。 */}
          {s.statusDetail && (
            <div className="mt-1 whitespace-pre-wrap break-words text-[12px] leading-relaxed text-slate-100">
              {s.statusDetail}
            </div>
          )}
        </div>
      )}

      <div className="mb-2 min-h-[36px] px-1 text-center">
        {action && <div className="truncate text-[12px] text-emerald-300">{action}</div>}
        {s.statusDetail && s.status !== "working" && !st.attention && (
          <div className="truncate text-[12px] text-amber-300">{s.statusDetail}</div>
        )}
        {escort && <div className="truncate text-[11px] text-violet-300">{escort}</div>}
        <div className="truncate text-[11.5px] text-slate-400" title={s.title ?? undefined}>
          {s.title ?? "（作業内容 未確定）"}
        </div>
      </div>

      <div className="flex flex-wrap gap-x-3 gap-y-1 border-t border-white/8 pt-2 text-[11px] tabular-nums text-slate-500">
        <span>最終活動 {ago(s.lastActivityAt, now)}</span>
        <span>稼働 {dur(s.startedAt, now)}</span>
        {s.tokens && <span>キャッシュ {kilo(s.tokens.cacheRead)}</span>}
        <span className="ml-auto">{s.statusSource === "hook" ? "hook" : "log"}</span>
      </div>

      {permissions.map((p) => (
        <PermissionPrompt key={p.key} permission={p} />
      ))}

      <OpenButtons
        sessionId={s.sessionId}
        xcodeProject={s.xcodeProject}
        answer={s.alive ? st.answer : null}
      />

      <MessageInput sessionId={s.sessionId} disabled={!s.canReceive} />
    </div>
  );
}
