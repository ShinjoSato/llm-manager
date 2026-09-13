import { useThree } from "@react-three/fiber";
import { useLayoutEffect, useMemo } from "react";
import { MeshStandardMaterial } from "three";
import type { SessionSnapshot } from "../../../src/types.js";
import Ziggurat from "./Ziggurat.js";
import {
  cameraFit,
  clearSpacingZ,
  columnsFor,
  FOOTPRINT_X,
  FOOTPRINT_Z,
  gridLayout,
  KID_HEIGHT,
  KID_Y,
  SKYLINE,
} from "./blueprint.js";

export const FOV = 34;
/** 見下ろす角度。浅いと段が潰れ、深いとキャラが真上から潰れる。 */
const ELEVATION = 0.42;
/** 基どうしの間隔。狭いと隣の段と稜線が重なって段数が読めない。 */
const SPACING_X = FOOTPRINT_X + 1;
/** 行の間隔。奥の行の足元が手前の子の頭に隠れない距離を取る。 */
const SPACING_Z = clearSpacingZ(KID_Y + KID_HEIGHT, FOOTPRINT_Z, ELEVATION);

const groundMat = new MeshStandardMaterial({ color: "#16243a", roughness: 1, metalness: 0 });

/** セッションの数だけピラミッドが建つ平らな空間。並び順は呼び出し側（カードと同じ順）に従う。 */
export function World({ sessions }: { sessions: SessionSnapshot[] }) {
  const { camera, size } = useThree();
  const aspect = size.width / size.height;
  const layout = useMemo(
    () => gridLayout(sessions.length, SPACING_X, SPACING_Z, columnsFor(aspect)),
    [sessions.length, aspect],
  );

  const fit = useMemo(
    () => cameraFit(layout, FOOTPRINT_X, FOOTPRINT_Z, SKYLINE, aspect, FOV, ELEVATION),
    [layout, aspect],
  );

  useLayoutEffect(() => {
    camera.position.set(...fit.position);
    camera.lookAt(...fit.target);
  }, [camera, fit]);

  // 地面は画角を埋めるだけ広げる。足りないと空間の縁が見えて箱庭になる。
  const reach = Math.hypot(fit.position[1] - fit.target[1], fit.position[2]);
  const width = reach * Math.tan((FOV * Math.PI) / 180 / 2) * Math.max(aspect, 1) * 2.6;

  return (
    <>
      <fog attach="fog" args={["#070c14", reach * 1.05, reach * 2.6]} />
      <ambientLight intensity={0.85} />
      <directionalLight position={[8, 14, 10]} intensity={1.7} />
      <directionalLight position={[-9, 4, -7]} intensity={0.5} color="#7dd3fc" />

      <mesh material={groundMat} rotation-x={-Math.PI / 2}>
        <planeGeometry args={[width, width]} />
      </mesh>
      <gridHelper
        args={[width, Math.max(2, Math.round(width / SPACING_X) * 2), "#1e3a5f", "#142234"]}
        position-y={0.005}
      />

      {sessions.map((s, i) => {
        const spot = layout.spots[i];
        return (
          spot && (
            <group key={s.sessionId} position={[spot.x, 0, spot.z]}>
              <Ziggurat session={s} />
            </group>
          )
        );
      })}
    </>
  );
}
