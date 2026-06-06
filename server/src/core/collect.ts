import { existsSync, writeFileSync, readFileSync, mkdirSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { REGISTRY, BOARDS, DASHBOARD_JSON } from "./paths.js";
import { readTsv } from "./tsv.js";
import { gitInfo, repoSlug } from "./git.js";
import { boardData, openPrs } from "./boards.js";
import { collectAppStore } from "./appstore.js";
import type { Dashboard, Project } from "../../../shared/types.js";

interface BoardCfg { owner: string; number: string; repo: string; url: string; }

/** 管理対象を横断収集して Dashboard を組み立てる（Python版 collect.py の main 相当）。 */
export async function collect(): Promise<Dashboard> {
  const boards: Record<string, BoardCfg> = {};
  for (const r of readTsv(BOARDS)) {
    if (r.length >= 5) boards[r[0]] = { owner: r[1], number: r[2], repo: r[3], url: r[4] };
  }
  const appstore = await collectAppStore();

  const projects: Project[] = [];
  for (const row of readTsv(REGISTRY)) {
    if (row.length < 3) continue;
    const [name, path, status] = row;
    const note = row[3] ?? "";
    if (status !== "active") continue;

    const exists = isDir(path);
    const slug = exists ? await repoSlug(path) : null;
    const project: Project = {
      name,
      path,
      note,
      repo: slug,
      exists,
      git: exists ? await gitInfo(path) : null,
      board: null,
      prs: slug ? await openPrs(slug) : [],
      appstore: appstore[name] ?? null,
    };
    if (boards[name]) {
      const b = boards[name];
      const bd = await boardData(b.owner, b.number);
      bd.number = b.number;
      bd.url = b.url;
      project.board = bd;
    }
    projects.push(project);
  }

  return { generatedAt: new Date().toISOString(), projects };
}

/** 収集して data/dashboard.json に保存。 */
export async function collectAndSave(): Promise<Dashboard> {
  const dash = await collect();
  mkdirSync(dirname(DASHBOARD_JSON), { recursive: true });
  writeFileSync(DASHBOARD_JSON, JSON.stringify(dash, null, 2), "utf-8");
  return dash;
}

/** 保存済み dashboard.json を読む。無ければ null。 */
export function readDashboard(): Dashboard | null {
  if (!existsSync(DASHBOARD_JSON)) return null;
  return JSON.parse(readFileSync(DASHBOARD_JSON, "utf-8")) as Dashboard;
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}
