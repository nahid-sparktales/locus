import { Scene } from '@babylonjs/core/scene.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { Mesh } from '@babylonjs/core/Meshes/mesh.js';
import type { Geometry } from '@babylonjs/core/Meshes/geometry.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { Color3 } from '@babylonjs/core/Maths/math.color.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import type { ShadowGenerator } from '@babylonjs/core/Lights/Shadows/shadowGenerator.js';

export const ISLAND_CREW_VARIANTS = ['straw-hat', 'swordsman', 'reindeer-doctor', 'navigator', 'archaeologist', 'shipwright', 'helmsman', 'marine'] as const;
export type IslandCrewVariant = typeof ISLAND_CREW_VARIANTS[number];
export type IslandCrew = {
  root: TransformNode;
  count: number;
  variants: readonly IslandCrewVariant[];
  /** Time is elapsed seconds. Only actual work animates the landing party. */
  animate(working: boolean, timeSeconds: number, reducedMotion: boolean): void;
  dispose(): void;
};

type XYZ = [number, number, number];
const COLORS = {
  ink: '#202A35', skin: '#F6C8A0', tan: '#CA9361', cream: '#FFF2D8', white: '#FFFFFF',
  straw: '#E7BD61', strawDark: '#B98238', red: '#DF493D', coral: '#F18178',
  blue: '#3469A4', navy: '#244467', teal: '#52B1BD', seaBlue: '#74C6D3',
  green: '#69AF59', forest: '#32674F', gold: '#EEC657', orange: '#F18C34',
  purple: '#8464AC', pink: '#EA8AAF', silver: '#A9C6D0', wood: '#80573D',
} as const;
type Palette = { [K in keyof typeof COLORS]: StandardMaterial };
type SharedAssets = { palette: Palette; geometries: Map<string, Geometry>; users: number };
const sharedByScene = new WeakMap<Scene, SharedAssets>();
const HIP_HEIGHT = 0.216, LEG_LENGTH = 0.094, ANKLE_HEIGHT = 0.028;

function crewHash(id: string, seed: number): number {
  let hash = (2166136261 ^ (Number.isFinite(seed) ? seed : 0)) >>> 0;
  for (let i = 0; i < id.length; i++) hash = Math.imul(hash ^ id.charCodeAt(i), 16777619) >>> 0;
  return hash;
}

/** Stable roster independent of transient status, render order, or frame time. */
export function islandCrewVariants(agentID: string, seed = 0): readonly IslandCrewVariant[] {
  const hash = crewHash(agentID, seed), count = 2 + ((hash >>> 4) % 2);
  return Array.from({ length: count }, (_, index) => ISLAND_CREW_VARIANTS[(hash + index * 3) % ISLAND_CREW_VARIANTS.length]);
}

function acquireAssets(scene: Scene): SharedAssets {
  let shared = sharedByScene.get(scene);
  if (!shared) {
    const palette = Object.fromEntries(Object.entries(COLORS).map(([name, hex]) => {
      const material = new StandardMaterial(`island-crew-${name}`, scene);
      material.diffuseColor = Color3.FromHexString(hex);
      material.specularColor = new Color3(0.055, 0.065, 0.065);
      material.specularPower = 28;
      if (name === 'silver') { material.specularColor.set(0.32, 0.38, 0.4); material.specularPower = 48; }
      return [name, material];
    })) as Palette;
    shared = { palette, geometries: new Map(), users: 0 };
    sharedByScene.set(scene, shared);
  }
  shared.users++;
  return shared;
}

/**
 * A miniature, articulated landing party: straw-hat adventurers, a green-haired
 * swordsman, reindeer doctor, navigator, archaeologist, cyborg shipwright,
 * fish-man helmsman and white-coated marine. All geometry is authored locally.
 * The supplied parent is the top of a 1.5 × .82 pier plaza, facing +Z to sea.
 */
