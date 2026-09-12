import { useFrame } from "@react-three/fiber";
import { memo, useEffect, useMemo, useRef } from "react";
import {
  AdditiveBlending,
  CanvasTexture,
  CircleGeometry,
  Group,
  MeshBasicMaterial,
  MeshStandardMaterial,
  SpriteMaterial,
} from "three";
import type { SessionSnapshot } from "../../../src/types.js";
import { MAX_KIDS } from "../pixel/AgentStage.js";
import { itemFor, jobFor, jobPalette } from "../pixel/kit.js";
import { lookOf } from "../pixel/look.js";
import { KID_STAND } from "../pixel/sprites.js";
import { voxelize } from "../pixel/voxelize.js";
import { prefersStill } from "./motion.js";
import { Voxels } from "./Voxels.js";
import {
  FOOTPRINT_X,
  FOOTPRINT_Z,
  glowOf,
  HOP,
  hop,
  ITEM_HEIGHT,
  ITEM_LIFT,
  ITEM_X,
  ITEM_Z,
  KID_GAP,
  KID_HEIGHT,
  KID_Y,
  KID_Z,
  PARENT_HEIGHT,
  phaseOf,
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

/** 中心から滲む光。一様な円板だと縁が輪として見え、影と区別が付かない。 */
function glowTexture(color: string): CanvasTexture {
  const size = 64;
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext("2d")!;
  const grad = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  grad.addColorStop(0, `${color}d0`);
  grad.addColorStop(0.4, `${color}50`);
  grad.addColorStop(1, `${color}00`);
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, size, size);
  return new CanvasTexture(canvas);
}

// 持ち物は稼働中しか出ないので、添える光も稼働中の色で固定でよい。
// 足し算で重ねる（霧も掛けない）。引き算になると光ではなく影に見える。
const itemGlowMat = new SpriteMaterial({
  map: glowTexture(glowOf("working")),
  transparent: true,
  blending: AdditiveBlending,
  depthWrite: false,
  fog: false,
  opacity: 0.9,
});
/** 光の広がり。持ち物より大きくしないと、絵の裏に隠れて見えない。 */
const ITEM_GLOW_SIZE = ITEM_HEIGHT * 2.1;

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

  // 2D のカードと同じ条件。ツールが変わるたび作り直さないよう、値で比べる。
  const item = useMemo(() => {
    const kit = s.status === "working" ? itemFor(s.currentTool, s.currentSkill) : null;
    if (!kit) return null;
    return { voxels: voxelize(kit.sprite, kit.palette), scale: ITEM_HEIGHT / kit.sprite.length };
  }, [s.status, s.currentTool, s.currentSkill]);

  // 状態が変わると材質を作り直すので、前のものは明示的に捨てる。
  useEffect(() => () => [parts.cap, parts.halo].forEach((m) => m.dispose()), [parts]);

  const phase = useMemo(() => phaseOf(s.sessionId), [s.sessionId]);

  const parentRef = useRef<Group>(null);
  const itemRef = useRef<Group>(null);
  const kidRefs = useRef<(Group | null)[]>([]);

  const parentY = TOP_Y + figures.parentScale / 2;
  const itemY = TOP_Y + ITEM_LIFT + (item?.scale ?? 0) / 2;
  const kidY = KID_Y + figures.kidScale / 2;

  useFrame(({ clock }) => {
    const still = prefersStill();
    const t = clock.elapsedTime;
    const level = pulse(s.status, still ? 0 : t + phase * Math.PI * 2);
    parts.cap.emissiveIntensity = level * 0.9;
    parts.halo.opacity = 0.05 + level * 0.09;

    // 親は 2D と同じく稼働中だけ跳ねる。持ち物は手にあるので同じ位相で動かす。
    const beat = still ? 0 : hop(t + phase * HOP.period, HOP.period, HOP.rise);
    const lift = (s.status === "working" ? beat : 0) * figures.parentScale;
    if (parentRef.current) parentRef.current.position.y = parentY + lift;
    if (itemRef.current) itemRef.current.position.y = itemY + beat * figures.parentScale;

    for (let i = 0; i < figures.kids.length; i++) {
      const kid = kidRefs.current[i];
      if (!kid) continue;
      // 子は 1 体ずつずらす。横一列が同時に跳ねると 1 枚の板に見える。
      const at = t + (phase + i * HOP.kidStagger) * HOP.kidPeriod;
      kid.position.y = kidY + (still ? 0 : hop(at, HOP.kidPeriod, HOP.rise)) * figures.kidScale;
    }
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

      <group ref={parentRef} position={[0, parentY, 0]} scale={figures.parentScale}>
        <Voxels voxels={figures.parent} depth={FIGURE_DEPTH} />
      </group>

      {item && (
        <group ref={itemRef} position={[ITEM_X, itemY, ITEM_Z]}>
          {/* 2D の緑の光に当たるもの。絵の裏に敷いて持ち物だけを浮き立たせる。 */}
          <sprite
            material={itemGlowMat}
            position={[0, ITEM_HEIGHT / 2 - item.scale / 2, 0]}
            scale={[ITEM_GLOW_SIZE, ITEM_GLOW_SIZE, 1]}
          />
          <group scale={item.scale}>
            <Voxels voxels={item.voxels} depth={FIGURE_DEPTH} />
          </group>
        </group>
      )}

      {figures.kids.map((kid, i) => (
        <group
          key={kid.id}
          ref={(g) => {
            kidRefs.current[i] = g;
          }}
          position={[(i - (figures.kids.length - 1) / 2) * KID_GAP, kidY, KID_Z]}
          scale={figures.kidScale}
        >
          <Voxels voxels={kid.voxels} depth={FIGURE_DEPTH} />
        </group>
      ))}
    </group>
  );
}

export default memo(Ziggurat);
