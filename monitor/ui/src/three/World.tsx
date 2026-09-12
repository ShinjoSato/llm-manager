import { useThree } from "@react-three/fiber";
import { useLayoutEffect, useMemo } from "react";
import type { SessionSnapshot } from "../../../src/types.js";
import Capitol from "./Capitol.js";
import { CAPITOL, CAPITOL_HEIGHT, cameraFit, columnsFor, gridLayout } from "./blueprint.js";

/** 建物どうしの間隔。狭いと隣の柱と重なって段が読めない。 */
const SPACING_X = CAPITOL.footprint + 1.9;
/** 奥行きは広めに取る。詰めると手前の棟が奥の段を隠す。 */
const SPACING_Z = CAPITOL.footprint + 4.2;
export const FOV = 34;
/** 見下ろす角度。浅いと奥の段が隠れ、深いと議事堂に見えない。 */
const ELEVATION = 0.5;

/** セッションの数だけ議事堂が建つ空間。並び順は呼び出し側（カードと同じ順）に従う。 */
export function World({ sessions }: { sessions: SessionSnapshot[] }) {
  const { camera, size } = useThree();
  const aspect = size.width / size.height;
  const layout = useMemo(
    () => gridLayout(sessions.length, SPACING_X, SPACING_Z, columnsFor(aspect)),
    [sessions.length, aspect],
  );

  useLayoutEffect(() => {
    const fit = cameraFit(
      layout,
      CAPITOL.footprint,
      CAPITOL_HEIGHT,
      aspect,
      FOV,
      ELEVATION,
    );
    camera.position.set(...fit.position);
    camera.lookAt(...fit.target);
  }, [camera, layout, aspect]);

  const ground = Math.max(layout.spanX, layout.spanZ) + CAPITOL.footprint * 4;

  return (
    <>
      <fog attach="fog" args={["#070c14", ground * 0.7, ground * 2.1]} />
      <ambientLight intensity={0.85} />
      <directionalLight position={[8, 14, 10]} intensity={1.7} />
      <directionalLight position={[-9, 4, -7]} intensity={0.5} color="#7dd3fc" />

      <mesh rotation-x={-Math.PI / 2} receiveShadow={false}>
        <circleGeometry args={[ground, 48]} />
        <meshStandardMaterial color="#0d141f" roughness={1} metalness={0} />
      </mesh>
      <gridHelper
        args={[ground * 2, Math.round(ground / 2) * 2, "#1e3a5f", "#142234"]}
        position-y={0.005}
      />

      {sessions.map((s, i) => {
        const spot = layout.spots[i];
        return (
          spot && (
            <group key={s.sessionId} position={[spot.x, 0, spot.z]}>
              <Capitol session={s} />
            </group>
          )
        );
      })}
    </>
  );
}
