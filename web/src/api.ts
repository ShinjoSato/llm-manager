import type { Dashboard, ManagerState } from "../../shared/types.js";

async function jsonFetch<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(url, init);
  if (!res.ok) throw new Error(`${url} → ${res.status}`);
  return res.json() as Promise<T>;
}

export const api = {
  getDashboard: () => jsonFetch<Dashboard>("/api/dashboard"),
  refresh: () => jsonFetch<Dashboard>("/api/refresh", { method: "POST" }),
  getState: () => jsonFetch<ManagerState>("/api/state"),
  saveState: (state: ManagerState) =>
    jsonFetch<ManagerState>("/api/state", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(state),
    }),
};