export function createIslandCrew(scene: Scene, shadow: ShadowGenerator, parent: TransformNode, agentID: string, seed: number): IslandCrew {
  const shared = acquireAssets(scene), p = shared.palette;
  const variants = islandCrewVariants(agentID, seed);
  const root = new TransformNode(`island-crew-${agentID}`, scene);
  root.parent = parent;
  root.metadata = { actorID: agentID, islandCrew: true };
  const liveMeshes: Mesh[] = [];
  const performers: Array<(working: boolean, time: number, reducedMotion: boolean) => void> = [];

  variants.forEach((variant, index) => {
    const prefix = `island-crew-${agentID}-${index}-`;
    const person = new TransformNode(`${prefix}${variant}`, scene);
    person.parent = root;
    person.metadata = { actorID: agentID, crewVariant: variant };
    const parts: Mesh[] = [];
    const node = (name: string, owner: TransformNode, at: XYZ): TransformNode => {
      const pivot = new TransformNode(`${prefix}${name}`, scene);
      pivot.parent = owner; pivot.position.set(...at); return pivot;
    };
    const finish = (mesh: Mesh, owner: TransformNode, at: XYZ, material: StandardMaterial): Mesh => {
      mesh.parent = owner; mesh.position.set(...at); mesh.material = material;
      mesh.metadata = { actorID: agentID, crewVariant: variant, islandCrew: true };
      mesh.isPickable = true; mesh.receiveShadows = true;
      shadow.addShadowCaster(mesh, false); parts.push(mesh); return mesh;
    };
    const oval = (name: string, owner: TransformNode, at: XYZ, size: XYZ, material: StandardMaterial, segments = 10): Mesh => {
      const mesh = finish(MeshBuilder.CreateSphere(`${prefix}${name}`, { diameter: 1, segments }, scene), owner, at, material);
      mesh.scaling.set(...size); return mesh;
    };
    const box = (name: string, owner: TransformNode, at: XYZ, size: XYZ, material: StandardMaterial): Mesh =>
      finish(MeshBuilder.CreateBox(`${prefix}${name}`, { width: size[0], height: size[1], depth: size[2] }, scene), owner, at, material);
    const cylinder = (name: string, owner: TransformNode, at: XYZ, height: number, bottom: number, top: number, material: StandardMaterial, sides = 12): Mesh =>
      finish(MeshBuilder.CreateCylinder(`${prefix}${name}`, { height, diameterTop: top, diameterBottom: bottom, tessellation: sides }, scene), owner, at, material);
    const tube = (name: string, owner: TransformNode, path: XYZ[], radius: number, material: StandardMaterial): Mesh =>
      finish(MeshBuilder.CreateTube(`${prefix}${name}`, { path: path.map(at => new Vector3(...at)), radius, tessellation: 6, cap: Mesh.CAP_ALL }, scene), owner, [0, 0, 0], material);
    const disc = (name: string, owner: TransformNode, at: XYZ, diameter: number, thickness: number, material: StandardMaterial): Mesh =>
      cylinder(name, owner, at, thickness, diameter, diameter, material, 20);
    const star = (name: string, owner: TransformNode, at: XYZ, radius: number, material: StandardMaterial): void => {
      for (let ray = 0; ray < 5; ray++) {
        const angle = ray * Math.PI * 2 / 5;
        const beam = box(`${name}-${ray}`, owner, [at[0] + Math.sin(angle) * radius * 0.34, at[1] + Math.cos(angle) * radius * 0.34, at[2]], [radius * 0.24, radius * 0.82, 0.003], material);
        beam.rotation.z = -angle;
      }
    };

    const doctor = variant === 'reindeer-doctor', broad = variant === 'shipwright' || variant === 'helmsman';
    const skin = variant === 'helmsman' ? p.seaBlue : doctor ? p.tan : p.skin;
    const shirt = ({ 'straw-hat': p.red, swordsman: p.green, 'reindeer-doctor': p.coral, navigator: p.cream, archaeologist: p.purple, shipwright: p.red, helmsman: p.orange, marine: p.white } as const)[variant];
    const trousers = variant === 'swordsman' ? p.forest : variant === 'helmsman' ? p.purple : p.blue;
    const pelvis = node('pelvis', person, [0, HIP_HEIGHT, 0]);
    const torso = node('torso', pelvis, [0, 0, 0]);
    const width = broad ? 0.185 : doctor ? 0.145 : 0.14;
    oval('shirt', torso, [0, 0.097, -0.002], [width, 0.215, broad ? 0.134 : 0.112], shirt, 12);
    oval('waist', torso, [0, 0.005, 0], [width * 0.81, 0.053, 0.109], trousers);
    oval('neck', torso, [0, 0.218, 0], [0.062, 0.057, 0.056], skin);
    const head = node('head', torso, [0, doctor ? 0.305 : 0.318, 0]);
    oval('face', head, [0, 0, 0], doctor ? [0.174, 0.157, 0.145] : broad ? [0.169, 0.176, 0.15] : [0.151, 0.174, 0.144], skin, 14);
    for (const side of [-1, 1]) {
      oval(`ear-${side}`, head, [side * 0.078, -0.008, 0], [0.027, 0.041, 0.036], skin);
      oval(`eye-white-${side}`, head, [side * 0.032, 0.012, 0.065], [0.025, 0.035, 0.019], p.cream);
      oval(`eye-${side}`, head, [side * 0.032, 0.012, 0.074], [0.011, 0.019, 0.008], p.ink, 8);
      oval(`eye-light-${side}`, head, [side * 0.032 - 0.003, 0.017, 0.078], [0.004, 0.006, 0.003], p.white, 6);
      tube(`brow-${side}`, head, [[side * 0.017, 0.038, 0.062], [side * 0.042, 0.042, 0.058]], 0.0033, p.ink);
    }
    oval('nose', head, [0, -0.017, 0.076], doctor ? [0.032, 0.019, 0.027] : [0.019, 0.025, 0.022], doctor ? p.blue : skin);
    tube('smile', head, [[-0.021, -0.039, 0.063], [0, -0.043, 0.069], [0.021, -0.039, 0.063]], 0.003, p.ink);

    const arms: Array<{ shoulder: TransformNode; elbow: TransformNode; side: number }> = [];
    const legs: Array<{ hip: TransformNode; knee: TransformNode; ankle: TransformNode; side: number }> = [];
    for (const side of [-1, 1]) {
      const shoulder = node(`shoulder-${side}`, torso, [side * (broad ? 0.098 : 0.077), 0.177, 0]);
      const armWidth = variant === 'shipwright' ? 0.073 : broad ? 0.06 : 0.045;
      oval(`sleeve-${side}`, shoulder, [0, -0.025, 0], [armWidth + 0.008, 0.074, armWidth + 0.008], variant === 'straw-hat' || variant === 'navigator' ? skin : shirt);
      oval(`upper-arm-${side}`, shoulder, [0, -0.059, 0], [armWidth, 0.082, armWidth], skin);
      const elbow = node(`elbow-${side}`, shoulder, [0, -0.087, 0]);
      oval(`forearm-${side}`, elbow, [0, -0.026, 0.005], [armWidth, 0.075, armWidth], variant === 'shipwright' ? p.silver : skin);
      oval(`hand-${side}`, elbow, [0, -0.064, 0.009], [armWidth + 0.004, 0.05, armWidth + 0.004], skin);
      if (variant === 'shipwright') star(`forearm-star-${side}`, elbow, [0, -0.025, armWidth / 2 + 0.007], 0.024, p.blue);
      arms.push({ shoulder, elbow, side });

      const hip = node(`hip-${side}`, pelvis, [side * 0.039, 0, 0]);
      oval(`thigh-${side}`, hip, [0, -0.041, 0], [0.063, 0.108, 0.068], trousers);
      const knee = node(`knee-${side}`, hip, [0, -LEG_LENGTH, 0]);
      oval(`shin-${side}`, knee, [0, -0.044, 0], [0.049, 0.105, 0.052], variant === 'straw-hat' || doctor || variant === 'shipwright' ? skin : trousers);
      const ankle = node(`ankle-${side}`, knee, [0, -LEG_LENGTH, 0]);
      oval(`foot-${side}`, ankle, [0, 0, 0.016], [0.059, ANKLE_HEIGHT * 2, 0.091], variant === 'straw-hat' ? p.wood : p.ink);
      legs.push({ hip, knee, ankle, side });
    }

    // Hair and headwear create readable silhouettes even at the map's scale.
    const hair = variant === 'swordsman' ? p.green : variant === 'navigator' ? p.orange : variant === 'shipwright' ? p.teal : p.ink;
    if (!doctor) {
      oval('hair-crown', head, [0, 0.058, -0.023], [0.163, 0.092, 0.14], hair);
      for (const side of [-1, 1]) oval(`sideburn-${side}`, head, [side * 0.069, 0.016, -0.006], [0.032, 0.09, 0.06], hair);
    }

    if (variant === 'straw-hat') {
      disc('straw-brim', head, [0, 0.089, -0.003], 0.238, 0.017, p.straw);
      oval('straw-crown', head, [0, 0.114, -0.009], [0.156, 0.105, 0.144], p.straw);
      cylinder('red-hat-band', head, [0, 0.10, -0.009], 0.023, 0.153, 0.147, p.red, 20);
      for (const side of [-1, 1]) {
        const vest = oval(`open-vest-${side}`, torso, [side * 0.045, 0.11, 0.048], [0.064, 0.182, 0.042], p.red);
        vest.rotation.z = side * 0.1;
        oval(`vest-button-${side}`, torso, [side * 0.028, 0.056, 0.074], [0.008, 0.008, 0.005], p.gold, 6);
      }
      oval('open-shirt-chest', torso, [0, 0.111, 0.053], [0.053, 0.16, 0.038], skin);
      box('yellow-sash', torso, [0, 0.016, 0.04], [0.135, 0.025, 0.05], p.gold);
      box('sash-tail', torso, [-0.061, -0.015, 0.049], [0.026, 0.075, 0.015], p.gold).rotation.z = -0.13;
      tube('cheek-scar', head, [[0.035, -0.013, 0.065], [0.055, -0.01, 0.054]], 0.0025, p.ink);
      const hand = arms[1].elbow;
      cylinder('mallet-handle', hand, [0, -0.09, 0.032], 0.1, 0.015, 0.015, p.wood, 8);
      box('mallet-head', hand, [0, -0.133, 0.032], [0.073, 0.035, 0.04], p.wood);
    } else if (variant === 'swordsman') {
      for (let tuft = 0; tuft < 7; tuft++) {
        const x = (tuft - 3) * 0.022;
        const spike = cylinder(`green-spike-${tuft}`, head, [x, 0.095 - Math.abs(x) * 0.25, -0.004], 0.067, 0.039, 0, p.green, 5);
        spike.rotation.z = -x * 4;
      }
      box('dark-obi', torso, [0, 0.022, 0.01], [0.14, 0.034, 0.119], p.forest);
      tube('robe-collar', torso, [[-0.045, 0.193, 0.047], [0.018, 0.064, 0.066], [0.055, 0.159, 0.047]], 0.009, p.forest);
      for (let sword = 0; sword < 3; sword++) {
        const scabbard = node(`sword-${sword}`, torso, [0.078, 0.025 + sword * 0.018, -0.035]);
        scabbard.rotation.z = 0.25 + sword * 0.1;
        cylinder('sheath', scabbard, [0, -0.082, 0], 0.18, 0.014, 0.018, sword === 1 ? p.cream : p.ink, 8);
        cylinder('sword-grip', scabbard, [0, 0.038, 0], 0.058, 0.014, 0.014, p.wood, 8);
        disc('sword-guard', scabbard, [0, 0.007, 0], 0.041, 0.007, p.gold);
      }
      for (let earring = 0; earring < 3; earring++) oval(`earring-${earring}`, head, [0.079 + earring * 0.007, -0.038, 0.015], [0.005, 0.023, 0.006], p.gold, 6);
      tube('closed-eye-scar', head, [[-0.036, 0.042, 0.068], [-0.032, -0.013, 0.073]], 0.0025, p.ink);
    } else if (doctor) {
      for (const side of [-1, 1]) {
        oval(`deer-ear-${side}`, head, [side * 0.091, 0.018, -0.013], [0.069, 0.038, 0.032], p.tan).rotation.z = side * 0.27;
        tube(`antler-${side}`, head, [[side * 0.065, 0.061, -0.034], [side * 0.101, 0.119, -0.042], [side * 0.104, 0.173, -0.043]], 0.009, p.wood);
        tube(`antler-prong-${side}`, head, [[side * 0.096, 0.115, -0.041], [side * 0.133, 0.136, -0.043]], 0.008, p.wood);
      }
      oval('deer-muzzle', head, [0, -0.035, 0.062], [0.088, 0.059, 0.048], p.cream);
      oval('blue-reindeer-nose', head, [0, -0.019, 0.092], [0.029, 0.019, 0.018], p.blue);
      disc('doctor-hat-brim', head, [0, 0.071, 0], 0.212, 0.018, p.pink);
      cylinder('doctor-hat', head, [0, 0.109, -0.006], 0.076, 0.153, 0.149, p.teal, 16);
      box('hat-cross-vertical', head, [0, 0.11, 0.071], [0.014, 0.042, 0.007], p.white);
      box('hat-cross-horizontal', head, [0, 0.11, 0.071], [0.042, 0.014, 0.008], p.white);
      box('medical-bag', torso, [0.061, 0.044, -0.043], [0.057, 0.063, 0.042], p.cream);
      tube('bag-strap', torso, [[-0.052, 0.193, -0.025], [0.003, 0.124, 0.06], [0.062, 0.046, -0.018]], 0.007, p.wood);
      box('bag-cross-v', torso, [0.061, 0.044, -0.065], [0.008, 0.028, 0.004], p.red);
      box('bag-cross-h', torso, [0.061, 0.044, -0.065], [0.026, 0.008, 0.005], p.red);
    } else if (variant === 'navigator' || variant === 'archaeologist') {
      const longHair = oval('long-hair', head, [0, -0.035, -0.052], [0.176, 0.254, 0.074], hair);
      longHair.rotation.x = -0.08;
      for (const side of [-1, 1]) {
        const lock = oval(`hair-lock-${side}`, head, [side * 0.067, -0.032, 0.003], [0.041, 0.21, 0.049], hair);
        lock.rotation.z = side * 0.07;
      }
      tube('hair-part', head, [[-0.055, 0.057, 0.047], [0.002, 0.077, 0.057], [0.058, 0.048, 0.04]], 0.014, hair);
      if (variant === 'navigator') {
        for (const y of [0.12, 0.145, 0.17]) box(`shirt-stripe-${y}`, torso, [0, y, 0.052], [0.119, 0.008, 0.01], p.teal);
        oval('log-pose-bracelet', arms[0].elbow, [0, -0.048, 0], [0.058, 0.018, 0.052], p.gold);
        oval('log-pose-dial', arms[0].elbow, [0, -0.048, 0.028], [0.029, 0.027, 0.017], p.teal);
        box('chart', arms[0].elbow, [0.01, -0.071, 0.043], [0.083, 0.061, 0.008], p.cream);
        tube('chart-route', arms[0].elbow, [[-0.021, -0.088, 0.048], [-0.004, -0.081, 0.048], [0.006, -0.064, 0.048], [0.035, -0.054, 0.048]], 0.0025, p.blue);
      } else {
        cylinder('long-skirt', torso, [0, -0.03, -0.005], 0.119, 0.148, 0.116, p.blue);
        tube('purple-collar', torso, [[-0.044, 0.198, 0.04], [0, 0.159, 0.061], [0.044, 0.198, 0.04]], 0.008, p.cream);
        for (const side of [-1, 1]) oval(`sunglass-${side}`, head, [side * 0.034, 0.074, 0.059], [0.046, 0.022, 0.014], p.purple);
        box('book-cover', arms[0].elbow, [0.01, -0.071, 0.031], [0.069, 0.087, 0.016], p.purple);
        box('book-pages', arms[0].elbow, [0.01, -0.071, 0.041], [0.06, 0.073, 0.009], p.cream);
        for (const y of [-0.089, -0.076, -0.063]) box(`book-line-${y}`, arms[0].elbow, [0.01, y, 0.046], [0.041, 0.002, 0.002], p.wood);
      }
    } else if (variant === 'shipwright') {
      const pompadour = oval('blue-pompadour', head, [0, 0.09, 0.028], [0.143, 0.094, 0.173], p.teal);
      pompadour.rotation.x = 0.35;
      oval('bare-chest', torso, [0, 0.109, 0.06], [0.111, 0.159, 0.046], skin);
      for (const side of [-1, 1]) {
        for (const y of [0.064, 0.144]) star(`shirt-flower-${side}-${y}`, torso, [side * 0.068, y, 0.053], 0.016, p.gold);
        oval(`goggle-${side}`, head, [side * 0.035, 0.043, 0.07], [0.047, 0.026, 0.02], p.silver);
        oval(`goggle-lens-${side}`, head, [side * 0.035, 0.043, 0.081], [0.035, 0.018, 0.009], p.navy);
      }
      cylinder('wrench-shaft', arms[1].elbow, [0, -0.101, 0.035], 0.094, 0.014, 0.014, p.silver, 8);
      box('wrench-jaw', arms[1].elbow, [0, -0.144, 0.034], [0.047, 0.024, 0.018], p.silver);
      box('wrench-opening', arms[1].elbow, [0, -0.154, 0.044], [0.018, 0.019, 0.004], p.ink);
      tube('chin-plates', head, [[-0.044, -0.05, 0.047], [0, -0.069, 0.064], [0.044, -0.05, 0.047]], 0.01, p.silver);
    } else if (variant === 'helmsman') {
      oval('topknot', head, [0, 0.108, -0.024], [0.069, 0.055, 0.071], p.ink);
      for (const side of [-1, 1]) {
        const fang = cylinder(`fang-${side}`, head, [side * 0.028, -0.039, 0.069], 0.033, 0.016, 0, p.cream, 6);
        fang.rotation.z = side * 0.13;
        tube(`side-fin-${side}`, head, [[side * 0.069, 0.036, -0.015], [side * 0.101, 0.011, -0.005], [side * 0.082, -0.025, 0.011]], 0.013, p.seaBlue);
        for (const y of [0.074, 0.139]) {
          const diamond = box(`kimono-diamond-${side}-${y}`, torso, [side * 0.056, y, 0.064], [0.035, 0.035, 0.005], p.gold);
          diamond.rotation.z = Math.PI / 4;
        }
      }
      tube('kimono-lapel', torso, [[-0.061, 0.203, 0.044], [0.024, 0.042, 0.074], [0.066, 0.176, 0.047]], 0.014, p.navy);
      box('kimono-obi', torso, [0, 0.023, 0.049], [0.161, 0.036, 0.05], p.purple);
      for (let ring = 0; ring < 3; ring++) {
        const rope = MeshBuilder.CreateTorus(`${prefix}rope-coil-${ring}`, { diameter: 0.069 + ring * 0.012, thickness: 0.006, tessellation: 16 }, scene);
        finish(rope, arms[0].elbow, [0.01, -0.095, 0.035], p.strawDark).rotation.x = Math.PI / 2;
      }
    } else {
      cylinder('marine-cap', head, [0, 0.075, 0], 0.052, 0.168, 0.147, p.white, 16);
      oval('marine-cap-visor', head, [0, 0.051, 0.07], [0.144, 0.018, 0.111], p.blue);
      box('cap-blue-band', head, [0, 0.069, 0.078], [0.111, 0.012, 0.008], p.blue);
      tube('cap-seagull', head, [[-0.023, 0.09, 0.078], [-0.012, 0.095, 0.081], [0, 0.089, 0.083], [0.013, 0.096, 0.081], [0.024, 0.091, 0.078]], 0.0025, p.blue);
      for (const side of [-1, 1]) {
        box(`coat-tail-${side}`, torso, [side * 0.052, -0.019, -0.023], [0.055, 0.125, 0.089], p.white).rotation.z = side * 0.09;
        box(`epaulette-${side}`, torso, [side * 0.078, 0.207, 0], [0.046, 0.011, 0.066], p.gold);
      }
      box('blue-neckerchief', torso, [0, 0.176, 0.06], [0.081, 0.025, 0.022], p.blue);
      box('tie', torso, [0, 0.128, 0.062], [0.019, 0.077, 0.014], p.blue).rotation.z = -0.08;
      box('clipboard', arms[0].elbow, [0.014, -0.073, 0.036], [0.076, 0.099, 0.014], p.wood);
      box('clipboard-paper', arms[0].elbow, [0.014, -0.073, 0.045], [0.064, 0.08, 0.005], p.cream);
      box('clipboard-clip', arms[0].elbow, [0.014, -0.029, 0.049], [0.034, 0.013, 0.009], p.silver);
      for (const y of [-0.049, -0.064, -0.079]) box(`manifest-line-${y}`, arms[0].elbow, [0.014, y, 0.049], [0.041, 0.002, 0.002], p.blue);
    }

    // Each color draws once per rigid joint. References share completed joint
    // geometry between landing parties, while retaining independent animation.
    const groups = new Map<TransformNode, Map<StandardMaterial, Mesh[]>>();
    for (const mesh of parts) {
      const owner = mesh.parent as TransformNode, material = mesh.material as StandardMaterial;
      let materials = groups.get(owner);
      if (!materials) { materials = new Map(); groups.set(owner, materials); }
      const group = materials.get(material) || [];
      group.push(mesh); materials.set(material, group);
    }
    for (const [owner, materials] of groups) for (const [material, group] of materials) {
      if (group.length < 2) continue;
      const local = owner.computeWorldMatrix(true).clone().invert();
      for (const mesh of group) { mesh.computeWorldMatrix(true); shadow.removeShadowCaster(mesh, false); }
      const combined = Mesh.MergeMeshes(group, true, true, undefined, false, false);
      if (!combined) { for (const mesh of group) shadow.addShadowCaster(mesh, false); continue; }
      combined.bakeTransformIntoVertices(local);
      combined.position.setAll(0); combined.rotation.setAll(0); combined.rotationQuaternion = null; combined.scaling.setAll(1);
      combined.name = `${owner.name}-${material.name}-merged`;
      finish(combined, owner, [0, 0, 0], material);
    }
    for (const mesh of person.getChildMeshes() as Mesh[]) {
      const geometry = mesh.geometry;
      if (!geometry) continue;
      const key = `${variant}:${mesh.name.slice(prefix.length)}`;
      const cached = shared.geometries.get(key);
      if (cached && !cached.isDisposed()) {
        cached.applyToMesh(mesh);
        if (geometry !== cached) geometry.dispose();
      } else shared.geometries.set(key, geometry);
      liveMeshes.push(mesh);
    }

    const homeX = variants.length === 3 ? (index - 1) * 0.31 : (index - 0.5) * 0.46;
    // Walk together to keep space between crew members on the narrow pier;
    // individual gait and work rhythms keep the party from moving in lockstep.
    const phaseOffset = (crewHash(agentID, seed) % 997) / 997 * 13;
    person.position.x = homeX;
    performers.push((working, time, reducedMotion) => {
      // Queued and attention states are still. Movement never implies invented
      // progress; the world owns the truth of whether this party is working.
      const active = working && !reducedMotion;
      const phase = active ? ((time + phaseOffset) % 13 + 13) % 13 : 0;
      const walking = active && phase < 4;
      const route = Math.max(0, Math.min(1, (phase - 0.35) / 3.3));
      const easedRoute = route * route * (3 - 2 * route);
      const routeAngle = easedRoute * Math.PI * 2;
      const walk = walking ? Math.sin(route * Math.PI) : 0;
      const cadence = phase * 9 + index * 1.9;
      const work = active && !walking ? Math.sin((phase - 4) * 3.7 + index * 1.4) : 0;
      person.position.set(homeX + (walking ? Math.sin(routeAngle) * 0.08 : 0), 0, walking ? (Math.cos(routeAngle) - 1) * 0.011 : 0);
      // Face the route tangent while walking. Turn on the spot before leaving
      // and after returning, so sideways shuffling never replaces the gait.
      const turn = (value: number): number => { const fraction = Math.max(0, Math.min(1, value)); return fraction * fraction * (3 - 2 * fraction); };
      person.rotation.y = !walking ? 0 : phase < 0.35 ? Math.PI / 2 * turn(phase / 0.35)
        : phase > 3.65 ? Math.PI / 2 * (1 - turn((phase - 3.65) / 0.35))
          : Math.atan2(0.08 * Math.cos(routeAngle), -0.011 * Math.sin(routeAngle));
      torso.rotation.x = active && !walking ? 0.065 : 0;
      torso.rotation.z = walking ? Math.sin(cadence) * 0.021 * walk : 0;
      head.rotation.x = active && !walking ? 0.12 + work * 0.025 : 0;
      head.rotation.y = active && !walking ? Math.sin(phase * 0.75) * 0.11 : 0;
      for (const { hip, knee, ankle, side } of legs) {
        const cycle = ((cadence + (side === 1 ? Math.PI : 0)) % (Math.PI * 2) + Math.PI * 2) % (Math.PI * 2);
        const fraction = cycle / (Math.PI * 2), swing = fraction < 0.5;
        const progress = swing ? fraction * 2 : (fraction - 0.5) * 2;
        const eased = progress * progress * (3 - 2 * progress);
        const z = (swing ? -0.023 + 0.046 * eased : 0.023 - 0.046 * progress) * walk;
        const lift = (swing ? Math.sin(progress * Math.PI) * 0.023 : 0) * walk;
        const drop = HIP_HEIGHT - ANKLE_HEIGHT - lift;
        const reach = Math.min(LEG_LENGTH * 2, Math.hypot(drop, z));
        const halfBend = Math.acos(reach / (LEG_LENGTH * 2));
        hip.rotation.x = Math.atan2(-z, drop) - halfBend;
        knee.rotation.x = halfBend * 2;
        ankle.rotation.x = -hip.rotation.x - knee.rotation.x;
      }
      for (const { shoulder, elbow, side } of arms) {
        shoulder.rotation.z = side * 0.035;
        shoulder.rotation.x = walking ? Math.sin(cadence + (side === 1 ? Math.PI : 0)) * 0.28 * walk : active ? -0.42 + (side === 1 ? work * 0.2 : 0) : -0.07;
        elbow.rotation.x = walking ? -0.08 : active ? -0.42 + (side === 1 ? work * 0.18 : 0) : -0.12;
      }
    });
  });

  let disposed = false;
  const animate = (working: boolean, time: number, reducedMotion: boolean): void => {
    if (disposed) return;
    const seconds = Number.isFinite(time) ? time : 0;
    for (const performer of performers) performer(working, seconds, reducedMotion);
  };
  root.onDisposeObservable.addOnce(() => {
    disposed = true;
    for (const mesh of liveMeshes) if (!mesh.isDisposed()) shadow.removeShadowCaster(mesh, false);
    if (--shared.users === 0) {
      for (const material of Object.values(shared.palette)) material.dispose();
      for (const geometry of shared.geometries.values()) if (!geometry.isDisposed()) geometry.dispose();
      sharedByScene.delete(scene);
    }
  });
  animate(false, 0, true);
  return { root, count: variants.length, variants, animate, dispose: () => root.dispose() };
}
