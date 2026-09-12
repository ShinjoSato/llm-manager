// 表示の切り替え。既定は 2D で、three.js は立体を選んだ時だけ読み込まれる。
import { useCallback, useEffect, useState } from "react";

const STORAGE_KEY = "monitor.render3d";

/** off=平面 / solid=キャラだけ立体 / world=ピラミッドの空間 */
export type RenderMode = "off" | "solid" | "world";

const MODES: readonly string[] = ["off", "solid", "world"];

export function loadRenderMode(): RenderMode {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    // 2 状態だった頃に保存された "on" はキャラだけ立体として読む。
    if (saved === "on") return "solid";
    return MODES.includes(saved ?? "") ? (saved as RenderMode) : "off";
  } catch {
    return "off";
  }
}

export function saveRenderMode(mode: RenderMode): void {
  try {
    localStorage.setItem(STORAGE_KEY, mode);
  } catch {
    // プライベートモード等で保存できなくても表示は続ける。
  }
}

export function useRenderMode(): [RenderMode, (mode: RenderMode) => void] {
  const [mode, setMode] = useState(loadRenderMode);
  useEffect(() => saveRenderMode(mode), [mode]);
  return [mode, useCallback((next: RenderMode) => setMode(next), [])];
}
