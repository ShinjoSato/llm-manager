import { useFrame } from "@react-three/fiber";
import { memo, useEffect, useMemo } from "react";
import { CircleGeometry, MeshBasicMaterial, MeshStandardMaterial } from "three";
import type { SessionSnapshot } from "../../../src/types.js";
import { MAX_KIDS } from "../pixel/AgentStage.js";
import { jobFor, jobPalette } from "../pixel/kit.js";
import { lookOf } from "../pixel/look.js";
import { KID_STAND } from "../pixel/sprites.js";
import { voxelize } from "../pixel/voxelize.js";
import { Voxels } from "./Voxels.js";
import {
  FOOTPRINT_X,
  FOOTPRINT_Z,
  glowOf,
  KID_GAP,
  KID_HEIGHT,
  KID_Y,
  KID_Z,
  PARENT_HEIGHT,
  pulse,
  STEPS,
  TOP_Y,
  ZIGGURAT,
} from "./blueprint.js";

/** キャラの厚み。絵の 1 マスを 1 とした値で、VoxelArt と揃えてある。 */
const FIGURE_DEPTH = 3;

// 隣り合う段で明るさを変えないと、遠くから見たとき 1 枚の斜面に潰れる。
const stone = new MeshStandardMaterial({ color: "#aeb9cc", roughness: 0.85, metalness: 0.05 });
const shade = new MeshStandardMaterial({ color: "#8b97ab", roughness: 0.9, metalness: 0.05 });
const haloGeo = new CircleGeometry(FOOTPRINT_X * 0.55, 28);
const shadowGeo = new CircleGeometry(FOOTPRINT_Z * 0.55, 24);
const shadowMat = new MeshBasicMaterial({ color: "#000000", transparent: true, opacity: 0.35 });

/** 同時に建つ基が揃って明滅しないよう、基ごとに脈をずらす種を作る。 */
function phaseOf(id: string): number {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) % 997;
  return (h / 997) * Math.PI * 2;
}

/** 段々のピラミッド 1 基。親が最上段、サブエージェントが 1 つ下の段に並ぶ。 */
function Ziggurat({ session: s }: { session: SessionSnapshot }) {
  const glow = glowOf(s.status);

  const parts = useMemo(
    () => ({
      cap: new MeshStandardMaterial({
        color: "#0d1726",
        emissive: glow,
        roughness: 0.5,
        metalness: 0.1,
      }),
      halo: new MeshBasicMaterial({ color: glow, transparent: true, opacity: 0.1 }),
    }),
    [glow],
  );

  const kidKey = s.agents
    .slice(0, MAX_KIDS)
    .map((a) => `${a.id}:${a.type ?? ""}`)
    .sort()
    .join(",");

  const figures = useMemo(() => {
    const look = lookOf(s.status);
    const kids = s.agents
      .slice(0, MAX_KIDS)
      .sort((a, b) => a.id.localeCompare(b.id))
      .map((a) => ({ id: a.id, voxels: voxelize(KID_STAND, jobPalette(jobFor(a.type))) }));
    return {
      parent: voxelize(look.sprite, look.palette),
      parentScale: PARENT_HEIGHT / look.sprite.length,
      kids,
      kidScale: KID_HEIGHT / KID_STAND.length,
    };
  // agents は毎秒作り直されるので、中身が同じなら組み直さない。
  }, [s.status, kidKey]); // eslint-disable-line react-hooks/exhaustive-deps

  // 状態が変わると材質を作り直すので、前のものは明示的に捨てる。
  useEffect(() => () => [parts.cap, parts.halo].forEach((m) => m.dispose()), [parts]);

  const phase = useMemo(() => phaseOf(s.sessionId), [s.sessionId]);

  useFrame(({ clock }) => {
    const level = pulse(s.status, clock.elapsedTime + phase);
    parts.cap.emissiveIntensity = level * 0.9;
    parts.halo.opacity = 0.05 + level * 0.09;
  });

  return (
    <group>
      <mesh geometry={shadowGeo} material={shadowMat} rotation-x={-Math.PI / 2} position-y={0.01} />
      <mesh geometry={haloGeo} material={parts.halo} rotation-x={-Math.PI / 2} position-y={0.02} />

      {STEPS.map((step) => {
        const body = step.top - step.base - ZIGGURAT.cap;
        return (
          <group key={step.level}>
            <mesh material={step.level % 2 ? stone : shade} position-y={step.base + body / 2}>
              <boxGeometry args={[step.width, body, step.depth]} />
            </mesh>
            {/* 縁取り板は一回り大きくする。同じ大きさで重ねると段の境目が消える。 */}
            <mesh material={parts.cap} position-y={step.top - ZIGGURAT.cap / 2}>
              <boxGeometry
                args={[
                  step.width + ZIGGURAT.nosing * 2,
                  ZIGGURAT.cap,
                  step.depth + ZIGGURAT.nosing * 2,
                ]}
              />
            </mesh>
          </group>
        );
      })}

      <group position={[0, TOP_Y + figures.parentScale / 2, 0]} scale={figures.parentScale}>
        <Voxels voxels={figures.parent} depth={FIGURE_DEPTH} />
      </group>

      {figures.kids.map((kid, i) => (
        <group
          key={kid.id}
          position={[
            (i - (figures.kids.length - 1) / 2) * KID_GAP,
            KID_Y + figures.kidScale / 2,
            KID_Z,
          ]}
          scale={figures.kidScale}
        >
          <Voxels voxels={kid.voxels} depth={FIGURE_DEPTH} />
        </group>
      ))}
    </group>
  );
}

export default memo(Ziggurat);
