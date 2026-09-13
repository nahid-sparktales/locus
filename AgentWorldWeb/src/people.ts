import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import type { Geometry } from '@babylonjs/core/Meshes/geometry.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import type { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';

export const PERSON_VARIANTS = ['cropped', 'bob', 'curls', 'swept', 'bun', 'silver'] as const;
export type PersonVariant = typeof PERSON_VARIANTS[number];
export type PersonActor = {
  root: TransformNode;
  variant: PersonVariant;
  /** Time is elapsed seconds. The owning map root is never moved by animation. */
  animate(moving: boolean, time: number, reducedMotion: boolean): void;
  dispose(): void;
};

type XYZ = [number, number, number];
type SharedMaterials = { materials: Map<string, StandardMaterial>; geometries: Map<string, Geometry>; users: number };
const sceneMaterials = new WeakMap<Scene, SharedMaterials>();
const HIP_HEIGHT = 0.715, LEG_LENGTH = 0.32, ANKLE_HEIGHT = 0.10;
const LOOKS = [
  { skin: '#DDA47D', hair: '#30241E', highlight: '#604637', shirt: '#C9F54A', inner: '#F2EEE4', width: 0.47 },
  { skin: '#EBC4A7', hair: '#442B25', highlight: '#78503F', shirt: '#F2EEE4', inner: '#46613E', width: 0.445 },
  { skin: '#875538', hair: '#221D19', highlight: '#463226', shirt: '#46613E', inner: '#F2EEE4', width: 0.50 },
  { skin: '#C88A60', hair: '#20201B', highlight: '#49483C', shirt: '#292820', inner: '#C9F54A', width: 0.48 },
  { skin: '#B77751', hair: '#25221B', highlight: '#534738', shirt: '#92B9B5', inner: '#F2EEE4', width: 0.445 },
  { skin: '#F0CEB7', hair: '#ADA89A', highlight: '#DDD8CB', shirt: '#768E6A', inner: '#F2EEE4', width: 0.49 },
] as const;

