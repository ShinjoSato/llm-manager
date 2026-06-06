import { existsSync } from "node:fs";
import { join } from "node:path";
import { run } from "./proc.js";
import type { GitInfo } from "../../../shared/types.js";

export async function gitInfo(path: string): Promise<GitInfo | null> {
  if (!existsSync(join(path, ".git"))) return null;
  const [branch, last, porcelain, ahead] = await Promise.all([
    run("git", ["-C", path, "branch", "--show-current"]),
    run("git", ["-C", path, "log", "-1", "--format=%cd (%h) %s", "--date=short"]),
    run("git", ["-C", path, "status", "--porcelain"]),
    run("git", ["-C", path, "rev-list", "--count", "@{u}..HEAD"]),
  ]);
  const dirty = porcelain.code === 0
    ? porcelain.stdout.split("\n").filter((l) => l.trim()).length
    : 0;
  return {
    branch: branch.stdout,
    lastCommit: last.stdout,
    dirty,
    ahead: /^\d+$/.test(ahead.stdout) ? Number(ahead.stdout) : null,
  };
}

export async function repoSlug(path: string): Promise<string | null> {
  const r = await run("git", ["-C", path, "remote", "get-url", "origin"]);
  if (r.code !== 0) return null;
  const m = r.stdout.match(/github\.com[:/]+([^/]+)\/([^/]+?)(?:\.git)?$/);
  return m ? `${m[1]}/${m[2]}` : null;
}
