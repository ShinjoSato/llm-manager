import type { AgentInfo, SessionStatus } from "../../../src/types.js";
import { PixelArt, type Palette } from "./PixelArt.js";
import { itemFor, jobFor } from "./kit.js";
import {
  AGENT_DOWN,
  AGENT_SIT,
  AGENT_STAND,
  KID_STAND,
  MARK_BANG,
  MARK_QUESTION,
  MARK_SLEEP,
  type Sprite,
} from "./sprites.js";

const SKIN = { S: "#f6d3ab", K: "#0a0e14" };

/** 状態ごとの姿勢・色・頭上マーク。 */
const LOOK: Record<SessionStatus, { sprite: Sprite; palette: Palette; mark?: Sprite; markColor?: string }> = {
  working: {
    sprite: AGENT_STAND,
    palette: { ...SKIN, G: "#34d399", B: "#10b981", D: "#0f766e" },
  },
  permission: {
    sprite: AGENT_STAND,
    palette: { ...SKIN, G: "#fbbf24", B: "#d97706", D: "#92400e" },
    mark: MARK_BANG,
    markColor: "#fbbf24",
  },
  waiting: {
    sprite: AGENT_STAND,
    palette: { ...SKIN, G: "#60a5fa", B: "#2563eb", D: "#1e40af" },
    mark: MARK_QUESTION,
    markColor: "#60a5fa",
  },
  error: {
    sprite: AGENT_DOWN,
    palette: { ...SKIN, G: "#f87171", B: "#dc2626", D: "#991b1b" },
  },
  idle: {
    sprite: AGENT_SIT,
    palette: { S: "#cbb99c", K: "#0a0e14", G: "#64748b", B: "#475569", D: "#334155" },
    mark: MARK_SLEEP,
    markColor: "#64748b",
  },
  stopped: {
    sprite: AGENT_SIT,
    palette: { S: "#8b8378", K: "#1e293b", G: "#3f4c5e", B: "#334155", D: "#1e293b" },
  },
};

const MAX_KIDS = 4;

export function AgentStage({
  status,
  tool,
  agents,
}: {
  status: SessionStatus;
  tool: string | null;
  agents: AgentInfo[];
}) {
  const look = LOOK[status] ?? LOOK.idle;
  const item = status === "working" ? itemFor(tool) : null;
  const kids = agents.slice(0, MAX_KIDS);
  const rest = agents.length - kids.length;

  return (
    <div className="relative flex min-h-[104px] items-end justify-center gap-1.5 pb-1">
      <div className="pointer-events-none absolute inset-x-[14%] bottom-0 h-px bg-gradient-to-r from-transparent via-white/10 to-transparent" />

      <div className="relative">
        {look.mark && (
          <PixelArt
            sprite={look.mark}
            palette={{ A: look.markColor ?? "#94a3b8" }}
            scale={3}
            className={`absolute -right-1 ${status === "idle" || status === "stopped" ? "top-6" : "top-0"}`}
          />
        )}
        <PixelArt
          sprite={look.sprite}
          palette={look.palette}
          scale={5}
          className={status === "working" ? "bob" : ""}
        />
      </div>

      {item && (
        <PixelArt
          sprite={item.sprite}
          palette={item.palette}
          scale={5}
          className="bob -ml-2 mb-3"
          style={{ filter: "drop-shadow(0 0 7px rgba(52,211,153,.35))" }}
        />
      )}

      {kids.length > 0 && (
        <div className="flex items-end gap-1">
          {kids.map((a) => {
            const job = jobFor(a.type);
            return (
              <PixelArt
                key={a.id}
                sprite={KID_STAND}
                palette={{ ...SKIN, C: job.light, E: job.dark, F: job.dark }}
                scale={3}
                className="bob-slow"
                title={job.label}
              />
            );
          })}
          {rest > 0 && <span className="mb-1 text-[10px] text-slate-500">+{rest}</span>}
        </div>
      )}
    </div>
  );
}
