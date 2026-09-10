// キャラを立体で描くかどうか。既定は 2D（three.js を読み込まずに初期表示を軽く保つ）。
import { useCallback, useState } from "react";

const STORAGE_KEY = "monitor.render3d";

export function loadRender3D(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === "on";
  } catch {
    return false;
  }
}

export function saveRender3D(on: boolean): void {
  try {
    localStorage.setItem(STORAGE_KEY, on ? "on" : "off");
  } catch {
    // プライベートモード等で保存できなくても表示は続ける。
  }
}

export function useRender3D(): [boolean, () => void] {
  const [on, setOn] = useState(loadRender3D);
  const toggle = useCallback(() => {
    setOn((prev) => {
      saveRender3D(!prev);
      return !prev;
    });
  }, []);
  return [on, toggle];
}