/** A small, fully articulated human crew member with an uncovered expressive face. */
export function createPerson(scene: Scene, shadow: ShadowGenerator, parent: TransformNode, id: string, seed: number): PersonActor {
  const index = (seed >>> 0) % PERSON_VARIANTS.length, variant = PERSON_VARIANTS[index], look = LOOKS[index];
  let shared = sceneMaterials.get(scene);
  if (!shared) {
    shared = { materials: new Map(), geometries: new Map(), users: 0 };
    sceneMaterials.set(scene, shared);
  }
  const resources = shared;
  resources.users++;
  const material = (color: string): StandardMaterial => {
    let found = resources.materials.get(color);
    if (!found) {
      found = new StandardMaterial(`locus-person-${color.slice(1)}`, scene);
      found.diffuseColor = Color3.FromHexString(color);
      found.specularColor = new Color3(0.035, 0.035, 0.03);
      found.specularPower = 24;
      resources.materials.set(color, found);
    }
    return found;
  };
  const skin = material(look.skin), skinShade = material(Color3.FromHexString(look.skin).scale(0.68).toHexString());
  const hair = material(look.hair), hairLight = material(look.highlight);
  const shirt = material(look.shirt), inner = material(look.inner);
  const ink = material('#171713'), trousers = material('#3D3B32'), cream = material('#F2EEE4'), lime = material('#C9F54A'), white = material('#FFFFFF');
  const meshes: Mesh[] = [];
  const root = new TransformNode(`person-${id}`, scene);
  root.parent = parent;
  root.metadata = { actorID: id, personVariant: variant };
  const node = (name: string, owner: TransformNode, position: XYZ): TransformNode => {
    const pivot = new TransformNode(`person-${id}-${name}`, scene);
    pivot.parent = owner; pivot.position.set(...position); return pivot;
  };
  const finish = (mesh: Mesh, owner: TransformNode, position: XYZ, surface: StandardMaterial): Mesh => {
    mesh.parent = owner; mesh.position.set(...position); mesh.material = surface;
    mesh.metadata = { actorID: id }; mesh.isPickable = true; mesh.receiveShadows = true;
    shadow.addShadowCaster(mesh, false); meshes.push(mesh); return mesh;
  };
  const oval = (name: string, owner: TransformNode, position: XYZ, size: XYZ, surface: StandardMaterial, segments = 12): Mesh => {
    const mesh = finish(MeshBuilder.CreateSphere(`person-${id}-${name}`, { diameter: 1, segments }, scene), owner, position, surface);
    mesh.scaling.set(...size); return mesh;
  };
  const tube = (name: string, owner: TransformNode, points: XYZ[], radius: number, surface: StandardMaterial): Mesh =>
    finish(MeshBuilder.CreateTube(`person-${id}-${name}`, { path: points.map(point => new Vector3(...point)), radius, tessellation: 8, cap: Mesh.CAP_ALL }, scene), owner, [0, 0, 0], surface);

  const pelvis = node('pelvis', root, [0, HIP_HEIGHT, 0]);
  const torso = node('torso', pelvis, [0, 0, 0]);
  oval('hips', pelvis, [0, 0.029, 0], [0.375, 0.21, 0.278], trousers);
  oval('shirt-body', torso, [0, 0.292, -0.008], [look.width, 0.536, 0.31], shirt, 16);
  oval('shirt-hem', torso, [0, 0.104, -0.005], [look.width * 0.84, 0.16, 0.287], shirt);
  oval('neck', torso, [0, 0.583, 0.009], [0.155, 0.16, 0.145], skin);
  oval('undershirt-collar', torso, [0, 0.534, 0.026], [0.254, 0.076, 0.23], inner);
  // Open overshirts and a neat centre seam give the cloth a readable silhouette.
  if (index !== 2 && index !== 4) {
    oval('shirt-inset', torso, [0, 0.327, 0.143], [0.156, 0.382, 0.036], inner);
    for (const side of [-1, 1]) {
      tube(`jacket-edge-${side}`, torso, [[side * 0.101, 0.503, 0.13], [side * 0.078, 0.367, 0.163], [side * 0.085, 0.156, 0.145]], 0.008, shirt);
      oval(`jacket-pocket-${side}`, torso, [side * 0.146, 0.218, 0.134], [0.072, 0.084, 0.034], shirt);
    }
  } else {
    tube('shirt-stitch', torso, [[-0.12, 0.123, 0.12], [0, 0.112, 0.144], [0.12, 0.123, 0.12]], 0.0045, inner);
  }
  oval('lime-crew-badge', torso, [-0.126, 0.405, 0.146], [0.05, 0.069, 0.022], lime);
  oval('badge-mark', torso, [-0.126, 0.409, 0.159], [0.019, 0.022, 0.007], ink, 8);

  const head = node('head', torso, [0, 0.815, 0.007]);
  oval('face', head, [0, 0, 0], [0.403, 0.458, 0.353], skin, 20);
  oval('jaw', head, [0, -0.149, 0.008], [0.293, 0.175, 0.267], skin, 16);
  for (const side of [-1, 1]) {
    oval(`ear-${side}`, head, [side * 0.200, -0.024, -0.005], [0.073, 0.126, 0.093], skin);
    oval(`ear-detail-${side}`, head, [side * 0.221, -0.025, 0.030], [0.028, 0.065, 0.025], skinShade, 8);
  }
  const eyes: TransformNode[] = [];
  for (const side of [-1, 1]) {
    const eye = node(`eye-${side}`, head, [side * 0.082, 0.015, 0.163]);
    oval(`eye-white-${side}`, eye, [0, 0, 0], [0.067, 0.042, 0.023], white);
    oval(`iris-${side}`, eye, [-side * 0.003, 0, 0.012], [0.028, 0.033, 0.014], ink);
    oval(`eye-glint-${side}`, eye, [-0.006, 0.008, 0.020], [0.009, 0.010, 0.005], white, 8);
    eyes.push(eye);
    tube(`eyebrow-${side}`, head, [[side * 0.045, 0.078, 0.169], [side * 0.080, 0.084, 0.162], [side * 0.118, 0.073, 0.144]], 0.010, hair);
  }
  oval('nose', head, [0, -0.044, 0.182], [0.071, 0.090, 0.080], skin, 16);
  for (const side of [-1, 1]) oval(`nostril-${side}`, head, [side * 0.019, -0.073, 0.208], [0.014, 0.008, 0.008], skinShade, 8);
  tube('smile', head, [[-0.065, -0.119, 0.141], [-0.035, -0.133, 0.157], [0, -0.137, 0.164], [0.035, -0.133, 0.157], [0.065, -0.119, 0.141]], 0.006, skinShade);
  oval('lower-lip', head, [0, -0.148, 0.145], [0.061, 0.011, 0.013], skin, 8);

  // Hair is modelled around the uncovered forehead, with distinct back profiles.
  oval('hair-crown', head, [0, 0.151, -0.030], [0.413, 0.230, 0.349], hair, 16);
  if (variant === 'bob') {
    oval('bob-back', head, [0, -0.007, -0.112], [0.430, 0.448, 0.237], hair, 16);
    for (const side of [-1, 1]) {
      oval(`bob-side-${side}`, head, [side * 0.176, -0.025, -0.043], [0.095, 0.346, 0.168], hair);
      tube(`bob-lock-${side}`, head, [[side * 0.152, 0.143, -0.012], [side * 0.206, 0.035, -0.016], [side * 0.202, -0.130, -0.04]], 0.009, hairLight);
    }
    oval('bob-fringe', head, [-0.04, 0.139, 0.108], [0.286, 0.140, 0.116], hair).rotation.z = -0.21;
  } else if (variant === 'curls') {
    for (let curl = 0; curl < 10; curl++) {
      const angle = curl / 10 * Math.PI * 2;
      oval(`curl-${curl}`, head, [Math.cos(angle) * 0.16, 0.167 + (curl % 3) * 0.014, Math.sin(angle) * 0.115 - 0.028], [0.156, 0.163, 0.148], hair);
    }
    oval('curl-top', head, [0.025, 0.216, -0.030], [0.21, 0.14, 0.23], hair);
    for (const side of [-1, 1]) oval(`curl-side-${side}`, head, [side * 0.19, 0.089, -0.070], [0.12, 0.19, 0.20], hair);
  } else if (variant === 'bun') {
    oval('hair-back', head, [0, 0.022, -0.138], [0.37, 0.356, 0.16], hair);
    oval('bun', head, [0, 0.183, -0.223], [0.218, 0.207, 0.190], hair, 16);
    oval('bun-tie', head, [0, 0.163, -0.223], [0.222, 0.037, 0.193], lime);
    for (const side of [-1, 1]) tube(`swept-lock-${side}`, head, [[side * 0.07, 0.223, 0.01], [side * 0.164, 0.153, -0.017], [side * 0.185, 0.07, -0.092]], 0.009, hairLight);
  } else {
    for (const side of [-1, 1]) oval(`short-side-${side}`, head, [side * 0.169, 0.085, -0.048], [0.068, 0.197, 0.214], hair);
    const fringe = oval('swept-fringe', head, [-0.047, 0.176, 0.089], [0.32, variant === 'cropped' ? 0.092 : 0.136, 0.165], hair, 16);
    fringe.rotation.z = -0.18;
    if (variant !== 'cropped') for (const offset of [-0.05, 0.005, 0.060]) {
      tube(`hair-part-${offset}`, head, [[-0.12 + offset, 0.173, 0.153], [-0.04 + offset, 0.236, 0.106], [0.06 + offset, 0.244, 0.025]], 0.006, hairLight);
    }
  }

  const arms: { shoulder: TransformNode; elbow: TransformNode; side: number }[] = [];
  const legs: { hip: TransformNode; knee: TransformNode; ankle: TransformNode; side: number }[] = [];
  for (const side of [-1, 1]) {
    const shoulder = node(`shoulder-${side}`, torso, [side * (look.width / 2 - 0.016), 0.454, 0]);
    shoulder.rotation.z = side * 0.115;
    oval(`sleeve-${side}`, shoulder, [0, -0.098, 0], [0.182, 0.276, 0.198], shirt);
    oval(`sleeve-cuff-${side}`, shoulder, [0, -0.203, 0], [0.149, 0.066, 0.160], inner);
    const elbow = node(`elbow-${side}`, shoulder, [0, -0.237, 0]);
    oval(`forearm-${side}`, elbow, [0, -0.094, 0.007], [0.133, 0.230, 0.141], skin);
    oval(`hand-${side}`, elbow, [0, -0.209, 0.014], [0.142, 0.159, 0.109], skin);
    oval(`thumb-${side}`, elbow, [-side * 0.060, -0.183, 0.040], [0.053, 0.089, 0.052], skin);
    if (side === -1) {
      oval('watch-band', elbow, [0, -0.155, 0.013], [0.139, 0.039, 0.147], ink);
      oval('watch-face', elbow, [0, -0.154, 0.086], [0.053, 0.039, 0.015], lime);
    }
    arms.push({ shoulder, elbow, side });

    const hip = node(`hip-${side}`, pelvis, [side * 0.116, 0, 0]);
    oval(`thigh-${side}`, hip, [0, -0.151, 0], [0.207, 0.359, 0.220], trousers);
    const knee = node(`knee-${side}`, hip, [0, -LEG_LENGTH, 0]);
    oval(`trouser-leg-${side}`, knee, [0, -0.147, 0], [0.169, 0.348, 0.181], trousers);
    const ankle = node(`foot-${side}`, knee, [0, -LEG_LENGTH, 0]);
    oval(`shoe-${side}`, ankle, [0, -0.022, 0.053], [0.19, 0.126, 0.285], ink, 16);
    oval(`sole-${side}`, ankle, [0, -0.079, 0.054], [0.197, 0.042, 0.292], cream, 16);
    tube(`shoe-stripe-${side}`, ankle, [[side * 0.086, -0.013, 0.040], [side * 0.092, -0.025, 0.100], [side * 0.079, -0.031, 0.141]], 0.010, lime);
    legs.push({ hip, knee, ankle, side });
  }

  // Static details share a draw call only within a rigid joint and material.
  const groups = new Map<TransformNode, Map<StandardMaterial, Mesh[]>>();
  for (const mesh of meshes) {
    const owner = mesh.parent as TransformNode, surface = mesh.material as StandardMaterial;
    let materials = groups.get(owner);
    if (!materials) { materials = new Map(); groups.set(owner, materials); }
    const parts = materials.get(surface) || [];
    parts.push(mesh); materials.set(surface, parts);
  }
  for (const [owner, materials] of groups) for (const [surface, parts] of materials) {
    if (parts.length < 2) continue;
    const local = owner.computeWorldMatrix(true).clone().invert();
    for (const part of parts) { part.computeWorldMatrix(true); shadow.removeShadowCaster(part, false); }
    const combined = Mesh.MergeMeshes(parts, true, true, undefined, false, false);
    if (!combined) { for (const part of parts) shadow.addShadowCaster(part, false); continue; }
    combined.bakeTransformIntoVertices(local);
    combined.position.setAll(0); combined.rotation.setAll(0); combined.rotationQuaternion = null; combined.scaling.setAll(1);
    combined.name = `${owner.name}-${surface.name}-merged`;
    finish(combined, owner, [0, 0, 0], surface);
  }
  for (const mesh of root.getChildMeshes() as Mesh[]) {
    const geometry = mesh.geometry;
    if (!geometry) continue;
    const key = `${variant}:${mesh.name.slice(`person-${id}-`.length)}`;
    const cached = resources.geometries.get(key);
    if (cached && !cached.isDisposed()) {
      cached.applyToMesh(mesh);
      if (geometry !== cached) geometry.dispose();
    } else resources.geometries.set(key, geometry);
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
    torso.position.y = reducedMotion ? 0 : Math.sin(seconds * 1.8) * 0.003 * (1 - motion);
    torso.rotation.z = reducedMotion ? 0 : Math.sin(cadence) * 0.011 * motion;
    head.rotation.y = reducedMotion ? 0 : Math.sin(seconds * 0.64 + (seed >>> 0) % 7) * 0.037 * (1 - motion);
    head.rotation.z = reducedMotion ? 0 : Math.sin(seconds * 0.95) * 0.009 * (1 - motion);
    head.rotation.x = reducedMotion ? 0 : Math.sin(cadence * 2) * 0.011 * motion;
    for (const { hip, knee, ankle, side } of legs) {
      const cycle = ((cadence + (side === 1 ? Math.PI : 0)) % (Math.PI * 2) + Math.PI * 2) % (Math.PI * 2);
      const fraction = cycle / (Math.PI * 2), swing = fraction < 0.5;
      const progress = swing ? fraction * 2 : (fraction - 0.5) * 2;
      const eased = progress * progress * (3 - 2 * progress);
      const z = (swing ? -0.12 + 0.24 * eased : 0.12 - 0.24 * progress) * motion;
      const lift = (swing ? Math.sin(progress * Math.PI) * 0.071 : 0) * motion;
      const drop = pelvis.position.y - ANKLE_HEIGHT - lift;
      const reach = Math.min(LEG_LENGTH * 2 - 0.00001, Math.hypot(drop, z));
      const halfBend = Math.acos(reach / (LEG_LENGTH * 2));
      hip.rotation.x = Math.atan2(-z, drop) - halfBend;
      knee.rotation.x = halfBend * 2;
      ankle.rotation.x = -hip.rotation.x - knee.rotation.x;
    }
    for (const { shoulder, elbow, side } of arms) {
      const stride = Math.sin(cadence + (side === 1 ? Math.PI : 0));
      shoulder.rotation.x = reducedMotion ? 0.03 : 0.03 + stride * 0.34 * motion;
      shoulder.rotation.z = side * (0.115 + (reducedMotion ? 0 : Math.sin(seconds * 1.6) * 0.008 * (1 - motion)));
      elbow.rotation.x = 0.085 + (reducedMotion ? 0 : (1 + stride) * 0.065 * motion);
    }
    const blinkTime = ((seconds + (seed >>> 0) % 13 * 0.19) % 5.7 + 5.7) % 5.7;
    const openness = reducedMotion || blinkTime > 0.15 ? 1 : 1 - Math.sin(blinkTime / 0.15 * Math.PI) * 0.92;
    for (const eye of eyes) eye.scaling.y = openness;
  };
  root.onDisposeObservable.addOnce(() => {
    disposed = true;
    for (const mesh of meshes) if (!mesh.isDisposed()) shadow.removeShadowCaster(mesh, false);
    if (--resources.users === 0) {
      for (const surface of resources.materials.values()) surface.dispose();
      for (const geometry of resources.geometries.values()) if (!geometry.isDisposed()) geometry.dispose();
      sceneMaterials.delete(scene);
    }
  });
  animate(false, 0, true);
  return { root, variant, animate, dispose: () => root.dispose() };
}
