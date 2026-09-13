import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import type { Geometry } from '@babylonjs/core/Meshes/geometry.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { VertexData } from '@babylonjs/core/Meshes/mesh.vertexData.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import type { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';

export const PANDA_VARIANTS = ['backpack', 'bandana', 'glasses', 'workvest'] as const;
export type PandaVariant = typeof PANDA_VARIANTS[number];
export type PandaActor = {
  root: TransformNode;
  variant: PandaVariant;
  /** Time is elapsed seconds; animation never moves the root across the map. */
  animate(moving: boolean, time: number, reducedMotion: boolean): void;
  dispose(): void;
};

type XYZ = [number, number, number];
type Palette = Record<'ink' | 'cream' | 'white' | 'lime' | 'moss' | 'softInk' | 'blush', StandardMaterial>;
type SharedPalette = { materials: Palette; geometries: Map<string, Geometry>; users: number };
const palettes = new WeakMap<Scene, SharedPalette>();
const HIP_HEIGHT = 0.525, LEG_LENGTH = 0.225, ANKLE_HEIGHT = 0.095;

function acquirePalette(scene: Scene): SharedPalette {
  let shared = palettes.get(scene);
  if (!shared) {
    const colors = { ink: '#161814', cream: '#fffdf7', white: '#ffffff', lime: '#c9f54a', moss: '#647755', softInk: '#343b32', blush: '#e9ac91' };
    const materials = Object.fromEntries(Object.entries(colors).map(([name, color]) => {
      const material = new StandardMaterial(`locus-panda-${name}`, scene);
      material.diffuseColor = Color3.FromHexString(color);
      material.specularColor = new Color3(0.07, 0.075, 0.065);
      material.specularPower = 24;
      if (name === 'ink' || name === 'softInk') material.specularColor.scaleInPlace(0.45);
      return [name, material];
    })) as Palette;
    shared = { materials, geometries: new Map(), users: 0 };
    palettes.set(scene, shared);
  }
  shared.users++;
  return shared;
}

/** An original articulated interpretation of the Locus site's ink/cream panda mascot. */
export function createPanda(scene: Scene, shadow: ShadowGenerator, parent: TransformNode, id: string, seed: number): PandaActor {
  const variant = PANDA_VARIANTS[(seed >>> 0) % PANDA_VARIANTS.length];
  const shared = acquirePalette(scene), palette = shared.materials;
  const meshes: Mesh[] = [];
  const root = new TransformNode(`panda-${id}`, scene);
  root.parent = parent;
  root.metadata = { actorID: id, pandaVariant: variant };
  const node = (name: string, owner: TransformNode, position: XYZ): TransformNode => {
    const pivot = new TransformNode(`panda-${id}-${name}`, scene);
    pivot.parent = owner; pivot.position.set(...position); return pivot;
  };
  const finish = (mesh: Mesh, owner: TransformNode, position: XYZ, material: StandardMaterial): Mesh => {
    mesh.parent = owner; mesh.position.set(...position); mesh.material = material;
    mesh.metadata = { actorID: id }; mesh.isPickable = true; mesh.receiveShadows = true;
    shadow.addShadowCaster(mesh, false); meshes.push(mesh); return mesh;
  };
  const oval = (name: string, owner: TransformNode, position: XYZ, size: XYZ, material: StandardMaterial, segments = 12): Mesh => {
    const mesh = finish(MeshBuilder.CreateSphere(`panda-${id}-${name}`, { diameter: 1, segments }, scene), owner, position, material);
    mesh.scaling.set(...size); return mesh;
  };
  const tube = (name: string, owner: TransformNode, points: XYZ[], radius: number, material: StandardMaterial): Mesh =>
    finish(MeshBuilder.CreateTube(`panda-${id}-${name}`, { path: points.map(point => new Vector3(...point)), radius, tessellation: 8, cap: Mesh.CAP_ALL }, scene), owner, [0, 0, 0], material);
  const patch = (name: string, owner: TransformNode, points: XYZ[], material: StandardMaterial): Mesh => {
    const mesh = new Mesh(`panda-${id}-${name}`, scene);
    const positions = [...points, ...points].flat(), indices = [0, 2, 1, 3, 4, 5], normals: number[] = [];
    VertexData.ComputeNormals(positions, indices, normals);
    const data = new VertexData(); data.positions = positions; data.indices = indices; data.normals = normals;
    data.uvs = [0, 0, 1, 0, 0.5, 1, 0, 0, 1, 0, 0.5, 1]; data.applyToMesh(mesh);
    return finish(mesh, owner, [0, 0, 0], material);
  };
  const loop = (name: string, owner: TransformNode, position: XYZ, diameter: number, thickness: number, material: StandardMaterial): Mesh =>
    finish(MeshBuilder.CreateTorus(`panda-${id}-${name}`, { diameter, thickness, tessellation: 32 }, scene), owner, position, material);

  const pelvis = node('pelvis', root, [0, HIP_HEIGHT, 0]);
  const torso = node('torso', pelvis, [0, 0, 0]);
  oval('body', torso, [0, 0.275, -0.005], [0.615, 0.68, 0.465], palette.ink, 16);
  oval('cream-belly', torso, [0, 0.258, 0.216], [0.47, 0.515, 0.105], palette.cream, 16);
  oval('tail', torso, [0, 0.13, -0.236], [0.17, 0.17, 0.17], palette.cream);

  const head = node('head', torso, [0, 0.815, 0.012]);
  oval('head-shape', head, [0, 0, 0], [0.815, 0.725, 0.68], palette.cream, 20);
  for (const side of [-1, 1]) {
    oval(`ear-${side}`, head, [side * 0.294, 0.302, -0.052], [0.29, 0.295, 0.185], palette.ink, 16);
    oval(`inner-ear-${side}`, head, [side * 0.294, 0.302, 0.042], [0.148, 0.151, 0.032], palette.softInk);
    const eyePatch = oval(`eye-patch-${side}`, head, [side * 0.158, 0.032, 0.302], [0.231, 0.285, 0.075], palette.ink, 16);
    eyePatch.rotation.z = side * 0.16;
  }
  const eyes: TransformNode[] = [];
  for (const side of [-1, 1]) {
    const eye = node(`eye-${side}`, head, [side * 0.151, 0.048, 0.344]);
    oval(`eye-white-${side}`, eye, [0, 0, 0], [0.092, 0.108, 0.032], palette.cream);
    oval(`pupil-${side}`, eye, [-side * 0.007, -0.003, 0.018], [0.052, 0.066, 0.025], palette.ink);
    oval(`eye-spark-${side}`, eye, [-0.009, 0.017, 0.032], [0.024, 0.026, 0.009], palette.white, 8);
    eyes.push(eye);
  }
  oval('muzzle', head, [0, -0.135, 0.292], [0.272, 0.159, 0.108], palette.cream);
  oval('nose', head, [0, -0.084, 0.36], [0.111, 0.078, 0.056], palette.ink);
  oval('nose-glint', head, [-0.019, -0.068, 0.384], [0.039, 0.014, 0.007], palette.softInk, 8);
  tube('nose-stem', head, [[0, -0.114, 0.369], [0, -0.163, 0.355]], 0.009, palette.ink);
  tube('smile', head, [[-0.107, -0.161, 0.323], [-0.083, -0.187, 0.337], [-0.048, -0.195, 0.346], [0, -0.172, 0.354], [0.048, -0.195, 0.346], [0.083, -0.187, 0.337], [0.107, -0.161, 0.323]], 0.0085, palette.ink);
  for (const side of [-1, 1]) oval(`cheek-${side}`, head, [side * 0.279, -0.114, 0.221], [0.071, 0.037, 0.018], palette.blush);

  // The lime collar is shared by every outfit, just like the website mascot.
  const collar = loop('lime-collar', torso, [0, 0.568, 0.007], 0.377, 0.076, palette.lime);
  collar.scaling.z = 0.92;
  const arms: { shoulder: TransformNode; elbow: TransformNode; side: number }[] = [];
  const legs: { hip: TransformNode; knee: TransformNode; ankle: TransformNode; side: number }[] = [];
  for (const side of [-1, 1]) {
    const shoulder = node(`shoulder-${side}`, torso, [side * 0.296, 0.502, 0]);
    shoulder.rotation.z = side * 0.16;
    oval(`upper-arm-${side}`, shoulder, [0, -0.105, 0], [0.22, 0.29, 0.238], palette.ink);
    const elbow = node(`elbow-${side}`, shoulder, [0, -0.214, 0]);
    oval(`forearm-${side}`, elbow, [0, -0.091, 0.013], [0.211, 0.255, 0.216], palette.ink);
    oval(`paw-${side}`, elbow, [0, -0.193, 0.032], [0.22, 0.205, 0.219], palette.ink);
    for (const offset of [-0.042, 0.025]) tube(`paw-groove-${side}-${offset}`, elbow, [[offset, -0.225, 0.121], [offset, -0.182, 0.135]], 0.005, palette.softInk);
    arms.push({ shoulder, elbow, side });

    const hip = node(`hip-${side}`, pelvis, [side * 0.159, 0, 0]);
    oval(`thigh-${side}`, hip, [0, -0.11, 0], [0.247, 0.302, 0.256], palette.ink);
    const knee = node(`knee-${side}`, hip, [0, -LEG_LENGTH, 0]);
    oval(`shin-${side}`, knee, [0, -0.112, 0], [0.233, 0.274, 0.236], palette.ink);
    const ankle = node(`ankle-${side}`, knee, [0, -LEG_LENGTH, 0]);
    oval(`foot-${side}`, ankle, [0, -0.045, 0.058], [0.265, 0.1, 0.348], palette.ink, 16);
    legs.push({ hip, knee, ankle, side });
  }

  if (variant === 'backpack') {
    oval('backpack-shell', torso, [0, 0.30, -0.304], [0.387, 0.443, 0.193], palette.moss);
    oval('backpack-front', torso, [0, 0.315, -0.39], [0.332, 0.382, 0.062], palette.lime);
    oval('backpack-pocket', torso, [0, 0.214, -0.424], [0.246, 0.153, 0.052], palette.moss);
    for (const side of [-1, 1]) tube(`pack-strap-${side}`, torso, [[side * 0.17, 0.54, -0.23], [side * 0.25, 0.51, 0.03], [side * 0.22, 0.33, 0.19], [side * 0.22, 0.13, 0.15]], 0.022, palette.moss);
    loop('pack-handle', torso, [0, 0.54, -0.32], 0.13, 0.025, palette.moss).rotation.x = Math.PI / 2;
  } else if (variant === 'bandana') {
    patch('bandana-front', torso, [[-0.18, 0.56, 0.18], [0.18, 0.56, 0.18], [0.05, 0.31, 0.265]], palette.lime);
    tube('bandana-fold', torso, [[-0.12, 0.52, 0.203], [-0.05, 0.44, 0.234], [0.05, 0.32, 0.266]], 0.005, palette.moss);
    oval('bandana-knot', torso, [0.208, 0.543, -0.04], [0.12, 0.11, 0.11], palette.lime);
    patch('bandana-tail-a', torso, [[0.19, 0.54, -0.05], [0.36, 0.48, -0.11], [0.29, 0.37, -0.08]], palette.lime);
    patch('bandana-tail-b', torso, [[0.20, 0.55, -0.07], [0.40, 0.62, -0.13], [0.34, 0.48, -0.14]], palette.lime);
  } else if (variant === 'glasses') {
    for (const side of [-1, 1]) {
      const frame = loop(`spectacle-${side}`, head, [side * 0.155, 0.053, 0.37], 0.230, 0.018, palette.moss);
      frame.rotation.x = Math.PI / 2;
      tube(`spectacle-temple-${side}`, head, [[side * 0.27, 0.06, 0.37], [side * 0.36, 0.07, 0.21], [side * 0.37, 0.04, 0.08]], 0.009, palette.moss);
      tube(`spectacle-highlight-${side}`, head, [[side * 0.155 - 0.06, 0.12, 0.38], [side * 0.155 - 0.03, 0.14, 0.38]], 0.005, palette.cream);
    }
    tube('spectacle-bridge', head, [[-0.039, 0.07, 0.37], [0, 0.082, 0.377], [0.039, 0.07, 0.37]], 0.009, palette.moss);
  } else {
    for (const side of [-1, 1]) {
      const vest = oval(`vest-panel-${side}`, torso, [side * 0.220, 0.35, 0.157], [0.161, 0.403, 0.132], palette.moss);
      vest.rotation.z = side * 0.12;
      tube(`vest-lime-seam-${side}`, torso, [[side * 0.19, 0.53, 0.205], [side * 0.136, 0.31, 0.236], [side * 0.147, 0.15, 0.207]], 0.009, palette.lime);
      oval(`vest-pocket-${side}`, torso, [side * 0.215, 0.22, 0.233], [0.111, 0.103, 0.029], palette.lime);
    }
    tube('vest-pencil', torso, [[-0.215, 0.22, 0.254], [-0.202, 0.33, 0.248]], 0.012, palette.cream);
  }

  // Merge only geometry rigidly attached to the same joint. Eyelids, arms and
  // legs keep their pivots while each material is drawn once per body part.
  const groups = new Map<TransformNode, Map<StandardMaterial, Mesh[]>>();
  for (const mesh of meshes) {
    const owner = mesh.parent as TransformNode, material = mesh.material as StandardMaterial;
    let materials = groups.get(owner);
    if (!materials) { materials = new Map(); groups.set(owner, materials); }
    const parts = materials.get(material) || [];
    parts.push(mesh); materials.set(material, parts);
  }
  for (const [owner, materials] of groups) for (const [material, parts] of materials) {
    if (parts.length < 2) continue;
    const local = owner.computeWorldMatrix(true).clone().invert();
    for (const part of parts) { part.computeWorldMatrix(true); shadow.removeShadowCaster(part, false); }
    const combined = Mesh.MergeMeshes(parts, true, true, undefined, false, false);
    if (!combined) { for (const part of parts) shadow.addShadowCaster(part, false); continue; }
    combined.bakeTransformIntoVertices(local);
    combined.position.setAll(0); combined.rotation.setAll(0); combined.rotationQuaternion = null; combined.scaling.setAll(1);
    combined.name = `${owner.name}-${material.name}-merged`;
    finish(combined, owner, [0, 0, 0], material);
  }

  // Reuse completed joint geometry for repeated outfits, while keeping actor
  // meshes and their picking metadata independent.
  for (const mesh of root.getChildMeshes() as Mesh[]) {
    const geometry = mesh.geometry;
    if (!geometry) continue;
    const key = `${variant}:${mesh.name.slice(`panda-${id}-`.length)}`;
    const cached = shared.geometries.get(key);
    if (cached && !cached.isDisposed()) {
      cached.applyToMesh(mesh);
      if (geometry !== cached) geometry.dispose();
    } else shared.geometries.set(key, geometry);
  }

  let motion = 0, previousTime: number | undefined, disposed = false;
  const animate = (moving: boolean, time: number, reducedMotion: boolean): void => {
    if (disposed) return;
    const seconds = Number.isFinite(time) ? time : 0;
    const dt = previousTime === undefined ? 1 / 30 : Math.max(0, Math.min(0.05, seconds - previousTime));
    previousTime = seconds;
    motion = reducedMotion ? 0 : motion + ((moving ? 1 : 0) - motion) * (1 - Math.exp(-dt * 12));
    const cadence = seconds * 7;
    pelvis.position.y = HIP_HEIGHT + (reducedMotion ? 0 : Math.cos(cadence * 2) * 0.004 * motion);
    torso.position.y = reducedMotion ? 0 : Math.sin(seconds * 1.8) * 0.005 * (1 - motion);
    torso.rotation.z = reducedMotion ? 0 : Math.sin(cadence) * 0.018 * motion;
    head.rotation.y = reducedMotion ? 0 : Math.sin(seconds * 0.64 + (seed >>> 0) % 7) * 0.036 * (1 - motion);
    head.rotation.z = reducedMotion ? 0 : Math.sin(seconds * 0.95) * 0.015 * (1 - motion);
    head.rotation.x = reducedMotion ? 0 : Math.sin(cadence * 2) * 0.018 * motion;
    for (const { hip, knee, ankle, side } of legs) {
      const cycle = ((cadence + (side === 1 ? Math.PI : 0)) % (Math.PI * 2) + Math.PI * 2) % (Math.PI * 2);
      const fraction = cycle / (Math.PI * 2), swing = fraction < 0.5;
      const progress = swing ? fraction * 2 : (fraction - 0.5) * 2;
      const eased = progress * progress * (3 - 2 * progress);
      const z = (swing ? -0.105 + 0.21 * eased : 0.105 - 0.21 * progress) * motion;
      const lift = (swing ? Math.sin(progress * Math.PI) * 0.067 : 0) * motion;
      const drop = pelvis.position.y - ANKLE_HEIGHT - lift;
      const reach = Math.min(LEG_LENGTH * 2 - 0.00001, Math.hypot(drop, z));
      const halfBend = Math.acos(reach / (LEG_LENGTH * 2));
      hip.rotation.x = Math.atan2(-z, drop) - halfBend;
      knee.rotation.x = halfBend * 2;
      ankle.rotation.x = -hip.rotation.x - knee.rotation.x;
    }
    for (const { shoulder, elbow, side } of arms) {
      shoulder.rotation.x = reducedMotion ? 0.04 : 0.04 + Math.sin(cadence + (side === 1 ? Math.PI : 0)) * 0.31 * motion;
      shoulder.rotation.z = side * (0.16 + (reducedMotion ? 0 : Math.sin(seconds * 1.6) * 0.012 * (1 - motion)));
      elbow.rotation.x = 0.1 + (reducedMotion ? 0 : (1 + Math.sin(cadence + (side === 1 ? Math.PI : 0))) * 0.07 * motion);
    }
    const blinkTime = ((seconds + (seed >>> 0) % 13 * 0.19) % 5.7 + 5.7) % 5.7;
    const openness = reducedMotion || blinkTime > 0.15 ? 1 : 1 - Math.sin(blinkTime / 0.15 * Math.PI) * 0.91;
    for (const eye of eyes) eye.scaling.y = openness;
  };
  root.onDisposeObservable.addOnce(() => {
    disposed = true;
    for (const mesh of meshes) if (!mesh.isDisposed()) shadow.removeShadowCaster(mesh, false);
    if (--shared.users === 0) {
      for (const material of Object.values(shared.materials)) material.dispose();
      for (const geometry of shared.geometries.values()) if (!geometry.isDisposed()) geometry.dispose();
      palettes.delete(scene);
    }
  });
  animate(false, 0, true);
  return { root, variant, animate, dispose: () => root.dispose() };
}
