import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import type { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';

type XYZ = [number, number, number];
function surface(scene: Scene, color: string): StandardMaterial {
  const name = `sea-signal-${color}`;
  const old = scene.getMaterialByName(name);
  if (old instanceof StandardMaterial) return old;
  const result = new StandardMaterial(name, scene);
  result.diffuseColor = Color3.FromHexString(color); result.specularColor.setAll(0.11);
  return result;
}
function builder(scene: Scene, shadow: ShadowGenerator, metadata: Record<string, string>) {
  const meshes: Mesh[] = [];
  const finish = (mesh: Mesh, parent: TransformNode, position: XYZ, color: string): Mesh => {
    mesh.parent = parent; mesh.position.set(...position); mesh.material = surface(scene, color);
    mesh.metadata = metadata; mesh.isPickable = true; mesh.receiveShadows = true;
    shadow.addShadowCaster(mesh, false); meshes.push(mesh); return mesh;
  };
  const oval = (name: string, parent: TransformNode, position: XYZ, size: XYZ, color: string): Mesh => {
    const mesh = finish(MeshBuilder.CreateSphere(name, { diameter: 1, segments: 12 }, scene), parent, position, color);
    mesh.scaling.set(...size); return mesh;
  };
  const box = (name: string, parent: TransformNode, position: XYZ, size: XYZ, color: string): Mesh =>
    finish(MeshBuilder.CreateBox(name, { width: size[0], height: size[1], depth: size[2] }, scene), parent, position, color);
  const tube = (name: string, parent: TransformNode, points: XYZ[], radius: number, color: string): Mesh =>
    finish(MeshBuilder.CreateTube(name, { path: points.map(p => new Vector3(...p)), radius, tessellation: 8, cap: Mesh.CAP_ALL }, scene), parent, [0, 0, 0], color);
  const merge = (): void => {
    const groups = new Map<TransformNode, Map<StandardMaterial, Mesh[]>>();
    for (const mesh of meshes) {
      const owner = mesh.parent as TransformNode, material = mesh.material as StandardMaterial;
      const group = groups.get(owner) ?? new Map<StandardMaterial, Mesh[]>();
      groups.set(owner, group); group.set(material, [...(group.get(material) ?? []), mesh]);
    }
    for (const [owner, group] of groups) for (const [material, parts] of group) {
      if (parts.length < 2) continue;
      const local = owner.computeWorldMatrix(true).clone().invert();
      for (const mesh of parts) { mesh.computeWorldMatrix(true); shadow.removeShadowCaster(mesh, false); }
      const merged = Mesh.MergeMeshes(parts, true, true, undefined, false, false);
      if (!merged) { for (const mesh of parts) shadow.addShadowCaster(mesh, false); continue; }
      merged.bakeTransformIntoVertices(local);
      merged.position.setAll(0); merged.rotation.setAll(0); merged.rotationQuaternion = null; merged.scaling.setAll(1);
      merged.name = `${owner.name}-${material.name}`;
      finish(merged, owner, [0, 0, 0], material.diffuseColor.toHexString());
    }
  };
  return { finish, oval, box, tube, merge };
}

/** Created only for a concrete native approval or input request. */
export function createDenDenMushi(scene: Scene, shadow: ShadowGenerator, parent: TransformNode, requestID: string, agentID: string) {
  const root = new TransformNode(`den-den-${requestID}`, scene); root.parent = parent;
  const { oval, box, tube, merge } = builder(scene, shadow, { attentionID: requestID, actorID: agentID });
  box('snail-deck-plinth', root, [0, 0.055, 0], [0.79, 0.10, 0.76], '#DBB76E');
  oval('snail-foot', root, [0, 0.16, 0.08], [0.69, 0.19, 0.73], '#A9CE9B');
  oval('coral-shell', root, [0, 0.39, -0.14], [0.55, 0.51, 0.46], '#D9836E');
  for (const side of [-1, 1]) {
    const spiral: XYZ[] = Array.from({ length: 40 }, (_, i) => {
      const t = i / 39, angle = t * Math.PI * 4.5, radius = 0.02 + t * 0.175;
      return [side * (0.276 - t * 0.035), 0.395 + Math.cos(angle) * radius, -0.14 + Math.sin(angle) * radius];
    });
    tube(`shell-spiral-${side}`, root, spiral, 0.019, '#F3CD95');
  }
  const head = new TransformNode(`den-den-head-${requestID}`, scene); head.parent = root; head.position.set(0, 0.25, 0.28);
  oval('snail-cheeks', head, [0, 0, 0], [0.45, 0.26, 0.28], '#C5DEA7');
  for (const side of [-1, 1]) {
    tube(`eye-stalk-${side}`, head, [[side * 0.13, 0.035, 0], [side * 0.17, 0.17, 0.016], [side * 0.17, 0.28, 0.022]], 0.032, '#A9CE9B');
    oval(`snail-eye-${side}`, head, [side * 0.17, 0.28, 0.034], [0.14, 0.15, 0.13], '#FFF5DB');
    oval(`snail-pupil-${side}`, head, [side * 0.17, 0.285, 0.094], [0.055, 0.081, 0.04], '#203D42');
    oval(`snail-eye-glint-${side}`, head, [side * 0.17 - 0.014, 0.306, 0.113], [0.018, 0.022, 0.008], '#FFF5DB');
  }
  tube('snail-smile', head, [[-0.095, -0.035, 0.122], [-0.045, -0.067, 0.136], [0.045, -0.067, 0.136], [0.095, -0.035, 0.122]], 0.009, '#50724E');
  const receiver = new TransformNode(`den-den-receiver-${requestID}`, scene); receiver.parent = root;
  tube('telephone-handset', receiver, [[-0.29, 0.59, -0.14], [-0.23, 0.71, -0.14], [0, 0.75, -0.14], [0.23, 0.71, -0.14], [0.29, 0.59, -0.14]], 0.047, '#203D42');
  for (const side of [-1, 1]) oval(`receiver-earpiece-${side}`, receiver, [side * 0.29, 0.59, -0.14], [0.17, 0.12, 0.19], '#203D42');
  tube('telephone-cord', root, Array.from({ length: 30 }, (_, i) => [0.30 + Math.sin(i * 1.2) * 0.03, 0.54 - i / 29 * 0.31, -0.13 + Math.cos(i * 1.2) * 0.03] as XYZ), 0.013, '#203D42');
  for (let row = 0; row < 2; row++) for (let col = 0; col < 3; col++) oval('dial-button', root, [(col - 1) * 0.083, 0.28 + row * 0.066, 0.062], [0.04, 0.04, 0.025], '#FFF5DB');
  merge();
  let disposed = false;
  root.onDisposeObservable.addOnce(() => { disposed = true; });
  return { root, animate(time: number, reduced: boolean) {
    if (disposed) return;
    const ring = reduced ? 0 : Math.sin(time * 7) * 0.028;
    receiver.rotation.z = ring; head.rotation.y = reduced ? 0 : Math.sin(time * 2.3) * 0.10;
  }, dispose: () => root.dispose() };
}

/** A compact mail skiff; unlike main ships, it visualizes one real transfer. */
export function createCourierBoat(scene: Scene, shadow: ShadowGenerator, parent: TransformNode, transferID: string, kind: 'handoff' | 'artifact') {
  const root = new TransformNode(`courier-${transferID}`, scene); root.parent = parent;
  const { finish, oval, box, tube, merge } = builder(scene, shadow, { transferID });
  oval('courier-hull', root, [0, 0.22, 0], [0.65, 0.41, 1.35], '#A85E3D');
  oval('courier-gunwale', root, [0, 0.37, 0], [0.69, 0.15, 1.25], '#DBB76E');
  oval('courier-deck', root, [0, 0.40, 0], [0.57, 0.06, 1.12], '#654331');
  tube('courier-mast', root, [[0, 0.42, 0.13], [0, 1.39, 0.13]], 0.031, '#654331');
  tube('courier-yard', root, [[-0.45, 1.24, 0.13], [0.45, 1.24, 0.13]], 0.021, '#654331');
  const sail = MeshBuilder.CreateRibbon('courier-sail', { pathArray: Array.from({ length: 7 }, (_, row) => Array.from({ length: 9 }, (_, col) => {
    const u = col / 8, v = row / 6;
    return new Vector3((u - 0.5) * 0.81, 1.22 - v * 0.62, 0.13 + Math.sin(u * Math.PI) * Math.sin(v * Math.PI) * 0.17);
  })), sideOrientation: Mesh.DOUBLESIDE }, scene);
  finish(sail, root, [0, 0, 0], '#FFF5DB');
  box('courier-parcel', root, [0, 0.57, -0.36], [0.37, 0.28, 0.34], kind === 'artifact' ? '#D9836E' : '#A9CE9B');
  box('parcel-ribbon', root, [0, 0.578, -0.36], [0.054, 0.293, 0.35], '#DBB76E');
  box('parcel-cross-ribbon', root, [0, 0.716, -0.36], [0.38, 0.019, 0.055], '#DBB76E');
  box('mail-emblem', root, [0, 0.88, 0.296], [0.22, 0.15, 0.012], '#D9836E');
  tube('mail-fold', root, [[-0.10, 0.942, 0.306], [0, 0.864, 0.316], [0.10, 0.942, 0.306]], 0.009, '#FFF5DB');
  const flag = MeshBuilder.CreatePlane('courier-pennant', { width: 0.25, height: 0.16, sideOrientation: Mesh.DOUBLESIDE }, scene);
  finish(flag, root, [0.12, 1.37, 0.13], '#D9836E');
  for (const side of [-1, 1]) tube(`courier-railing-${side}`, root, [[side * 0.25, 0.47, -0.37], [side * 0.29, 0.46, 0], [side * 0.20, 0.46, 0.4]], 0.018, '#DBB76E');
  merge();
  return { root, dispose: () => root.dispose() };
}
