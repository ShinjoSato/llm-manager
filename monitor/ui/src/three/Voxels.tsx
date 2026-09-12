import { useLayoutEffect, useRef } from "react";
import { Color, InstancedMesh, Object3D } from "three";
import type { Voxel } from "../pixel/voxelize.js";

const dummy = new Object3D();
const color = new Color();

/** 立方体の集まりを 1 つの InstancedMesh で描く。カード内の表示でも空間でも同じものを使う。 */
export function Voxels({ voxels, depth }: { voxels: Voxel[]; depth: number }) {
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
