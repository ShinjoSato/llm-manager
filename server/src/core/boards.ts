import { run } from "./proc.js";
import type { Board, BoardItem, PullRequest } from "../../../shared/types.js";

/** GitHub Project（ボード）の項目を集計（Python版 board_data 相当）。 */
export async function boardData(owner: string, number: string): Promise<Board> {
  const r = await run("gh", [
    "project", "item-list", number, "--owner", owner, "--limit", "1000", "--format", "json",
  ]);
  if (r.code !== 0) return emptyBoard(r.stderr || "gh project item-list 失敗");
  let data: any;
  try {
    data = JSON.parse(r.stdout);
  } catch {
    return emptyBoard("ボードJSONの解析に失敗");
  }
  const items: any[] = data.items ?? [];
  const counts: Record<string, number> = {};
  const active: BoardItem[] = [];
  for (const it of items) {
    const st = it.status || "(no status)";
    counts[st] = (counts[st] ?? 0) + 1;
    if (st !== "Done") {
      const c = it.content ?? {};
      active.push({
        number: c.number ?? null,
        title: it.title || c.title || "(無題)",
        status: st,
        repo: (c.repository || "").split("/").pop() || "",
        url: c.url ?? null,
      });
    }
  }
  const total = data.totalCount ?? items.length;
  const done = counts["Done"] ?? 0;
  return {
    counts,
    total,
    doneRate: total ? Math.round((done / total) * 100) : 0,
    active,
  };
}

function emptyBoard(error: string): Board {
  return { counts: {}, total: 0, doneRate: 0, active: [], error };
}

/** リポジトリのオープン PR（Python版 open_prs 相当）。 */
export async function openPrs(repo: string): Promise<PullRequest[]> {
  const r = await run("gh", [
    "pr", "list", "-R", repo, "--state", "open", "--limit", "30",
    "--json", "number,title,createdAt,url,isDraft",
  ]);
  if (r.code !== 0) return [];
  try {
    return JSON.parse(r.stdout) as PullRequest[];
  } catch {
    return [];
  }
}
