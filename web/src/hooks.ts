import { useState, useEffect, useCallback } from "react";
import { api } from "./api.js";
import type { Dashboard, ManagerState, BoardItem } from "../../shared/types.js";

export interface Highlight {
  proj: string;
  item: BoardItem;
  why: string;
  pinned: boolean;
}

export function useDashboard() {
  const [dash, setDash] = useState<Dashboard | null>(null);
  const [state, setState] = useState<ManagerState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [d, s] = await Promise.all([api.getDashboard(), api.getState()]);
      setDash(d);
      setState(s);
      setError(null);
    } catch (e) {
      setError(String(e));
    }
  }, []);

  const refresh = useCallback(async () => {
    setBusy(true);
    try {
      setDash(await api.refresh());
      setError(null);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }, []);

  const saveState = useCallback(async (next: ManagerState) => {
    setState(next);
    await api.saveState(next);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  return { dash, state, busy, error, refresh, saveState };
}

/** pinned + キーワード一致から『要注目』を算出（Python版 dashboard と同ロジック）。 */
export function computeHighlights(dash: Dashboard, state: ManagerState): Highlight[] {
  const pinned = new Map<string, string>();
  for (const p of state.pinned) pinned.set(`${p.project}#${p.number}`, p.reason || "");
  const kws = state.autoHighlightKeywords.map((k) => k.toLowerCase());

  const out: Highlight[] = [];
  for (const p of dash.projects) {
    for (const it of p.board?.active ?? []) {
      const key = `${p.name}#${it.number}`;
      const reason = pinned.get(key);
      const kw = kws.find((k) => (it.title || "").toLowerCase().includes(k));
      if (reason !== undefined || kw) {
        out.push({
          proj: p.name,
          item: it,
          why: reason || `キーワード: ${kw}`,
          pinned: reason !== undefined,
        });
      }
    }
  }
  out.sort((a, b) => Number(b.pinned) - Number(a.pinned));
  return out;
}
