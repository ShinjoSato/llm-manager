// ~/.claude 配下のパス解決。
import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const CLAUDE_DIR = process.env.CLAUDE_HOME ?? join(homedir(), ".claude");
export const SESSIONS_DIR = join(CLAUDE_DIR, "sessions");
export const PROJECTS_DIR = join(CLAUDE_DIR, "projects");

/** cwd からプロジェクトディレクトリ名を推測する（/Users/x/p -> -Users-x-p）。 */
export function slugForCwd(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9]/g, "-");
}

const resolved = new Map<string, string>();

/**
 * セッションの transcript（jsonl）を解決する。
 * スラッグ規則は Claude Code 側の実装依存なので、推測が外れたら projects/ を走査して実測で見つける。
 */
export function resolveTranscript(sessionId: string, cwd: string): string | null {
  const cached = resolved.get(sessionId);
  if (cached && existsSync(cached)) return cached;

  const guess = join(PROJECTS_DIR, slugForCwd(cwd), `${sessionId}.jsonl`);
  if (existsSync(guess)) {
    resolved.set(sessionId, guess);
    return guess;
  }

  let dirs: string[];
  try {
    dirs = readdirSync(PROJECTS_DIR);
  } catch {
    return null;
  }
  for (const dir of dirs) {
    const candidate = join(PROJECTS_DIR, dir, `${sessionId}.jsonl`);
    if (existsSync(candidate)) {
      resolved.set(sessionId, candidate);
      return candidate;
    }
  }
  return null;
}

/** サブエージェントの transcript ディレクトリ（存在すれば）。 */
export function subagentDir(transcriptPath: string): string {
  return transcriptPath.replace(/\.jsonl$/, "") + "/subagents";
}
