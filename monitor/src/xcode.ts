// セッションの作業場所から Xcode で開く対象を探す。規則は claude-deck の findXcodeProject と揃える。
import { readdirSync } from "node:fs";
import { join } from "node:path";

const MAX_DEPTH = 3;
/** 潜っても無駄か、誤検出のもとになるディレクトリ。 */
const SKIP = new Set([".git", "Pods", "node_modules", ".build", "DerivedData", "build", ".swiftpm"]);

interface Candidate {
  path: string;
  depth: number;
  workspace: boolean;
}

/** `.xcworkspace` 優先・最も浅い階層のものを 1 つ返す。無ければ null。 */
export function findXcodeProject(dir: string): string | null {
  const queue: Array<[string, number]> = [[dir, 0]];
  let best: Candidate | null = null;

  for (let i = 0; i < queue.length; i++) {
    const [current, depth] = queue[i]!;
    let entries;
    try {
      entries = readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const path = join(current, entry.name);
      const workspace = entry.name.endsWith(".xcworkspace");
      // バンドルには潜らない。`.xcodeproj/project.xcworkspace` は内部ファイルで開く対象ではない。
      if (workspace || entry.name.endsWith(".xcodeproj")) {
        if (better(best, depth, workspace)) best = { path, depth, workspace };
        continue;
      }
      if (!entry.isDirectory() || entry.name.startsWith(".") || SKIP.has(entry.name)) continue;
      if (depth < MAX_DEPTH) queue.push([path, depth + 1]);
    }
  }
  return best?.path ?? null;
}

function better(best: Candidate | null, depth: number, workspace: boolean): boolean {
  if (!best) return true;
  if (depth !== best.depth) return depth < best.depth;
  return workspace && !best.workspace;
}

const cache = new Map<string, string | null>();

/** 同じ作業場所を何度も走査しないよう、cwd 単位で覚える。 */
export function xcodeProjectFor(cwd: string): string | null {
  const cached = cache.get(cwd);
  if (cached !== undefined) return cached;
  const found = findXcodeProject(cwd);
  cache.set(cwd, found);
  return found;
}
