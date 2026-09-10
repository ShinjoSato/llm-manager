// ライブフィードの絞り込み。除外リストで持つので、新しいセッションは自動で表示に含まれる。

const STORAGE_KEY = "monitor.feed.hidden";

export function loadHidden(): string[] {
  try {
    const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

export function saveHidden(ids: string[]): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(ids));
  } catch {
    // プライベートモード等で保存できなくても表示は続ける。
  }
}

/**
 * チップを押した後の除外リスト。
 * only（Option+クリック）は「これだけ表示」で、既にその状態なら全表示に戻す。
 */
export function nextHidden(
  hidden: string[],
  allIds: string[],
  id: string,
  only: boolean,
): string[] {
  if (only) {
    const others = allIds.filter((x) => x !== id);
    const alreadyOnly = others.length === hidden.length && others.every((o) => hidden.includes(o));
    return alreadyOnly ? [] : others;
  }
  return hidden.includes(id) ? hidden.filter((h) => h !== id) : [...hidden, id];
}

/** 一覧から消えたセッションの設定を捨てる。localStorage に溜めない。 */
export function pruneHidden(hidden: string[], aliveIds: string[]): string[] {
  const alive = new Set(aliveIds);
  return hidden.filter((id) => alive.has(id));
}
