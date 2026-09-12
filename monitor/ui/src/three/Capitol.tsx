import { useFrame } from "@react-three/fiber";
import { memo, useEffect, useMemo } from "react";
import {
  CircleGeometry,
  CylinderGeometry,
  MeshBasicMaterial,
  MeshStandardMaterial,
  SphereGeometry,
} from "three";
import type { SessionSnapshot } from "../../../src/types.js";
import { MAX_KIDS } from "../pixel/AgentStage.js";
import { jobFor, jobPalette } from "../pixel/kit.js";
import { lookOf } from "../pixel/look.js";
import { KID_STAND } from "../pixel/sprites.js";
import { voxelize } from "../pixel/voxelize.js";
import { Voxels } from "./Voxels.js";
import {
  CAPITOL,
  CAPITOL_HEIGHT,
  CORNICE_TOP,
  glowOf,
  KID_HEIGHT,
  PARENT_HEIGHT,
  pulse,
  TIER2_TOP,
  TIER3_TOP,
} from "./blueprint.js";

/** キャラの厚み。絵の 1 マスを 1 とした値で、VoxelArt と揃えてある。 */
const FIGURE_DEPTH = 3;
/** 子は 2 段目の手前に並べる。奥に置くと柱に隠れる。 */
// 前柱（span/2 = 1.1・半径 0.1）より手前に出す。重なるとめり込んで見える。
const KID_Z = 1.4;
const KID_GAP = 0.8;

const stone = new MeshStandardMaterial({ color: "#aeb9cc", roughness: 0.8, metalness: 0.05 });
const shade = new MeshStandardMaterial({ color: "#8b97ab", roughness: 0.85, metalness: 0.05 });
const columnGeo = new CylinderGeometry(
  CAPITOL.colonnade.radius,
  CAPITOL.colonnade.radius,
  CAPITOL.colonnade.height,
  10,
);
const pierGeo = new CylinderGeometry(
  CAPITOL.piers.radius,
  CAPITOL.piers.radius,
  CAPITOL.piers.height,
  8,
);
const rotundaGeo = new CylinderGeometry(
  CAPITOL.rotunda.radius,
  CAPITOL.rotunda.radius,
  CAPITOL.rotunda.height,
  8,
);
const corniceGeo = new CylinderGeometry(
  CAPITOL.cornice.radius,
  CAPITOL.cornice.radius * 1.06,
  CAPITOL.cornice.height,
  24,
);
// 上半分だけの球。伏せた椀がドームになる。
const domeGeo = new SphereGeometry(CAPITOL.dome.radius, 24, 12, 0, Math.PI * 2, 0, Math.PI / 2);
const finialGeo = new SphereGeometry(CAPITOL.finial.radius, 10, 8);
const haloGeo = new CircleGeometry(CAPITOL.footprint * 0.78, 28);
const shadowGeo = new CircleGeometry(CAPITOL.footprint * 0.62, 24);
const shadowMat = new MeshBasicMaterial({ color: "#000000", transparent: true, opacity: 0.35 });

/** 土台の列柱。四辺に等間隔で並べ、角は重ねない。 */
const COLONNADE = (() => {
  const { span, perSide } = CAPITOL.colonnade;
  const half = span / 2;
  const spots: [number, number][] = [];
  for (let i = 0; i < perSide; i++) {
    const t = -half + (span * i) / (perSide - 1);
    spots.push([t, -half], [t, half]);
    if (i > 0 && i < perSide - 1) spots.push([-half, t], [half, t]);
  }
  return spots;
})();

const PIERS: [number, number][] = [
  [-CAPITOL.piers.span / 2, -CAPITOL.piers.span / 2],
  [CAPITOL.piers.span / 2, -CAPITOL.piers.span / 2],
  [-CAPITOL.piers.span / 2, CAPITOL.piers.span / 2],
  [CAPITOL.piers.span / 2, CAPITOL.piers.span / 2],
];

const ROTUNDA = Array.from({ length: CAPITOL.rotunda.count }, (_, i) => {
  // 半目盛りずらす。0 から始めると柱が真正面に来て親の顔を縦に隠す。
  const a = ((i + 0.5) / CAPITOL.rotunda.count) * Math.PI * 2;
  return [Math.sin(a) * CAPITOL.rotunda.ring, Math.cos(a) * CAPITOL.rotunda.ring] as [
    number,
    number,
  ];
});

/** 同時に建つ建物が揃って明滅しないよう、棟ごとに脈をずらす種を作る。 */
function phaseOf(id: string): number {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) % 997;
  return (h / 997) * Math.PI * 2;
}

