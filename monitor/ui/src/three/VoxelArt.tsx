import { View } from "@react-three/drei";
import { memo, useLayoutEffect, useMemo, useRef } from "react";
import { Color, InstancedMesh, Object3D } from "three";
import type { ArtProps } from "../pixel/PixelArt.js";
import { voxelize, type Voxel } from "../pixel/voxelize.js";
import { fitScale, projectedSize } from "./fit.js";

/** 立方体の厚み。薄いと板に見え、厚いと小さい枠で像が潰れる。 */
const DEPTH = 3;
/** 見る角度。強く回すと横顔になって誰なのか分からなくなる。 */
const ROT_Y = 0.44;
const ROT_X = 0.16;
/** 幅の狭い記号は同じだけ回すと枠に対して大きくはみ出し、縮められて潰れる。 */
const THIN_WIDTH = 6;
const THIN_RATIO = 0.4;

const dummy = new Object3D();
const color = new Color();

function Voxels({ voxels, depth }: { voxels: Voxel[]; depth: number }) {
  const mesh = useRef<InstancedMesh>(null);

  useLayoutEffect(() => {
    const m = mesh.current;
    if (!m) return;
    voxels.forEach((v, i) => {
      dummy.position.set(v.x, v.y, v.z);
      dummy.updateMatrix();
      m.setMatrixAt(i, dummy.matrix);
      m.setColorAt(i, color.set(v.color));
    });
    m.instanceMatrix.needsUpdate = true;
    if (m.instanceColor) m.instanceColor.needsUpdate = true;
  }, [voxels]);

  return (
    // 個体ごとの位置は行列で持つので、形状の境界球では正しく判定できない。
    <instancedMesh ref={mesh} args={[undefined, undefined, voxels.length]} frustumCulled={false}>
      <boxGeometry args={[1, 1, depth]} />
      <meshLambertMaterial />
    </instancedMesh>
  );
}

/**
 * PixelArt と同じ引数で、同じ寸法の枠に立体を描く。
 * 描くのは画面に 1 枚だけ置いた canvas（Stage3DCanvas）で、ここは領域を貸すだけ。
 */
function VoxelArt({ sprite, palette, scale = 4, className = "", style, label }: ArtProps) {
  const shape = useMemo(() => {
    const voxels = voxelize(sprite, palette);
    const frame = {
      width: sprite.length ? Math.max(...sprite.map((r) => r.length)) : 0,
      height: sprite.length,
    };
    const thin = frame.width < THIN_WIDTH;
    const depth = thin ? 1 : DEPTH;
    const rotX = thin ? ROT_X * THIN_RATIO : ROT_X;
    const rotY = thin ? ROT_Y * THIN_RATIO : ROT_Y;
    // 枠の中心に寄せる。中身の外接箱で寄せると、余白のある絵だけ 2D より浮く。
    const centerY = (frame.height - 1) / 2;
    const fit = fitScale(frame, projectedSize(frame.width, frame.height, depth, rotX, rotY));
    return { voxels, frame, depth, rotX, rotY, centerY, fit };
  }, [sprite, palette]);

  return (
    <div
      className={className}
      style={{ width: shape.frame.width * scale, height: shape.frame.height * scale, ...style }}
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : "true"}
    >
      <View style={{ width: "100%", height: "100%" }}>
        <ambientLight intensity={1.5} />
        <directionalLight position={[5, 7, 10]} intensity={2.2} />
        <directionalLight position={[-7, 2, -5]} intensity={0.9} />
        <group scale={scale * shape.fit} rotation-x={shape.rotX}>
          <group rotation-y={shape.rotY}>
            <group position={[0, -shape.centerY, 0]}>
              <Voxels voxels={shape.voxels} depth={shape.depth} />
            </group>
          </group>
        </group>
      </View>
    </div>
  );
}

export default memo(VoxelArt);
