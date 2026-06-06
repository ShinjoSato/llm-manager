import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { STATE_JSON } from "./paths.js";
import type { ManagerState } from "../../../shared/types.js";

const DEFAULT_STATE: ManagerState = {
  updatedAt: "",
  focusNotes: [],
  pinned: [],
  autoHighlightKeywords: [],
};

export function readState(): ManagerState {
  if (!existsSync(STATE_JSON)) return { ...DEFAULT_STATE };
  return JSON.parse(readFileSync(STATE_JSON, "utf-8")) as ManagerState;
}

export function writeState(state: ManagerState): ManagerState {
  mkdirSync(dirname(STATE_JSON), { recursive: true });
  writeFileSync(STATE_JSON, JSON.stringify(state, null, 2) + "\n", "utf-8");
  return state;
}
