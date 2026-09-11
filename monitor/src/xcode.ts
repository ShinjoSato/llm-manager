// セッションの作業場所から Xcode で開く対象を探す。規則は claude-deck の findXcodeProject と揃える。
import { readdirSync } from "node:fs";
import { join } from "node:path";

const MAX_DEPTH = 3;
/** 走査するディレクトリ数の上限。cwd が巨大だと同期走査がイベントループを止める。 */
const MAX_DIRS = 2_000;
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

  for (let i = 0; i < queue.length && i < MAX_DIRS; i++) {
    // 深さ 0 の候補は最初の 1 周で出揃い、それより浅いものは無いので打ち切れる。
    if (best?.depth === 0) break;
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
      // リンクは辿らない。循環で走査が終わらなくなるため、claude-deck とはここだけ挙動が違う。
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

