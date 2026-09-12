import { useThree } from "@react-three/fiber";
import { useLayoutEffect, useMemo } from "react";
import { MeshStandardMaterial } from "three";
import type { SessionSnapshot } from "../../../src/types.js";
import Capitol from "./Capitol.js";
import {
  CAPITOL,
  CAPITOL_HEIGHT,
  cameraFit,
  columnsFor,
  gridLayout,
  terraces,
} from "./blueprint.js";

/** 建物どうしの間隔。狭いと隣の柱と重なって段が読めない。 */
const SPACING_X = CAPITOL.footprintX + 2;
/** 奥行きは広めに取る。詰めると段の踏み面が見えず階段に読めない。 */
const SPACING_Z = CAPITOL.footprintZ + 3.6;
/** 行 1 つぶんの高さ。奥の棟が手前の棟の上に抜けるだけの高さが要る。 */
const RISE = 1.7;
/** 棟が建つ踊り場の奥行き。建物の footprint より広くないと足元が段から落ちる。 */
const LANDING = CAPITOL.footprintZ + 1;
/** 踊り場と踊り場の間に刻む段数。1 段だと壁に見えて階段に読めない。 */
const FLIGHT = 4;
/** 棟が建つ行より奥にも段を伸ばす。手前しか埋まっていなくても階段に見える。 */
const EXTRA_STEPS = 3;
/** 段鼻。踏み面を一回り大きくして縁を明るくすると、段の境目が線として読める。 */
const NOSING = 0.1;
export const FOV = 34;
/** 見下ろす角度。浅いと段が潰れ、深いと議事堂に見えない。 */
const ELEVATION = 0.42;

// 蹴上げと踏み面で明るさを分けないと、遠くの段が 1 枚の壁に潰れる。
const riserMat = new MeshStandardMaterial({ color: "#111c2b", roughness: 1, metalness: 0 });
const treadMat = new MeshStandardMaterial({ color: "#2b3d55", roughness: 0.9, metalness: 0 });
const groundMat = new MeshStandardMaterial({ color: "#16243a", roughness: 1, metalness: 0 });

/** セッションの数だけ議事堂が建つ階段状の空間。並び順は呼び出し側（カードと同じ順）に従う。 */
export function World({ sessions }: { sessions: SessionSnapshot[] }) {
  const { camera, size } = useThree();
  const aspect = size.width / size.height;
  const layout = useMemo(
    () => gridLayout(sessions.length, SPACING_X, SPACING_Z, columnsFor(aspect), RISE),
    [sessions.length, aspect],
  );

  const fit = useMemo(
    () =>
      cameraFit(
        layout,
        CAPITOL.footprintX,
        CAPITOL.footprintZ,
        CAPITOL_HEIGHT,
        aspect,
        FOV,
        ELEVATION,
      ),
    [layout, aspect],
  );

  useLayoutEffect(() => {
    camera.position.set(...fit.position);
    camera.lookAt(...fit.target);
  }, [camera, fit]);

  const steps = useMemo(
    () => terraces(layout.rows, SPACING_Z, RISE, EXTRA_STEPS, LANDING, FLIGHT),
    [layout.rows],
  );

  // 段と地面は画角を埋めるだけ広げる。足りないと空間の縁が見えて箱庭になる。
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

      {steps.map((step) => {
        const depth = step.front - step.back;
        // 刻みを細かくしすぎても蹴上げが裏返らないよう下限を置く。
        const riser = Math.max(step.top - NOSING, 0.01);
        return (
          <group key={step.top.toFixed(3)} position={[0, 0, (step.front + step.back) / 2]}>
            <mesh material={riserMat} position-y={riser / 2}>
              <boxGeometry args={[width, riser, depth]} />
            </mesh>
            {/* 踏み面は段鼻で一回り大きくする。同じ大きさで重ねると面が競って縞が出る。 */}
            <mesh material={treadMat} position={[0, step.top - NOSING / 2, NOSING / 2]}>
              <boxGeometry args={[width + NOSING, NOSING, depth + NOSING]} />
            </mesh>
          </group>
        );
      })}

      {sessions.map((s, i) => {
        const spot = layout.spots[i];
        return (
          spot && (
            <group key={s.sessionId} position={[spot.x, spot.y, spot.z]}>
              <Capitol session={s} />
            </group>
          )
        );
      })}
    </>
  );
}
