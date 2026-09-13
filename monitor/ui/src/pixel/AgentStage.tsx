import type { CSSProperties } from "react";
import type { AgentInfo, SessionSnapshot } from "../../../src/types.js";
import { Tooltip, type TooltipRow } from "../components/Tooltip.js";
import { ago, dur } from "../format.js";
import { PixelArt, type ArtComponent } from "./PixelArt.js";
import { styleOf } from "../status.js";
import { itemFor, jobFor, jobPalette, skillLabel } from "./kit.js";
import { FALLBACK_MARK, lookOf, markTop } from "./look.js";
import { KID_STAND } from "./sprites.js";

/** 1 セッションで見せるサブエージェントの上限。空間の 2 段目もこの数に合わせる。 */
export const MAX_KIDS = 4;
// memo が効くよう毎レンダー作り直さない。
const ITEM_GLOW: CSSProperties = { filter: "drop-shadow(0 0 7px rgba(52,211,153,.35))" };

/**
 * カード内のキャラ表示。絵の描き方（art）だけを差し替えられる。
 * 情報の並びとツールチップを 1 箇所に持たせ、2D と 3D で食い違わないようにする。
 */
export function AgentStage({
  session: s,
  now,
  art: Art = PixelArt,
}: {
  session: SessionSnapshot;
  now: number;
  art?: ArtComponent;
}) {
  const look = lookOf(s.status);
  const item = s.status === "working" ? itemFor(s.currentTool, s.currentSkill) : null;
  // 直近に動いている順で選び、描画は id 順に固定する（2 秒ごとに並びが入れ替わるのを防ぐ）。
  const kids = s.agents.slice(0, MAX_KIDS).sort((a, b) => a.id.localeCompare(b.id));
  const rest = s.agents.length - kids.length;

  const statusLabel = styleOf(s.status).label;
  const parentRows: TooltipRow[] = [
    { label: "状態", value: `${statusLabel} — ${look.note}` },
    { label: "ブランチ", value: s.branch ?? "—", mono: true },
    { label: "稼働", value: `${dur(s.startedAt, now)}（最終活動 ${ago(s.lastActivityAt, now)}）` },
    { label: "場所", value: s.cwd, mono: true },
    { label: "セッション", value: `${s.name} · pid ${s.pid}`, mono: true },
  ];
  if (s.statusDetail) parentRows.splice(1, 0, { label: "詳細", value: s.statusDetail });

  return (
    <div className="relative flex min-h-[104px] items-end justify-center gap-1.5 pb-1">
      <div className="pointer-events-none absolute inset-x-[14%] bottom-0 h-px bg-gradient-to-r from-transparent via-white/10 to-transparent" />

      <Tooltip title={s.project} subtitle={s.title ?? "作業内容 未確定"} rows={parentRows}>
        <span className="relative inline-flex">
          {look.mark && (
            <Art
              sprite={look.mark}
              palette={look.markPalette ?? FALLBACK_MARK}
              scale={3}
              className={`absolute -right-1 ${markTop(s.status)}`}
            />
          )}
          <Art
            sprite={look.sprite}
            palette={look.palette}
            scale={5}
            className={s.status === "working" ? "bob" : ""}
            label={`${s.project}（${statusLabel}）`}
          />
        </span>
      </Tooltip>

      {item && (
        <Tooltip
          title={
            s.currentSkill ? `スキル『${skillLabel(s.currentSkill)}』` : (s.currentTool ?? "ツール")
          }
          subtitle={item.verb}
          rows={[
            ...(s.currentSkill
              ? [{ label: "スキル", value: s.currentSkill, mono: true } as TooltipRow]
              : []),
            { label: "ツール", value: s.currentTool ?? "—", mono: true },
            ...(s.currentAction ? [{ label: "内容", value: s.currentAction } as TooltipRow] : []),
          ]}
        >
          <Art
            sprite={item.sprite}
            palette={item.palette}
            scale={5}
            className="bob -ml-2 mb-3"
            style={ITEM_GLOW}
            label={s.currentSkill ? skillLabel(s.currentSkill) : (s.currentTool ?? "持ち物")}
          />
        </Tooltip>
      )}

      {kids.length > 0 && (
        <div className="flex items-end gap-1">
          {kids.map((a) => (
            <KidSprite key={a.id} agent={a} now={now} art={Art} />
          ))}
          {rest > 0 && <span className="mb-1 text-[10px] text-slate-500">+{rest}</span>}
        </div>
      )}
    </div>
  );
}

function KidSprite({
  agent,
  now,
  art: Art,
}: {
  agent: AgentInfo;
  now: number;
  art: ArtComponent;
}) {
  const job = jobFor(agent.type);
  return (
    <Tooltip
      title={job.label}
      subtitle={job.role}
      focusable={false}
      rows={[
        { label: "種別", value: agent.type ?? "（不明）", mono: true },
        { label: "最終活動", value: ago(agent.lastActivityAt, now) },
      ]}
    >
      <Art
        sprite={KID_STAND}
        palette={jobPalette(job)}
        scale={3}
        className="bob-slow"
        label={`${job.label} — ${job.role}`}
      />
    </Tooltip>
  );
}
