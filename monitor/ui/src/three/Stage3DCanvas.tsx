import { View } from "@react-three/drei";
import { Canvas } from "@react-three/fiber";

/**
 * 立体表示の描画面。カードごとに canvas を置くと WebGL のコンテキスト数が上限に
 * 当たって古いものから消えるので、画面に 1 枚だけ置いて各キャラの領域に切り出す。
 * 正射影・zoom 1 なので 1 単位 = 1 画素になり、2D の scale と寸法が揃う。
 */
export default function Stage3DCanvas() {
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