/** 議事堂 1 棟。段数は固定で、親が頂上・サブエージェントが 2 段目に立つ。 */
function Capitol({ session: s }: { session: SessionSnapshot }) {
  const glow = glowOf(s.status);

  const parts = useMemo(() => {
    const emissive = { emissive: glow, color: "#cfd8e6", roughness: 0.6, metalness: 0.1 };
    return {
      dome: new MeshStandardMaterial(emissive),
      finial: new MeshStandardMaterial({ ...emissive, color: glow }),
      halo: new MeshBasicMaterial({ color: glow, transparent: true, opacity: 0.1 }),
    };
  }, [glow]);

  const kidKey = s.agents
    .slice(0, MAX_KIDS)
    .map((a) => `${a.id}:${a.type ?? ""}`)
    .sort()
    .join(",");

  const figures = useMemo(() => {
    const look = lookOf(s.status);
    const parentScale = PARENT_HEIGHT / look.sprite.length;
    const kids = s.agents
      .slice(0, MAX_KIDS)
      .sort((a, b) => a.id.localeCompare(b.id))
      .map((a) => ({ id: a.id, voxels: voxelize(KID_STAND, jobPalette(jobFor(a.type))) }));
    return {
      parent: voxelize(look.sprite, look.palette),
      parentScale,
      kids,
      kidScale: KID_HEIGHT / KID_STAND.length,
    };
  // agents は毎秒作り直されるので、中身が同じなら組み直さない。
  }, [s.status, kidKey]); // eslint-disable-line react-hooks/exhaustive-deps

  // 状態が変わると材質を作り直すので、前のものは明示的に捨てる。
  useEffect(() => () => [parts.dome, parts.finial, parts.halo].forEach((m) => m.dispose()), [parts]);

  const phase = useMemo(() => phaseOf(s.sessionId), [s.sessionId]);

  useFrame(({ clock }) => {
    const level = pulse(s.status, clock.elapsedTime + phase);
    parts.dome.emissiveIntensity = level * 0.45;
    parts.finial.emissiveIntensity = level * 1.6;
    parts.halo.opacity = 0.05 + level * 0.09;
  });

  return (
    <group>
      <mesh geometry={shadowGeo} material={shadowMat} rotation-x={-Math.PI / 2} position-y={0.01} />
      <mesh geometry={haloGeo} material={parts.halo} rotation-x={-Math.PI / 2} position-y={0.02} />

      <mesh material={shade} position-y={CAPITOL.stepA.height / 2}>
        <boxGeometry args={[CAPITOL.stepA.size, CAPITOL.stepA.height, CAPITOL.stepA.size]} />
      </mesh>
      <mesh material={stone} position-y={CAPITOL.stepA.height + CAPITOL.stepB.height / 2}>
        <boxGeometry args={[CAPITOL.stepB.size, CAPITOL.stepB.height, CAPITOL.stepB.size]} />
      </mesh>

      {COLONNADE.map(([x, z], i) => (
        <mesh
          key={i}
          geometry={columnGeo}
          material={stone}
          position={[x, TIER2_TOP - CAPITOL.tier2.thickness - CAPITOL.colonnade.height / 2, z]}
        />
      ))}

      <mesh material={shade} position-y={TIER2_TOP - CAPITOL.tier2.thickness / 2}>
        <boxGeometry args={[CAPITOL.tier2.size, CAPITOL.tier2.thickness, CAPITOL.tier2.size]} />
      </mesh>

      {PIERS.map(([x, z], i) => (
        <mesh
          key={i}
          geometry={pierGeo}
          material={stone}
          position={[x, TIER2_TOP + CAPITOL.piers.height / 2, z]}
        />
      ))}

      <mesh material={shade} position-y={TIER3_TOP - CAPITOL.tier3.thickness / 2}>
        <boxGeometry args={[CAPITOL.tier3.size, CAPITOL.tier3.thickness, CAPITOL.tier3.size]} />
      </mesh>

      {ROTUNDA.map(([x, z], i) => (
        <mesh
          key={i}
          geometry={rotundaGeo}
          material={stone}
          position={[x, TIER3_TOP + CAPITOL.rotunda.height / 2, z]}
        />
      ))}

      <mesh
        geometry={corniceGeo}
        material={stone}
        position-y={CORNICE_TOP - CAPITOL.cornice.height / 2}
      />
      <mesh geometry={domeGeo} material={parts.dome} position-y={CORNICE_TOP} />
      <mesh
        geometry={finialGeo}
        material={parts.finial}
        position-y={CAPITOL_HEIGHT - CAPITOL.finial.radius}
      />

      <group position={[0, TIER3_TOP + figures.parentScale / 2, 0.2]} scale={figures.parentScale}>
        <Voxels voxels={figures.parent} depth={FIGURE_DEPTH} />
      </group>

      {figures.kids.map((kid, i) => (
        <group
          key={kid.id}
          position={[
            (i - (figures.kids.length - 1) / 2) * KID_GAP,
            TIER2_TOP + figures.kidScale / 2,
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

export default memo(Capitol);
