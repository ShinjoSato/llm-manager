import { View } from "@react-three/drei";
import { Canvas } from "@react-three/fiber";
import type { SessionSnapshot } from "../../../src/types.js";
import { FOV, World } from "./World.js";

type Props =
  /** カードの中のキャラだけを立体にする。 */
  | { mode: "solid" }
  /** セッションごとに議事堂が建つ空間を描く。 */
  | { mode: "world"; sessions: SessionSnapshot[] };

/**
 * 立体表示の描画面。canvas を増やすと WebGL のコンテキスト数が上限に当たって
 * 古いものから消えるので、どちらの方式でも画面に 1 枚だけ置く。
 */
export default function Stage3DCanvas(props: Props) {
  if (props.mode === "world") {
    return (
      <Canvas
        camera={{ fov: FOV, near: 0.1, far: 400 }}
        dpr={[1, 2]}
        gl={{ antialias: true, alpha: true }}
        style={{ pointerEvents: "none" }}
      >
        <World sessions={props.sessions} />
      </Canvas>
    );
  }

  // 正射影・zoom 1 なので 1 単位 = 1 画素になり、2D の scale と寸法が揃う。
  return (
    <Canvas
      orthographic
      camera={{ position: [0, 0, 400], zoom: 1, near: 0.1, far: 2000 }}
      dpr={[1, 2]}
      gl={{ antialias: true, alpha: true }}
      style={{ position: "fixed", inset: 0, pointerEvents: "none", zIndex: 30 }}
    >
      <View.Port />
    </Canvas>
  );
}
