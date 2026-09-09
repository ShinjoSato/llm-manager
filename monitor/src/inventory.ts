// 在庫層: ~/.claude/sessions/<pid>.json から稼働中セッションを復元する。
// フックが飛ばない時（monitor 起動前に始まったセッション等）でも全体像が取れる唯一の経路。
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { SESSIONS_DIR } from "./paths.js";
import type { RawSession } from "./types.js";

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM は他ユーザーのプロセスで、存在はしている。
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

/** セッションレジストリを走査する。壊れた JSON は黙って飛ばす（書き込み途中を掴むことがある）。 */
export function scanSessions(): RawSession[] {
  let files: string[];
  try {
    files = readdirSync(SESSIONS_DIR).filter((f) => f.endsWith(".json"));
  } catch {
    return [];
  }

  const out: RawSession[] = [];
  for (const file of files) {
    let raw: Record<string, unknown>;
    try {
      raw = JSON.parse(readFileSync(join(SESSIONS_DIR, file), "utf8"));
    } catch {
      continue;
    }
    const pid = Number(raw.pid);
    const sessionId = typeof raw.sessionId === "string" ? raw.sessionId : "";
    const cwd = typeof raw.cwd === "string" ? raw.cwd : "";
    if (!pid || !sessionId || !cwd) continue;

    out.push({
      pid,
      sessionId,
      cwd,
      startedAt: Number(raw.startedAt) || 0,
      name: typeof raw.name === "string" ? raw.name : undefined,
      version: typeof raw.version === "string" ? raw.version : undefined,
      entrypoint: typeof raw.entrypoint === "string" ? raw.entrypoint : undefined,
      kind: typeof raw.kind === "string" ? raw.kind : undefined,
      messagingSocketPath:
        typeof raw.messagingSocketPath === "string" ? raw.messagingSocketPath : undefined,
      alive: isAlive(pid),
    });
  }
  return out;
}
